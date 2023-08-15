
function plot_dm_commands(dm::DMFeed)
    actuator_volts = fill(0f0, size(dm.actuator_map))
    scale_amount=Ref(Cfloat(0.1))

    sub_bestflat = Ref(true)
    sub_tt = Ref(true)

    
    # tip_1  = dm.tiptilt(0.1, 0.0)
    # tilt_1 = dm.tiptilt(0.0, 0.1)
    # tip_2  = dm.tiptilt(1.0, 0.0)
    # tilt_2 = dm.tiptilt(0.0, 1.0)

    function (commands)
        actuator_volts .= commands
        actuator_volts[.! dm.valid_actuator_map] .= Inf
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
            
        act_bounds_min = ImPlot.ImPlotPoint(0.0,0.0)
        act_bounds_max = ImPlot.ImPlotPoint(size(commands)...)
        ImPlot.SetNextPlotLimits(0,size(commands,1),0,size(commands,2),ImGuiCond_Always)

        # w = CImGui.GetWindowContentRegionWidth()-80
        # h = CImGui.GetWindowContentRegionWidth() - 50 
        # d = min(w,h)
        d = 200
        plotsize = ImVec2(d,d)

        if ImPlot.BeginPlot("", "", "", plotsize, flags=ImPlot.ImPlotFlags_Equal, y_flags=ImPlotAxisFlags_NoDecorations, x_flags=ImPlotAxisFlags_NoDecorations)
            ImPlot.PushColormap(ImPlot.LibCImPlot.ImPlotColormap_RdBu)
            ImPlot.PlotHeatmap(@views(actuator_volts[:]),reverse(size(actuator_volts))...,-scale_amount[],scale_amount[]; bounds_min=act_bounds_min, bounds_max=act_bounds_max)
            ImPlot.PopColormap()    
            ImPlot.EndPlot()
        end
        CImGui.SameLine();
        ImPlot.ColormapScale("nm##cmap", -scale_amount[], scale_amount[], ImVec2(80,d), ImPlot.LibCImPlot.ImPlotColormap_RdBu);

        # DM commands auto-scale
        scale_min = 0.00001f0
        scale_amount_new = Float32(max(
            abs(minimum(commands)),
            maximum(commands),
            scale_min,
        ))
        if scale_amount_new != scale_min
            if scale_amount[] == Cfloat(0.1)
                scale_amount[] = scale_amount_new
            end    
            scale_amount[] = scale_amount[] + 0.015(scale_amount_new - scale_amount[])
        end

        CImGui.Text("Subtract:")
        CImGui.SameLine()
        CImGui.Text("(TODO)")
        # CImGui.Checkbox("best flat##checkbox", sub_bestflat)
        # CImGui.SameLine()
        # CImGui.Checkbox("tip/tilt##checkbox", sub_tt)



    end
end