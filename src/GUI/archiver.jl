
using Aeron
using AstroImages
using SpidersMessageSender

mutable struct ArchiverComponent
    const name::String
    const aeron_event_pub::Aeron.AeronPublication
    const aeron_status_sub::Aeron.AeronSubscription
    const aeron_watch_handle::Aeron.AeronWatchHandle
    status::Dict{Symbol,Any}
    last_heartbeat_time::Base.RefValue{Float64}
    waiting_for_status::Bool
end

function ArchiverComponent(conf)
    aeron_event_config = AeronConfig(conf["event-channel"], conf["event-stream"])
    aeron_status_config = AeronConfig(conf["status-channel"], conf["status-stream"])
    aeron_event_pub = Aeron.publisher(aeron, aeron_event_config)
    aeron_status_sub = Aeron.subscriber(aeron, aeron_status_config)
    status = Dict{Symbol,Any}()
    last_heartbeat_time = Ref(0.0)

    block = nothing
    watch_handle = Aeron.watch(aeron_status_sub) do frame
        if isnothing(block)
            return
        end
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
            @error "Error receiving status update" exception=(err, catch_backtrace())
        end
        block.waiting_for_status = false
    end
    block = ArchiverComponent(
        conf["name"],
        aeron_event_pub,
        aeron_status_sub,
        watch_handle,
        status,
        last_heartbeat_time,
        true # start by indicating we are waiting to hear from the component
    )
    # Request initial status
    sendevents(aeron_event_pub; StatusRequest=nothing)
    return block
end
name(iv::ArchiverComponent) = iv.name


