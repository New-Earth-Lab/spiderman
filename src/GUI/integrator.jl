using Aeron
using LinearAlgebra
using HTTP
mutable struct Integrator
    const name::String
    const url_scc::String
    const url_lowfs::String
    const url_integ::String
end
function Integrator(conf)
    return Integrator(
        conf["name"],
        conf["url-scc"],
        conf["url-lowfs"],
        conf["url-integ"],
    )
end
name(iv::Integrator) = iv.name





function gui_panel(::Type{Integrator}, component_config)

    err_msg = nothing

    calibrating = false
    first_view = true

    gain = Ref{Float32}(0)
    leak = Ref{Float32}(0)

    function draw(integ::Integrator, visible)
        CImGui.SetNextWindowSize((350,350), CImGui.ImGuiCond_FirstUseEver)
        if !CImGui.Begin(component_config["name"], visible)#, ImGuiWindowFlags_MenuBar)
            return
        end
        if first_view
            errormonitor(@async begin
                resp = HTTP.get(integ.url_integ*"/gain";)
                if !(200 <= resp.status < 300)
                    err_msg = string(resp.body)
                else
                    gain[] = parse(Float32, String(resp.body))
                    @info "Got gain" gain[]
                end

                resp = HTTP.get(integ.url_integ*"/leak";)
                if !(200 <= resp.status < 300)
                    err_msg = string(resp.body)
                else
                    leak[] = parse(Float32, String(resp.body))
                    @info "Got leak" leak[]
                end
            end)
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



        CImGui.Text("LOWFS Sensor")
        if CImGui.Button("Calibrate##lowfs") && !calibrating
            errormonitor(@async begin
                calibrating = true
                out = run(`julia --project=/opt/spiders/lowfsservice/ /opt/spiders/lowfsservice/scripts/aeron-calibrate-llowfs.jl`)
                calibrating = false
                if out.exitcode != 0
                    err_msg = string("Calibration failed")
                end
            end)
        end
        CImGui.SameLine()
        if CImGui.Button("(startsvc)##lowfs")
            errormonitor(@async begin
                calibrating = true
                out = run(`systemctl --user start lowfs.service `)
                if out.exitcode != 0
                    err_msg = string("Could not start service. Run `systemctl --user status lowfs.service`")
                end
            end)
        end
        CImGui.SameLine()
        if CImGui.Button("(stopsvc)##lowfs")
            errormonitor(@async begin
                calibrating = true
                out = run(`systemctl --user stop lowfs.service `)
                if out.exitcode != 0
                    err_msg = string("Could not stop service. Run `systemctl --user status lowfs.service`")
                end
            end)
        end
        CImGui.SameLine()
        if CImGui.Button("Apply Cal##lowfs")
            errormonitor(@async begin
                resp = HTTP.post(integ.url_lowfs*"/state/")
                if !(200 <= resp.status < 300)
                    err_msg = string(resp.body)
                end
            end)
        end




        CImGui.Text("SCC Sensor")
        if CImGui.Button("Calibrate##scc") && !calibrating
            errormonitor(@async begin
                calibrating = true
                out = run(`julia --project=/opt/spiders/sccservice/ /opt/spiders/sccservice/scripts/aeron-scc-calibrate.jl`)
                calibrating = false
                if out.exitcode != 0
                    err_msg = string("Calibration failed")
                end
            end)
        end
        CImGui.SameLine()
        if CImGui.Button("(startsvc)##scc")
            errormonitor(@async begin
                calibrating = true
                out = run(`systemctl --user start scc.service `)
                if out.exitcode != 0
                    err_msg = string("Could not start service. Run `systemctl --user status scc.service`")
                end
            end)
        end
        CImGui.SameLine()
        if CImGui.Button("(stopsvc)##scc")
            errormonitor(@async begin
                calibrating = true
                out = run(`systemctl --user stop scc.service `)
                if out.exitcode != 0
                    err_msg = string("Could not stop service. Run `systemctl --user status scc.service`")
                end
            end)
        end

        # CImGui.SameLine()
        # if CImGui.Button("Apply Cal##scc")
        #     errormonitor(@async begin
        #         resp = HTTP.post(integ.url_scc*"/state/")
        #         if !(200 <= resp.status < 300)
        #             err_msg = string(resp.body)
        #         end
        #     end)
        # end


        CImGui.Text("Integrator")

        CImGui.DragFloat("Gain", gain, 0.001, 0.0, 1.0, "%1.3f")
        CImGui.DragFloat("Leak", leak, 0.001, 0.0, 1.0, "%1.3f")

        if CImGui.Button("Apply")
            errormonitor(@async begin
                resp = HTTP.post(integ.url_integ*"/leak/$(leak[])")
                if !(200 <= resp.status < 300)
                    err_msg = string(resp.body)
                end
            end)
            errormonitor(@async begin
                resp = HTTP.post(integ.url_integ*"/gain/$(gain[])")
                if !(200 <= resp.status < 300)
                    err_msg = string(resp.body)
                end
            end)
            # TODO: should be combined as one update
        end
        CImGui.SameLine()

        if CImGui.Button("Reset")
            errormonitor(@async begin
                resp = HTTP.post(integ.url_integ*"/reset";)
                if !(200 <= resp.status < 300)
                    err_msg = string(resp.body)
                end

                resp = HTTP.get(integ.url_integ*"/gain";)
                if !(200 <= resp.status < 300)
                    err_msg = string(resp.body)
                else
                    gain[] = parse(Float32, String(resp.body))
                    @info "Got gain" gain[]
                end

                resp = HTTP.get(integ.url_integ*"/leak";)
                if !(200 <= resp.status < 300)
                    err_msg = string(resp.body)
                else
                    leak[] = parse(Float32, String(resp.body))
                    @info "Got leak" leak[]
                end
            end)

        end

        if CImGui.Button("CLOSE LOOP")
            gain[] = 0.2
            errormonitor(@async begin
                resp = HTTP.post(integ.url_integ*"/gain/$(gain[])")
                if !(200 <= resp.status < 300)
                    err_msg = string(resp.body)
                end
            end)
        end
        CImGui.SameLine()
        if CImGui.Button("OPEN LOOP")
            gain[] = 0
            errormonitor(@async begin
                resp = HTTP.post(integ.url_integ*"/gain/$(gain[])")
                if !(200 <= resp.status < 300)
                    err_msg = string(resp.body)
                end
            end)
        end


        CImGui.End() # End of this panel

    end


    return draw
end





            # resp = HTTP.get("http://httpbin.org/ip")
            # println(resp.status)
            # println(String(resp.body))

            # # make a POST request, sending data via `body` keyword argument
            # resp = HTTP.post("http://httpbin.org/body"; body="request body")

            # # make a POST request, sending form-urlencoded body
            # resp = HTTP.post("http://httpbin.org/body"; body=Dict("nm" => "val"))

            # # include query parameters in a request
            # # and turn on verbose logging of the request/response process
            # resp = HTTP.get("http://httpbin.org/anything"; query=["hello" => "world"], verbose=2)