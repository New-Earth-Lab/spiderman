# Quick Controls Panel
# A unified panel for viewing and controlling multiple mechanisms and control loops
# in a compact format.

using Aeron
using SpidersMessageSender

# Colors for button states
const qc_selected_color = ImVec4(0.2f0, 0.7f0, 0.3f0, 1.0f0)  # Green for selected
const qc_normal_color = ImVec4(0.3f0, 0.3f0, 0.3f0, 1.0f0)    # Gray for normal
const qc_inactive_color = ImVec4(0.5f0, 0.5f0, 0.2f0, 1.0f0)  # Yellow-ish for inactive/unknown

# Sub-component for control loops (Play/Pause/Stop/Reset)
mutable struct QCControlLoop
    const name::String
    const display_name::String
    const aeron_event_pub::Aeron.AeronPublication
    const aeron_status_sub::Aeron.AeronSubscription
    const aeron_watch_handle::Aeron.AeronWatchHandle
    status::Dict{Symbol,Any}
    last_heartbeat_time::Base.RefValue{Float64}
end

# Sub-component for mechanisms with position presets
mutable struct QCMechanism
    const name::String
    const display_name::String
    const aeron_event_pub::Aeron.AeronPublication
    const aeron_status_sub::Aeron.AeronSubscription
    const aeron_watch_handle::Aeron.AeronWatchHandle
    const presets::Vector{Tuple{String, Float64}}  # (name, value) pairs
    const position_tolerance::Float64
    status::Dict{Symbol,Any}
    last_heartbeat_time::Base.RefValue{Float64}
end

# Sub-component for PDU power outlets (on/off control)
mutable struct QCPDUOutlet
    const name::String
    const display_name::String
    const outlet_number::Int
    const aeron_event_pub::Aeron.AeronPublication
    const aeron_status_sub::Aeron.AeronSubscription
    const aeron_watch_handle::Aeron.AeronWatchHandle
    status::Dict{Symbol,Any}
    last_heartbeat_time::Base.RefValue{Float64}
end

# Main component
mutable struct QuickControls
    const name::String
    const control_loops::Vector{QCControlLoop}
    const mechanisms::Vector{QCMechanism}
    const pdu_outlets::Vector{QCPDUOutlet}
end

# Helper to create Aeron watch that updates status dict
function create_status_watcher(sub, status_dict, heartbeat_ref)
    return Aeron.watch(sub) do frame
        try
            heartbeat_ref[] = time()
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
            status_dict[key] = val
        catch err
            @error "QuickControls: Error receiving status" exception=(err, catch_backtrace())
        end
    end
end

function QCControlLoop(conf)
    aeron_event_pub = Aeron.publisher(aeron, AeronConfig(conf["event-channel"], conf["event-stream"]))
    aeron_status_sub = Aeron.subscriber(aeron, AeronConfig(conf["status-channel"], conf["status-stream"]))
    status = Dict{Symbol,Any}()
    heartbeat = Ref(0.0)
    watch_handle = create_status_watcher(aeron_status_sub, status, heartbeat)

    # Request initial status
    sendevents(aeron_event_pub; StatusRequest=nothing)

    return QCControlLoop(
        conf["name"],
        get(conf, "display-name", conf["name"]),
        aeron_event_pub,
        aeron_status_sub,
        watch_handle,
        status,
        heartbeat
    )
end

function QCMechanism(conf)
    aeron_event_pub = Aeron.publisher(aeron, AeronConfig(conf["event-channel"], conf["event-stream"]))
    aeron_status_sub = Aeron.subscriber(aeron, AeronConfig(conf["status-channel"], conf["status-stream"]))
    status = Dict{Symbol,Any}()
    heartbeat = Ref(0.0)
    watch_handle = create_status_watcher(aeron_status_sub, status, heartbeat)

    # Parse presets from config
    presets = Tuple{String, Float64}[]
    for preset in get(conf, "presets", [])
        push!(presets, (preset[1], Float64(preset[2])))
    end

    # Request initial status
    sendevents(aeron_event_pub; StatusRequest=nothing)

    return QCMechanism(
        conf["name"],
        get(conf, "display-name", conf["name"]),
        aeron_event_pub,
        aeron_status_sub,
        watch_handle,
        presets,
        get(conf, "position-tolerance", 1000.0),
        status,
        heartbeat
    )
