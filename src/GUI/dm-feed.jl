using Aeron
using AstroImages
mutable struct DMFeed
    const name::String
    const aeron_config::AeronConfig
    const aeron_watch_handle::Aeron.AeronWatchHandle
    actuator_map::BitMatrix
    valid_actuator_map::BitMatrix
    last_cmd_map::Matrix{Float32}
end
function DMFeed(conf)
    aeron_config = AeronConfig(conf["input-channel"], conf["input-stream"])
    actuator_map = BitMatrix(load(conf["actuator-map"]))
    valid_actuator_map = BitMatrix(load(conf["valid-actuator-map"]))

    subscription = Aeron.subscribe(aeron_config)

    last_cmd_map = zeros(Float32, size(actuator_map))

    watch_handle = Aeron.watch(subscription) do frame
        header = VenomsWireFormat(frame.buffer)
        # @info "Message received" SizeX(header) SizeY(header) TimestampNs(header)
        # display(header)
        image = Image(header)
        last_cmd_map[actuator_map] .= vec(image)
    end
    feed = DMFeed(
        conf["name"],
        aeron_config,
        watch_handle,
        actuator_map,
        valid_actuator_map,
        last_cmd_map
    )

    return feed
end
name(iv::DMFeed) = iv.name





function gui_panel(::Type{DMFeed}, component_config)

    err_msg = nothing

    # Embeded image viewer panel
    dm_cmd_draw = nothing

    first_view = true

    function draw(dm_feed, visible)
        # Only do work assembling incoming messages if the panel is visible
        Aeron.active(dm_feed.aeron_watch_handle, visible[]) 
        # Not safe to decimate DM commands since they don't always come as continuous 
        # high speed streams. We might miss the last one and not show an important command
        dm_feed.aeron_watch_handle.decimate_time = 0
        CImGui.SetNextWindowSize((350,350), CImGui.ImGuiCond_FirstUseEver)
        if !CImGui.Begin(component_config["name"], visible)#, ImGuiWindowFlags_MenuBar)
            return
        end
        if first_view
            dm_cmd_draw = plot_dm_commands(dm_feed)
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


        dm_cmd_draw(dm_feed.last_cmd_map)

        CImGui.End() # End of this panel

    end


    return draw
end

