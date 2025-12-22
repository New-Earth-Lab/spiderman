# BNC Clock Generator Control Panel
# Compact GUI for controlling the BNC 525/575 pulse generator
# Features: Run/Stop, per-channel enable/disable, delay control with presets

using Aeron
using SpidersMessageSender

# Colors
const cg_running_color = ImVec4(0.2f0, 0.8f0, 0.3f0, 1.0f0)    # Bright green
const cg_stopped_color = ImVec4(0.8f0, 0.3f0, 0.2f0, 1.0f0)    # Red
const cg_enabled_color = ImVec4(0.3f0, 0.7f0, 0.4f0, 1.0f0)    # Green
const cg_disabled_color = ImVec4(0.5f0, 0.5f0, 0.5f0, 1.0f0)   # Gray
const cg_stale_color = ImVec4(0.6f0, 0.6f0, 0.3f0, 1.0f0)      # Yellow
const cg_header_color = ImVec4(0.5f0, 0.7f0, 1.0f0, 1.0f0)     # Light blue

# Delay presets (name, value in seconds)
const DELAY_PRESETS = [
    ("0", 0.0),
    ("100ns", 100e-9),
    ("1us", 1e-6),
    ("10us", 10e-6),
    ("100us", 100e-6),
    ("1ms", 1e-3),
]

mutable struct ClockGen
    const name::String
    const aeron_event_pub::Aeron.AeronPublication
    const aeron_status_sub::Aeron.AeronSubscription
    const aeron_watch_handle::Aeron.AeronWatchHandle
    status::Dict{Symbol,Any}
    last_heartbeat_time::Base.RefValue{Float64}
    # UI state for delay input fields (per channel, in microseconds for display)
    delay_input::Vector{Cfloat}
    # Track which channels are expanded
    channel_expanded::Vector{Bool}
    # Configurable channel names
    channel_names::Vector{String}
end

function ClockGen(conf)
    aeron_event_pub = Aeron.publisher(aeron, AeronConfig(conf["event-channel"], conf["event-stream"]))
    aeron_status_sub = Aeron.subscriber(aeron, AeronConfig(conf["status-channel"], conf["status-stream"]))
    status = Dict{Symbol,Any}()
    heartbeat = Ref(0.0)

    # Status watcher
    watch_handle = Aeron.watch(aeron_status_sub) do frame
        try
            heartbeat[] = time()
            event = EventMessage(frame.buffer, initialize=false)
            val = getargument(event)
            if val isa AbstractString
                val = String(val)
            elseif val isa AbstractArray
                val = collect(val)
            end
            status[Symbol(event.name)] = val
        catch err
            @error "ClockGen: Error receiving status" exception=(err, catch_backtrace())
        end
    end

    # Request initial status
    sendevents(aeron_event_pub; StatusRequest=nothing)

    # Initialize delay inputs (6 channels A-F, default 0)
    delay_input = Cfloat[0.0f0 for _ in 1:6]
    channel_expanded = Bool[true, false, false, false, false, false]

    # Channel names from config, or defaults (A-F)
    default_names = ["Ch$c" for c in 'A':'F']
    channel_names = get(conf, "channel-names", default_names)
    # Ensure we have 6 names (pad with defaults if needed)
    while length(channel_names) < 6
        push!(channel_names, "Ch$('A' + length(channel_names))")
    end

    return ClockGen(
        conf["name"],
        aeron_event_pub,
        aeron_status_sub,
        watch_handle,
        status,
        heartbeat,
        delay_input,
        channel_expanded,
        channel_names
    )
end

name(cg::ClockGen) = cg.name

