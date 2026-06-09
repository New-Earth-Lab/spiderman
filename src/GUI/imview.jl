using AstroImages
using Statistics
using FFTW

# Transform registry: Vector of (name, function) tuples
# Each function takes an array and returns a transformed array
# Easy to extend: just add new (name, function) tuples
const AVAILABLE_TRANSFORMS = [
    ("FFT (spatial)",  img -> abs.(fftshift(fft(img, (1,2)), (1,2)))),
    ("FFT (temporal)", img -> abs.(fftshift(fft(img, (3,)), (3,)))),
    ("log10",          img -> log10.(max.(img .- minimum(img), 1e-10))),
    ("asinh",          img -> asinh.(img .- minimum(img))),
    ("sqrt",           img -> sqrt.(max.(img .- minimum(img), 0))),
    # ("normalize",      img -> (img .- mean(img)) ./ max(std(img), 1e-10)),
]

# Helper to look up transform by name
function get_transform(name::String)
    for (n, f) in AVAILABLE_TRANSFORMS
        n == name && return f
    end
    return nothing
end

# Apply a pipeline of transforms in order
function apply_transform_pipeline(img, transform_names::Vector{String})
    if isempty(transform_names)
        return img
    end
    result = copy(img)
    for name in transform_names
        f = get_transform(name)
        if !isnothing(f)
            try
                result = f(result)
            catch e
                @warn "Transform $name failed" exception=e
            end
        end
    end
    result[.!isfinite.(result)] .= 0
    return result
end

mutable struct ImageViewer
    # Set these to load data on next render
    new_contents
    new_action
    new_name
    
    name
end
ImageViewer(conf) = ImageViewer(nothing,nothing,nothing,conf["name"])
name(iv::ImageViewer) = iv.name


_viewer_lock = ReentrantLock()

# Shared state for synced viewer groups (colorscale, zoom/pan, mask, transforms, averaging)
mutable struct SyncGroupState
    # Colorscale
    cmin::Ref{Cfloat}
    cmax::Ref{Cfloat}
    cmap::Ref{Int32}
    # Plot limits (zoom/pan)
    xlim_min::Ref{Cdouble}
    xlim_max::Ref{Cdouble}
    ylim_min::Ref{Cdouble}
    ylim_max::Ref{Cdouble}
    limits_initialized::Ref{Bool}
    # Mask state
    selected_mask_idx::Ref{Cint}
    mask_alpha::Ref{Cfloat}
    current_mask::Ref{Any}  # BitMatrix or nothing
    # Transform pipeline (ordered list of transform names)
    active_transforms::Ref{Vector{String}}
    # Averaging settings
    averaging_enabled::Ref{Bool}
    averaging_count::Ref{Cint}      # target frames (e.g., 100)
    averaging_progress::Ref{Cint}   # current accumulated frames (for display)
end

const _sync_groups = Dict{String, SyncGroupState}()
const _sync_lock = ReentrantLock()

function get_sync_group_state(group_name::String)
    @lock _sync_lock begin
        if !haskey(_sync_groups, group_name)
            _sync_groups[group_name] = SyncGroupState(
                Ref{Cfloat}(0),           # cmin
                Ref{Cfloat}(1000),        # cmax
                Ref{Int32}(ImPlot.ImPlotColormap_Plasma),  # cmap
                Ref{Cdouble}(0.0),        # xlim_min
                Ref{Cdouble}(1.0),        # xlim_max
                Ref{Cdouble}(0.0),        # ylim_min
                Ref{Cdouble}(1.0),        # ylim_max
                Ref{Bool}(false),         # limits_initialized
                Ref{Cint}(0),             # selected_mask_idx
                Ref{Cfloat}(0.3),         # mask_alpha
                Ref{Any}(nothing),        # current_mask
                Ref{Vector{String}}(String[]),  # active_transforms (empty pipeline)
                Ref{Bool}(false),         # averaging_enabled
                Ref{Cint}(100),           # averaging_count (default 100 frames)
                Ref{Cint}(0),             # averaging_progress
            )
        end
        return _sync_groups[group_name]
    end
end

# Function for sending images to the image viewer panel, if open.
# Sends to the first image viewer if multiple are open.
function imviewgui(path_or_arr; action="=", name="buffer")
    viewers = activecomponents(ImageViewer)
    if length(viewers) < 1
        error("No open image viewers (check config.toml and run labgui())")
    end
    @lock _viewer_lock begin
        viewer = first(viewers)
        viewer.new_contents = path_or_arr
        viewer.new_action = action
        viewer.new_name = name
        showcomponent(SpiderMan.name(viewer))
    end
    return nothing