end

function QCPDUOutlet(conf, shared_pub, shared_sub, shared_status, shared_heartbeat, shared_watch)
    return QCPDUOutlet(
        conf["name"],
        get(conf, "display-name", conf["name"]),
        conf["outlet"],
        shared_pub,
        shared_sub,
        shared_watch,
        shared_status,
        shared_heartbeat
    )
end

function QuickControls(conf)
    control_loops = QCControlLoop[]
    mechanisms = QCMechanism[]
    pdu_outlets = QCPDUOutlet[]

    # Build control loops
    for loop_conf in get(conf, "control-loop", [])
        push!(control_loops, QCControlLoop(loop_conf))
    end

    # Build mechanisms
    for mech_conf in get(conf, "mechanism", [])
        push!(mechanisms, QCMechanism(mech_conf))
    end

    # Build PDU outlets (all share the same Aeron pub/sub)
    pdu_conf = get(conf, "pdu", nothing)
    if !isnothing(pdu_conf)
        pdu_event_pub = Aeron.publisher(aeron, AeronConfig(pdu_conf["event-channel"], pdu_conf["event-stream"]))
        pdu_status_sub = Aeron.subscriber(aeron, AeronConfig(pdu_conf["status-channel"], pdu_conf["status-stream"]))
        pdu_status = Dict{Symbol,Any}()
        pdu_heartbeat = Ref(0.0)
        pdu_watch = create_status_watcher(pdu_status_sub, pdu_status, pdu_heartbeat)

        # Request initial status
        sendevents(pdu_event_pub; StatusRequest=nothing)

        for outlet_conf in get(pdu_conf, "outlet", [])
            push!(pdu_outlets, QCPDUOutlet(outlet_conf, pdu_event_pub, pdu_status_sub, pdu_status, pdu_heartbeat, pdu_watch))
        end
    end

    return QuickControls(conf["name"], control_loops, mechanisms, pdu_outlets)
end

name(qc::QuickControls) = qc.name


function gui_panel(::Type{QuickControls}, component_config)

    # Label column width for alignment (narrower for compact layout)
    label_width = 85.0f0
    state_column = 280.0f0

    function draw(qc::QuickControls, visible)
        CImGui.SetNextWindowSize((500, 400), CImGui.ImGuiCond_FirstUseEver)

        if !CImGui.Begin(component_config["name"], visible)
            CImGui.End()
            return
        end

        # ===== LOOPS SECTION =====
        if !isempty(qc.control_loops)
            CImGui.TextColored(ImVec4(0.7f0, 0.7f0, 1.0f0, 1.0f0), "LOOPS")
            CImGui.Separator()

            for (i, loop) in enumerate(qc.control_loops)
                draw_control_loop_row(loop, i, label_width, state_column)
            end

            CImGui.Spacing()
        end

        # ===== MECHANISMS SECTION =====
        if !isempty(qc.mechanisms)
            CImGui.TextColored(ImVec4(0.7f0, 0.7f0, 1.0f0, 1.0f0), "MECHANISMS")
            CImGui.Separator()

            for (i, mech) in enumerate(qc.mechanisms)
                draw_mechanism_row(mech, i, label_width)
            end

            CImGui.Spacing()
        end

        # ===== POWER (PDU) SECTION =====
        if !isempty(qc.pdu_outlets)
            CImGui.TextColored(ImVec4(0.7f0, 0.7f0, 1.0f0, 1.0f0), "POWER")
            CImGui.Separator()

            for (i, outlet) in enumerate(qc.pdu_outlets)
                draw_pdu_outlet_row(outlet, i, label_width)
            end
        end

        CImGui.End()
    end

    return draw