function gui_panel(::Type{ClockGen}, component_config)
    # Local state
    err_msg = Ref{Union{Nothing,String}}(nothing)
    err_timeout = Ref(0.0)

    function draw(cg::ClockGen, visible)
        CImGui.SetNextWindowSize((320, 380), CImGui.ImGuiCond_FirstUseEver)

        if !CImGui.Begin(component_config["name"], visible)
            CImGui.End()
            return
        end

        inactive = time() - cg.last_heartbeat_time[] > 5.0
        state = get(cg.status, :state, nothing)
        running = get(cg.status, :running, nothing)
        device_id = get(cg.status, :device_id, "")

        if CImGui.SmallButton("Reset")
            sendevents(cg.aeron_event_pub; Reset=nothing)
        end
        CImGui.SameLine()
        if CImGui.SmallButton("StatusRequest")
            sendevents(cg.aeron_event_pub; StatusRequest=nothing)
        end
        CImGui.SameLine()
        # Show raw state
        CImGui.Text("State: $(something(state, "?"))")

        # Error display
        if !isnothing(err_msg[])
            CImGui.TextColored(ImVec4(1.0f0, 0.3f0, 0.3f0, 1.0f0), "Error: $(err_msg[])")
            if time() > err_timeout[]
                err_msg[] = nothing
            end
        end

        # ===== STATUS BAR =====
        # Compact single-line status with connection info
        if isnothing(state)
            CImGui.TextColored(cg_stale_color, "Not connected")
            CImGui.SameLine()
            if CImGui.SmallButton("Connect")
                sendevents(cg.aeron_event_pub; Connect=nothing)
            end
        elseif state == :Waiting || string(state) == "Waiting"
            CImGui.TextColored(cg_stale_color, "Waiting")
            CImGui.SameLine()
            if CImGui.SmallButton("Connect")
                sendevents(cg.aeron_event_pub; Connect=nothing)
            end
        elseif inactive
            CImGui.TextColored(cg_stale_color, "$(state) (stale)")
        else
            # Connected - show device ID briefly
            if !isempty(device_id) && device_id != ""
                CImGui.TextColored(cg_header_color, "$(device_id)")
            else
                CImGui.TextColored(cg_enabled_color, "Connected")
            end
        end

        CImGui.Separator()

        # ===== GLOBAL RUN/STOP =====
        CImGui.TextColored(cg_header_color, "MASTER")
        CImGui.SameLine(80)

        # Run button
        is_running = running === true || running == 1
        if is_running
            CImGui.PushStyleColor(ImGuiCol_Button, cg_running_color)
        end
        if CImGui.Button("RUN", (55, 0))
            sendevents(cg.aeron_event_pub; Run=nothing)
        end
        if is_running
            CImGui.PopStyleColor()
        end
        CImGui.SameLine()

        # Stop button
        is_stopped = running === false || running == 0
        if is_stopped
            CImGui.PushStyleColor(ImGuiCol_Button, cg_stopped_color)
        end
        if CImGui.Button("STOP", (55, 0))
            sendevents(cg.aeron_event_pub; Stop=nothing)
        end
        if is_stopped
            CImGui.PopStyleColor()
        end
        CImGui.SameLine()

        # Status indicator
        if isnothing(running)
            CImGui.TextColored(cg_stale_color, "?")
        elseif is_running
            CImGui.TextColored(cg_running_color, "RUNNING")
        else
            CImGui.TextColored(cg_stopped_color, "STOPPED")
        end

        CImGui.Spacing()
        CImGui.Separator()

        # ===== CHANNELS =====
        CImGui.TextColored(cg_header_color, "CHANNELS")
        CImGui.SameLine(200)
        if CImGui.SmallButton("Refresh")
            sendevents(cg.aeron_event_pub; Refresh=nothing)
        end

        CImGui.Spacing()

        # Draw each channel (A-F)
        for ch in 1:6
            draw_channel_row(cg, ch)
        end

        CImGui.Spacing()
        CImGui.Separator()


        CImGui.End()
    end

    return draw
end

