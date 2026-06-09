using Aeron
using AstroImages
using SpidersMessageSender
mutable struct Sequencer
    const name::String
end
function Sequencer(conf::Dict)
    return Sequencer(
        conf["name"],
    )
end
name(iv::Sequencer) = iv.name


function gui_panel(::Type{Sequencer}, component_config)

    err_msg = nothing
    err_msg_timeout = time()
    first_view = true

   

    function draw(block, visible)
        CImGui.SetNextWindowSize((350,350), CImGui.ImGuiCond_FirstUseEver)

        if !CImGui.Begin(component_config["name"], visible)#, ImGuiWindowFlags_MenuBar)
            return
        end
        if first_view
        end
        first_view = false


        if !isnothing(err_msg)
            CImGui.TextColored(bad_color, "ERROR:")
            CImGui.SameLine();
            CImGui.TextWrapped(err_msg)
            if CImGui.Button("Clear") 
                err_msg = nothing
            end
            if time() > err_msg_timeout 
                err_msg = nothing
            end
        end



        CImGui.PushFont(font_huge)
        
        w = CImGui.GetWindowWidth() - 10
        h = CImGui.GetWindowHeight() - 40


        CImGui.PushStyleColor(ImGuiCol_Button, CImGui.IM_COL32(0x0D, 0x8A, 0x01, 0xff));
        CImGui.PushStyleColor(ImGuiCol_ButtonHovered, CImGui.IM_COL32(0x1D, 0x9A, 0x11, 0xff));
        if CImGui.Button("PLAY",CImGui.ImVec2(w,h/3))
            errormonitor(@async begin
                send_confirm_events(aeron, uri="aeron:ipc", stream=401, Play=nothing)
                sleep(1)
                send_confirm_events(aeron, uri="aeron:ipc", stream=9401, Play=nothing)
            end)
        end
        CImGui.PopStyleColor()
        CImGui.PopStyleColor()


        if CImGui.Button("PAUSE",CImGui.ImVec2(w,h/3))
            errormonitor(@async begin
                send_confirm_events(aeron, uri="aeron:ipc", stream=9401, Pause=nothing)
                send_confirm_events(aeron, uri="aeron:ipc", stream=401, Pause=nothing)
            end)
        end

        CImGui.PushStyleColor(ImGuiCol_Button, CImGui.IM_COL32(0xB5, 0x00, 0x00, 0xff));
        CImGui.PushStyleColor(ImGuiCol_ButtonHovered, CImGui.IM_COL32(0xC5, 0x20, 0x20, 0xff));
        if CImGui.Button("STOP",CImGui.ImVec2(w,h/3))
            errormonitor(@async begin
                send_confirm_events(aeron, uri="aeron:ipc", stream=9401, Stop=nothing)
                send_confirm_events(aeron, uri="aeron:ipc", stream=401, Stop=nothing)
            end)
        end
        CImGui.PopStyleColor()
        CImGui.PopStyleColor()

        CImGui.PopFont()

        CImGui.End() # End of this panel
        return 

    end
end
