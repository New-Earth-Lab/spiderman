"""
Package of various graphical user interface tools.
"""

# Utillity functions
nonans(array) = all(isfinite, array)


# Helper functions

function disabled_button(label)
    # CImGui.PushStyleVar(ImGuiStyleVar_Alpha, CImGui.GetStyle().Alpha * 0.5)
    CImGui.PushStyleVar(ImGuiStyleVar_Alpha, 0.5)
    CImGui.Button(label)
    CImGui.PopStyleVar()
end

function disabled_loop_starting_button()
    disabled_button("Start Loop")
    CImGui.SameLine()
    CImGui.Text("Loop is starting...")
end


function disabled_loop_stopping_button()
    disabled_button("Stop Loop")
    CImGui.SameLine()
    CImGui.Text("Loop is stopping...")
end

using ImGuiGLFWBackend
using ImGuiGLFWBackend.LibCImGui
using ImGuiGLFWBackend.LibGLFW
using ImGuiOpenGLBackend
using ImGuiOpenGLBackend.ModernGL

using CImGui
using CImGui.CSyntax
using CImGui.CSyntax.CStatic

using Printf
using ImPlot
# using ImPlot.LibCImPlot
using CImGui.LibCImGui
LibCImPlot = LibCImGui

const gui_active = Ref(false)

using Base.Threads

using Revise
# using FFTW
# using LinearAlgebra
# using DelimitedFiles
# using Statistics
# using Dates
# using Printf


# Fallback panel 
function gui_panel(::Any, config)
    # Draw an empty panel for devices without a GUI component
    return function(device=nothing,loop_status=nothing,visible=nothing)
        title = config["name"]
        # @show device title
        CImGui.Begin(title, C_NULL)
        T = string(config["type"])
        CImGui.Text("GUI panel for $T not implemented.")
        CImGui.End()
    end
end


# include("dm-plot.jl")


# include("camera.jl")
# include("powerbar.jl")
# include("brightsource.jl")
# include("chopper.jl")
# include("dm.jl")
# include("aeron-dm-feed.jl")
# include("pressuregauge.jl")
# include("phase-screens.jl")
# include("iftscontroller.jl")

# include("chopped-images.jl")
# include("cdi.jl")
# include("scc.jl")
# include("lowfs.jl")
# include("spottracking.jl")
# include("integrator.jl")
# include("image-integrator.jl")
# include("stats.jl")
# include("turbulence.jl")

include("main-panel.jl")
include("imview.jl")
include("image-feed.jl")
include("dm-feed.jl")
include("dm-plot.jl")
include("dm-offset-tool.jl")
include("tip-tilt-monitor.jl")
include("integrator.jl")

include("block.jl")


# Background for whole GUI
const clear_color = Cfloat[0.2, 0.2, 0.2, 1.0] #Cfloat[0.0, 0.15294117647058825, 0.25098039215686274, 1.00]
const good_color =  Cfloat[0.15294117647058825, 0.6588235294117647, 0.1607843137254902, 1.0, ]
const dimmed_color = Cfloat[0.6, 0.6, 0.6, 1.0]
const active_color = Cfloat[0.6, 1.0, 0.6, 1.0]
const bad_color = 0xCF2121FF

data_path = nothing


const component_panel_map = Dict{Any, Any}()

global font_default
global font_small

# HOT RELOADING
# The VENOMS GUI supports hot code reloading powered by Revise.jl
# Inside the GUI, the user can click "revise" to adopt new code changes.
# Otherwise, the running code is not affected.
# That said, the contents of this file and the overall GUI loop below
# do not support hot reloading. Close and re-open the GUI for your
# changes to have effect. (can't hot reload the hot-reloader!).

