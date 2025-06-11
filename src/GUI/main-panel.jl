using Logging

const connect_status_msg = Ref("")
function main_panel_draw(info)

    time_info, alloc_hist, time_start, time_hist, frame_draw_time, frame_i, component_panel_map = info

    i = mod1(frame_i, length(alloc_hist))
    if i == 1
        # Trigger an incremental GC periodically
        # This prevents very large GCs from triggering after letting memory usage creep upwards
        # GC.gc(false)
        fill!(alloc_hist,0)
        fill!(time_hist,0)
    end
    # Keep track of allocations in bytes/second.
    # This is more meaningful than bytes per gui frame, since loops can run out of sync of gui.
    alloc_hist[i] = time_info.bytes/(frame_draw_time/1e9)/1e6
    time_hist[i] = frame_draw_time/1e6 # ns to ms

    if !CImGui.Begin("Overview", C_NULL,) # ImGuiWindowFlags_MenuBar
        CImGui.End()
        return false
    end
    trigger_revision = false

  
      
    CImGui.Text("LOG")
    CImGui.SameLine()
    if CImGui.Button("Flush")
        @spawn flush_log[]()
    end
    CImGui.SameLine()
    if CImGui.Button("Screenshot")
        @spawn writescreenshot()
    end
    

    CImGui.PlotLines(
        "alloc mb/s",
        alloc_hist,
        length(alloc_hist),
        # mod(frame_i, length(alloc_hist)),
        0,
        C_NULL,
        minimum(alloc_hist),
        maximum(alloc_hist),
        CImGui.ImVec2(250, 0)
    )
    CImGui.PlotLines(
        "gui ms/frame",
        time_hist,
        length(time_hist),
        # mod(frame_i, length(time_hist)),
        0,
        C_NULL,
        minimum(time_hist),
        maximum(time_hist),
        CImGui.ImVec2(250, 0)
    )


    CImGui.Separator()
    
    for (message, level) in gui_logger[].last_messages
        if level == Logging.Error
            CImGui.PushStyleColor(ImGuiCol_Text, ImVec4(1.0f0, 0.4f0, 0.4f0, 1.0f0))
        elseif level == Logging.Warn
            CImGui.PushStyleColor(ImGuiCol_Text, ImVec4(0.902f0, 0.827f0, 0.161f0, 1.0f0))
        else
            CImGui.PushStyleColor(ImGuiCol_Text, ImVec4(1f0, 1f0, 1f0, 1.0f0))
        end
        # Text wrapped allows messages to wrap around the console. This can get sort of
        # messy so for now just truncate the message at the end of the window.
        # The user can expand the window, or look at the actual command prompt to see more.
        # CImGui.TextWrapped(message)
        CImGui.Text(message)
        CImGui.PopStyleColor()
    end

    CImGui.End()

    return trigger_revision
end