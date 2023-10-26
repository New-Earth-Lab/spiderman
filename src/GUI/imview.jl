using AstroImages
using Statistics
using FFTW

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

function gui_panel(::Type{ImageViewer}, component_config; ischild=false, child_size=(380,300))

    browser = nothing
    image_path = nothing
    image = nothing
    slice_position = [1,1,1,1]
    buffer = nothing
    buffer_changed = false
    image_headers = nothing
    err_msg = nothing

    cmin = Ref{Cfloat}(0)
    cmax = Ref{Cfloat}(1000)

    iscbdrag = false
    cbdrag_cmin = cmin[]
    cbdrag_cmax = cmax[]
    # cmap = LibCImPlot.ImPlotColormap_Plasma
    cmap = ImPlot.ImPlotColormap_Plasma
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
            newimage = view(newimage, :, reverse(axes(newimage,2)), [(:) for _ in axes(newimage)[3:end]]...)
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
                        buffer = parent(image)[:,:,slice_position...]
                        image_headers = header(image)
                    else
                        buffer = image[:,:,slice_position...]
                    end
                    if eltype(buffer) ∉ (Cfloat, Cdouble)
                        buffer = Cfloat.(buffer)
                    end
                elseif action == "-"
                    try
                        image .-= newimage
                    catch err
                        err_msg = string(err)
                    end
                    buffer .= image[:,:,slice_position...]
                elseif action == "+"
                    try
                        image .+= newimage
                    catch err
                        err_msg = string(err)
                    end
                    buffer .= image[:,:,slice_position...]
                elseif action == "*"
                    try
                        image .*= newimage
                    catch err
                        err_msg = string(err)
                    end
                    buffer .= image[:,:,slice_position...]
                elseif action == "/"
                    try
                        image ./= newimage
                    catch err
                        err_msg = string(err)
                    end
                    buffer .= image[:,:,slice_position...]
                else
                    error("Unsupported operation $action")
                end
                setconfig(component_config, "input", image)
                buffer[.! isfinite.(buffer)] .= 0
                if buffer_changed                
                    # Default color limits. Try to take them from the full cube is it's reasonably sized, this is nicer.
                    if length(image) == 0
                        cmin[]=cmax[]=0
                    elseif length(image) < 256^3 && all(isfinite, image)
                        cmin[], cmax[] = quantile(vec(image), (0.0001, 0.9999))
                    else
                        cmin[], cmax[] = quantile(vec(buffer), (0.0001, 0.9999))
                    end
                    if cmin[] == cmax[] 
                        cmin[]=0
                        cmax[]=1
                    end
                end
            end
            CImGui.SetNextWindowFocus()
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
                    ds9show(image)
                end
                CImGui.EndMenu()
            end
            if CImGui.BeginMenu("Scale")
                if !isnothing(buffer)
                    if CImGui.MenuItem("100%")
                        cmin[], cmax[] = extrema(buffer)
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
                        cmap = cmapkey
                    end
                end
                CImGui.EndMenu()
            end
            if !ischild && CImGui.BeginMenu("Transform")
                CImGui.Text("(disables live updates)")
                if CImGui.MenuItem("FFT") && !isnothing(buffer)
                    image = abs.(fftshift(fft(image,(1,2)),(1,2)))
                    buffer .= image[:,:,slice_position...]
                    buffer[.! isfinite.(buffer)] .= 0
                    cmin[], cmax[] = quantile(vec(buffer), (0.0001, 0.9999))
                end
                if CImGui.MenuItem("asinh") && !isnothing(buffer)
                    if minimum(image) <= 0
                        image = image .- minimum(image)
                    end
                    image = asinh.(image)
                    buffer .= image[:,:,slice_position...]
                    buffer[.! isfinite.(buffer)] .= 0
                    cmin[], cmax[] = quantile(vec(buffer), (0.0001, 0.9999))
                end
                if CImGui.MenuItem("log10") && !isnothing(buffer)
                    if minimum(image) <= 0
                        image = image .- minimum(image)
                    end
                    image = log10.(image)
                    buffer .= image[:,:,slice_position...]
                    buffer[.! isfinite.(buffer)] .= 0
                    cmin[], cmax[] = quantile(vec(buffer), (0.0001, 0.9999))
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

        w = CImGui.GetWindowWidth()-100
        h = CImGui.GetWindowHeight()-130 - 30*(length(axes(image))-2)
        if ischild 
            h += 50
        end
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
        if axis_changed || myhash(vec(image)) != hash_loaded
            buffer .= image[:,:,slice_position...]
            buffer[.! isfinite.(buffer)] .= 0
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
            if buffer_changed
                axis_cond = ImGuiCond_Always
            else
                axis_cond = ImGuiCond_Once
            end
            ImPlot.SetupAxis(ImPlot.ImAxis_X1, "")
            ImPlot.SetupAxis(ImPlot.ImAxis_Y1, "")
            ImPlot.SetupAxisLimits(ImPlot.ImAxis_X1, 0.0, float(size(buffer,1)), axis_cond)
            ImPlot.SetupAxisLimits(ImPlot.ImAxis_Y1, 0.0, float(size(buffer,2)), axis_cond)
            # ImPlot.PlotHeatmap(vec(actuator_nm),reverse(size(actuator_nm))...,-scale_amount[],scale_amount[]; label_fmt=C_NULL)
            ImPlot.SetupFinish()


            ImPlot.PushColormap(cmap)
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
        ImPlot.ColormapScale("##cmap", cmin[], cmax[], ImVec2(80,h), "%g", ImPlot.ImPlotColormapScaleFlags_None, cmap);

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
        max(1,round(Int,size(image,2)-plotquery.ymax+1)):min(size(image,2), round(Int,size(image,2)-plotquery.ymin)),
        slice_position...
    ]
end