function draw_channel_row(cg::ClockGen, ch::Int)
    ch_letter = Char('A' + ch - 1)  # 1->A, 2->B, etc. (for UI IDs only)
    # Service uses numeric keys internally
    enabled_key = Symbol("ch$(ch)_enabled")
    delay_key = Symbol("ch$(ch)_delay")

    ch_enabled = get(cg.status, enabled_key, nothing)
    ch_delay = get(cg.status, delay_key, nothing)

    # Update local delay input from status (convert to microseconds)
    if !isnothing(ch_delay) && ch_delay isa Number
        cg.delay_input[ch] = Cfloat(ch_delay * 1e6)  # Convert to us
    end

    # Channel label with enable/disable toggle
    is_enabled = ch_enabled === true || ch_enabled == 1

    # Compact row: [Ch#] [On/Off] [Delay input] [Presets]
    CImGui.PushID("ch$ch")

    # Channel name with color indicator
    ch_name = cg.channel_names[ch]
    if is_enabled
        CImGui.TextColored(cg_enabled_color, ch_name)
    else
        CImGui.TextColored(cg_disabled_color, ch_name)
    end
    CImGui.SameLine(70)

    # Enable/Disable toggle button
    if is_enabled
        CImGui.PushStyleColor(ImGuiCol_Button, cg_enabled_color)
        if CImGui.SmallButton("ON ##$ch")
            sendevents(cg.aeron_event_pub; (Symbol("Ch$(ch)Disable") => nothing,)...)
        end
        CImGui.PopStyleColor()
    else
        CImGui.PushStyleColor(ImGuiCol_Button, cg_disabled_color)
        if CImGui.SmallButton("OFF##$ch")
            sendevents(cg.aeron_event_pub; (Symbol("Ch$(ch)Enable") => nothing,)...)
        end
        CImGui.PopStyleColor()
    end
    CImGui.SameLine()

    # Delay input (in microseconds)
    CImGui.SetNextItemWidth(50)
    delay_ref = Ref(cg.delay_input[ch])
    changed = false
    if CImGui.DragFloat("##$ch-delay", delay_ref, 100.0, 0, 10000, "%.3f")
        cg.delay_input[ch] = delay_ref[]
        changed = true
    end
    CImGui.SameLine()
    if CImGui.SmallButton("-##$ch")
        cg.delay_input[ch] -= 100 # us
        changed = true
    end
    CImGui.SameLine()
    if CImGui.SmallButton("+##$ch")
        cg.delay_input[ch] += 100 # us
        changed = true
    end
    CImGui.SameLine()
    CImGui.Text("   us")

    # Set button - sends the delay value
    # if CImGui.SmallButton("Set")
    if changed 
        delay_seconds = Float64(cg.delay_input[ch]) * 1e-6  # Convert us to seconds
        sendevents(cg.aeron_event_pub; (Symbol("Ch$(ch)Delay") => delay_seconds,)...)
    end

    # Preset buttons on second line if channel is expanded
    if cg.channel_expanded[ch]
        # CImGui.Indent(40)
        # if CImGui.SmallButton("0##ch$(ch)")
        #         sendevents(cg.aeron_event_pub; (Symbol("Ch$(ch)Delay") => 0,)...)
        #         cg.delay_input[ch] = 0
        #     end
        # for (i, (preset_name, preset_val)) in enumerate(DELAY_PRESETS)
        #     if i > 1
        #         CImGui.SameLine()
        #     end
        #     # Highlight if current delay matches preset (within 1%)
        #     is_selected = false
        #     if !isnothing(ch_delay) && ch_delay isa Number && preset_val > 0
        #         is_selected = abs(ch_delay - preset_val) / preset_val < 0.01
        #     elseif !isnothing(ch_delay) && preset_val == 0.0
        #         is_selected = ch_delay == 0.0
        #     end

        #     if is_selected
        #         CImGui.PushStyleColor(ImGuiCol_Button, cg_enabled_color)
        #     end
        #     if CImGui.SmallButton("$(preset_name)##ch$(ch_letter)")
        #         sendevents(cg.aeron_event_pub; (Symbol("Ch$(ch_letter)Delay") => preset_val,)...)
        #         cg.delay_input[ch] = Cfloat(preset_val * 1e6)
        #     end
        #     if is_selected
        #         CImGui.PopStyleColor()
        #     end
        # end
        # CImGui.Unindent(40)
    end

    # Toggle expand/collapse for presets
    # CImGui.SameLine(290)
    # expand_label = cg.channel_expanded[ch] ? "-" : "+"
    # if CImGui.SmallButton("$(expand_label)##exp$ch")
    #     cg.channel_expanded[ch] = !cg.channel_expanded[ch]
    # end

    CImGui.PopID()
end
