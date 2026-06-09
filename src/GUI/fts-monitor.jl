using Aeron
using LinearAlgebra
using AstroImages
mutable struct FTSMonitor
    const name::String
    const aeron_config::AeronConfig
    const aeron_watch_handle::Aeron.AeronWatchHandle
    opd_history::Vector{Float32}
    vel_history::Vector{Float32}
    counter::Base.RefValue{Int}
end
function FTSMonitor(conf)
    aeron_config = AeronConfig(conf["input-channel"], conf["input-stream"])
    history_length = conf["history-length"]
    opd_history = zeros(Float32, history_length)
    vel_history = zeros(Float32, history_length)
    subscription = Aeron.subscriber(aeron, aeron_config)
    counter = Ref(0)

    # Julia fast closure bug workaround
    watch_handle = let counter=counter, opd_history=opd_history
        watch_handle = Aeron.watch(subscription) do frame
            try
                opd_msg = ArrayMessage{Int64,1}(frame.buffer, initialize=false)
                counter[] += 1
                if counter[] > size(opd_history,1)
                    counter[] = 1
                end
                opd_history[counter[]] = only(SpidersMessageEncoding.arraydata(opd_msg))
                if counter[] > 1
                    vel_history[counter[]] = abs(opd_history[counter[]] - opd_history[counter[]-1])
                end
            catch err
                @error "Error receiving OPD update" exception=(err, catch_backtrace())
            end
        end 
    end
    feed = FTSMonitor(
        conf["name"],
        aeron_config,
        watch_handle,
        opd_history,
        vel_history,
        counter,
    )

    return feed
end
name(iv::FTSMonitor) = iv.name





function gui_panel(::Type{FTSMonitor}, component_config)

    err_msg = nothing


    first_view = true

    x = [0f0]
    y = [0f0]

    ax = nothing

    function draw(ftsmon, visible)
        # Only do work assembling incoming messages if the panel is visible
        Aeron.active(ftsmon.aeron_watch_handle, visible[]) 
        # Not safe to decimate DM commands since they don't always come as continuous 
        # high speed streams. We might miss the last one and not show an important command
        ftsmon.aeron_watch_handle.decimate_time = 0
        CImGui.SetNextWindowSize((350,350), CImGui.ImGuiCond_FirstUseEver)
        if !CImGui.Begin(component_config["name"], visible)#, ImGuiWindowFlags_MenuBar)
            return
        end
        if first_view
            ax = collect(Float32.(axes(ftsmon.opd_history,1)))
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
        h = (CImGui.GetWindowHeight() - 40)/2
        plotsize = ImVec2(w,h)
        
        # if ImPlot.BeginPlot(
        #     "##ftsmon",
        #     plotsize,
        #     ImPlot.ImPlotFlags_Crosshairs |
        #     ImPlot.ImPlotFlags_NoLegend
        # )
        #     ImPlot.SetupAxis(ImPlot.ImAxis_X1, "frame number (arb)",ImPlot.ImPlotAxisFlags_AutoFit)
        #     ImPlot.SetupAxis(ImPlot.ImAxis_Y1, "OPD (angstrom)",ImPlot.ImPlotAxisFlags_AutoFit)
        #     ImPlot.SetupFinish()
        #     ImPlot.SetNextLineStyle(ImVec4(1f0, 1.f0, 1f0, 0.25f0););

        #     if ftsmon.counter[] != 0
        #         @views ImPlot.PlotLine("Integrated", ftsmon.opd_history[:,1], ftsmon.opd_history[:,2], size(ftsmon.opd_history,1), 0, ftsmon.counter[]);
        #         ImPlot.PushStyleVar(ImPlot.ImPlotStyleVar_FillAlpha, 0.75f0);
        #         ImPlot.SetNextMarkerStyle(ImPlot.ImPlotMarker_Circle, 6, ImPlot.GetColormapColor(0), ImPlot.IMPLOT_AUTO, ImPlot.GetColormapColor(0));
        #         x .= ftsmon.opd_history[ftsmon.counter[],1]
        #         y .= ftsmon.opd_history[ftsmon.counter[],2]
        #         ImPlot.PlotScatter("Integrated (latest)", x, y, 1);
        #         ImPlot.PopStyleVar();
        #     end

        #     ImPlot.EndPlot()
        # end

        if ImPlot.BeginPlot(
            "##ftsmon-timeseries",
            plotsize,
            ImPlot.ImPlotFlags_Crosshairs |
            ImPlot.ImPlotFlags_NoLegend
        )
            ImPlot.SetupAxis(ImPlot.ImAxis_X1, "camera frame (arb.)")
            ImPlot.SetupAxis(ImPlot.ImAxis_Y1, "optical path difference (A)")
            ImPlot.SetupFinish()
            ImPlot.PlotLine("#OPD", ax, ftsmon.opd_history, size(ftsmon.opd_history,1));
            ImPlot.EndPlot()

            CImGui.SameLine();
        end

        CImGui.Text("ANC")


        if ImPlot.BeginPlot(
            "##ftsmon-velseries",
            plotsize,
            ImPlot.ImPlotFlags_Crosshairs |
            ImPlot.ImPlotFlags_NoLegend
        )
            ImPlot.SetupAxis(ImPlot.ImAxis_X1, "camera frame (arb.)")
            ImPlot.SetupAxis(ImPlot.ImAxis_Y1, "dOPD (A)")
            ImPlot.SetupFinish()
            ImPlot.PlotLine("dOPD", ax, ftsmon.vel_history, size(ftsmon.opd_history,1));
            ImPlot.EndPlot()

            CImGui.SameLine();
        end


        # TODO: moving vertical line at counter position

        CImGui.End() # End of this panel

    end


    return draw
end

