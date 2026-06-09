# SCC Mask Configuration and GUI Panel
# Allows interactive control of SCC mask geometry parameters

using Aeron
using AstroImages
using SpidersMessageSender

# Configuration struct for SCC mask geometry
Base.@kwdef mutable struct SCCMaskConfig
    # Image dimensions and center
    image_width::Int = 640
    image_height::Int = 512
    centre_x::Float64 = 318.0
    centre_y::Float64 = 215.0

    # Camera and wavelength parameters
    wavelength::Float64 = 1.550  # micron
    camera_rot::Float64 = 31.0   # degrees

    # Half dark hole (amplitude correction) mask parameters
    hdh_r_inn::Float64 = 16.0    # inner radius in lambda/D
    hdh_r_out::Float64 = 85.0    # outer radius in lambda/D
    hdh_pa_width::Float64 = 200.0  # position angle width in degrees
    hdh_pa_rot::Float64 = 60.0    # position angle rotation in degrees

    # Full dark hole (phase correction) mask parameters
    fdh_r_inn::Float64 = 16.0    # inner radius in lambda/D
    fdh_r_out::Float64 = 85.0    # outer radius in lambda/D
    fdh_pa_width::Float64 = 360.0  # position angle width in degrees (360 = full circle)
    fdh_pa_rot::Float64 = 150.0   # position angle rotation in degrees
end

