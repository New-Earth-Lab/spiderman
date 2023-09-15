using Aeron
using LinearAlgebra
using AstroImages
mutable struct TTMonitor
    const name::String
    const aeron_config::AeronConfig
    const aeron_watch_handle::Aeron.AeronWatchHandle
    actus2modes::Matrix{Float32}
    mode_history::Matrix{Float32}
    counter::Base.RefValue{Int}
end
function TTMonitor(conf)
    aeron_config = AeronConfig(conf["input-channel"], conf["input-stream"])
    mode2actus = load(conf["modes-to-actus"])
    actus2modes = pinv(mode2actus)'
    history_length = conf["history-length"]

    mode_history = zeros(Float32, history_length, size(actus2modes,1))

    subscription = Aeron.subscribe(aeron_config)
    counter = Ref(0)

    # Julia fast closure bug workaround
    watch_handle = let mode2actus=mode2actus, counter=counter, mode_history=mode_history
        watch_handle = Aeron.watch(subscription) do frame
            header = VenomsWireFormat(frame.buffer)
            # @info "Message received" SizeX(header) SizeY(header) TimestampNs(header)
            # display(header)
            image = Image(header)
            counter[] += 1
            if counter[] > size(mode_history,1)
                counter[] = 1
            end
            v = view(mode_history, counter[], :)
            mul!(vec(v)'', actus2modes, vec(image))
        end 
    end
    feed = TTMonitor(
        conf["name"],
        aeron_config,
        watch_handle,
        actus2modes,
        mode_history,
        counter,
    )

    return feed
end
name(iv::TTMonitor) = iv.name





function gui_panel(::Type{TTMonitor}, component_config)

    err_msg = nothing


    first_view = true

    x = [0f0]
    y = [0f0]

    function draw(ttmon, visible)
        # Only do work assembling incoming messages if the panel is visible
        Aeron.active(ttmon.aeron_watch_handle, visible[]) 
        # Not safe to decimate DM commands since they don't always come as continuous 
        # high speed streams. We might miss the last one and not show an important command
        ttmon.aeron_watch_handle.decimate_time = 0
        CImGui.SetNextWindowSize((350,350), CImGui.ImGuiCond_FirstUseEver)
        if !CImGui.Begin(component_config["name"], visible)#, ImGuiWindowFlags_MenuBar)
            return
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

        w = CImGui.GetWindowWidth() - 10
        h = CImGui.GetWindowHeight() - 10
        # d = min(w,h)
        # plotsize = ImVec2(d,d)
        plotsize = ImVec2(w,h)

        # if ImPlot.BeginPlot("", "", "", plotsize, flags=ImPlot.ImPlotFlags_Equal, y_flags=ImPlotAxisFlags_NoDecorations, x_flags=ImPlotAxisFlags_NoDecorations)
        #     ImPlot.PushColormap(ImPlot.LibCImPlot.ImPlotColormap_RdBu)
        #     ImPlot.PlotHeatmap(@views(actuator_nm[:]),reverse(size(actuator_nm))...,-scale_amount[],scale_amount[]; bounds_min=act_bounds_min, bounds_max=act_bounds_max)
        #     ImPlot.PopColormap()    
        #     ImPlot.EndPlot()
        # end

        
        if ImPlot.BeginPlot(
            "##ttmon",
            plotsize,
            ImPlot.ImPlotFlags_Crosshairs |
            ImPlot.ImPlotFlags_Equal |
            ImPlot.ImPlotFlags_NoLegend
        )
            ImPlot.SetupAxis(ImPlot.ImAxis_X1, "tip")
            ImPlot.SetupAxis(ImPlot.ImAxis_Y1, "tilt")
            # ImPlot.SetupAxisLimits(ImPlot.ImAxis_X1, 0.0, float(size(commands,1)), ImGuiCond_Always)
            # ImPlot.SetupAxisLimits(ImPlot.ImAxis_Y1, 0.0, float(size(commands,2)), ImGuiCond_Always)
            ImPlot.SetupFinish()
            ImPlot.SetNextLineStyle(ImVec4(1f0, 1.f0, 1f0, 0.25f0););
            @views ImPlot.PlotLine("Integrated", ttmon.mode_history[:,1], ttmon.mode_history[:,2], size(ttmon.mode_history,1), 0, ttmon.counter[]);
            ImPlot.PushStyleVar(ImPlot.ImPlotStyleVar_FillAlpha, 0.75f0);
            ImPlot.SetNextMarkerStyle(ImPlot.ImPlotMarker_Circle, 6, ImPlot.GetColormapColor(0), ImPlot.IMPLOT_AUTO, ImPlot.GetColormapColor(0));
            x .= ttmon.mode_history[ttmon.counter[],1]
            y .= ttmon.mode_history[ttmon.counter[],2]
            ImPlot.PlotScatter("Integrated (latest)", x, y, 1);
            ImPlot.PopStyleVar();

            ImPlot.EndPlot()

            CImGui.SameLine();
        end


        CImGui.End() # End of this panel

    end


    return draw
end