export spiderman
"""
    spiderman(bg=true)

Launch the main interface for the lab software.
If `bg=true` (default), then it will run as a separate task
allowing you to continue using the Julia
prompt.

Note: the precompilemode flag runs the GUI for just a few frames before closing.
This allows us to precompile the startup workload (althrough the GUI does flash on the screen).
This is not critical functionality.
"""
function spiderman(;bg=true,_launch_waiter_event=Event(),precompilemode=false)

    # Option to launch the GUI on a background thread
    if bg

        if gui_active[]
            error("Cannot run two main GUIs silmultaneously. Close the existing window first. To force, set `SpiderMan.gui_active[] = false`")
        end
        
        # Before returning, wait on a task that finishes after first frame appears.
        # That ensures any error launching makes it to the REPL.
        _launch_waiter_event = Event()
        # Ensure we stay on the main thread if launched on the main thread by using @async
        guitask = Threads.@spawn :default try
        # guitask = @async try
            spiderman(;bg=false, _launch_waiter_event)
        catch exception
            notify(_launch_waiter_event)
            if exception isa InterruptException
                rethrow(exception)
            end
            println(stderr)
            println(stderr)
            @error "Error during GUI loop" exception=(exception,catch_backtrace())  _module=nothing _file=nothing _line=0
            println(stderr)
        end

        # This wait ensures the GUI is shown and visible before returning to the REPL
        wait(_launch_waiter_event)
        return guitask
    end

    global data_path
    if isnothing(data_path)
        data_path = config("general", "data_path")
    end

    # We create a panel for each component in the config file.
    # This dictionary tracks what panel belongs to what
    # component.
    # component_panel_map = Dict{Any, Union{Nothing,Function}}()

    if gui_active[]
        error("Cannot run two main GUIs silmultaneously. Close the existing window first.")
    end


    # Track GUI frame rate and application allocation rate.
    time_info = @timed nothing
    alloc_hist = zeros(Float32, 1024)
    time_start = 0.0
    time_hist = zeros(Float32, 1024)
    frame_draw_time = 0.0


    # create contexts
    imgui_ctx = igCreateContext(C_NULL)

    window_ctx = ImGuiGLFWBackend.create_context()
    window = ImGuiGLFWBackend.get_window(window_ctx)

    gl_ctx = ImGuiOpenGLBackend.create_context()
    if gl_ctx == C_NULL
        error("Could not create OpenGL context")
    end

    # Set to 1 (default) to enable framerate vsync or 0 to run at maximum speed
    glfwSwapInterval(0)


    # enable docking and multi-viewport
    io = igGetIO()
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ImGuiConfigFlags_DockingEnable
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ImGuiConfigFlags_ViewportsEnable
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ImGuiConfigFlags_NavEnableKeyboard
    unsafe_store!(io.ConfigWindowsMoveFromTitleBarOnly, true)
    unsafe_store!(io.ConfigDragClickToInputText, true)
    # Draws a usual OS window border around each floating window:
    # unsafe_store!(io.ConfigViewportsNoDecoration, false)
    # set style
    igStyleColorsDark(C_NULL)

    # Specify a custom font
    fonts = unsafe_load(io.Fonts)
    # CImGui.AddFontFromFileTTF(fonts, joinpath(@__DIR__, "fonts/NotoSansMono-Regular.ttf"), 30)
    # CImGui.AddFontFromFileTTF(fonts, joinpath(@__DIR__, "fonts/Sweet16mono.ttf"), 18)
    global font_default
    global font_small
    global font_large
    font_default = CImGui.AddFontFromFileTTF(fonts, joinpath(@__DIR__, "fonts/Inter-Regular.ttf"), 18)
    font_small = CImGui.AddFontFromFileTTF(fonts, joinpath(@__DIR__, "fonts/Inter-Regular.ttf"), 10)
    font_large = CImGui.AddFontFromFileTTF(fonts, joinpath(@__DIR__, "fonts/Inter-Regular.ttf"), 24)


    # init
    ImGuiGLFWBackend.init(window_ctx)
    ImGuiOpenGLBackend.init(gl_ctx)

    pctx = ImPlot.CreateContext()
    ImPlot.SetImGuiContext(imgui_ctx)

    gui_active[] = true

    # How long should we sleep after each frame to achieve 60fps?
    sleep_delta_t = 0.000
    # We start this at zero and updatebased on the frame rate to aim for 60fps

    frame_i = 0
    trigger_revision = false
    world = Base.get_world_counter() 
    try
        while glfwWindowShouldClose(window) == GLFW_FALSE
            glfwPollEvents()

            # new frame
            ImGuiOpenGLBackend.new_frame(gl_ctx)
            ImGuiGLFWBackend.new_frame(window_ctx)
            igNewFrame()       

            # During the first sequence of frames, we set things in motion one frame at a time
            # so that the user sees something nice.
            # We first: set the title, size, and position.
            # Then, draw a loading screen
            # From then on, draw the actual frame contents. The first time this happens
            # we might hang while we compile code, so it's nice to show the loading screen first.
            if frame_i == 0
                
                # This should not be so difficult to set basic window properties
                ImGuiGLFWBackend.ImGui_ImplGlfw_SetWindowTitle(igGetMainViewport(), convert(Ptr{Int8}, pointer("SPIDER-MAN")))
                ImGuiGLFWBackend.ImGui_ImplGlfw_SetWindowSize(igGetMainViewport(), ImVec2(400,600))
                # ImGuiGLFWBackend.ImGui_ImplGlfw_SetWindowPos(igGetMainViewport(), ImVec2(10,30))
            end

            
            if trigger_revision && frame_i == 2
                @info "Revising code..." 
                Revise.revise(throw=true)   # Let errors bubble up and crash the GUI
                @info "Revision complete" 
                # And store the current world age. All calls in the GUI will be locked to this world age
                # until the next recompile is triggered.
                world = Base.get_world_counter()
                trigger_revision = false
            end

            # Wait for loading screen to appear, then populate the component maps
            if frame_i == 4 
                Base.invoke_in_world(world, fill_component_panel_map!, component_panel_map)
            end
            # Notify that we are done launching the guitask
            if frame_i == 5
                notify(_launch_waiter_event)
            end
            # If precompiling, break out as soon as we hit the main
            # code paths.
            if frame_i == 6 && precompilemode
                return
            end
            # Main normal drawing loop
            frame_i += 1
            time_start = time_ns()
            time_info = @timed begin


                # Some windows from the GUI toolkit demonstrating various components in action.
                # Uncomment to view and play around with them.
                # igShowDemoWindow(Ref(true))
                # igShowMetricsWindow(Ref(true))
                # ImPlot.LibCImPlot.ShowDemoWindow(Ref(true))
                
                # Package up these tracking state variables
                info = (time_info, alloc_hist, time_start, time_hist, frame_draw_time, frame_i, component_panel_map)
                
                # Hot-reloading:
                # We ensure the GUI is locked to a given world age so that if the user edits the code
                # and triggeres top-level evaluation (e.g. running something on the REPL) the GUI
                # cannot be affected. 
                # If a recompile is requested, we run revise after the loop iteration and bump the world age 
                # cleanly.
                trigger_revision |= Base.invoke_in_world(world, draw_loop, info)
            end
            curr_time = time_ns()
            frame_draw_time = curr_time - time_start
                

            # rendering
            igRender()
            glfwMakeContextCurrent(window)
            w_ref, h_ref = Ref{Cint}(0), Ref{Cint}(0)
            glfwGetFramebufferSize(window, w_ref, h_ref)
            display_w, display_h = w_ref[], h_ref[]
            glViewport(0, 0, display_w, display_h)
            glClearColor(clear_color...)
            glClear(GL_COLOR_BUFFER_BIT)
            ImGuiOpenGLBackend.render(gl_ctx)

            if unsafe_load(igGetIO().ConfigFlags) & ImGuiConfigFlags_ViewportsEnable == ImGuiConfigFlags_ViewportsEnable
                backup_current_context = glfwGetCurrentContext()
                igUpdatePlatformWindows()
                GC.@preserve gl_ctx igRenderPlatformWindowsDefault(C_NULL, pointer_from_objref(gl_ctx))
                glfwMakeContextCurrent(backup_current_context)
            end

            glfwSwapBuffers(window)


            # Show loading splash screen while we revise
            if trigger_revision
                # reset to the beginning of our loading/displaying sequence
                frame_i = 2
                @info "Triggering revision"
            end
            # We need to yield control so that other taks on the same thread can work.
            # Typically we run the GUI on thread 1 (the interactive thread) which is the
            # same thread that hosts the REPL.
            # So if we don't yield, the REPL will hang.
            # That said, yielding once per frame is pretty short. Oftentimes the GUI
            # will yield, the REPL will print a few characters, then we'll sit here
            # spinning until the the next frame/sync comes in. 
            # So the best strategy is to yield with a sleep to explicitly say that
            # the REPL can run for a little while. In theory waiting until we absolutely 
            # have to generate the next frame can actually reduce GUI latency by a sub-frame 
            # amount. Some video games do this. But that's not the main reason here.
            # yield()
            fps = unsafe_load(CImGui.GetIO().Framerate)
            delta = 1/60 - 1/fps
            sleep_delta_t = sleep_delta_t + 0.05*delta
            sleep_delta_t = clamp(sleep_delta_t, 0, 1)
            sleep(sleep_delta_t)
        end
    finally
        # Run when the GUI exits for any reason
        gui_active[] = false

        ImGuiOpenGLBackend.shutdown(gl_ctx)
        ImGuiGLFWBackend.shutdown(window_ctx)
        ImPlot.DestroyContext(pctx)
        igDestroyContext(imgui_ctx)
        glfwDestroyWindow(window)
    end
