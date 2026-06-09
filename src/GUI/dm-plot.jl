using ImPlot

function plot_dm_commands(dm::DMFeed)
    actuator_nm = fill(0f0, size(dm.actuator_map))
    scale_amount=Ref(Cfloat(100))

    # sub_bestflat = Ref(true)
    sub_tt = Ref(false)

    auto_scale = true
    scale_min = 0.01f0

    # tip_1  = dm.tiptilt(0.1, 0.0)
    # tilt_1 = dm.tiptilt(0.0, 0.1)
    # tip_2  = dm.tiptilt(1.0, 0.0)
    # tilt_2 = dm.tiptilt(0.0, 1.0)

    xs = axes(dm.actuator_map,1)
    ys = axes(dm.actuator_map,2)
    xs = xs .- mean(xs)
    ys = ys .- mean(ys)
    tip_1 = dm.actuator_map .* xs .+ 0 .* ys
    tilt_1 = dm.actuator_map .* ys' .+ 0 .* xs


    function (commands)
        actuator_nm .= commands .* 10 .* 1e3
        


        actuator_nm[.! dm.valid_actuator_map] .= Inf
        # Remove any user-requested modes
        # if sub_bestflat[]
        #     commands_local .-= dot(commands_local,dm.bestflat)/dot(dm.bestflat,dm.bestflat).*dm.bestflat
        # end
        if sub_tt[]
            actuator_nm[dm.valid_actuator_map] .-= @views dot(actuator_nm[dm.valid_actuator_map],tip_1[dm.valid_actuator_map])/dot(tip_1[dm.valid_actuator_map],tip_1[dm.valid_actuator_map]).*tip_1[dm.valid_actuator_map]
            actuator_nm[dm.valid_actuator_map] .-= @views dot(actuator_nm[dm.valid_actuator_map],tilt_1[dm.valid_actuator_map])/dot(tilt_1[dm.valid_actuator_map],tilt_1[dm.valid_actuator_map]).*tilt_1[dm.valid_actuator_map]
        end 

        rmsnm = sqrt(mean(px^2 for px in view(actuator_nm, dm.valid_actuator_map)))
        actuator_nm_extrema = Float32(max(
            abs(minimum(view(actuator_nm, dm.valid_actuator_map))),
            maximum(view(actuator_nm, dm.valid_actuator_map)),
        ))

        # Set the scale a bit beyond the extrema of the current
        # command, this gives room to see transients before
        # the auto-scale adjusts
        actuator_nm_extrema *= 1.5
        w = CImGui.GetWindowWidth() -60
        h = CImGui.GetWindowHeight() - 90
        d = min(w,h)
        plotsize = ImVec2(d,d)

        # if ImPlot.BeginPlot("", "", "", plotsize, flags=ImPlot.ImPlotFlags_Equal, y_flags=ImPlotAxisFlags_NoDecorations, x_flags=ImPlotAxisFlags_NoDecorations)
        #     ImPlot.PushColormap(ImPlot.LibCImPlot.ImPlotColormap_RdBu)
        #     ImPlot.PlotHeatmap(@views(actuator_nm[:]),reverse(size(actuator_nm))...,-scale_amount[],scale_amount[]; bounds_min=act_bounds_min, bounds_max=act_bounds_max)
        #     ImPlot.PopColormap()    
        #     ImPlot.EndPlot()
        # end

        if ImPlot.BeginPlot("", plotsize, ImPlot.ImPlotFlags_Crosshairs | ImPlot.ImPlotFlags_Equal)
            cmap = ImPlot.ImPlotColormap_RdBu

            ImPlot.SetupAxis(ImPlot.ImAxis_X1, "", ImPlot.ImPlotAxisFlags_NoDecorations | ImPlot.ImPlotAxisFlags_AutoFit)
            ImPlot.SetupAxis(ImPlot.ImAxis_Y1, "", ImPlot.ImPlotAxisFlags_NoDecorations | ImPlot.ImPlotAxisFlags_AutoFit)
            # ImPlot.SetupAxisLimits(ImPlot.ImAxis_X1, 0.0, float(size(commands,1)), ImGuiCond_Always)
            # ImPlot.SetupAxisLimits(ImPlot.ImAxis_Y1, 0.0, float(size(commands,2)), ImGuiCond_Always)
            ImPlot.PushColormap(cmap)
            ImPlot.SetupFinish()
            ImPlot.PlotHeatmap(vec(actuator_nm),reverse(size(actuator_nm))...,-scale_amount[],scale_amount[]; label_fmt=C_NULL)
            ImPlot.EndPlot()
            ImPlot.PopColormap()

            CImGui.SameLine();
            ImPlot.ColormapScale("nm##cmap", -scale_amount[], scale_amount[], ImVec2(20,d), "%g", ImPlot.ImPlotColormapScaleFlags_None, cmap);
        end



        # DM commands auto-scale
        if auto_scale
            if actuator_nm_extrema >= scale_min
                if scale_amount[] == Cfloat(0.1)
                    scale_amount[] = actuator_nm_extrema
                end    
                scale_amount[] = scale_amount[] + 0.01(actuator_nm_extrema - scale_amount[])
            end
        end
        if CImGui.SmallButton("auto")
            auto_scale = true
        end
        CImGui.SameLine()
        if CImGui.SmallButton("1 nm")
            auto_scale = false
            scale_amount[] = 1
        end
        CImGui.SameLine()
        if CImGui.SmallButton("10 nm")
            auto_scale = false
            scale_amount[] = 10
        end
        #CImGui.SameLine()
        if CImGui.SmallButton("100 nm")
            auto_scale = false
            scale_amount[] = 100
        end
        CImGui.SameLine()
        if CImGui.SmallButton("1 um")
            auto_scale = false
            scale_amount[] = 1000
        end
        CImGui.SameLine()
        if CImGui.SmallButton("10 um")
            auto_scale = false
            scale_amount[] = 10000
        end

        # CImGui.Checkbox("best flat##checkbox", sub_bestflat)
        CImGui.Checkbox("sub. tip/tilt##checkbox", sub_tt)
        CImGui.SameLine()

        CImGui.Text(@sprintf("RMS (nm): %04.2f ", rmsnm))


    end
end