function gui_panel(::Type{ArchiverComponent}, component_config)

    err_msg = nothing
    err_msg_timeout = time()
    first_view = true
    last_status_request_time = Ref(0.0)

    meta_observer = Ref("\0"^32) # 32-byte length (see common.xml)
    meta_object = Ref("\0"^32) # 32-byte length (see common.xml)

    # Build lookup for configured streams: "uri:stream" -> stream_spec
    configured_streams = Dict{String,Any}()
    for stream_spec in get(component_config, "stream", [])
        key = "$(stream_spec["input-channel"]):$(stream_spec["input-stream"])"
        configured_streams[key] = stream_spec
    end

    function draw(block, visible)
        CImGui.SetNextWindowSize((400,500), CImGui.ImGuiCond_FirstUseEver)

        if !CImGui.Begin(component_config["name"], visible)
            return
        end

        # Periodically request status updates
        if time() - last_status_request_time[] > 2.0
            sendevents(block.aeron_event_pub; StatusRequest=nothing)
            last_status_request_time[] = time()
        end

        first_view = false

        inactive = time() - block.last_heartbeat_time[] > 5

        if !isnothing(err_msg)
            CImGui.TextColored(bad_color, "ERROR:")
            CImGui.SameLine();
            CImGui.TextWrapped(err_msg)
            if CImGui.Button("Clear")
                err_msg = nothing
            end
            if time() > err_msg_timeout
                err_msg = nothing
            end
        end

        # Show service status
        state = get(block.status, :state, nothing)
        if isnothing(state)
            CImGui.Spacing()
            CImGui.PushFont(font_large)
            CImGui.Text("Status: ")
            CImGui.SameLine()
            CImGui.PushStyleColor(ImGuiCol_Text, CImGui.IM_COL32(0xFF, 0xCC, 0x00, 0xff));
            CImGui.Text(string("Unknown.\nIs the service running?"))
            CImGui.PopStyleColor()
            CImGui.PopFont()
            CImGui.End()
            return
        end

        CImGui.Spacing()
        CImGui.PushFont(font_large)
        CImGui.Text("Status: ")
        CImGui.SameLine()
        if block.waiting_for_status
            CImGui.Text("...")
        else
            if inactive
                CImGui.PushStyleColor(ImGuiCol_Text, CImGui.IM_COL32(0xFF, 0xEA, 0x00, 0xff));
                CImGui.Text("$state (late heartbeat)")
            else
                CImGui.PushStyleColor(ImGuiCol_Text, CImGui.IM_COL32(0x42, 0x87, 0xf5, 0xff));
                CImGui.Text("$state")
            end
            CImGui.PopStyleColor()
        end
        CImGui.PopFont()

        CImGui.Spacing()
        CImGui.Separator()

        # Display metrics
        if CImGui.CollapsingHeader("Metrics", ImGuiTreeNodeFlags_DefaultOpen)
            total_messages = get(block.status, :total_messages_received, 0.0)
            total_bytes_written = get(block.status, :total_bytes_written, 0.0)
            total_bytes_received = get(block.status, :total_bytes_received, 0.0)
            bytes_pending = get(block.status, :bytes_pending_or_lost, 0.0)
            current_batch = get(block.status, :current_batch_size, 0.0)
            current_file_size = get(block.status, :current_file_size, 0.0)
            current_file = get(block.status, :current_data_file, "")
            uptime = get(block.status, :uptime_seconds, 0.0)

            # Format bytes nicely
            function format_bytes(b)
                if b >= 1e9
                    return @sprintf("%.2f GB", b / 1e9)
                elseif b >= 1e6
                    return @sprintf("%.2f MB", b / 1e6)
                elseif b >= 1e3
                    return @sprintf("%.2f KB", b / 1e3)
                else
                    return @sprintf("%.0f B", b)
                end
            end

            function format_uptime(s)
                hours = floor(Int, s / 3600)
                mins = floor(Int, (s % 3600) / 60)
                secs = floor(Int, s % 60)
                return @sprintf("%02d:%02d:%02d", hours, mins, secs)
            end

            CImGui.Text("Messages received: $(Int(total_messages))")
            CImGui.Text("Bytes written: $(format_bytes(total_bytes_written))")
            CImGui.Text("Bytes received: $(format_bytes(total_bytes_received))")

            # Show bytes pending/lost with color coding
            if bytes_pending > 0
                CImGui.TextColored(ImVec4(1.0f0, 0.8f0, 0.0f0, 1.0f0),
                    "Bytes pending/lost: $(format_bytes(bytes_pending))")
            else
                CImGui.Text("Bytes pending/lost: $(format_bytes(bytes_pending))")
            end

            CImGui.Text("Current batch: $(Int(current_batch))")
            CImGui.Text("Current file size: $(format_bytes(current_file_size))")
            CImGui.Text("Current file: $current_file")
            CImGui.Text("Uptime: $(format_uptime(uptime))")
        end

        CImGui.Spacing()
        CImGui.Separator()

        # Metadata fields
        if CImGui.CollapsingHeader("Metadata")
            CImGui.InputText("Observer", meta_observer[], length(meta_observer[]))
            CImGui.SameLine()
            if CImGui.Button("Send##observer")
                corr_num, len_sent = sendevents(
                    uri=component_config["metadata-channel"],
                    stream=component_config["metadata-stream"];
                    observer=meta_observer[]
                )
                if len_sent == 0
                    err_msg = "service not listening"
                    err_msg_timeout = time() + 3
                end
            end

            CImGui.InputText("Object", meta_object[], length(meta_object[]))
            CImGui.SameLine()
            if CImGui.Button("Send##object")
                corr_num, len_sent = sendevents(
                    uri=component_config["metadata-channel"],
                    stream=component_config["metadata-stream"];
                    object=meta_object[]
                )
                if len_sent == 0
                    err_msg = "service not listening"
                    err_msg_timeout = time() + 3
                end
            end
        end

        CImGui.Spacing()
        CImGui.Separator()

        # Stream recording controls
        CImGui.Text("Recording Streams:")
        CImGui.Spacing()

        # Parse current recording streams from status
        recording_streams_str = get(block.status, :recording_streams, "")
        recording_set = Set{String}()
        if !isempty(recording_streams_str)
            for s in split(recording_streams_str, ",")
                s = strip(s)
                if !isempty(s)
                    push!(recording_set, s)
                end
            end
        end

        # Count how many configured streams are enabled
        num_configured = length(component_config["stream"])
        num_enabled = 0
        for stream_spec in component_config["stream"]
            key = "$(stream_spec["input-channel"]):$(stream_spec["input-stream"])"
            if key in recording_set
                num_enabled += 1
            end
        end

        # Tri-state Enable All / Disable All checkbox
        all_enabled = num_enabled == num_configured && num_configured > 0
        none_enabled = num_enabled == 0
        mixed_state = !all_enabled && !none_enabled

        # Checkbox ref for the tri-state button
        checkbox_ref = Ref{Bool}(all_enabled || mixed_state)

        if mixed_state
            # Push mixed value flag for the checkbox
            igPushItemFlag(ImGuiItemFlags_MixedValue, true)
        end

        toggled = CImGui.Checkbox("Enable All##master", checkbox_ref)

        if mixed_state
            igPopItemFlag()
        end

        # Handle toggle action
        if toggled
            block.waiting_for_status = true
            if checkbox_ref[]
                # Enable all configured streams
                for stream_spec in component_config["stream"]
                    corr_num, len_sent = sendevents(
                        block.aeron_event_pub;
                        uri=stream_spec["input-channel"],
                        stream=stream_spec["input-stream"],
                        enabled=1
                    )
                end
            else
                # Disable all configured streams
                for stream_spec in component_config["stream"]
                    corr_num, len_sent = sendevents(
                        block.aeron_event_pub;
                        uri=stream_spec["input-channel"],
                        stream=stream_spec["input-stream"],
                        enabled=0
                    )
                end
            end
        end

        CImGui.SameLine()
        CImGui.TextDisabled("($num_enabled/$num_configured enabled)")

        CImGui.Spacing()

        # Individual stream checkboxes
        for stream_spec in component_config["stream"]
            stream_name = stream_spec["name"]
            stream_key = "$(stream_spec["input-channel"]):$(stream_spec["input-stream"])"
            is_enabled = stream_key in recording_set

            checkbox_val = Ref{Bool}(is_enabled)
            if CImGui.Checkbox("$stream_name##stream", checkbox_val)
                block.waiting_for_status = true
                corr_num, len_sent = sendevents(
                    block.aeron_event_pub;
                    uri=stream_spec["input-channel"],
                    stream=stream_spec["input-stream"],
                    enabled=checkbox_val[] ? 1 : 0
                )
                if len_sent == 0
                    err_msg = "service not listening"
                    err_msg_timeout = time() + 3
                end
            end

            # Show stream details on hover
            if CImGui.IsItemHovered()
                CImGui.BeginTooltip()
                CImGui.Text("Channel: $(stream_spec["input-channel"])")
                CImGui.Text("Stream: $(stream_spec["input-stream"])")
                CImGui.EndTooltip()
            end
        end

        CImGui.End()
    end

    return draw
end