end


# Helper to check if state matches a pattern (case-insensitive, handles "Playing" matching "Play" etc.)
function state_matches(state, pattern::String)
    isnothing(state) && return false
    s = lowercase(string(state))
    p = lowercase(pattern)
    return s == p || startswith(s, p)
end

function draw_control_loop_row(loop::QCControlLoop, idx::Int, label_width::Float32, state_column::Float32)
    inactive = time() - loop.last_heartbeat_time[] > 5.0
    state = get(loop.status, :state, nothing)

    # Label
    CImGui.Text(loop.display_name * ":")
    CImGui.SameLine(label_width)

    # Send All button - sends all default values from the RTCBlock1 config
    if CImGui.SmallButton("Send All##loop$idx")
        send_all_defaults(loop)
    end
    CImGui.SameLine()

    # Play button - matches "Play", "Playing", etc.
    is_playing = state_matches(state, "play")
    if is_playing
        CImGui.PushStyleColor(ImGuiCol_Button, qc_selected_color)
    end
    if CImGui.SmallButton("Play##loop$idx")
        sendevents(loop.aeron_event_pub; Play=nothing)
    end
    if is_playing
        CImGui.PopStyleColor()
    end
    CImGui.SameLine()

    # Pause button - matches "Pause", "Paused", etc.
    is_paused = state_matches(state, "pause")
    if is_paused
        CImGui.PushStyleColor(ImGuiCol_Button, qc_selected_color)
    end
    if CImGui.SmallButton("Pause##loop$idx")
        sendevents(loop.aeron_event_pub; Pause=nothing)
    end
    if is_paused
        CImGui.PopStyleColor()
    end
    CImGui.SameLine()

    # Stop button - matches "Stop", "Stopped", etc.
    is_stopped = state_matches(state, "stop")
    if is_stopped
        CImGui.PushStyleColor(ImGuiCol_Button, qc_selected_color)
    end
    if CImGui.SmallButton("Stop##loop$idx")
        sendevents(loop.aeron_event_pub; Stop=nothing)
    end
    if is_stopped
        CImGui.PopStyleColor()
    end
    CImGui.SameLine()

    # Reset button (no highlight state)
    if CImGui.SmallButton("Reset##loop$idx")
        sendevents(loop.aeron_event_pub; Reset=nothing)
    end


    # Status display
    CImGui.SameLine(state_column)
    if isnothing(state)
        CImGui.TextColored(qc_inactive_color, "?")
    elseif inactive
        CImGui.TextColored(qc_inactive_color, "$state (stale)")
    else
        CImGui.Text("$state")
    end
end

# Send all default values from the corresponding RTCBlock1 config
function send_all_defaults(loop::QCControlLoop)
    # Look up the RTCBlock1 config by name
    comp_config = availcomponent(loop.name)
    if isnothing(comp_config)
        @warn "Could not find RTCBlock1 config for $(loop.name)"
        return
    end

    event_fields = get(comp_config, "event-fields", [])
    if isempty(event_fields)
        return
    end

    # Build kwargs for sendevents
    for event_spec in event_fields
        event_name, event_argtype, event_argdefault = event_spec[1], event_spec[2], event_spec[3]

        # Parse the default value based on type
        local val
        if event_argtype == "Float64"
            val = parse(Float64, event_argdefault)
        elseif event_argtype == "Int"
            val = parse(Int, event_argdefault)
        elseif event_argtype == "Bool"
            val = parse(Int, event_argdefault) > 0
        elseif event_argtype == "String" || startswith(event_argtype, "array")
            val = strip(event_argdefault, '\0')
        else
            # Skip unsupported types like JogControl, array-paddle, etc.
            continue
        end

        sendevents(loop.aeron_event_pub; (Symbol(event_name) => val,)...)
    end
end