end
export imviewgui

# Super speedy "hash" function to detect if contents have changed.
function myhash(buffer)
    if isnothing(buffer)
        objectid(buffer)
    elseif length(buffer) == 1
        sum(objectid(buffer) .* buffer)
    else
        objectid(buffer) * std(buffer[range(start=begin,stop=end,step=max(1,round(Int, end÷100)))])
    end
end

# Load a mask file from disk. Returns a BitMatrix or nothing on error.
function load_mask_file(filepath::AbstractString)
    try
        @info "Loading mask file" filepath
        di = load(filepath, :)
        di = filter(i -> i isa AbstractArray, di)
        if isempty(di)
            @warn "No array data found in mask file" filepath
            return nothing
        end
        mask_data = parent(first(di))
        # Convert to BitMatrix if not already boolean
        if eltype(mask_data) <: Bool
            return BitMatrix(mask_data)
        else
            # Assume nonzero values are "masked" (true)
            return BitMatrix(mask_data .!= 0)
        end
    catch err
        @error "Failed to load mask file" filepath exception=(err, catch_backtrace())
        return nothing
    end
end

function gui_panel(::Type{ImageViewer}, component_config; ischild=false, child_size=(380,300))

    browser = nothing
    image_path = nothing
    image = nothing
    slice_position = [1,1,1,1]
    buffer = nothing
    buffer_changed = false
    image_headers = nothing
    err_msg = nothing

    # Sync group support - share colorscale, zoom/pan, and mask between viewers
    sync_group_name = get(component_config, "colorscale-sync-group", nothing)
    sync_state = !isnothing(sync_group_name) ? get_sync_group_state(sync_group_name) : nothing

    if !isnothing(sync_state)
        cmin = sync_state.cmin
        cmax = sync_state.cmax
        cmap_ref = sync_state.cmap
        selected_mask_idx = sync_state.selected_mask_idx
        mask_alpha = sync_state.mask_alpha
        active_transforms = sync_state.active_transforms
    else
        cmin = Ref{Cfloat}(0)
        cmax = Ref{Cfloat}(1000)
        cmap_ref = Ref{Int32}(ImPlot.ImPlotColormap_Plasma)
        selected_mask_idx = Ref{Cint}(0)  # 0 = None
        mask_alpha = Ref{Cfloat}(0.3f0)
        active_transforms = Ref{Vector{String}}(String[])
    end

    # Mask overlay state
    mask_files = get(component_config, "mask-files", String[])
    mask_file_labels = vcat(["None"], [basename(f) for f in mask_files])
    # Local mask cache - synced viewers share via sync_state.current_mask
    local_current_mask = nothing

    iscbdrag = false
    cbdrag_cmin = cmin[]
    cbdrag_cmax = cmax[]
    # cbdrag_initial_limits = ImPlot.GetPlotLimits()
    wasmousedown = false
    cmaps = [
        (ImPlot.ImPlotColormap_BrBG, "BrBG"),
        (ImPlot.ImPlotColormap_Cool, "Cool"),
        # (ImPlot.ImPlotColormap_Dark, "Dark"),
        # (ImPlot.ImPlotColormap_Deep, "Deep"),
        (ImPlot.ImPlotColormap_Greys, "Greys"),
        (ImPlot.ImPlotColormap_Hot, "Hot"),
        (ImPlot.ImPlotColormap_Jet, "Jet"),
        # (ImPlot.ImPlotColormap_Paired, "Paired"),
        # (ImPlot.ImPlotColormap_Pastel, "Pastel"),
        (ImPlot.ImPlotColormap_Pink, "Pink"),
        (ImPlot.ImPlotColormap_PiYG, "PiYG"),
        (ImPlot.ImPlotColormap_Plasma, "Plasma (default)"),
        (ImPlot.ImPlotColormap_RdBu, "RdBu"),
        (ImPlot.ImPlotColormap_Spectral, "Spectral"),
        (ImPlot.ImPlotColormap_Twilight, "Twilight"),
        (ImPlot.ImPlotColormap_Viridis, "Viridis"),
    ]

    plotquery = nothing
    show_query_statistics = false

    hash_loaded = myhash(0)
    prev_transforms = String[]  # Track previous transform pipeline for change detection

    function draw(component, visible)
        local send_input, send_action, send_name
        @lock _viewer_lock begin
            send_input = component.new_contents
            send_action = component.new_action
            send_name = component.new_name
            if !isnothing(component.new_contents)
                component.new_contents = nothing
                component.new_action = nothing
                component.new_name = nothing
            end
        end

        if isnothing(send_input) && haskey(component_config, "input") && isnothing(image)
            send_input = component_config["input"]
            send_action = "="
            send_name = "restored"
            @info "Restoring buffer to image viewer" name = name(component)
        end

        buffer_changed = false
        
        new_file = nothing
        action = nothing
        newimage = nothing
        if !isnothing(browser)
            shouldclose, new_file, action = browser()
            if shouldclose
                browser = nothing
            end
        end
        if typeof(send_input) <: AbstractString
            new_file = send_input
            action = send_action
        elseif typeof(send_input) <: AbstractArray
            newimage = send_input
            action = send_action
            image_path = send_name
        end
        if !isnothing(new_file)
            @info "Loading new file in image viewer" new_file
            image_path = new_file
            di = load(image_path,:)
            di = filter(i->i isa AbstractArray, di)
            image_headers = header(first(di))
            images = parent.(di)
            if length(images) == 1
                newimage = only(images)
            else
                @info "Stacking multi-extension cube"   
                newimage = cat(images...,dims=length(size(first(images)))+1)
            end
        end
        if !isnothing(newimage)
            hash_loaded = myhash(image)
            if length(size(newimage)) > 6
                @error "Cubes with more than 6 dimensions are not supported. (This is crazy!)"
                newimage = nothing
                image_path = nothing
            else
                # if size(newimage,1) > 257 || size(newimage,2) > 257
                #     @warn "Image with dimensions larger than 256 are currently not supported (plotting library too slow). The upcomging version shoudl remove this limitation" size(newimage)
                #     @warn "Cropping"
                #     mx = size(newimage,1)÷2
                #     my = size(newimage,2)÷2
                #     if length(size(newimage)) > 2
                #         ax = axes(newimage)[3:end]
                #         newimage = newimage[max(1,mx-128):min(end,mx+128),max(1,my-128):min(end,my+128),ax...]
                #     else
                #         newimage = newimage[max(1,mx-128):min(end,mx+128),max(1,my-128):min(end,my+128)]
                #     end
                # end
                if action == "=" || isnothing(image)
                    if isnothing(image) || size(image) != size(newimage)
                        # Reset colour limits and zoom if and only if the new image has different dimensions.
                        buffer_changed = true
                        @info "new dimensions" isnothing(image)
                    end
                    image = newimage
                    try
                        image[:,:,slice_position...]
                    catch
                        slice_position = [1,1,1,1]
                    end
                    if typeof(image) <: AstroImage
                        raw_slice = parent(image)[:,:,slice_position...]
                        image_headers = header(image)
                    else
                        raw_slice = image[:,:,slice_position...]
                    end
                    if eltype(raw_slice) ∉ (Cfloat, Cdouble)
                        raw_slice = Cfloat.(raw_slice)
                    end
                    # Apply transform pipeline (live transforms)
                    buffer = apply_transform_pipeline(raw_slice, active_transforms[])
                elseif action == "-"
                    try
                        image .-= newimage
                    catch err
                        err_msg = string(err)
                    end
                    raw_slice = Float32.(image[:,:,slice_position...])
                    buffer .= apply_transform_pipeline(raw_slice, active_transforms[])
                elseif action == "+"
                    try
                        image .+= newimage
                    catch err
                        err_msg = string(err)
                    end
                    raw_slice = Float32.(image[:,:,slice_position...])
                    buffer .= apply_transform_pipeline(raw_slice, active_transforms[])
                elseif action == "*"
                    try
                        image .*= newimage
                    catch err
                        err_msg = string(err)
                    end
                    raw_slice = Float32.(image[:,:,slice_position...])
                    buffer .= apply_transform_pipeline(raw_slice, active_transforms[])
                elseif action == "/"
                    try
                        image ./= newimage
                    catch err
                        err_msg = string(err)
                    end
                    raw_slice = Float32.(image[:,:,slice_position...])
                    buffer .= apply_transform_pipeline(raw_slice, active_transforms[])
                else
                    error("Unsupported operation $action")
                end
                setconfig(component_config, "input", image)
                # Note: apply_transform_pipeline already handles non-finite values
                if buffer_changed
                    # Default color limits.
                    # Skip the first 4 (linear-indexed) pixels: some cameras encode the
                    # frame number / camera status there, which otherwise skews the limits.
                    if length(image) == 0
                        cmin[]=cmax[]=0
                    elseif !isempty(active_transforms[])
                        # When transforms are active, use the transformed buffer for color limits
                        cmin[], cmax[] = quantile(@view(buffer[5:end]), (0.0001, 0.9999))
                    elseif length(image) < 256^3 && all(isfinite, image)
                        # For small cubes without transforms, use full cube for nicer limits
                        cmin[], cmax[] = quantile(@view(image[5:end]), (0.0001, 0.9999))
                    else
                        cmin[], cmax[] = quantile(@view(buffer[5:end]), (0.0001, 0.9999))
                    end
                    if cmin[] == cmax[]
                        cmin[]=0
                        cmax[]=1
                    end
                end
            end
            # CImGui.SetNextWindowFocus()
        end
        

        if ischild
            if !CImGui.BeginChild(component_config["name"], child_size, true, ImGuiWindowFlags_MenuBar | ImGuiWindowFlags_NoScrollbar)
                CImGui.EndChild()
                return
            end
        else
            CImGui.SetNextWindowSize((350,350), CImGui.ImGuiCond_FirstUseEver)
            CImGui.SetNextWindowSizeConstraints(ImVec2(300,300), ImVec2(1920,1080), winsizecallback_c)
            if !CImGui.Begin(component_config["name"], visible, ImGuiWindowFlags_MenuBar | ImGuiWindowFlags_NoScrollbar)
                return
            end
        end

        # Power and connect buttons are in the menu bar
        if CImGui.BeginMenuBar()
            if CImGui.BeginMenu("File")
                if !ischild && CImGui.MenuItem("Open...")
                    browser = filebrowse(r"\.fits|.fits.gz$",name=component_config["name"])
                end
                if CImGui.MenuItem("Send to DS9")
                    ds9show(buffer)
                end
                CImGui.EndMenu()
            end
            if CImGui.BeginMenu("Scale")
                if !isnothing(buffer)
                    if CImGui.MenuItem("100%")
                        # Skip the first 4 pixels (frame counter / camera status on some cameras)
                        cmin[], cmax[] = extrema(@view(buffer[5:end]))
                    end
                    if CImGui.MenuItem("99.99% (default)")
                        cmin[], cmax[] = quantile(@view(buffer[5:end]), (0.0001, 0.9999))
                    end
                    if CImGui.MenuItem("99.9%")
                        cmin[], cmax[] = quantile(@view(buffer[5:end]), (0.001, 0.999))
                    end
                    if CImGui.MenuItem("99%")
                        cmin[], cmax[] = quantile(@view(buffer[5:end]), (0.01, 0.99))
                    end
                    if CImGui.MenuItem("95%")
                        cmin[], cmax[] = quantile(@view(buffer[5:end]), (0.05, 0.95))
                    end
                    if CImGui.MenuItem("90%")
                        cmin[], cmax[] = quantile(@view(buffer[5:end]), (0.1, 0.90))
                    end
                    if CImGui.MenuItem("70%")
                        cmin[], cmax[] = quantile(@view(buffer[5:end]), (0.3, 0.70))
                    end
                    if CImGui.MenuItem("60%")
                        cmin[], cmax[] = quantile(@view(buffer[5:end]), (0.4, 0.60))
                    end
                    if cmin[] == cmax[] 
                        cmin[]=0
                        cmax[]=1
                    end
                else
                    CImGui.MenuItem("Waiting for buffer")
                end
                CImGui.EndMenu()
            end
            if CImGui.BeginMenu("Colour")
                for (cmapkey, cmapname) in cmaps
                    if CImGui.MenuItem(cmapname)
                        cmap_ref[] = cmapkey
                    end
                end
                CImGui.EndMenu()
            end
            if CImGui.BeginMenu("Transform")
                # Show current pipeline
                pipeline_str = isempty(active_transforms[]) ? "(none)" : join(active_transforms[], " -> ")
                CImGui.Text("Pipeline: $pipeline_str")
                CImGui.SameLine()
                if CImGui.SmallButton("Clear") && !isempty(active_transforms[])
                    active_transforms[] = String[]
                    # Recalculate color limits after clearing (skip first 4 status pixels)
                    if !isnothing(buffer) && length(buffer) > 0
                        cmin[], cmax[] = quantile(@view(buffer[5:end]), (0.0001, 0.9999))
                    end
                end
                CImGui.Separator()
                CImGui.Text("Add transform:")
                # Buttons to add each transform
                for (tname, _) in AVAILABLE_TRANSFORMS
                    if CImGui.MenuItem("+ $tname")
                        active_transforms[] = vcat(active_transforms[], tname)
                        # Recalculate color limits after adding transform
                        if !isnothing(image)
                            slice = image[:,:,slice_position...]
                            transformed = apply_transform_pipeline(Float32.(slice), active_transforms[])
                            # Skip first 4 status pixels when computing limits
                            cmin[], cmax[] = quantile(@view(transformed[5:end]), (0.0001, 0.9999))
                        end
                    end
                end
                CImGui.EndMenu()
            end
            if !isempty(mask_files) && CImGui.BeginMenu("Mask")
                # Combo box for mask selection - reloads from disk each time
                prev_idx = selected_mask_idx[]
                if CImGui.BeginCombo("##mask_combo", mask_file_labels[selected_mask_idx[] + 1])
                    for (i, label) in enumerate(mask_file_labels)
                        is_selected = (i - 1) == selected_mask_idx[]
                        if CImGui.Selectable(label, is_selected)
                            selected_mask_idx[] = i - 1
                        end
                        if is_selected
                            CImGui.SetItemDefaultFocus()
                        end
                    end
                    CImGui.EndCombo()
                end
                # Reload mask if selection changed (or reload button pressed)
                mask_changed = prev_idx != selected_mask_idx[]
                CImGui.SameLine()
                if CImGui.SmallButton("Reload") || mask_changed
                    if selected_mask_idx[] == 0
                        local_current_mask = nothing
                    else
                        local_current_mask = load_mask_file(mask_files[selected_mask_idx[]])
                    end
                    # Sync mask to group if synced
                    if !isnothing(sync_state)
                        sync_state.current_mask[] = local_current_mask
                    end
                end
                CImGui.SliderFloat("Opacity", mask_alpha, 0.0f0, 1.0f0)
                # Show mask dimensions if loaded
                active_mask = !isnothing(sync_state) ? sync_state.current_mask[] : local_current_mask
                if !isnothing(active_mask)
                    CImGui.Text("Mask size: $(size(active_mask))")
                    if !isnothing(buffer) && size(active_mask) != size(buffer)
                        CImGui.TextColored(ImVec4(1,1,0,1), "Warning: size mismatch with image")
                    end
                end
                CImGui.EndMenu()
            end
            if CImGui.BeginMenu("Query Region")
                pq = Ref(!isnothing(plotquery))
                if CImGui.Checkbox("Show region",pq)
                    if pq[] && !isnothing(image)
                        plotquery = (
                            xmin = mean(axes(image, 1))*0.8,
                            xmax = mean(axes(image, 1))*1.2,
                            ymin = mean(axes(image, 2))*0.8,
                            ymax = mean(axes(image, 2))*1.2,
                        )
                    else
                        plotquery = nothing
                    end
                end
                pq = Ref(show_query_statistics)
                if CImGui.Checkbox("Show statistics",pq)  && !isnothing(plotquery)
                    show_query_statistics = pq[]
                end 
                if CImGui.MenuItem("Send cutout to main viewer") && !isnothing(plotquery)
                    queryregion = queryview(image, plotquery, slice_position)
                    imviewgui(queryregion, name="cutout")
                end
                if CImGui.MenuItem("Send all to main viewer") && !isnothing(plotquery)
                    imviewgui(image, name="cutout")
                end
                CImGui.EndMenu()
            end
            CImGui.EndMenuBar()
        end

        if isnothing(image) || isnothing(buffer)            
            ischild ? CImGui.EndChild() : CImGui.End()
            return
        end
        if !ischild
            CImGui.Text(image_path * " "* string(size(image)))
        end

        if !isnothing(err_msg)
            CImGui.TextColored(bad_color, "ERROR:")
            CImGui.SameLine();
            CImGui.TextWrapped(err_msg)
            if CImGui.Button("Clear") 
                err_msg = nothing
            end
        end

        w = CImGui.GetWindowWidth()-50
        h = CImGui.GetWindowHeight()-30 - 30*(length(axes(image))-2)
        # if ischild 
        #     h += 50
        # end
        # h = CImGui.GetWindowContentRegionWidth()/size(image,1)*size(image,2)
        plotsize = ImVec2(w,h)

        CImGui.PushItemWidth(-80)
        # Slice sliders if more than 2D
        axis_changed = false
        if length(size(image)) > 2
            for slicenum in 3:length(size(image))
                l = size(image,slicenum)
                axis_changed |= CImGui.SliderInt("Axis $slicenum", pointer(slice_position, slicenum-2), 1, l)
            end
        end
        # Check if transforms changed
        transforms_changed = active_transforms[] != prev_transforms
        if transforms_changed
            prev_transforms = copy(active_transforms[])
        end
        # Update buffer when image/axis/transforms change
        if axis_changed || myhash(vec(image)) != hash_loaded || transforms_changed
            raw_slice = Float32.(image[:,:,slice_position...])
            buffer .= apply_transform_pipeline(raw_slice, active_transforms[])
            # Recalculate color limits if transforms changed (skip first 4 status pixels)
            if transforms_changed && length(buffer) > 0
                cmin[], cmax[] = quantile(@view(buffer[5:end]), (0.0001, 0.9999))
                if cmin[] == cmax[]
                    cmin[] = 0
                    cmax[] = 1
                end
            end
        end
        CImGui.PopItemWidth()

        # ImPlot.SetNextPlotLimits(0,size(buffer,1),0,size(buffer,2),buffer_changed ? ImGuiCond_Always : ImGuiCond_Once)
        
        bounds_min = ImPlot.ImPlotPoint(0.0,0.0)
        bounds_max = ImPlot.ImPlotPoint(size(buffer)...)
        plot_flags = ImPlot.ImPlotFlags_Equal  | ImPlot.ImPlotFlags_Crosshairs
        winhovered = CImGui.IsWindowHovered() # must be before beginplot

        if ImPlot.BeginPlot(
            "", "", "",plotsize, 
            flags=ImPlot.ImPlotFlags(plot_flags),
            # x_flags=ImPlot.ImPlotAxisFlags(ImPlot.ImPlotAxisFlags_NoLabel),#ImPlot.ImPlotAxisFlags_None|ImPlot.ImPlotAxisFlags_NoDecorations),
            # y_flags=ImPlot.ImPlotAxisFlags(ImPlot.ImPlotAxisFlags_NoLabel)
        )
            over_cb = winhovered && 
                CImGui.GetMousePos().x - CImGui.GetWindowPos().x > w &&
                20 < CImGui.GetMousePos().y - CImGui.GetWindowPos().y < h
            # Handle color scale interaction
            if over_cb && !ImPlot.IsPlotHovered() && CImGui.IsMouseDown(0) && !iscbdrag
                iscbdrag = true
                cbdrag_cmin = cmin[]
                cbdrag_cmax = cmax[]
            end
            if !CImGui.IsMouseDragging(0) || CImGui.IsMouseReleased(0)
                iscbdrag = false
            end
            if CImGui.IsMouseDragging(0) && iscbdrag
                # Todo: need to track start event, do color updates since the start not keep updating

                # @show ImPlot.LibCImPlot.GetPlotMousePos(0)
                delta = CImGui.GetMouseDragDelta(0)
                dx  = delta.y
                dy  = delta.x
                # Account for contrast scaling and offset scaling
                stepscale = 2*abs(cbdrag_cmax - cbdrag_cmin)/CImGui.GetWindowHeight()

                startval = cbdrag_cmin + dx*stepscale
                endval = cbdrag_cmax + dx*stepscale
            
                contrast = (endval - startval)
                midpoint = (startval + endval)/2
                contrast -= dy*stepscale
                startval = midpoint - contrast/2
                endval = midpoint + contrast/2

                cmin[] = max(startval, nextfloat(typemin(Cfloat)))
                cmax[] = min(endval, prevfloat(typemax(Cfloat)))

    
            end

            axis_flags = ImPlot.ImPlotAxisFlags_NoLabel | ImPlot.ImPlotAxisFlags_AutoFit
            ImPlot.SetupAxis(ImPlot.ImAxis_X1, "")
            ImPlot.SetupAxis(ImPlot.ImAxis_Y1, "")

            # Axis limits - use linked limits for synced plots
            if !isnothing(sync_state)
                # Initialize limits on first use or buffer change
                if !sync_state.limits_initialized[] || buffer_changed
                    sync_state.xlim_min[] = 0.0
                    sync_state.xlim_max[] = float(size(buffer,1))
                    sync_state.ylim_min[] = 0.0
                    sync_state.ylim_max[] = float(size(buffer,2))
                    sync_state.limits_initialized[] = true
                end
                # Link axes to shared Refs - ImPlot updates these directly on pan/zoom
                ImPlot.SetupAxisLinks(ImPlot.ImAxis_X1, sync_state.xlim_min, sync_state.xlim_max)
                ImPlot.SetupAxisLinks(ImPlot.ImAxis_Y1, sync_state.ylim_min, sync_state.ylim_max)
            elseif buffer_changed
                ImPlot.SetupAxisLimits(ImPlot.ImAxis_X1, 0.0, float(size(buffer,1)), ImGuiCond_Always)
                ImPlot.SetupAxisLimits(ImPlot.ImAxis_Y1, 0.0, float(size(buffer,2)), ImGuiCond_Always)
            else
                ImPlot.SetupAxisLimits(ImPlot.ImAxis_X1, 0.0, float(size(buffer,1)), ImGuiCond_Once)
                ImPlot.SetupAxisLimits(ImPlot.ImAxis_Y1, 0.0, float(size(buffer,2)), ImGuiCond_Once)
            end
            ImPlot.SetupFinish()

            # Get active mask (synced or local)
            active_mask = !isnothing(sync_state) ? sync_state.current_mask[] : local_current_mask

            # Mask overlay rendering - apply before plotting
            # Blend mask into buffer display: masked pixels get pushed toward cmin (dark)
            if !isnothing(active_mask) && mask_alpha[] > 0 && size(active_mask) == size(buffer)
                blend = mask_alpha[]
                cmin_val = cmin[]
                @inbounds for i in eachindex(buffer)
                    if !active_mask[i]
                        buffer[i] = buffer[i] * (1 - blend) + cmin_val * blend
                    end
                end
            end

            ImPlot.PushColormap(cmap_ref[])
            ImPlot.PlotHeatmap(vec(buffer),reverse(size(buffer))...,cmin[],cmax[]; label_fmt=C_NULL, bounds_min=bounds_min, bounds_max=bounds_max)
            ImPlot.PopColormap()

            if !isnothing(plotquery)

                # User-selectable region for statistics
                xmin = Ref(plotquery.xmin)
                ymin = Ref(plotquery.ymin)
                xmax = Ref(plotquery.xmax)
                ymax = Ref(plotquery.ymax)
                ImPlot.DragRect(0,xmin,ymin,xmax,ymax,ImVec4(1,1,1,1))
                if wasmousedown && !CImGui.IsMouseDown(0) #,flags, &clicked, &hovered, &held);
                    # Make sure bounds adapt to show rounded positions to make it very clear which
                    # pixels are included
                    xmin[] = round(Int, xmin[])
                    xmax[] = round(Int, xmax[])
                    ymax[] = round(Int, ymax[])
                    ymin[] = round(Int, ymin[])
                end

                # Query annotation
                xmin = xmin[]
                ymin = ymin[]
                xmax = xmax[]
                ymax = ymax[]
                if xmin > xmax
                    xmin, xmax = xmax, xmin
                end
                if ymin > ymax
                    ymin, ymax = ymax, ymin
                end
                if abs(xmin - xmax) < 1
                    xmax += 1
                end
                if abs(ymin - ymax) < 1
                    ymax += 1
                end
                plotquery = (;xmin,xmax,ymin,ymax)


                if show_query_statistics
                    queryregion = queryview(image, plotquery, slice_position)
                    # Not working as expected, have to do it manually
                    # ImPlot.Annotation(0.5,0.5,ImVec4(1,1,1,1),ImVec2(0,0),false,)
                    ccall((:ImPlot_Annotation_Str, LibCImGui.libcimgui), Cvoid,
                        (Cdouble, Cdouble, ImVec4, ImVec2, Bool, Cstring),
                        plotquery.xmin, plotquery.ymax, ImVec4(1,1,1,0.75),ImVec2(0,-15), true, show_queryregion_statistics(queryregion))
                end
            end

            ImPlot.EndPlot()
        end
        CImGui.SameLine();
        ImPlot.ColormapScale("##cmap", cmin[], cmax[], ImVec2(20,h), "%g", ImPlot.ImPlotColormapScaleFlags_None, cmap_ref[]);

        CImGui.Text("Left drag colour bar for brightness/contrast.")
        CImGui.Text("Left drag image to pan. Scroll or right-drag image to zoom.")

        ischild ? CImGui.EndChild() : CImGui.End()
        wasmousedown = CImGui.IsMouseDown(0)

        return 
    end
    return draw
