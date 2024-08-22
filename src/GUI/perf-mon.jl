using Aeron
using LinearAlgebra
using AstroImages
mutable struct PerfMon
    const name::String
    const aeron_config::AeronConfig
    const aeron_watch_handle::Aeron.AeronWatchHandle
    last_histogram::Vector{Float32}
end
function PerfMon(conf)
    aeron_config = AeronConfig(conf["input-channel"], conf["input-stream"])
    last_histogram = zeros(Float32, 0)
    subscription = Aeron.subscriber(aeron, aeron_config)
    counter = Ref(0)

    # Julia fast closure bug workaround
    watch_handle = let counter=counter, last_histogram=last_histogram
        watch_handle = Aeron.watch(subscription) do frame
            try
                msg = ArrayMessage{Int64,1}(frame.buffer, initialize=false)
                arr = SpidersMessageEncoding.arraydata(msg)
                resize!(last_histogram, length(arr))
                last_histogram .= arr # downconvert from Int64 to Float32 for plotting
            catch err
                @error "Error receiving OPD update" exception=(err, catch_backtrace())
            end
        end 
    end
    feed = PerfMon(
        conf["name"],
        aeron_config,
        watch_handle,
        last_histogram,
    )

    return feed
end
name(iv::PerfMon) = iv.name





function gui_panel(::Type{PerfMon}, component_config)

    err_msg = nothing


    first_view = true

    bins_x_ns = Float32.(0:10_000:5_000_000)
    bins_x_ms = bins_x_ns ./ 1e6

    ax = nothing

    function draw(perfmon, visible)
        # Only do work assembling incoming messages if the panel is visible
        Aeron.active(perfmon.aeron_watch_handle, visible[]) 
        # Not safe to decimate DM commands since they don't always come as continuous 
        # high speed streams. We might miss the last one and not show an important command
        perfmon.aeron_watch_handle.decimate_time = 0
        CImGui.SetNextWindowSize((350,350), CImGui.ImGuiCond_FirstUseEver)
        if !CImGui.Begin(component_config["name"], visible, ImGuiWindowFlags_MenuBar)
            return
        end
        if first_view
        end
        first_view = false


        if CImGui.BeginMenuBar()
            if CImGui.BeginMenu("File")
                if CImGui.MenuItem("Save vector to FITS")
                    fnameout = "/tmp/perfmon-hist.fits"
                    out = copy(perfmon.last_histogram)
                    AstroImages.writefits(fnameout, out)
                    @info "DM command vector ($(perfmon.name)) written" fnameout
                end
                CImGui.EndMenu()
            end
            CImGui.EndMenuBar()
        end


        if !isnothing(err_msg)
            CImGui.TextColored(bad_color, "ERROR:")
            CImGui.SameLine();
            CImGui.TextWrapped(err_msg)
            if CImGui.Button("Clear") 
                err_msg = nothing
            end
        end


        w = CImGui.GetWindowWidth() - 10
        h = (CImGui.GetWindowHeight() - 60)
        plotsize = ImVec2(w,h)
        
        # if ImPlot.BeginPlot(
        #     "##perfmon",
        #     plotsize,
        #     ImPlot.ImPlotFlags_Crosshairs |
        #     ImPlot.ImPlotFlags_NoLegend
        # )
        #     ImPlot.SetupAxis(ImPlot.ImAxis_X1, "frame number (arb)",ImPlot.ImPlotAxisFlags_AutoFit)
        #     ImPlot.SetupAxis(ImPlot.ImAxis_Y1, "OPD (angstrom)",ImPlot.ImPlotAxisFlags_AutoFit)
        #     ImPlot.SetupFinish()
        #     ImPlot.SetNextLineStyle(ImVec4(1f0, 1.f0, 1f0, 0.25f0););

        #     if perfmon.counter[] != 0
        #         @views ImPlot.PlotLine("Integrated", perfmon.opd_history[:,1], perfmon.opd_history[:,2], size(perfmon.opd_history,1), 0, perfmon.counter[]);
        #         ImPlot.PushStyleVar(ImPlot.ImPlotStyleVar_FillAlpha, 0.75f0);
        #         ImPlot.SetNextMarkerStyle(ImPlot.ImPlotMarker_Circle, 6, ImPlot.GetColormapColor(0), ImPlot.IMPLOT_AUTO, ImPlot.GetColormapColor(0));
        #         x .= perfmon.opd_history[perfmon.counter[],1]
        #         y .= perfmon.opd_history[perfmon.counter[],2]
        #         ImPlot.PlotScatter("Integrated (latest)", x, y, 1);
        #         ImPlot.PopStyleVar();
        #     end

        #     ImPlot.EndPlot()
        # end

        if ImPlot.BeginPlot(
            "##perfmon-histplot",
            plotsize,
            ImPlot.ImPlotFlags_Crosshairs |
            ImPlot.ImPlotFlags_NoLegend,
        )
            ImPlot.SetupAxis(ImPlot.ImAxis_X1, "latency [ms]")
            ImPlot.SetupAxis(ImPlot.ImAxis_Y1, "counts")
            ImPlot.SetupFinish()
            ImPlot.PlotLine("#hist", bins_x_ms, perfmon.last_histogram, size(perfmon.last_histogram,1));
            ImPlot.EndPlot()

            CImGui.SameLine();
        end

        CImGui.End() # End of this panel

    end


    return draw
end