# SuperK buttons for mechanism row
function draw_superk_buttons(mech::QCMechanism, idx::Int, state, inactive::Bool)
    is_waiting = state_matches(state, "waiting")

    if is_waiting
        CImGui.PushStyleColor(ImGuiCol_Button, qc_inactive_color)
        if CImGui.SmallButton("Connect##superk-m$idx")
            sendevents(mech.aeron_event_pub; Connect=nothing)
        end
        CImGui.PopStyleColor()
        CImGui.SameLine()
        CImGui.TextColored(qc_inactive_color, "(waiting)")
    else
        if CImGui.SmallButton("Interlock Off##superk-m$idx")
            sendevents(mech.aeron_event_pub; Interlock=false)
        end
        CImGui.SameLine()

        emission = get(mech.status, :Emission, nothing)
        is_on = !isnothing(emission) && emission == true

        if is_on
            CImGui.PushStyleColor(ImGuiCol_Button, qc_selected_color)
        end
        if CImGui.SmallButton("Emission On##superk-m$idx")
            sendevents(mech.aeron_event_pub; Emission=true)
        end
        if is_on
            CImGui.PopStyleColor()
        end
        CImGui.SameLine()

        if !is_on && !isnothing(emission)
            CImGui.PushStyleColor(ImGuiCol_Button, qc_selected_color)
        end
        if CImGui.SmallButton("Emission Off##superk-m$idx")
            sendevents(mech.aeron_event_pub; Emission=false)
        end
        if !is_on && !isnothing(emission)
            CImGui.PopStyleColor()
        end

        if isnothing(state)
            CImGui.SameLine()
            CImGui.TextColored(qc_inactive_color, "?")
        elseif inactive
            CImGui.SameLine()
            CImGui.TextColored(qc_inactive_color, "(stale)")
        end
    end
end

const qc_moving_color = ImVec4(0.3f0, 0.6f0, 0.9f0, 1.0f0)  # Blue for moving/homing

function draw_mechanism_row(mech::QCMechanism, idx::Int, label_width::Float32)
    inactive = time() - mech.last_heartbeat_time[] > 5.0
    state = get(mech.status, :state, nothing)
    current_pos = get(mech.status, :position, nothing)

    # Special case for SuperK Laser
    if occursin("SuperK", mech.name) || occursin("Laser", mech.name)
        # Label
        CImGui.Text(mech.display_name * ":")
        CImGui.SameLine(label_width)
        draw_superk_buttons(mech, idx, state, inactive)
        return
    end

    # Check mechanism states
    is_error = state_matches(state, "error")
    is_waiting = state_matches(state, "waiting")
    is_not_homed = state_matches(state, "nothomed") || state_matches(state, "not_homed") || state_matches(state, "not homed")
    is_homing = state_matches(state, "homing")
    is_moving = state_matches(state, "moving")

    # Label
    CImGui.Text(mech.display_name * ":")
    CImGui.SameLine(label_width)

    if is_error
        # Show Connect button when waiting for connection
        CImGui.PushStyleColor(ImGuiCol_Button, bad_color)
        if CImGui.SmallButton("Reset##mech$idx")
            sendevents(mech.aeron_event_pub; Reset=nothing)
        end
        CImGui.PopStyleColor()
        CImGui.SameLine()
        CImGui.TextColored(bad_color, "(error)")

    elseif is_waiting
        # Show Connect button when waiting for connection
        CImGui.PushStyleColor(ImGuiCol_Button, qc_inactive_color)
        if CImGui.SmallButton("Connect##mech$idx")
            sendevents(mech.aeron_event_pub; Connect=nothing)
        end
        CImGui.PopStyleColor()
        CImGui.SameLine()
        CImGui.TextColored(qc_inactive_color, "(waiting)")

    elseif is_not_homed
        # Only show Home button when not homed
        CImGui.PushStyleColor(ImGuiCol_Button, qc_inactive_color)
        if CImGui.SmallButton("Home##mech$idx")
            sendevents(mech.aeron_event_pub; Home=nothing)
        end
        CImGui.PopStyleColor()
        # CImGui.SameLine()
        # CImGui.TextColored(qc_inactive_color, "(not homed)")

    elseif is_homing
        # Show homing indicator
        CImGui.TextColored(qc_moving_color, "Homing...")

    elseif is_moving
        # Show moving indicator with disabled preset buttons
        for (j, (preset_name, preset_val)) in enumerate(mech.presets)
            # Check if this is the target position
            is_selected = false
            if !isnothing(current_pos) && current_pos isa Number
                is_selected = abs(Float64(current_pos) - preset_val) < mech.position_tolerance
            end

            # Draw disabled button
            CImGui.PushStyleVar(ImGuiStyleVar_Alpha, 0.5f0)
            if is_selected
                CImGui.PushStyleColor(ImGuiCol_Button, qc_moving_color)
            end
            CImGui.SmallButton("$preset_name##mech$idx-$j")
            if is_selected
                CImGui.PopStyleColor()
            end
            CImGui.PopStyleVar()
            CImGui.SameLine()
        end

        # Moving indicator
        CImGui.TextColored(qc_moving_color, "Moving...")

    else
        # Normal state (AtPosition or similar) - show clickable preset buttons
        for (j, (preset_name, preset_val)) in enumerate(mech.presets)
            # Check if this preset is currently selected
            is_selected = false
            if !isnothing(current_pos) && current_pos isa Number
                is_selected = abs(Float64(current_pos) - preset_val) < mech.position_tolerance
            end

            if is_selected
                CImGui.PushStyleColor(ImGuiCol_Button, qc_selected_color)
            end

            if CImGui.SmallButton("$preset_name##mech$idx-$j")
                sendevents(mech.aeron_event_pub; position=preset_val)
            end

            if is_selected
                CImGui.PopStyleColor()
            end

            CImGui.SameLine()
        end
        # Remove trailing SameLine by adding a dummy element
        CImGui.Text("")
    end