end

function show_queryregion_statistics(queryregion)
    if length(queryregion) == 0 
        return "no data"
    end
    qmin, qmax = extrema(queryregion)
    qmean = mean(queryregion)
    qstd = std(queryregion,mean=qmean)
    @sprintf(
        "region statistics\nmin=%3g\nmax=%3g\nmean=%3g\nstd=%3g", qmin, qmax, qmean, qstd
    )
end

function filebrowse(filepattern=r"\.fit|\.fits|\.fit.gz|\.fits.gz$";current_directory=config("general", "data_path"),name="")

    getdir(path) = filter(reverse(readdir(path))) do fname
        perm_allowed = true
        isadir = false
        try
            isadir = isdir(joinpath(current_directory,fname))
        catch
            perm_allowed = false
            isadir = false
        end
        return perm_allowed && isadir || occursin(filepattern, fname)
    end

    current_listing = getdir(current_directory)
    isdirs = isdir.(joinpath.(current_directory, current_listing))
    return function()

        if !CImGui.Begin("Select File##$name")
            return false, nothing, nothing
        end
        CImGui.Text(current_directory)
        CImGui.Text(@sprintf("%d matching entries",length(current_listing))) 
        CImGui.SameLine()
        if CImGui.Button("Up")
            current_directory = joinpath(splitpath(current_directory)[1:max(1,end-1)]...)
            current_listing = getdir(current_directory)
            isdirs = isdir.(joinpath.(current_directory, current_listing))
        end
        CImGui.SameLine()
        if CImGui.Button("Refresh")
            current_listing = getdir(current_directory)
            isdirs = isdir.(joinpath.(current_directory, current_listing))
        end
        CImGui.SameLine()
        if CImGui.Button("Close")
            CImGui.End()
            return true,nothing,nothing
        end
        CImGui.Separator()
        if CImGui.BeginChild("##child-frame", ImVec2(-1,-1))
            for (fname, isadir) in zip(current_listing,isdirs)
                if isadir && CImGui.Button("Browse##"*fname)
                    current_directory = joinpath(current_directory, fname)
                    current_listing = getdir(current_directory)
                    isdirs = isdir.(joinpath.(current_directory, current_listing))
                end
                if !isadir && CImGui.Button("Open##"*fname)
                    return false, joinpath(current_directory,fname),"="
                end
                CImGui.SameLine()
                if !isadir && CImGui.Button("-##"*fname)
                    return false, joinpath(current_directory,fname),"-"
                end
                CImGui.SameLine()
                if !isadir && CImGui.Button("+##"*fname)
                    return false, joinpath(current_directory,fname),"+"
                end
                CImGui.SameLine()
                if !isadir && CImGui.Button("*##"*fname)
                    return false, joinpath(current_directory,fname),"*"
                end
                CImGui.SameLine()
                if !isadir && CImGui.Button("/##"*fname)
                    return false, joinpath(current_directory,fname),"/"
                end
                CImGui.SameLine()
                CImGui.Text(fname)
            end
            CImGui.EndChild()
        end

        CImGui.End()

        return false, nothing,nothing
    end
end



function winsizecallback4(sizedata_ptr)
    data = unsafe_load(sizedata_ptr)
    # data->DesiredSize.x = data->DesiredSize.y = (data->DesiredSize.x > data->DesiredSize.y ? data->DesiredSize.x : data->DesiredSize.y); }
    longest_dim = max(data.DesiredSize.x, data.DesiredSize.y-80)
    newdata = LibCImGui.ImGuiSizeCallbackData(
        data.UserData,
        data.Pos,
        data.CurrentSize,
        ImVec2(longest_dim, longest_dim+80)
    )
    unsafe_store!(sizedata_ptr, newdata)
    return
end
winsizecallback_c = @cfunction(winsizecallback4, Cvoid, (Ptr{LibCImGui.ImGuiSizeCallbackData},))



function queryview(image, plotquery, slice_position)
    return @view image[
        max(1,round(Int,plotquery.xmin+1)):min(size(image,1), round(Int,plotquery.xmax)),
        max(1,round(Int,plotquery.ymin+1)):min(size(image,2), round(Int,plotquery.ymax)),
        slice_position...
    ]
end
