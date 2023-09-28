using Aeron
using AstroImages
mutable struct DMFeed
    const name::String
    const aeron_config::AeronConfig
    const aeron_watch_handle::Aeron.AeronWatchHandle
    actuator_map::BitMatrix
    valid_actuator_map::BitMatrix
    last_cmd_map::Matrix{Float32}
    last_update_time::Base.RefValue{Float64}
    const idle_timeout::Float64
end
function DMFeed(conf)
    aeron_config = AeronConfig(conf["input-channel"], conf["input-stream"])
    actuator_map = BitMatrix(load(conf["actuator-map"]))
    valid_actuator_map = BitMatrix(load(conf["valid-actuator-map"]))
    idle_timeout = conf["idle-timeout"]
    subscription = Aeron.subscribe(aeron_config)
    last_update_time = Ref(0.0)

    last_cmd_map = zeros(Float32, size(actuator_map))

    watch_handle = Aeron.watch(subscription) do frame
        header = VenomsWireFormat(frame.buffer)
        # @info "Message received" SizeX(header) SizeY(header) TimestampNs(header)
        # display(header)
        image = Image(header)
        last_cmd_map[actuator_map] .= vec(image)
        last_update_time[] = time()
    end
    feed = DMFeed(
        conf["name"],
        aeron_config,
        watch_handle,
        actuator_map,
        valid_actuator_map,
        last_cmd_map,
        last_update_time,
        idle_timeout
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


        inactive = time() - dm_feed.last_update_time[] > dm_feed.idle_timeout

        # @info "stat" time() - dm_feed.last_update_time[] dm_feed.idle_timeout inactive
        # @info "stat" dm_feed.last_update_time[] dm_feed.idle_timeout inactive
        CImGui.SetNextWindowSize((350,350), CImGui.ImGuiCond_FirstUseEver)

        if inactive
            CImGui.PushStyleColor(ImGuiCol_Text, CImGui.IM_COL32(0xff, 0x22, 0x22, 0xff));
        end
        ret = CImGui.Begin(component_config["name"], visible)#, ImGuiWindowFlags_MenuBar)
        CImGui.PopStyleColor()
        if !ret
            
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

