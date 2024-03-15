using Aeron
mutable struct ImageFeed
    const name::String
    const aeron_config::AeronConfig
    const aeron_watch_handle::Aeron.AeronWatchHandle
    last_img::Matrix{Float32}
    first_view::Bool
end
function ImageFeed(conf)
    aeron_config = AeronConfig(conf["input-channel"], conf["input-stream"])
    subscription = Aeron.subscriber(aeron, aeron_config)

    watch_handle = Aeron.watch(subscription) do frame
        try
            ten = TensorMessage(frame.buffer, initialize=false)
            if size(feed.last_img) != size(ten)
                feed.last_img = Float32.(SpidersMessageEncoding.arraydata(ten))
                feed.first_view = true
            else
                feed.last_img .= Float32.(SpidersMessageEncoding.arraydata(ten))
            end
        catch err
            @error "Error receiving image update" exception=(err, catch_backtrace())
        end
    end

    feed = ImageFeed(conf["name"], aeron_config, watch_handle, zeros(Float32, 0, 0), true)

    return feed
end
name(iv::ImageFeed) = iv.name





function gui_panel(::Type{ImageFeed}, component_config)

    err_msg = nothing

    # Embeded image viewer panel
    child_imview = ImageViewer(Dict("name"=>component_config["name"]))
    child_imview_draw = gui_panel(ImageViewer, Dict{String,Any}(
        "name"=>component_config["name"]
    ); ischild=true, child_size=(-1,-30))

    first_view_0 = true

    function draw(image_feed, visible)
        # Only do work assembling incoming messages if the panel is visible
        Aeron.active(image_feed.aeron_watch_handle, visible[]) 
        image_feed.aeron_watch_handle.decimate_time = 1/60

        CImGui.SetNextWindowSize((350,350), CImGui.ImGuiCond_FirstUseEver)

        if !CImGui.Begin(component_config["name"], visible)#, ImGuiWindowFlags_MenuBar)
            return
        end
        if image_feed.first_view || first_view_0
            child_imview.new_contents = image_feed.last_img
            child_imview.new_action = "="
            child_imview.new_name = "image feed"
        end
        first_view_0 = image_feed.first_view = false
        

        if !isnothing(err_msg)
            CImGui.TextColored(bad_color, "ERROR:")
            CImGui.SameLine();
            CImGui.TextWrapped(err_msg)
            if CImGui.Button("Clear") 
                err_msg = nothing
            end
        end


        child_imview_draw(child_imview, true)

        CImGui.End() # End of this panel

    end


    return draw
end

