using Aeron
using AstroImages
using SpidersMessageSender
mutable struct RTCBlock1
    const name::String
    const aeron_event_pub::Aeron.AeronPublication
    const aeron_status_sub::Aeron.AeronSubscription
    const aeron_watch_handle::Aeron.AeronWatchHandle
    status::Dict{Symbol,Any}
end
function RTCBlock1(conf)
    aeron_event_config = AeronConfig(conf["event-channel"], conf["event-stream"])
    aeron_status_config = AeronConfig(conf["status-channel"], conf["status-stream"])
    aeron_event_pub = Aeron.publisher(aeron, aeron_event_config)
    aeron_status_sub = Aeron.subscriber(aeron, aeron_status_config)
    status = Dict{Symbol,Any}()
    
    watch_handle = Aeron.watch(aeron_status_sub) do frame
        try
            event = EventMessage(frame.buffer, initialize=false)
            val = getargument(event)
            if val isa AbstractString
                val = String(val)
            end
            if val isa AbstractArray
                val = collect(val)
            end
            if val isa TensorMessage
                val = collect(SpidersMessageEncoding.arraydata(val))
            end              
            key = Symbol(event.name)  
            status[key] = val
            if isnothing(status[key])
                delete!(status, key)
            end
        catch err
            @error "Error receiving status update" exception=(err, catch_backtrace())
        end
    end
    # Catch up right away by asking for a status update
    sendevents(aeron_event_pub; StatusRequest=nothing)
    block = RTCBlock1(
        conf["name"],
        aeron_event_pub,
        aeron_status_sub,
        watch_handle,
        status
    )

    return block
end
name(iv::RTCBlock1) = iv.name


function gui_panel(::Type{RTCBlock1}, component_config)

    err_msg = nothing

    first_view = true

    event_fields_ref = map(component_config["event-fields"]) do event_spec
        event_name, event_argtype, event_argdefault = event_spec
        if event_argtype == "Float64"
            arg_val_ref = Ref(parse(Float32,event_argdefault))
        elseif event_argtype == "String" || event_argtype == "array"
            arg_val_ref = Ref(event_argdefault * "\0"^100)
        else
            Ref{Any}(nothing)
        end
    end

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
        end

        for key in keys(block.status)
            if key == :state
                continue
            end
            val = block.status[key]
            if val isa AbstractString || val isa Number
                CImGui.Text(string(key, " = ", val))
            elseif val isa AbstractArray
                CImGui.Text(string(key, " = array ($(ndims(val))D)"))
            else
                CImGui.Text(string(key, " = ?"))
            end

        end

        CImGui.Separator()
        CImGui.Spacing()



        CImGui.Text("State = "*string(get(block.status, :state, "?")))

        CImGui.Separator()
        CImGui.Spacing()

        for event_name in component_config["event-buttons"]
            if CImGui.Button(event_name*"##user-button$event_name")
                sendevents(
                    block.aeron_event_pub;
                    (Symbol(event_name) => nothing,)...
                )
            end
            CImGui.SameLine()
        end
        CImGui.Separator()
        CImGui.Spacing()


        for (ref, event_spec) in zip(event_fields_ref, component_config["event-fields"])
            event_name, event_argtype, event_argdefault = event_spec
            CImGui.Text(event_name)
            if event_argtype == "Float64"
                CImGui.InputFloat("##$event_name", ref, 1.0)
                CImGui.SameLine()
                if CImGui.Button("Send##$event_name")
                    val = ref[]
                    sendevents(
                        block.aeron_event_pub;
                        (Symbol(event_name) => val,)...
                    )
                end
            elseif event_argtype == "String" || event_argtype == "array"
                CImGui.InputText("##$event_name", ref[], length(ref[]))
                CImGui.SameLine()
                if CImGui.Button("Send##$event_name")
                    sendevents(
                        block.aeron_event_pub;
                        (Symbol(event_name) => strip(ref[], '\0'),)...
                    )
                end
            end
        end


        CImGui.End() # End of this panel

    end


    return draw
end