# Build a single SCC mask from parameters
function build_scc_mask(;
    centre_x, centre_y, r_inn, r_out, pa_width, pa_rot, camera_rot, axx, axy, wavelength=1.550
)
    # Convert angular parameters to radians
    pa_width_rad = deg2rad(pa_width)
    pa_rot_rad = deg2rad(pa_rot)
    camera_rot_rad = deg2rad(camera_rot)

    # Scale radii by wavelength ratio (reference is 1.550 micron)
    scale = 1.550 / wavelength
    r_inn_scaled = r_inn * scale
    r_out_scaled = r_out * scale

    pa_start = rem2pi(pa_rot_rad - pa_width_rad/2, RoundDown)
    pa_stop = rem2pi(pa_rot_rad + pa_width_rad/2, RoundDown)

    x = axx .- centre_x
    y = axy .- centre_y

    r = sqrt.(x.^2 .+ y'.^2)

    θ = rem2pi.(atan.(y', x), RoundDown)
    θ_rot = rem2pi.(θ .+ camera_rot_rad, RoundDown)
    x_rot = r .* cos.(θ_rot)
    y_rot = r .* sin.(θ_rot)

    # Circular inner + rectangular outer limits
    mask = r .>= r_inn_scaled .&& abs.(x_rot) .< r_out_scaled .&& abs.(y_rot) .< r_out_scaled

    if pa_width < 360.0
        if pa_start < pa_stop
            mask .&= pa_start .<= θ .&& θ .<= pa_stop
        else
            mask .&= pa_start .<= θ .|| θ .<= pa_stop
        end
    end

    if !any(mask)
        @warn "Mask is empty with current parameters"
    end

    return BitMatrix(mask)
end

# Build all SCC masks from a config
function build_all_scc_masks(config::SCCMaskConfig; overall_margin::Int=5)
    axx = 1:config.image_width
    axy = 1:config.image_height

    # Half dark hole mask (amplitude correction)
    mask_hdh = build_scc_mask(;
        centre_x = config.centre_x,
        centre_y = config.centre_y,
        r_inn = config.hdh_r_inn,
        r_out = config.hdh_r_out,
        pa_width = config.hdh_pa_width,
        pa_rot = config.hdh_pa_rot,
        camera_rot = config.camera_rot,
        axx = axx,
        axy = axy,
        wavelength = config.wavelength
    )

    # Full dark hole mask (phase correction)
    mask_fdh = build_scc_mask(;
        centre_x = config.centre_x,
        centre_y = config.centre_y,
        r_inn = config.fdh_r_inn,
        r_out = config.fdh_r_out,
        pa_width = config.fdh_pa_width,
        pa_rot = config.fdh_pa_rot,
        camera_rot = config.camera_rot,
        axx = axx,
        axy = axy,
        wavelength = config.wavelength
    )

    # Overall mask: use full 360° coverage with slightly expanded bounds
    # This ensures mask_overall doesn't change when HDH/FDH angles change
    r_inn_overall = min(config.hdh_r_inn, config.fdh_r_inn) - overall_margin
    r_out_overall = max(config.hdh_r_out, config.fdh_r_out) + overall_margin
    r_inn_overall = max(r_inn_overall, 0.0)  # Don't go negative

    mask_overall = build_scc_mask(;
        centre_x = config.centre_x,
        centre_y = config.centre_y,
        r_inn = r_inn_overall,
        r_out = r_out_overall,
        pa_width = 360.0,  # Full circle - no angular dependence
        pa_rot = 0.0,
        camera_rot = config.camera_rot,
        axx = axx,
        axy = axy,
        wavelength = config.wavelength
    )

    return (;
        mask_hdh,      # amplitude correction mask
        mask_fdh,      # phase correction mask
        mask_overall   # combined mask (with margin, angle-independent)
    )
end

# Save masks to FITS files
function save_scc_masks(masks;
    path_overall = "/mnt/datadrive/DATA/SCC/mask-overall.fits",
    path_phase = "/mnt/datadrive/DATA/SCC/mask-phase-correction.fits",
    path_amplitude = "/mnt/datadrive/DATA/SCC/mask-amplitude-correction.fits"
)
    save(path_phase, UInt8.(masks.mask_fdh))
    save(path_amplitude, UInt8.(masks.mask_hdh))
    save(path_overall, UInt8.(masks.mask_overall))
    @info "Saved SCC masks" path_overall path_phase path_amplitude
    return (path_overall, path_phase, path_amplitude)
end

# Component struct for the GUI panel
mutable struct SCCMaskPanel
    const name::String
    const aeron_event_pub::Union{Nothing, Aeron.AeronPublication}
    const aeron_status_sub::Union{Nothing, Aeron.AeronSubscription}
    const aeron_watch_handle::Union{Nothing, Aeron.AeronWatchHandle}
    status::Dict{Symbol,Any}
    last_heartbeat_time::Base.RefValue{Float64}
    config::SCCMaskConfig
    masks_dirty::Bool  # True if masks need regeneration
end

function SCCMaskPanel(conf)
    # Connect to SCC service for sending mask updates
    aeron_event_pub = nothing
    aeron_status_sub = nothing
    watch_handle = nothing
    status = Dict{Symbol,Any}()
    last_heartbeat_time = Ref(0.0)

    if haskey(conf, "event-channel") && haskey(conf, "event-stream")
        aeron_event_config = AeronConfig(conf["event-channel"], conf["event-stream"])
        aeron_event_pub = Aeron.publisher(aeron, aeron_event_config)
    end

    if haskey(conf, "status-channel") && haskey(conf, "status-stream")
        aeron_status_config = AeronConfig(conf["status-channel"], conf["status-stream"])
        aeron_status_sub = Aeron.subscriber(aeron, aeron_status_config)

        watch_handle = Aeron.watch(aeron_status_sub) do frame
            try
                last_heartbeat_time[] = time()
                event = EventMessage(frame.buffer, initialize=false)
                val = getargument(event)
                if val isa AbstractString
                    val = String(val)
                elseif val isa AbstractArray
                    val = collect(val)
                elseif val isa TensorMessage
                    val = collect(SpidersMessageEncoding.arraydata(val))
                end
                key = Symbol(event.name)
                status[key] = val
            catch err
                @error "Error receiving SCC status" exception=(err, catch_backtrace())
            end
        end

        # Request initial status
        if !isnothing(aeron_event_pub)
            sendevents(aeron_event_pub; StatusRequest=nothing)
        end
    end

    # Initialize config with defaults
    config = SCCMaskConfig()

    # Load any saved config values from conf
    if haskey(conf, "wavelength")
        config.wavelength = Float64(conf["wavelength"])
    end
    if haskey(conf, "camera-rot")
        config.camera_rot = Float64(conf["camera-rot"])
    end
    if haskey(conf, "centre-x")
        config.centre_x = Float64(conf["centre-x"])
    end
    if haskey(conf, "centre-y")
        config.centre_y = Float64(conf["centre-y"])
    end

    return SCCMaskPanel(
        conf["name"],
        aeron_event_pub,
        aeron_status_sub,
        watch_handle,
        status,
        last_heartbeat_time,
        config,
        true  # Start with masks needing generation
    )
end

name(panel::SCCMaskPanel) = panel.name

function gui_panel(::Type{SCCMaskPanel}, component_config)

    err_msg = nothing
    err_msg_timeout = time()
    first_view = true

    # Preview state
    preview_mask = nothing
    preview_dirty = true
    last_preview_time = 0.0

    # File paths
    path_overall = get(component_config, "path-overall", "/mnt/datadrive/DATA/SCC/mask-overall.fits")
    path_phase = get(component_config, "path-phase", "/mnt/datadrive/DATA/SCC/mask-phase-correction.fits")
    path_amplitude = get(component_config, "path-amplitude", "/mnt/datadrive/DATA/SCC/mask-amplitude-correction.fits")

    # Refs for ImGui inputs
    wavelength_ref = Ref{Cfloat}(1.550f0)
    camera_rot_ref = Ref{Cfloat}(31.0f0)
    centre_x_ref = Ref{Cfloat}(318.0f0)
    centre_y_ref = Ref{Cfloat}(215.0f0)

    # HDH (Half Dark Hole) parameters
    hdh_r_inn_ref = Ref{Cfloat}(16.0f0)
    hdh_r_out_ref = Ref{Cfloat}(85.0f0)
    hdh_pa_width_ref = Ref{Cfloat}(200.0f0)
    hdh_pa_rot_ref = Ref{Cfloat}(60.0f0)

    # FDH (Full Dark Hole) parameters
    fdh_r_inn_ref = Ref{Cfloat}(16.0f0)
    fdh_r_out_ref = Ref{Cfloat}(85.0f0)
    fdh_pa_width_ref = Ref{Cfloat}(360.0f0)
    fdh_pa_rot_ref = Ref{Cfloat}(150.0f0)

    # Preview selection (0=overall, 1=phase/fdh, 2=amplitude/hdh)
    preview_type_ref = Ref{Cint}(0)
    preview_labels = ["Overall (combined)", "Phase (FDH)", "Amplitude (HDH)"]

    function update_config_from_refs!(config)
        config.wavelength = wavelength_ref[]
        config.camera_rot = camera_rot_ref[]
        config.centre_x = centre_x_ref[]
        config.centre_y = centre_y_ref[]
        config.hdh_r_inn = hdh_r_inn_ref[]
        config.hdh_r_out = hdh_r_out_ref[]
        config.hdh_pa_width = hdh_pa_width_ref[]
        config.hdh_pa_rot = hdh_pa_rot_ref[]
        config.fdh_r_inn = fdh_r_inn_ref[]
        config.fdh_r_out = fdh_r_out_ref[]
        config.fdh_pa_width = fdh_pa_width_ref[]
        config.fdh_pa_rot = fdh_pa_rot_ref[]
    end

    function update_refs_from_config!(config)
        wavelength_ref[] = config.wavelength
        camera_rot_ref[] = config.camera_rot
        centre_x_ref[] = config.centre_x
        centre_y_ref[] = config.centre_y
        hdh_r_inn_ref[] = config.hdh_r_inn
        hdh_r_out_ref[] = config.hdh_r_out
        hdh_pa_width_ref[] = config.hdh_pa_width
        hdh_pa_rot_ref[] = config.hdh_pa_rot
        fdh_r_inn_ref[] = config.fdh_r_inn
        fdh_r_out_ref[] = config.fdh_r_out
        fdh_pa_width_ref[] = config.fdh_pa_width
        fdh_pa_rot_ref[] = config.fdh_pa_rot
    end

    function draw(panel::SCCMaskPanel, visible)
        CImGui.SetNextWindowSize((450, 650), CImGui.ImGuiCond_FirstUseEver)

        if !CImGui.Begin(component_config["name"], visible)
            CImGui.End()
            return
        end

        if first_view
            update_refs_from_config!(panel.config)
            first_view = false
        end

        # Error display
        if !isnothing(err_msg)
            CImGui.TextColored(bad_color, "ERROR:")
            CImGui.SameLine()
            CImGui.TextWrapped(err_msg)
            if CImGui.Button("Clear##err") || time() > err_msg_timeout
                err_msg = nothing
            end
        end

        # SCC Service status
        inactive = time() - panel.last_heartbeat_time[] > 5
        state = get(panel.status, :state, nothing)

        CImGui.Text("SCC Service: ")
        CImGui.SameLine()
        if isnothing(state)
            CImGui.TextColored(ImVec4(1.0f0, 0.8f0, 0.0f0, 1.0f0), "Unknown")
        elseif inactive
            CImGui.TextColored(ImVec4(1.0f0, 0.8f0, 0.0f0, 1.0f0), "$state (stale)")
        else
            CImGui.TextColored(ImVec4(0.4f0, 0.8f0, 0.4f0, 1.0f0), "$state")
        end

        CImGui.Separator()

        # Global parameters
        CImGui.TextColored(ImVec4(0.7f0, 0.7f0, 1.0f0, 1.0f0), "GLOBAL PARAMETERS")

        changed = false
        CImGui.PushItemWidth(100)

        changed |= CImGui.DragFloat("Wavelength (um)", wavelength_ref, 0.01f0, 0.9f0, 2.5f0, "%.3f")
        changed |= CImGui.DragFloat("Camera Rot (deg)", camera_rot_ref, 0.5f0, -180.0f0, 180.0f0, "%.1f")
        changed |= CImGui.DragFloat("Centre X (px)", centre_x_ref, 1.0f0, 0.0f0, 640.0f0, "%.1f")
        changed |= CImGui.DragFloat("Centre Y (px)", centre_y_ref, 1.0f0, 0.0f0, 512.0f0, "%.1f")

        CImGui.PopItemWidth()
        CImGui.Separator()

        # Half Dark Hole (Amplitude) parameters
        CImGui.TextColored(ImVec4(0.7f0, 0.7f0, 1.0f0, 1.0f0), "HALF DARK HOLE (Amplitude Correction)")
        CImGui.PushItemWidth(100)

        changed |= CImGui.DragFloat("HDH Inner R (l/D)", hdh_r_inn_ref, 0.5f0, 0.0f0, 50.0f0, "%.1f")
        changed |= CImGui.DragFloat("HDH Outer R (l/D)", hdh_r_out_ref, 1.0f0, 10.0f0, 200.0f0, "%.1f")
        changed |= CImGui.DragFloat("HDH PA Width (deg)", hdh_pa_width_ref, 5.0f0, 0.0f0, 360.0f0, "%.1f")

        # Special highlight for the HDH angle control - this is the main feature requested
        CImGui.PushStyleColor(ImGuiCol_FrameBg, ImVec4(0.2f0, 0.3f0, 0.5f0, 1.0f0))
        changed |= CImGui.SliderFloat("HDH PA Angle (deg)", hdh_pa_rot_ref, 0.0f0, 360.0f0, "%.1f")
        CImGui.PopStyleColor()

        # Quick angle presets
        CImGui.Text("HDH Angle Presets:")
        CImGui.SameLine()
        if CImGui.SmallButton("0##hdh")
            hdh_pa_rot_ref[] = 0.0f0
            changed = true
        end
        CImGui.SameLine()
        if CImGui.SmallButton("45##hdh")
            hdh_pa_rot_ref[] = 45.0f0
            changed = true
        end
        CImGui.SameLine()
        if CImGui.SmallButton("60##hdh")
            hdh_pa_rot_ref[] = 60.0f0
            changed = true
        end
        CImGui.SameLine()
        if CImGui.SmallButton("90##hdh")
            hdh_pa_rot_ref[] = 90.0f0
            changed = true
        end
        CImGui.SameLine()
        if CImGui.SmallButton("180##hdh")
            hdh_pa_rot_ref[] = 180.0f0
            changed = true
        end
        CImGui.SameLine()
        if CImGui.SmallButton("270##hdh")
            hdh_pa_rot_ref[] = 270.0f0
            changed = true
        end

        CImGui.PopItemWidth()
        CImGui.Separator()

        # Full Dark Hole (Phase) parameters
        CImGui.TextColored(ImVec4(0.7f0, 0.7f0, 1.0f0, 1.0f0), "FULL DARK HOLE (Phase Correction)")
        CImGui.PushItemWidth(100)

        changed |= CImGui.DragFloat("FDH Inner R (l/D)", fdh_r_inn_ref, 0.5f0, 0.0f0, 50.0f0, "%.1f")
        changed |= CImGui.DragFloat("FDH Outer R (l/D)", fdh_r_out_ref, 1.0f0, 10.0f0, 200.0f0, "%.1f")
        changed |= CImGui.DragFloat("FDH PA Width (deg)", fdh_pa_width_ref, 5.0f0, 0.0f0, 360.0f0, "%.1f")
        changed |= CImGui.SliderFloat("FDH PA Angle (deg)", fdh_pa_rot_ref, 0.0f0, 360.0f0, "%.1f")

        CImGui.PopItemWidth()
        CImGui.Separator()

        # Update config if changed
        if changed
            update_config_from_refs!(panel.config)
            panel.masks_dirty = true
            preview_dirty = true
        end

        # Preview selection and update
        CImGui.TextColored(ImVec4(0.7f0, 0.7f0, 1.0f0, 1.0f0), "PREVIEW")

        if CImGui.BeginCombo("Preview Type", preview_labels[preview_type_ref[] + 1])
            for (i, label) in enumerate(preview_labels)
                if CImGui.Selectable(label, (i-1) == preview_type_ref[])
                    preview_type_ref[] = i - 1
                    preview_dirty = true
                end
            end
            CImGui.EndCombo()
        end

        # Generate preview (rate limited to avoid slowdown)
        current_time = time()
        if preview_dirty && (current_time - last_preview_time) > 0.1
            try
                masks = build_all_scc_masks(panel.config)
                if preview_type_ref[] == 0
                    preview_mask = masks.mask_overall
                elseif preview_type_ref[] == 1
                    preview_mask = masks.mask_fdh
                else
                    preview_mask = masks.mask_hdh
                end
                last_preview_time = current_time
                preview_dirty = false
            catch e
                err_msg = "Preview generation failed: $(e)"
                err_msg_timeout = time() + 5
            end
        end

        if CImGui.Button("View in Image Viewer")
            if !isnothing(preview_mask)
                try
                    imviewgui(Float32.(preview_mask), name="SCC Mask Preview")
                catch e
                    err_msg = "Could not send to viewer: $(e)"
                    err_msg_timeout = time() + 5
                end
            end
        end

        # Show mask statistics
        if !isnothing(preview_mask)
            n_pixels = count(preview_mask)
            total_pixels = length(preview_mask)
            CImGui.Text("Mask: $n_pixels / $total_pixels pixels ($(round(100*n_pixels/total_pixels, digits=1))%)")
        end

        CImGui.Separator()

        # Action buttons
        CImGui.TextColored(ImVec4(0.7f0, 0.7f0, 1.0f0, 1.0f0), "ACTIONS")

        # Save to files
        if CImGui.Button("Save Masks to Files", ImVec2(200, 0))
            try
                masks = build_all_scc_masks(panel.config)
                save_scc_masks(masks;
                    path_overall = path_overall,
                    path_phase = path_phase,
                    path_amplitude = path_amplitude
                )
                panel.masks_dirty = false
                @info "Masks saved successfully"
            catch e
                err_msg = "Save failed: $(e)"
                err_msg_timeout = time() + 5
            end
        end

        # Send to SCC service
        if CImGui.Button("Send Masks to SCC Service", ImVec2(200, 0))
            if isnothing(panel.aeron_event_pub)
                err_msg = "No connection to SCC service"
                err_msg_timeout = time() + 5
            else
                try
                    masks = build_all_scc_masks(panel.config)
                    # SCC service expects UInt8 arrays directly
                    sendevents(panel.aeron_event_pub;
                        image_mask = UInt8.(masks.mask_overall),
                        image_mask_phase = UInt8.(masks.mask_fdh),
                        image_mask_amplitude = UInt8.(masks.mask_hdh)
                    )
                    panel.masks_dirty = false
                    @info "Masks sent to SCC service"
                catch e
                    err_msg = "Send failed: $(e)"
                    err_msg_timeout = time() + 5
                end
            end
        end

        # Quick button to save AND send
        CImGui.PushStyleColor(ImGuiCol_Button, ImVec4(0.2f0, 0.5f0, 0.3f0, 1.0f0))
        if CImGui.Button("Save & Send to SCC", ImVec2(200, 0))
            if isnothing(panel.aeron_event_pub)
                err_msg = "No connection to SCC service"
                err_msg_timeout = time() + 5
            else
                try
                    masks = build_all_scc_masks(panel.config)
                    # Save to files
                    save_scc_masks(masks;
                        path_overall = path_overall,
                        path_phase = path_phase,
                        path_amplitude = path_amplitude
                    )
                    # Send arrays directly to SCC service
                    sendevents(panel.aeron_event_pub;
                        image_mask = UInt8.(masks.mask_overall),
                        image_mask_phase = UInt8.(masks.mask_fdh),
                        image_mask_amplitude = UInt8.(masks.mask_hdh)
                    )
                    panel.masks_dirty = false
                    @info "Masks saved and sent to SCC service"
                catch e
                    err_msg = "Operation failed: $(e)"
                    err_msg_timeout = time() + 5
                end
            end
        end
        CImGui.PopStyleColor()

        # Dirty indicator
        if panel.masks_dirty
            CImGui.TextColored(ImVec4(1.0f0, 0.8f0, 0.0f0, 1.0f0), "* Masks have unsaved changes")
        end

        CImGui.Separator()

        # Reset to defaults
        if CImGui.Button("Reset to Defaults")
            panel.config = SCCMaskConfig()
            update_refs_from_config!(panel.config)
            panel.masks_dirty = true
            preview_dirty = true
        end

        CImGui.End()
    end

    return draw
end
