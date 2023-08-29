using ImPlot

function plot_dm_commands(dm::DMFeed)
    actuator_nm = fill(0f0, size(dm.actuator_map))
    scale_amount=Ref(Cfloat(100))

    # sub_bestflat = Ref(true)
    # sub_tt = Ref(true)

    auto_scale = true
    scale_min = 0.01f0

    # tip_1  = dm.tiptilt(0.1, 0.0)
    # tilt_1 = dm.tiptilt(0.0, 0.1)
    # tip_2  = dm.tiptilt(1.0, 0.0)
    # tilt_2 = dm.tiptilt(0.0, 1.0)

    function (commands)
        actuator_nm .= commands .* 10 .* 1e3
        rmsnm = sqrt(mean(px^2 for px in vec(actuator_nm)))
        actuator_nm_extrema = Float32(max(
            abs(minimum(actuator_nm)),
            maximum(actuator_nm),
        ))
        actuator_nm[.! dm.valid_actuator_map] .= Inf
        # Remove any user-requested modes
        # if sub_bestflat[]
        #     commands_local .-= dot(commands_local,dm.bestflat)/dot(dm.bestflat,dm.bestflat).*dm.bestflat
        # end
        # if sub_tt[]
        #     commands_local .-= dot(commands_local,tip_1)/dot(tip_1,tip_1).*tip_1
        #     commands_local .-= dot(commands_local,tip_2)/dot(tip_2,tip_2).*tip_2
        #     commands_local .-= dot(commands_local,tilt_1)/dot(tilt_1,tilt_1).*tilt_1
        #     commands_local .-= dot(commands_local,tilt_2)/dot(tilt_2,tilt_2).*tilt_2
        # end 

        w = CImGui.GetWindowWidth() -80
        h = CImGui.GetWindowHeight() - 95
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
            ImPlot.ColormapScale("nm##cmap", -scale_amount[], scale_amount[], ImVec2(80,d), "%g", ImPlot.ImPlotColormapScaleFlags_None, cmap);
        end

        CImGui.Text(@sprintf("RMS: %.1f nm", rmsnm))


        # DM commands auto-scale
        if auto_scale
            if actuator_nm_extrema >= scale_min
                if scale_amount[] == Cfloat(0.1)
                    scale_amount[] = actuator_nm_extrema
                end    
                scale_amount[] = scale_amount[] + 0.015(actuator_nm_extrema - scale_amount[])
            end
        end
        if CImGui.Button("auto")
            auto_scale = true
        end
        CImGui.SameLine()
        if CImGui.Button("10 nm")
            auto_scale = false
            scale_amount[] = 10
        end
        CImGui.SameLine()
        if CImGui.Button("100 nm")
            auto_scale = false
            scale_amount[] = 100
        end
        CImGui.SameLine()
        if CImGui.Button("1 um")
            auto_scale = false
            scale_amount[] = 1000
        end
        CImGui.SameLine()
        if CImGui.Button("10 um")
            auto_scale = false
            scale_amount[] = 10000
        end

        # CImGui.Checkbox("best flat##checkbox", sub_bestflat)
        # CImGui.SameLine()
        # CImGui.Checkbox("tip/tilt##checkbox", sub_tt)



    end
end