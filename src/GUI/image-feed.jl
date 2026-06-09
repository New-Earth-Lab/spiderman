using Aeron
mutable struct ImageFeed
    const name::String
    const aeron_config::AeronConfig
    const aeron_watch_handle::Aeron.AeronWatchHandle
    # Optional publisher used to drive the upstream service's averaging /
    # decimation parameters. When non-nothing, the panel's averaging controls
    # configure the upstream service instead of accumulating locally.
    const upstream_event_pub::Union{Nothing,Aeron.AeronPublication}
    last_img::Matrix{Float32}
    first_view::Bool
    fps::Float64
    last_time::Float64
    # Averaging state (local fallback when no upstream control is wired up)
    accumulator::Matrix{Float32}
    frame_count::Int
    averaging_enabled::Bool
    averaging_target::Int
end
function ImageFeed(conf)
    aeron_config = AeronConfig(conf["input-channel"], conf["input-stream"])
    subscription = Aeron.subscriber(aeron, aeron_config)

    # If upstream control is configured, open a publisher so the panel can
    # tell the upstream service how to decimate/average. Both keys are
    # required to enable this path.
    upstream_event_pub = nothing
    if haskey(conf, "upstream-control-channel") && haskey(conf, "upstream-control-stream")
        upstream_event_pub = Aeron.publisher(aeron,
            AeronConfig(conf["upstream-control-channel"], conf["upstream-control-stream"]))
    end

    feed = nothing
    watch_handle = Aeron.watch(subscription) do frame
        if isnothing(feed)
            println("waiting for feed construction")
            return
        end
        try
            ten = TensorMessage(frame.buffer, initialize=false)
            incoming_data = Float32.(SpidersMessageEncoding.arraydata(ten))

            if feed.averaging_enabled && feed.averaging_target > 1
                # Averaging mode: accumulate frames
                if size(feed.accumulator) != size(incoming_data)
                    # Reset accumulator on size change
                    feed.accumulator = zeros(Float32, size(incoming_data))
                    feed.frame_count = 0
                end
                feed.accumulator .+= incoming_data
                feed.frame_count += 1

                if feed.frame_count >= feed.averaging_target
                    # Block update: compute average and send to viewer
                    if size(feed.last_img) != size(feed.accumulator)
                        feed.last_img = feed.accumulator ./ feed.frame_count
                    else
                        feed.last_img .= feed.accumulator ./ feed.frame_count
                    end
                    feed.first_view = true
                    # Reset accumulator for next block
                    feed.accumulator .= 0
                    feed.frame_count = 0
                end
            else
                # Direct passthrough (normal mode)
                if size(feed.last_img) != size(incoming_data)
                    feed.last_img = incoming_data
                    feed.first_view = true
                else
                    feed.last_img .= incoming_data
                end
            end

            curr_time = time()
            new_fps = 1/(curr_time - feed.last_time)
            feed.fps = feed.fps - 0.05*(feed.fps - new_fps)
            feed.last_time = curr_time
        catch err
            @error "Error receiving image update" exception=(err, catch_backtrace())
        end
    end

    feed = ImageFeed(
        conf["name"], aeron_config, watch_handle,
        upstream_event_pub,    # upstream_event_pub
        zeros(Float32, 0, 0),  # last_img
        true,                   # first_view
        0.0,                    # fps
        0.0,                    # last_time
        zeros(Float32, 0, 0),  # accumulator
        0,                      # frame_count
        false,                  # averaging_enabled
        100                     # averaging_target (default)
    )

    return feed
end
name(iv::ImageFeed) = iv.name





