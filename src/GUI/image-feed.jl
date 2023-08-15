using Aeron
mutable struct ImageFeed
    const name::String
    const aeron_config::AeronConfig
    const aeron_watch_handle::Aeron.AeronWatchHandle
    last_img::Matrix{Float32}
end
function ImageFeed(conf)
    aeron_config = AeronConfig(conf["input-channel"], conf["input-stream"])
    subscription = Aeron.subscribe(aeron_config)
    watch_handle = Aeron.watch(subscription) do frame
        header = VenomsWireFormat(frame.buffer)

        # @info "Message received" SizeX(header) SizeY(header) TimestampNs(header)
        # display(header)
        image = Image(header)

        # Check if last image compatible with new dimensions and data type
        # copy into last img
        if size(feed.last_img) != size(image)
            @info "New image feed dimensions received"
            feed.last_img = Float32.(image)
        else
            feed.last_img .= image
        end
    end
    feed = ImageFeed(conf["name"], aeron_config, watch_handle, zeros(Float32, 0, 0))

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

    first_view = true

    function draw(image_feed, visible)
        # Only do work assembling incoming messages if the panel is visible
        Aeron.active(image_feed.aeron_watch_handle, visible[]) 
        image_feed.aeron_watch_handle.decimate_time = 1/60
        if !CImGui.Begin(component_config["name"], visible)#, ImGuiWindowFlags_MenuBar)
            return
        end
        if first_view
            child_imview.new_contents = image_feed.last_img
            child_imview.new_action = "="
            child_imview.new_name = "image feed"
        end
        first_view = false
        # if CImGui.BeginMenuBar()

        #     if CImGui.BeginMenu("Device")

        #         # If not connected, do not proceed
        #         if isnothing(camera)
        #             if connecting
        #                 device_status_msg = "Connecting..."
        #             elseif CImGui.MenuItem("Connect")
        #                 # TODO Error handling
        #                 Threads.@spawn try
        #                     cam = connectdevice(component_config["name"])
        #                     # capture(cam)
        #                     device_status_msg = nothing
        #                 catch err
        #                     err_msg = string(err)
        #                     @error "Could not connect to camera" exception=err
        #                     Base.show_backtrace(stderr, catch_backtrace())
        #                 finally
        #                     connecting = false
        #                 end
        #                 connecting = true
        #             end
        #         else
        #             if CImGui.MenuItem("Disconnect")
        #                 Threads.@spawn try
        #                     camtmp = camera
        #                     camera = nothing
        #                     disconnectdevice(camtmp)
        #                     img = nothing
        #                     @info "Disconnected from camera"
        #                 catch err
        #                     err_msg = string(err)
        #                     @error "Could not disconnect from camera" exception=err
        #                     Base.show_backtrace(stderr, catch_backtrace())
        #                 end
        #             end
        #         end

               


        #         CImGui.EndMenu()
        #     end

        #     if !isnothing(camera)
        #         if CImGui.BeginMenu("Calibration")
        #             CImGui.MenuItem("Record dark") && Threads.@spawn try
        #                 record_dark(camera, calib_integration)
        #             catch err
        #                 Base.show_backtrace(stderr, catch_backtrace())
        #                 rethrow(err)
        #             end
        #             CImGui.MenuItem("Record flat") && Threads.@spawn try
        #                 record_flat(camera, calib_integration)
        #             catch err
        #                 Base.show_backtrace(stderr, catch_backtrace())
        #                 rethrow(err)
        #             end
        #             CImGui.EndMenu()
        #         end

        #         if CImGui.BeginMenu("Acquisition") 
        #             CImGui.MenuItem("Start") && startAcquisition(camera)
        #             # CImGui.MenuItem("Stop") && stopAcquisition(camera)
        #             if !(camera isa GoldEye) # Stop acquisition works on gold eye but must be reconnected after, disable for now until fixed
        #                 CImGui.MenuItem("Stop") && stopAcquisition(camera)
        #             end
        #             CImGui.EndMenu()
        #         end

        #         if CImGui.BeginMenu("View") 
        #             size_x = length(crop[1])
        #             size_y = length(crop[2])
        #             regstr = "box $centre_x $centre_y $size_x $size_y # color=red"
        #             if CImGui.MenuItem("Cropped Area")
        #                 # TODO: this doesn't get updated when the panel is closed.
        #                 imview(cropped, name=component_config["name"])
        #             end
        #             if typeof(camera) <: Cred2 && CImGui.MenuItem("Buffer")
        #                 Threads.@spawn try
        #                     buf = CRED2.dump_buffer(camera, pause_acquisition=false)
        #                     cropped_buf = zeros(Float32, ceil.(Int, length.(crop)./bin)...,size(buf,3))
        #                     cropped_buf .= @view buf[crop[1][begin]:bin:crop[1][end],crop[2][begin]:bin:crop[2][end],:]
        #                     @show size(cropped_buf)
        #                     imview(DirectImage(cropped_buf, system_headers()), name="Buffer")
        #                 catch err
        #                     println(stderr,err)
        #                 end
        #             end
        #             if typeof(camera) <: Cred2 && CImGui.MenuItem("Stack")
        #                 Threads.@spawn try
        #                     buf = CRED2.dump_buffer(camera, pause_acquisition=false)
        #                     stack = mean(buf, dims=3)[:,:,1]
        #                     cropped_stack = zeros(Float32, ceil.(Int, length.(crop)./bin))
        #                     cropped_stack .= @view img[crop[1][begin]:bin:crop[1][end],crop[2][begin]:bin:crop[2][end]]
        #                     imview(DirectImage(cropped_stack, system_headers()), name="Stack")
        #                 catch err
        #                     println(stderr,err)
        #                 end
        #             end
        #             if CImGui.MenuItem("Full image (ds9)")
        #                 ds9show(DirectImage(img, system_headers()), setscale=99.5, regions=[regstr], setcmap="viridis")
        #             end
        #             if typeof(camera) <: Cred2 && CImGui.MenuItem("Stack full frames (ds9)")
        #                 Threads.@spawn begin
        #                     buf = CRED2.dump_buffer(camera, pause_acquisition=false)
        #                     stack = mean(buf, dims=3)[:,:,1]
        #                     ds9show(DirectImage(stack, system_headers()), setscale=99.5, setcmap="viridis", regions=[regstr])
        #                 end
        #             end
        #             if typeof(camera) <: Cred2 && CImGui.MenuItem("Buffer of full frames (ds9)")
        #                 Threads.@spawn begin
        #                     buf = CRED2.dump_buffer(camera, pause_acquisition=false)
        #                     ds9show(DirectImage(buf, system_headers()), setscale=99.5, setcmap="viridis", regions=[regstr])
        #                 end
        #             end
        #             CImGui.EndMenu()
        #         end
        #     end

        #     CImGui.EndMenuBar()
        # end

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

