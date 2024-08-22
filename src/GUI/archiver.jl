
using Aeron
using AstroImages
using SpidersMessageSender
mutable struct ArchiverComponent
    const name::String
    const aeron_event_pub::Aeron.AeronPublication
    const aeron_status_sub::Aeron.AeronSubscription
    const aeron_watch_handle::Aeron.AeronWatchHandle
    status::Dict{Symbol,Any}
end
function ArchiverComponent(conf)
    aeron_event_config = AeronConfig(conf["event-channel"], conf["event-stream"])
    aeron_status_config = AeronConfig(conf["status-channel"], conf["status-stream"])
    aeron_event_pub = Aeron.publisher(aeron, aeron_event_config)
    aeron_status_sub = Aeron.subscriber(aeron, aeron_status_config)
    status = Dict{Symbol,Any}()
    
    # TODO: this is not currently used since the archiverservice isn't ever republishing anything yet
    watch_handle = Aeron.watch(aeron_status_sub) do frame
        try
            event = EventMessage(frame.buffer, initialize=false)
            @info "event" name=string(event.name)
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
    end
    block = ArchiverComponent(
        conf["name"],
        aeron_event_pub,
        aeron_status_sub,
        watch_handle,
        status,
    )
    return block
end
name(iv::ArchiverComponent) = iv.name


function gui_panel(::Type{ArchiverComponent}, component_config)

    err_msg = nothing
    err_msg_timeout = time()
    first_view = true

    meta_observer = Ref("\0"^32) # 32-byte length (see common.xml)
    meta_object = Ref("\0"^32) # 32-byte length (see common.xml)

    function draw(block, visible)
        CImGui.SetNextWindowSize((350,350), CImGui.ImGuiCond_FirstUseEver)

        if !CImGui.Begin(component_config["name"], visible)#, ImGuiWindowFlags_MenuBar)
            return
        end
        if first_view
        end
        first_view = false
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

        # These are text fields to enter arbitrary metadata
        CImGui.InputText("Observer", meta_observer[], length(meta_observer[]))
        CImGui.SameLine()
        if CImGui.Button("Send##observer")
            # Now send metadata
            corr_num, len_sent = sendevents(
                uri=component_config["metadata-channel"],
                stream=component_config["metadata-stream"];
                observer=meta_observer[]
            )
            if len_sent == 0
                err_msg =  "service not listening"
                err_msg_timeout = time() + 3
            end
        end

        CImGui.InputText("Object", meta_object[], length(meta_object[]))
        CImGui.SameLine()
        if CImGui.Button("Send##object")
            # Now send metadata
            corr_num, len_sent = sendevents(
                uri=component_config["metadata-channel"],
                stream=component_config["metadata-stream"];
                object=meta_object[]
            )
            if len_sent == 0
                err_msg =  "service not listening"
                err_msg_timeout = time() + 3
            end
        end


        CImGui.Spacing()
        CImGui.TextWrapped("You can enable/or disable recording of different data streams using the buttons below. Ensure the archiver service is running.")
        CImGui.Spacing()

        enable_all = CImGui.Button("enable all")
        CImGui.SameLine()
        disable_all = CImGui.Button("disable all")
        for stream_spec in component_config["stream"]
            stream_name = stream_spec["name"]
            CImGui.Spacing()
            CImGui.Text(stream_name)

            if CImGui.Button("enable##$stream_name") || enable_all
                corr_num, len_sent = sendevents(
                    block.aeron_event_pub;
                    uri=stream_spec["input-channel"],
                    stream=stream_spec["input-stream"],
                    enabled=1
                )
                if len_sent == 0
                    err_msg =  "service not listening"
                    err_msg_timeout = time() + 3
                end
            end
            CImGui.SameLine()
            if CImGui.Button("disable##$stream_name") || disable_all
                corr_num, len_sent = sendevents(
                    block.aeron_event_pub;
                    uri=stream_spec["input-channel"],
                    stream=stream_spec["input-stream"],
                    enabled=0
                )
                if len_sent == 0
                    err_msg =  "service not listening"
                    err_msg_timeout = time() + 3
                end
            end
        end


        CImGui.End() # End of this panel

    end


    return draw
end