function gui_panel(::Type{ImageFeed}, component_config)

    err_msg = nothing

    # Embeded image viewer panel - pass through mask-files and colorscale-sync-group config
    child_config = Dict{String,Any}("name" => component_config["name"])
    if haskey(component_config, "mask-files")
        child_config["mask-files"] = component_config["mask-files"]
    end
    if haskey(component_config, "colorscale-sync-group")
        child_config["colorscale-sync-group"] = component_config["colorscale-sync-group"]
    end
    child_imview = ImageViewer(child_config)
    child_imview_draw = gui_panel(ImageViewer, child_config; ischild=true, child_size=(-1,-1))

    # Access sync group for averaging settings (shared across panels in same group)
    sync_group_name = get(component_config, "colorscale-sync-group", nothing)
    sync_state = !isnothing(sync_group_name) ? get_sync_group_state(sync_group_name) : nothing

    # Local averaging settings if no sync group
    local_averaging_enabled = Ref{Bool}(false)
    local_averaging_count = Ref{Cint}(100)

    first_view_0 = true

    last_time = time()

    # Tracks the last averaging-frames value sent to the upstream service so
    # we only emit an event when the user changes the desired setting. -1 forces
    # an initial send on the first frame.
    last_sent_upstream_avg_n = Ref{Int}(-1)

    # Name of the event used to configure averaging on the upstream service.
    # For services that publish a single decimated stream, the default
    # `decimated_averaging_frames` suffices. Services with multiple output
    # streams (e.g. choppedframesort) override this per-feed so each panel
    # talks to a distinct upstream knob.
    upstream_event_name = Symbol(get(component_config,
        "upstream-control-event-name", "decimated_averaging_frames"))

    function draw(image_feed, visible)
        # Get averaging settings from sync group or local
        if !isnothing(sync_state)
            avg_enabled_ref = sync_state.averaging_enabled
            avg_count_ref = sync_state.averaging_count
            avg_progress_ref = sync_state.averaging_progress
        else
            avg_enabled_ref = local_averaging_enabled
            avg_count_ref = local_averaging_count
            avg_progress_ref = Ref{Cint}(0)  # Local progress
        end

        upstream_controlled = !isnothing(image_feed.upstream_event_pub)

        if upstream_controlled
            # The upstream service handles averaging/decimation; locally we
            # just display whatever frames arrive at the reduced cadence.
            image_feed.averaging_enabled = false
            image_feed.averaging_target = 1
            # Push the desired averaging-frames value to the upstream service
            # whenever the user changes it. N=1 means "decimate only".
            desired_n = (avg_enabled_ref[] && avg_count_ref[] > 1) ? Int(avg_count_ref[]) : 1
            if desired_n != last_sent_upstream_avg_n[]
                try
                    sendevents(image_feed.upstream_event_pub;
                        (upstream_event_name => Float64(desired_n),)...)
                    last_sent_upstream_avg_n[] = desired_n
                catch err
                    @error "Failed to send averaging config to upstream" exception=(err, catch_backtrace())
                end
            end
            avg_progress_ref[] = Cint(0)
        else
            # Sync averaging settings to ImageFeed (for the watch handler)
            image_feed.averaging_enabled = avg_enabled_ref[]
            image_feed.averaging_target = avg_count_ref[]
            # Update progress for display
            avg_progress_ref[] = Cint(image_feed.frame_count)
        end

        # Only do work assembling incoming messages if the panel is visible
        Aeron.active(image_feed.aeron_watch_handle, visible[])

        if upstream_controlled
            # The stream is already throttled upstream; no further client-side
            # decimation is needed and would only add display jitter.
            image_feed.aeron_watch_handle.decimate_time = 0
        elseif image_feed.averaging_enabled && image_feed.averaging_target > 1
            # Disable decimation when averaging (we want ALL frames)
            image_feed.aeron_watch_handle.decimate_time = 0
        else
            image_feed.aeron_watch_handle.decimate_time = 1/60
        end

        CImGui.SetNextWindowSize((350,400), CImGui.ImGuiCond_FirstUseEver)

        if !CImGui.Begin(component_config["name"], visible)
            return
        end
        if image_feed.first_view || first_view_0
            child_imview.new_contents = image_feed.last_img
            child_imview.new_action = "="
            child_imview.new_name = "image feed"
        end
        first_view_0 = image_feed.first_view = false

        CImGui.Text("Stream: $(image_feed.aeron_config.stream)   FPS: "*string(round(Int, image_feed.fps)))

        # Averaging controls
        CImGui.SameLine(CImGui.GetWindowWidth()-200)

        avg_checkbox = Ref(avg_enabled_ref[])
        if CImGui.Checkbox("Avg", avg_checkbox)
            avg_enabled_ref[] = avg_checkbox[]
            # Reset accumulator when toggling
            if !avg_enabled_ref[]
                image_feed.frame_count = 0
                if length(image_feed.accumulator) > 0
                    image_feed.accumulator .= 0
                end
            end
        end
        CImGui.SameLine()

        if CImGui.SmallButton("10")
            avg_count_ref[] = 10
            avg_enabled_ref[] = true
            if !avg_enabled_ref[]
                image_feed.frame_count = 0
                if length(image_feed.accumulator) > 0
                    image_feed.accumulator .= 0
                end
            end
        end
        CImGui.SameLine()

        if CImGui.SmallButton("100")
            avg_count_ref[] = 100
            avg_enabled_ref[] = true
            if !avg_enabled_ref[]
                image_feed.frame_count = 0
                if length(image_feed.accumulator) > 0
                    image_feed.accumulator .= 0
                end
            end
        end
        CImGui.SameLine()

        
        CImGui.PushItemWidth(60)
        avg_count_val = Ref(avg_count_ref[])
        if CImGui.InputInt("##avgN", avg_count_val, 0, 0)
            avg_count_ref[] = max(Cint(1), avg_count_val[])
        end
        CImGui.PopItemWidth()
        CImGui.SameLine()
        CImGui.Text("frames")

        # Show progress bar when averaging is enabled (local averaging only;
        # upstream-controlled averaging doesn't expose per-frame progress and
        # we don't want to imply a meaningful 0%).
        if !upstream_controlled && avg_enabled_ref[] && avg_count_ref[] > 1
            progress = Float32(image_feed.frame_count) / Float32(avg_count_ref[])
            CImGui.ProgressBar(progress, ImVec2(-1, 2), "")  # 2px tall, no text
        else
            CImGui.ProgressBar(0f0, ImVec2(-1, 2), "")  # 2px tall, no text
        end

        if !isnothing(err_msg)
            CImGui.TextColored(bad_color, "ERROR:")
            CImGui.SameLine();
            CImGui.TextWrapped(err_msg)
            if CImGui.Button("Clear")
                err_msg = nothing
            end
        end

        child_imview_draw(child_imview, true)

        CImGui.End() # End of this panel

    end


    return draw
end

