using Printf
using LinearAlgebra
using Aeron
using SpidersMessageEncoding

mutable struct Galil
    const name::String
    const aeron_event_pub::Aeron.AeronPublication
    const aeron_status_sub::Aeron.AeronSubscription
    const aeron_watch_handle::Aeron.AeronWatchHandle
    status::Dict{Symbol,Any}
    waiting_for_status::Bool
end
function Galil(conf)
    aeron_event_config = AeronConfig(conf["event-channel"], conf["event-stream"])
    aeron_status_config = AeronConfig(conf["status-channel"], conf["status-stream"])
    aeron_event_pub = Aeron.publisher(aeron, aeron_event_config)
    aeron_status_sub = Aeron.subscriber(aeron, aeron_status_config)
    status = Dict{Symbol,Any}()
    
    block = nothing
    watch_handle = Aeron.watch(aeron_status_sub) do frame
        if isnothing(block)
            return
        end
        try
            event = EventMessage(frame.buffer, initialize=false)
            @info "event" component=conf["name"] event=string(event.name)
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
    block = Galil(
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
name(g::Galil) = g.name

function gui_panel(::Type{Galil}, component_config)

    err_msg = nothing
    err_msg_timeout = time()
    first_view = true
    coarse = Ref(false)

    event_fields_ref = map(component_config["event-fields"]) do event_spec
        event_name, event_argtype, event_argdefault = event_spec
        if event_argtype == "Float64"
            arg_val_ref = Ref(parse(Float32, event_argdefault))
        elseif event_argtype == "Int"
            arg_val_ref = Ref(parse(Int32, event_argdefault))
        elseif event_argtype == "String" || startswith(event_argtype, "array")
            arg_val_ref = Ref(event_argdefault * "\0"^100)
        elseif event_argtype == "Bool"
            arg_val_ref = Ref(parse(Int, event_argdefault) > 0)
        else
            Ref{Any}(nothing)
        end
    end

    position = Dict{String,Dict{String,Ref{Float32}}}()
    for (bandname, bandconf) in component_config["band"]
        position[bandname] = Dict{String,Ref{Float32}}()
        for (axisname, _) in bandconf["position_mm"]
            position[bandname][axisname] = Ref{Float32}(bandconf["position_mm"][axisname])
        end
    end

    band_index = Ref{Int32}(0)

    function draw(block, visible)
        CImGui.SetNextWindowSize((350,350), CImGui.ImGuiCond_FirstUseEver)

        if !CImGui.Begin(component_config["name"], visible)
            CImGui.End()
            return
        end
        if first_view
        end
        first_view = false
        if !isnothing(err_msg)
            CImGui.TextColored(bad_color, "ERROR:")
            CImGui.SameLine()
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
            CImGui.PushStyleColor(ImGuiCol_Text, CImGui.IM_COL32(0xFF, 0xCC, 0x00, 0xff))
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
            CImGui.PushStyleColor(ImGuiCol_Text, CImGui.IM_COL32(0x42, 0x87, 0xf5, 0xff))
            CImGui.Text("$state")
            CImGui.PopStyleColor()
        end
        CImGui.PopFont()

        CImGui.Spacing()

        for event_name in component_config["event-buttons"]
            if CImGui.Button(event_name * "##user-button$event_name")
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

        sendall = CImGui.Button("Send all")
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
                if CImGui.Button("Send##$event_name") || sendall
                    block.waiting_for_status = true
                    corr_num, len_sent = sendevents(
                        block.aeron_event_pub;
                        (Symbol(event_name) => ref[],)...
                    )
                    if len_sent == 0
                        err_msg = "service not listening"
                        err_msg_timeout = time() + 3
                    end
                end
            elseif event_argtype == "Int"
                CImGui.InputInt("##$event_name", ref, 1)
                CImGui.SameLine()
                if CImGui.Button("Send##$event_name") || sendall
                    block.waiting_for_status = true
                    corr_num, len_sent = sendevents(
                        block.aeron_event_pub;
                        (Symbol(event_name) => ref[],)...
                    )
                    if len_sent == 0
                        err_msg = "service not listening"
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
                if CImGui.Button("Send##$event_name") || sendall
                    block.waiting_for_status = true
                    corr_num, len_sent = sendevents(
                        block.aeron_event_pub;
                        (Symbol(event_name) => ref[],)...
                    )
                    if len_sent == 0
                        err_msg = "service not listening"
                        err_msg_timeout = time() + 3
                    end
                end
            elseif event_argtype == "String" || startswith(event_argtype, "array")
                if isnothing(ref[])
                    ref[] = ""
                end
                CImGui.InputText("##$event_name", ref[], length(ref[]))
                CImGui.SameLine()
                if CImGui.Button("Send##$event_name") || sendall
                    block.waiting_for_status = true
                    corr_num, len_sent = sendevents(
                        block.aeron_event_pub;
                        keepstr=true,
                        (Symbol(event_name) => strip(ref[], '\0'),)...
                    )
                    if len_sent == 0
                        err_msg = "service not listening"
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
                changed = CImGui.InputFloat("##$event_name-1", r1, 1.0)
                changed |= CImGui.InputFloat("##$event_name-2", r2, 1.0)
                if sendall || changed
                    block.waiting_for_status = true
                    corr_num, len_sent = sendevents(
                        block.aeron_event_pub;
                        (Symbol(event_name) => Float32[r1[], r2[]],)...
                    )
                    if len_sent == 0
                        err_msg = "service not listening"
                        err_msg_timeout = time() + 3
                    end
                end
            elseif event_argtype == "array-sliders" && found && !isnothing(val)
                l = length(val)
                refs = [Ref{eltype(val)}(v) for v in val]
                changed = false
                for i in eachindex(refs)
                    # changed |= CImGui.DragFloat("$i##$event_name-$i", refs[i], 0.001)
                    changed |= CImGui.SliderFloat("$i##$event_name-$i", refs[i], 0.0, 2.0)

                end
                if sendall || changed
                    block.waiting_for_status = true
                    corr_num, len_sent = sendevents(
                        block.aeron_event_pub;
                        (Symbol(event_name) => getindex.(refs),)...
                    )
                    if len_sent == 0
                        err_msg = "service not listening"
                        err_msg_timeout = time() + 3
                    end
                end
            end
        end        

        ###################
        # Custom controls
        ###################

        changed = false

        # CImGui.SameLine()
        # if CImGui.SmallButton("Reset")
        #     changed = true
        # end

        config_file_ref = Ref(component_config["config-file"])
        CImGui.Text("Configuration File")
        CImGui.InputText("##GallConfigFile", config_file_ref[], length(config_file_ref[]))
        CImGui.SameLine()

        # Load the values from the configuration file
        if CImGui.Button("Load")
            positions = TOML.parsefile(config_file_ref[])
        end

        bands = collect(keys(position))  # Convert to array

        # Use the band names as strings
        band_names = [string(band) for band in bands]
        CImGui.Text("Band")
        CImGui.Combo("##band", band_index, band_names)

        # Get the selected band
        selected_band = bands[band_index[]+1]

        CImGui.Checkbox("Coarse", coarse)

        for (name, label) in sort(collect(component_config["axis"]), by=first)
            CImGui.Text("$label position")
            if CImGui.Button("Home##$(name)")
                event_name = "HomeAxis$name"
                block.waiting_for_status = true
                corr_num, len_sent = sendevents(
                    block.aeron_event_pub;
                    (Symbol(event_name) => "$name",)...
                )
                if len_sent == 0
                    err_msg = "service not listening"
                    err_msg_timeout = time() + 3
                end
            end
            CImGui.SameLine()
            increment = Float64(coarse[] ? 0.01 : 0.001)
            if CImGui.InputFloat("##position_$(name)", position[selected_band][name], increment, 0.05, "%.5f mm")
                position[selected_band][name][] = clamp(position[selected_band][name][], 0.0, 12.0)
                changed = true
            end
            CImGui.SameLine()
            if CImGui.Button("Move##$(name)")
                event_name = "MoveAxis$name"
                block.waiting_for_status = true
                corr_num, len_sent = sendevents(
                    block.aeron_event_pub;
                    (Symbol(event_name) => position[selected_band][name][],)...
                )
                if len_sent == 0
                    err_msg = "service not listening"
                    err_msg_timeout = time() + 3
                end
                # Save the position in the configuration file
                open(config_file_ref[], "w") do io
                    # TOML.print(io, position)
                end
            end
        end

        CImGui.End()

        return
    end
end