end

# Colors for PDU power states
const qc_power_on_color = ImVec4(0.2f0, 0.7f0, 0.3f0, 1.0f0)   # Green for ON
const qc_power_off_color = ImVec4(0.7f0, 0.2f0, 0.2f0, 1.0f0)  # Red for OFF

function draw_pdu_outlet_row(outlet::QCPDUOutlet, idx::Int, label_width::Float32)
    inactive = time() - outlet.last_heartbeat_time[] > 15.0

    # Get the outlet state from shared status dict
    outlet_key = Symbol("outlet_$(outlet.outlet_number)")
    raw_state = get(outlet.status, outlet_key, nothing)
    is_on = isnothing(raw_state) ? nothing : Bool(raw_state)

    # Label
    CImGui.Text(outlet.display_name * ":")
    CImGui.SameLine(label_width)

    # ON button
    if is_on === true
        CImGui.PushStyleColor(ImGuiCol_Button, qc_power_on_color)
    end
    if CImGui.SmallButton("On##pdu$idx")
        event_name = Symbol("outlet_$(outlet.outlet_number)")
        sendevents(outlet.aeron_event_pub; (event_name => 1.0,)...)
    end
    if is_on === true
        CImGui.PopStyleColor()
    end
    CImGui.SameLine()

    # OFF button
    if is_on === false
        CImGui.PushStyleColor(ImGuiCol_Button, qc_power_off_color)
    end
    if CImGui.SmallButton("Off##pdu$idx")
        event_name = Symbol("outlet_$(outlet.outlet_number)")
        sendevents(outlet.aeron_event_pub; (event_name => 0.0,)...)
    end
    if is_on === false
        CImGui.PopStyleColor()
    end

    # Status indicator
    CImGui.SameLine()
    if isnothing(is_on)
        CImGui.TextColored(qc_inactive_color, "?")
    elseif inactive
        status_text = is_on ? "ON" : "OFF"
        CImGui.TextColored(qc_inactive_color, "$status_text (stale)")
    else
        if is_on
            CImGui.TextColored(qc_power_on_color, "ON")
        else
            CImGui.TextColored(qc_power_off_color, "OFF")
        end
    end
end
