using Aeron
using AstroImages
using SpidersMessageSender
mutable struct RTCBlock1
    const name::String
    const aeron_event_pub::Aeron.AeronPublication
    const aeron_status_sub::Aeron.AeronSubscription
    const aeron_watch_handle::Aeron.AeronWatchHandle
    status::Dict{Symbol,Any}
    # Flag we set after sending anything, that is unset as soon as we receive something.
    # We don't check correlation numbers, it's just to give the uesr an indication of
    # a sign of life from the service.
    waiting_for_status::Bool
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
        block.waiting_for_status = false
    end
    block = RTCBlock1(
        conf["name"],
        aeron_event_pub,
        aeron_status_sub,
        watch_handle,
        status,
        true # start by indicating we are waiting to hear from the component
    )
    # Catch up right away by asking for a status update
    # TODO: check if not connected.
    sendevents(aeron_event_pub; StatusRequest=nothing)
    return block
end
name(iv::RTCBlock1) = iv.name


function gui_panel(::Type{RTCBlock1}, component_config)

    err_msg = nothing
    err_msg_timeout = time()
    first_view = true

    event_fields_ref = map(component_config["event-fields"]) do event_spec
        event_name, event_argtype, event_argdefault = event_spec
        if event_argtype == "Float64"
            arg_val_ref = Ref(parse(Float32,event_argdefault))
        elseif event_argtype == "Int"
            arg_val_ref = Ref(parse(Int32,event_argdefault))
        elseif event_argtype == "String" || startswith(event_argtype, "array")
            arg_val_ref = Ref(event_argdefault * "\0"^100)
        elseif event_argtype == "Bool"
            arg_val_ref = Ref(parse(Int, event_argdefault)>0)
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
            if time() > err_msg_timeout 
                err_msg = nothing
            end
        end


        CImGui.Spacing()
        CImGui.PushFont(font_large)
        CImGui.PushStyleColor(ImGuiCol_Text, CImGui.IM_COL32(0x42, 0x87, 0xf5, 0xff));
        CImGui.Text(string(get(block.status, :state, "Unknown state")))
        CImGui.PopStyleColor()
        CImGui.PopFont()

        if block.waiting_for_status
            CImGui.SameLine()
            CImGui.Text("...")
        end

        CImGui.Spacing()

        for event_name in component_config["event-buttons"]
            if CImGui.Button(event_name*"##user-button$event_name")
                block.waiting_for_status = true
                corr_num, len_sent = sendevents(
                    block.aeron_event_pub;
                    (Symbol(event_name) => nothing,)...
                )
                if len_sent == 0
                    err_msg = "service not listening"
                    err_msg_timeout = time() + 3
                end
            end
            CImGui.SameLine()
        end

        CImGui.Spacing()

        sendall = CImGui.Button("send all")
        for (ref, event_spec) in zip(event_fields_ref, component_config["event-fields"])
            event_name, event_argtype, event_argdefault = event_spec

            CImGui.Spacing()
            s = Symbol(event_name)
            local val
            found = false
            for key in keys(block.status)
                if key != s
                    continue
                end
                val = block.status[key]
                found = true
                break
            end

            if !found
                CImGui.Text(string(event_name, " = ?"))
            else
                if val isa AbstractString || val isa Number
                    CImGui.Text(string(event_name, " = ", val))
                elseif val isa AbstractArray
                    CImGui.Text(string(event_name, " = $(ndims(val))D array"))
                    CImGui.SameLine()
                    if CImGui.SmallButton("view##$event_name")
                        @info "openning imview for " typeof(val) size(val)
                        imviewgui(val)
                    end
                elseif isnothing(val)
                    CImGui.Text(string(event_name, " = nothing"))
                else
                    CImGui.Text(string(event_name, " = other"))
                end
            end


            if event_argtype == "Float64"
                CImGui.InputFloat("##$event_name", ref, 0.1)
                CImGui.SameLine()
                if  CImGui.Button("Send##$event_name") || sendall
                    block.waiting_for_status = true
                    corr_num, len_sent = sendevents(
                        block.aeron_event_pub;
                        (Symbol(event_name) => ref[],)...
                    )
                    if len_sent == 0
                        err_msg =  "service not listening"
                        err_msg_timeout = time() + 3
                    end
                end
            elseif event_argtype == "Int"
                CImGui.InputInt("##$event_name", ref, 1)
                CImGui.SameLine()
                if  CImGui.Button("Send##$event_name") || sendall
                    block.waiting_for_status = true
                    corr_num, len_sent = sendevents(
                        block.aeron_event_pub;
                        (Symbol(event_name) => ref[],)...
                    )
                    if len_sent == 0
                        err_msg =  "service not listening"
                        err_msg_timeout = time() + 3
                    end
                end
            elseif event_argtype == "Bool"
                if isnothing(ref[])
                    ref[] = 0
                end
                ref′ = Ref{Bool}(ref[] isa Number && ref[] > 0)
                CImGui.Checkbox("##$event_name", ref′)
                ref[] = ref′[]
                CImGui.SameLine()
                if  CImGui.Button("Send##$event_name") || sendall
                    block.waiting_for_status = true
                    corr_num, len_sent = sendevents(
                        block.aeron_event_pub;
                        (Symbol(event_name) => ref[],)...
                    )
                    if len_sent == 0
                        err_msg =  "service not listening"
                        err_msg_timeout = time() + 3
                    end
                end
            elseif event_argtype == "String" || startswith(event_argtype, "array")
                if isnothing(ref[])
                    ref[] = ""
                end
                CImGui.InputText("##$event_name", ref[], length(ref[]))
                CImGui.SameLine()
                if  CImGui.Button("Send##$event_name") || sendall
                    block.waiting_for_status = true
                    corr_num, len_sent = sendevents(
                        block.aeron_event_pub;
                        (Symbol(event_name) => strip(ref[], '\0'),)...
                    )
                    if len_sent == 0
                        err_msg =  "service not listening"
                        err_msg_timeout = time() + 3
                    end
                end
            end

            # Rich controls.
            # These are nicer ways for the user to interact with certain kinds of fields
            
            # 2D arrows to bump up and down
            if event_argtype == "array-paddle" && found && !isnothing(val)
                r1 = Ref{Float32}(val[1])
                r2 = Ref{Float32}(val[2])
                changed  = CImGui.InputFloat("##$event_name-1", r1, 1.0)
                changed |= CImGui.InputFloat("##$event_name-2", r2, 1.0)
                if sendall || changed
                    block.waiting_for_status = true
                    corr_num, len_sent = sendevents(
                        block.aeron_event_pub;
                        (Symbol(event_name) => Float32[r1[], r2[]],)...
                    )
                    if len_sent == 0
                        err_msg =  "service not listening"
                        err_msg_timeout = time() + 3
                    end
                end
            elseif event_argtype == "array-sliders" && found && !isnothing(val)
                l = length(val)
                refs = [Ref{eltype(val)}(v) for v in val]
                changed = false
                for i in eachindex(refs)
                    changed |= CImGui.DragFloat("##$event_name-$i", refs[i], 0.001)
                end
                if sendall || changed
                    block.waiting_for_status = true
                    corr_num, len_sent = sendevents(
                        block.aeron_event_pub;
                        (Symbol(event_name) => getindex.(refs),)...
                    )
                    if len_sent == 0
                        err_msg =  "service not listening"
                        err_msg_timeout = time() + 3
                    end
                end
            end
        end


        CImGui.End() # End of this panel

    end


    return draw
end

