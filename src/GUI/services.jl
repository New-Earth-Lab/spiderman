"""
Services Panel - Manage spiders-* systemd services
"""

mutable struct ServicesPanel
    const name::String
    ServicesPanel(conf::Dict) = new(conf["name"])
end

name(sp::ServicesPanel) = sp.name

function gui_panel(::Type{ServicesPanel}, component_config)

    err_msg = nothing
    err_msg_timeout = 0.0

    # Service state
    services = String[]
    status = Dict{String, String}()
    last_refresh = Ref(0.0)
    refreshing = Ref(false)
    first_draw = true
    auto_refresh = Ref(true)

    # Discover services from systemctl
    function discover_services!()
        try
            # # List all services and filter for spiders-* in Julia
            # output = read(`systemctl list-units --type=service --all --no-legend --plain`, String)
            # empty!(services)
            # for line in split(output, '\n')
            #     isempty(strip(line)) && continue
            #     parts = split(line)
            #     isempty(parts) && continue
            #     svc_name = replace(parts[1], ".service" => "")
            #     if startswith(svc_name, "spiders-") && svc_name != "spiders-aeronmd"
            #         push!(services, svc_name)
            #     end
            # end
            output = read(`ls  /etc/systemd/system/`, String)
            empty!(services)
            for line in split(output, '\n')
                isempty(strip(line)) && continue
                parts = split(line)
                isempty(parts) && continue
                svc_name = replace(parts[1], ".service" => "")
                if startswith(svc_name, "spiders-") && svc_name != "spiders-aeronmd"
                    push!(services, svc_name)
                end
            end
            sort!(services)
        catch e
            @warn "Failed to discover services" exception=e
        end
    end

    # Refresh status of all services
    function refresh_status!()
        refreshing[] = true
        for svc in services
            # try
                proc = run(pipeline(ignorestatus(`systemctl is-active $(svc).service`),stdout=devnull, stderr=devnull))
                if proc.exitcode == 0
                    status[svc] = "active"
                elseif proc.exitcode == 3
                    status[svc] = "inactive"
                else
                    status[svc] = "failed"
                end
            # catch 
                # status[svc] = "unknown"
            # end
        end
        last_refresh[] = time()
        refreshing[] = false
    end

    function draw(panel::ServicesPanel, visible)
        CImGui.SetNextWindowSize((420, 500), CImGui.ImGuiCond_FirstUseEver)
        if !CImGui.Begin(component_config["name"], visible)
            CImGui.End()
            return
        end

        # First draw: discover services
        if first_draw
            first_draw = false
            errormonitor(@async begin
                discover_services!()
                refresh_status!()
            end)
        end

        # Auto-refresh every 5 seconds
        if auto_refresh[] && !refreshing[] && time() - last_refresh[] > 5.0
            errormonitor(@async refresh_status!())
        end

        # Error message display
        if !isnothing(err_msg)
            CImGui.TextColored(bad_color, "ERROR:")
            CImGui.SameLine()
            CImGui.TextWrapped(err_msg)
            CImGui.SameLine()
            if CImGui.Button("Clear##err")
                err_msg = nothing
            end
            if time() > err_msg_timeout
                err_msg = nothing
            end
        end

        # Top controls
        # Working great but commented out to preserve space
        # if CImGui.Button("Refresh")
        #     errormonitor(@async begin
        #         discover_services!()
        #         refresh_status!()
        #     end)
        # end
        # CImGui.SameLine()
        # if CImGui.Button("Start All")
        #     errormonitor(@async begin
        #         for svc in services
        #             if get(status, svc, "") != "active"
        #                 try
        #                     run(`sudo systemctl start $(svc).service`)
        #                 catch e
        #                     err_msg = "Failed to start $svc"
        #                     err_msg_timeout = time() + 5.0
        #                 end
        #             end
        #         end
        #         refresh_status!()
        #     end)
        # end
        # CImGui.SameLine()
        # if CImGui.Button("Stop All")
        #     errormonitor(@async begin
        #         for svc in services
        #             if get(status, svc, "") == "active"
        #                 try
        #                     run(`sudo systemctl stop $(svc).service`)
        #                 catch e
        #                     err_msg = "Failed to stop $svc"
        #                     err_msg_timeout = time() + 5.0
        #                 end
        #             end
        #         end
        #         refresh_status!()
        #     end)
        # end
        # CImGui.SameLine()
        # CImGui.Checkbox("Auto", auto_refresh)
        # if refreshing[]
        #     CImGui.SameLine()
        #     CImGui.TextColored(dimmed_color, "(refreshing...)")
        # end

        # CImGui.Separator()

        # Service list header
        CImGui.Columns(3, "services_columns", true)
        CImGui.SetColumnWidth(0, 140)
        CImGui.SetColumnWidth(1, 80)
        CImGui.Text("Service")
        CImGui.NextColumn()
        CImGui.Text("Status")
        CImGui.NextColumn()
        CImGui.Text("")
        CImGui.NextColumn()
        CImGui.Separator()

        # Service rows
        for svc in services
            svc_status = get(status, svc, "unknown")

            # Service name (strip "spiders-" prefix for display)
            display_name = replace(svc, "spiders-" => "")
            CImGui.Text(display_name)
            CImGui.NextColumn()

            # Status with color
            if svc_status == "active"
                CImGui.TextColored(good_color, "RUNNING")
            elseif svc_status == "failed"
                CImGui.TextColored(bad_color, "FAILED")
            elseif svc_status == "inactive"
                CImGui.TextColored(dimmed_color, "STOPPED")
            else
                CImGui.TextColored(dimmed_color, svc_status)
            end
            CImGui.NextColumn()

            # Action buttons
            if svc_status == "active"
                if CImGui.SmallButton("Stop##$svc")
                    errormonitor(@async begin
                        try
                            out = run(`sudo systemctl stop $(svc).service`)
                            if out.exitcode != 0
                                err_msg = "Failed to stop $svc"
                                err_msg_timeout = time() + 5.0
                            end
                        catch e
                            err_msg = "Failed to stop $svc: $e"
                            err_msg_timeout = time() + 5.0
                        end
                        refresh_status!()
                    end)
                end
            else
                if CImGui.SmallButton("Start##$svc")
                    errormonitor(@async begin
                        try
                            out = run(`sudo systemctl start $(svc).service`)
                            if out.exitcode != 0
                                err_msg = "Failed to start $svc"
                                err_msg_timeout = time() + 5.0
                            end
                        catch e
                            err_msg = "Failed to start $svc: $e"
                            err_msg_timeout = time() + 5.0
                        end
                        refresh_status!()
                    end)
                end
            end
            CImGui.SameLine()
            if CImGui.SmallButton("Restart##$svc")
                errormonitor(@async begin
                    try
                        out = run(`sudo systemctl restart $(svc).service`)
                        if out.exitcode != 0
                            err_msg = "Failed to restart $svc"
                            err_msg_timeout = time() + 5.0
                        end
                    catch e
                        err_msg = "Failed to restart $svc: $e"
                        err_msg_timeout = time() + 5.0
                    end
                    refresh_status!()
                end)
            end
            CImGui.NextColumn()
        end

        CImGui.Columns(1)

        CImGui.Separator()
        CImGui.TextColored(dimmed_color, "$(length(services)) services")

        CImGui.End()
    end

    return draw
end