end



# We isloate all of the rendering into this function so that we can revise it.
# Otherwise, if we modify the draw loop while the code is running and trigger
# revise bad things happen.
# All of the variables that need to be tracked across renders are passed in through the `info`
# tuple for context.
# If a revise needs to be triggered, this function returns true to inform the render loop
# to pause and recompile.
function draw_loop(info)

    time_info, alloc_hist, time_start, time_hist, frame_draw_time, frame_i, component_panel_map = info
    trigger_revision = false


    igDockSpaceOverViewport(igGetMainViewport(),C_NULL,C_NULL);    

    ImPlot.PushStyleColor(ImPlot.ImPlotCol_FrameBg, ImVec4(0,0,0,0));
    ImPlot.PushStyleColor(ImPlot.ImPlotCol_PlotBg, ImVec4(0,0,0,0));

    if CImGui.BeginMainMenuBar()
        if CImGui.BeginMenu("Application")
            if CImGui.MenuItem("Reload config file")
                config("general", refresh=true)
                availcomponents(refresh=true)
                # This special way of calling this function ensures
                # that we pick up changes if the user edits the code.
                fill_component_panel_map!(component_panel_map)
            end
            if CImGui.MenuItem("Export config file")
                writeconfig()
            end
            if CImGui.MenuItem("Revise")
                trigger_revision = true
            end
            if CImGui.MenuItem("Close window")
                CImGui.EndMenu()
                CImGui.EndMenuBar()
                throw(InterruptException())
            end
            if CImGui.MenuItem("Quit")
                exit();
            end
            CImGui.EndMenu()
        end
        if CImGui.BeginMenu("Tools")
            # for (k, v) in pairs(component_panel_map)
            for k in sort(collect(keys(component_panel_map)),by=k->k[2])
                v = component_panel_map[k]
                (type, name) = k
                (func, visible) = v
                if CImGui.MenuItem(name, C_NULL, visible[])
                    component_panel_map[k] = [func, Ref(!visible[]), Ref(false)]
                end
            end
            CImGui.EndMenu()
        end

        CImGui.SameLine(CImGui.GetWindowWidth()-100)
        fps = unsafe_load(CImGui.GetIO().Framerate)
        CImGui.Text(@sprintf("GUI FPS: %3.0f",fps))
        CImGui.EndMainMenuBar()
    end

    # The main gui might freeze momentarily when lots of new panel functions
    # get compiled (if not properly precompiled). Therefore, show a small
    # splash screen for a few frames first, so that if it freezes, people
    # know that things are still loading.
    if frame_i < 5
        p = CImGui.GetWindowPos()
        CImGui.SetNextWindowPos(ImVec2(50 + p.x, 50 + p.y))
        CImGui.SetNextWindowSize(ImVec2(400,400))
        CImGui.SetNextWindowFocus()
        CImGui.Begin("##loading")
        CImGui.TextWrapped("Loading...")
        CImGui.End()
    else

        # show the big demo window
        # ImPlot.LibCImPlot.ShowDemoWindow(true)

        # Show any components 
        @lock to_show_component_lock begin
            for (component_to_show, visible) in to_show_component
                @info "Showing component" name=component_to_show visible
                for key in keys(component_panel_map)
                    (component_type, component_name) = key
                    if component_name == component_to_show
                        component_panel_map[key][2][] = visible
                        component_panel_map[key][3][] = true
                        break
                    end
                end
            end
            empty!(to_show_component)
        end

        active = activecomponents()
        for component_config in availcomponents()
            component = nothing
            for maybe_component in active
                if name(maybe_component) == component_config["name"]
                    component = maybe_component
                end
            end            
            key = (component_config["type"], component_config["name"])
            if haskey(component_panel_map, key) && !isnothing(component_panel_map[key]) && component_panel_map[key][2][] # set to visible
                if component_panel_map[key][3][]
                    CImGui.SetNextWindowFocus()
                    component_panel_map[key][3][] = false
                end
                try
                    component_panel_map[key][1](component, component_panel_map[key][2])
                catch err
                    if err isa InterruptException
                        rethrow(err)
                    end
                    bt = catch_backtrace()
                    bts = sprint(showerror, err, bt)
                    if length(bts) > 2048
                        bts = bts[begin:begin+2048]*"...\n error message truncated."
                    end
                    component_panel_map[key][1] = function(a,b=nothing,visible=nothing)
                        CImGui.Begin(component_config["name"],)
                        if CImGui.Button("Reset")
                            @info "Reseting component" type=component_config["type"] name=component_config["name"]
                            component_panel_map[key][1] = gui_panel(component_config["type"], component_config)
                        end
                        CImGui.TextColored(bad_color, "ERROR:")
                        CImGui.SameLine();
                        CImGui.TextWrapped(bts)
                    end
                    component_panel_map[key][2][] = true
                    component_panel_map[key][3][] = true
                    @error "Error in GUI panel " exception=(err, bt) name=component_config["name"] typeof(err)  _module=nothing _file=nothing _line=0
                end
            end
        end

        main_panel_draw(info)
    end

    ImPlot.PopStyleColor(2);

    return trigger_revision
end




function fill_component_panel_map!(components_panel_map)
    
    # Keep any visibilty statuses
    visibles = Dict{String,Bool}()
    for (key,value) in pairs(components_panel_map)
        type,name = key
        visibles[name] = value[2][]
    end


    empty!(components_panel_map)
    for components_config in availcomponents()

        visible = get(components_config, "auto_show", false)
        if haskey(visibles, components_config["name"])
            visible = visibles[components_config["name"]]
        end

        panel = gui_panel(components_config["type"], components_config)
        components_panel_map[
            (components_config["type"], components_config["name"])
        ] = [panel, Ref(visible), Ref(false)]
        # function, visible

        # precompile(panel, (nothing,))
        # precompile(panel, (components_config["type"],))
    end
end

to_show_component = []
to_show_component_lock = ReentrantLock()
function showcomponent(component_name::AbstractString, visible=true)
    @lock to_show_component_lock push!(to_show_component, (component_name, visible))
end