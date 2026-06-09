using Aeron
using AstroImages
using SpidersMessageSender
mutable struct RTCBlock1
    const name::String
    const aeron_event_pub::Aeron.AeronPublication
    const aeron_status_sub::Aeron.AeronSubscription
    const aeron_watch_handle::Aeron.AeronWatchHandle
    status::Dict{Symbol,Any}
    last_heartbeat_time::Base.RefValue{Float64}
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
    last_heartbeat_time = Ref(0.0)    
    block = nothing
    watch_handle = Aeron.watch(aeron_status_sub) do frame
        if isnothing(block)
            return
        end
        try
            last_heartbeat_time[] = time()
            event = EventMessage(frame.buffer, initialize=false)
            #@info "event" component=conf["name"] event=string(event.name)
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
        last_heartbeat_time,
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
        if event_argtype == "Float64" || event_argdefault == "Float64-preset"
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

            CImGui.End() # End of this panel
            return
        end


        CImGui.Spacing()
        CImGui.PushFont(font_large)
        CImGui.Text("Status: ")
        CImGui.SameLine()
        if block.waiting_for_status
            CImGui.SameLine()
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
        i = 0
        for (ref, event_spec) in zip(event_fields_ref, component_config["event-fields"])
            i+= 1
            event_name, event_argtype, event_argdefault, remaining... = event_spec

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
                    if CImGui.SmallButton("view##$event_name-$i")
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
                CImGui.InputFloat("##$event_name-$i", ref, 0.1)
                CImGui.SameLine()
                if  CImGui.Button("Send##$event_name-$i") || sendall
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

                if !isempty(remaining)
                    j = 0
                    for (name, value_str) in zip(collect(remaining)[1:2:end-1], collect(remaining)[2:2:end])
                        j+=1
                        label = "$name"
                        if CImGui.Button("$label##$event_name-$i-$j")
                            val = parse(Float64, value_str)
                            corr_num, len_sent = sendevents(
                                block.aeron_event_pub;
                                (Symbol(event_name) => val,)...
                            )
                        end
                        CImGui.SameLine()
                        CImGui.Text(value_str)
                    end
                end

            # elseif event_argtype == "Float64-preset"
            #     if  CImGui.Button("Send $(event_argdefault)##$event_name-$i")
            #         block.waiting_for_status = true
            #         corr_num, len_sent = sendevents(
            #             block.aeron_event_pub;
            #             (Symbol(event_name) => event_argdefault,)...
            #         )
            #         if len_sent == 0
            #             err_msg =  "service not listening"
            #             err_msg_timeout = time() + 3
            #         end
            #     end
            elseif event_argtype == "Int"
                CImGui.InputInt("##$event_name-$i", ref, 1)
                CImGui.SameLine()
                if  CImGui.Button("Send##$event_name-$i") || sendall
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
                CImGui.Checkbox("##$event_name-$i", ref′)
                ref[] = ref′[]
                CImGui.SameLine()
                if  CImGui.Button("Send##$event_name-$i") || sendall
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
                CImGui.InputText("##$event_name-$i", ref[], length(ref[]))
                CImGui.SameLine()
                if  CImGui.Button("Send##$event_name-$i") || sendall
                    block.waiting_for_status = true
                    corr_num, len_sent = sendevents(
                        block.aeron_event_pub;
                        keepstr=true,
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
            
            # 1D paddle buttons for jogging
            if event_argtype == "JogControl"
                pressed_minus = CImGui.SmallButton("J-##$event_name-$i-1")
                CImGui.SameLine()
                pressed_plus  = CImGui.SmallButton("J+##$event_name-$i-1")
                changed = false
                if pressed_minus
                    changed = true
                    val = -1
                elseif pressed_plus
                    changed = true
                    val = +1
                end
                if changed
                    block.waiting_for_status = true
                    corr_num, len_sent = sendevents(
                        block.aeron_event_pub;
                        (Symbol(event_name) => Float64(val),)...
                    )
                    if len_sent == 0
                        err_msg =  "service not listening"
                        err_msg_timeout = time() + 3
                    end
                end
            # 2D arrows to bump up and down
            elseif event_argtype == "array-paddle" && found && !isnothing(val)
                r1 = Ref{Float32}(val[1])
                r2 = Ref{Float32}(val[2])
                changed  = CImGui.InputFloat("##$event_name-$i-1", r1, 1.0)
                changed |= CImGui.InputFloat("##$event_name-$i-2", r2, 1.0)
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


                if CImGui.CollapsingHeader("$event_name##$i")
                    for j in eachindex(refs)
                        # changed |= CImGui.DragFloat("$j##$event_name-$i-$j", refs[j], 0.001)
                        changed |= CImGui.SliderFloat("$j##$event_name-$i-$j", refs[j], 0.0, 2.0,"%.3g")

                    end
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
            elseif event_argtype == "array-group-sliders-lowfs" && found && !isnothing(val)
                l = length(val)
                refs = [Ref{eltype(val)}(v) for v in val]
                changed1 = CImGui.SliderFloat("TT##$event_name-$i", refs[1], 0.0, 1.5, "%.3g")
                if changed1
                    for r in refs[1:2]
                        r[] = refs[1][]
                    end
                end
                changed2 = false
                if length(refs) > 2
                changed2 = CImGui.SliderFloat("LO##$event_name-$i", refs[3], 0.0, 1.5, "%.3g")
                if changed2
                    for r in refs[3:end]
                        r[] = refs[3][]
                    end
                end
                end
                changed = changed1 | changed2
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
            elseif event_argtype == "array-group-sliders-scc" && found && !isnothing(val)
                l = length(val)
                refs = [Ref{eltype(val)}(v) for v in val]
                changed_tt = CImGui.SliderFloat("TT##$event_name-$i", refs[1], 0.0, 1.5, "%.3g")
                if changed_tt
                    for r in refs[1:2]
                        r[] = refs[1][]
                    end
                end
                changed_lo = CImGui.SliderFloat("LO##$event_name-$i", refs[3], 0.0, 1.5, "%.3g")
                if changed_lo
                    for r in refs[3:14]
                        r[] = refs[3][]
                    end
                end
                changed1 = CImGui.SliderFloat("RS##$event_name-$i", refs[18], 0.0, 1.5, "%.3g")
                if changed1
                    for r in refs[15:150]
                        r[] = refs[18][]
                    end
                end
                changed2 = CImGui.SliderFloat("MID##$event_name-$i", refs[151], 0.0, 1.5, "%.3g")
                if changed2
                    for r in refs[151:300]
                        r[] = refs[151][]
                    end
                end
                changed3 = CImGui.SliderFloat("HI##$event_name-$i", refs[301], 0.0, 1.5, "%.3g")
                if changed3
                    for r in refs[301:end]
                        r[] = refs[301][]
                    end
                end
                changed = changed_tt | changed_lo | changed1 | changed2 | changed3
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
             elseif event_argtype == "array-group-sliders" && found && !isnothing(val)
                l = length(val)
                refs = [Ref{eltype(val)}(v) for v in val]
                changed1 = CImGui.SliderFloat("TT##$event_name-$i", refs[1], 0.0, 1.5, "%.3g")
                if changed1
                    for r in refs[1:2]
                        r[] = refs[1][]
                    end
                end
                changed2 = CImGui.SliderFloat("LO##$event_name-$i", refs[3], 0.0, 1.5, "%.3g")
                if changed2
                    for r in refs[3:15]
                        r[] = refs[3][]
                    end
                end
                changed3 = CImGui.SliderFloat("HI##$event_name-$i", refs[25], 0.0, 1.5, "%.3g")
                if changed3
                    for r in refs[16:end]
                        r[] = refs[25][]
                    end
                end
                changed = changed1 | changed2 | changed3
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

