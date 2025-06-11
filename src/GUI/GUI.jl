"""
Package of various graphical user interface tools.
"""

# Import the new CImGui API
import CImGui
import CImGui as ig
import ModernGL
import GLFW
using CImGui.lib  # For ImGui types
using CSyntax
using Printf
using Base.Threads
using Revise

# Note: ImPlot integration would need to be updated separately
# For now, we'll comment out ImPlot-specific functionality

# Utility functions
nonans(array) = all(isfinite, array)

# Helper functions
function disabled_button(label)
    ig.PushStyleVar(ig.ImGuiStyleVar_Alpha, 0.5)
    ig.Button(label)
    ig.PopStyleVar()
end

function disabled_loop_starting_button()
    disabled_button("Start Loop")
    ig.SameLine()
    ig.Text("Loop is starting...")
end

function disabled_loop_stopping_button()
    disabled_button("Stop Loop")
    ig.SameLine()
    ig.Text("Loop is stopping...")
end

const gui_active = Ref(false)

# Fallback panel 
function gui_panel(::Any, config)
    # Draw an empty panel for devices without a GUI component
    return function(device=nothing, loop_status=nothing, visible=nothing)
        title = config["name"]
        ig.Begin(title)
        T = string(config["type"])
        ig.Text("GUI panel for $T not implemented.")
        ig.End()
    end
end

# Include your custom panels here
include("main-panel.jl")
include("imview.jl")
include("image-feed.jl")
include("dm-feed.jl")
include("dm-plot.jl")
include("dm-offset-tool.jl")
include("tip-tilt-monitor.jl")
include("fts-monitor.jl")
include("perf-mon.jl")
include("integrator.jl")
include("block.jl")
include("archiver.jl")

# Background for whole GUI
const clear_color = Cfloat[0.2, 0.2, 0.2, 1.0]
const good_color = Cfloat[0.15294117647058825, 0.6588235294117647, 0.1607843137254902, 1.0]
const dimmed_color = Cfloat[0.6, 0.6, 0.6, 1.0]
const active_color = Cfloat[0.6, 1.0, 0.6, 1.0]
const bad_color = UInt32(0xCF2121FF)

data_path = nothing

const component_panel_map = Dict{Any, Any}()

# Global state for the GUI
mutable struct GuiState
    trigger_revision::Bool
    world::UInt64
    time_info::NamedTuple
    alloc_hist::Vector{Float32}
    time_start::Float64
    time_hist::Vector{Float32}
    frame_draw_time::Float64
    frame_i::Int
    font_default::Ptr{ImFont}
    font_small::Ptr{ImFont}
    font_large::Ptr{ImFont}
end

GuiState() = GuiState(
    false,
    Base.get_world_counter(),
    (time=0.0, bytes=0, gctime=0.0, compile_time=0.0, recompile_time=0.0),
    zeros(Float32, 1024),
    0.0,
    zeros(Float32, 1024),
    0.0,
    0,
    C_NULL,
    C_NULL,
    C_NULL
)

const gui_state = GuiState()
const launch_waiter_event = Ref{Union{Event,Nothing}}(nothing)
const is_precompilemode = Ref(false)

export spiderman
"""
    spiderman(bg=true)

Launch the main interface for the lab software.
If `bg=true` (default), then it will run as a separate task
allowing you to continue using the Julia prompt.
"""
function spiderman(; bg=true, _launch_waiter_event=Event(), precompilemode=false)
    # Option to launch the GUI on a background thread
    if bg
        if gui_active[]
            error("Cannot run two main GUIs simultaneously. Close the existing window first. To force, set `SpiderMan.gui_active[] = false`")
        end
        
        _launch_waiter_event = Event()
        guitask = Threads.@spawn :default try
            spiderman(; bg=false, _launch_waiter_event)
        catch exception
            notify(_launch_waiter_event)
            if exception isa InterruptException
                rethrow(exception)
            end
            println(stderr)
            println(stderr)
            @error "Error during GUI loop" exception=(exception, catch_backtrace()) _module=nothing _file=nothing _line=0
            println(stderr)
        end

        wait(_launch_waiter_event)
        return guitask
    end

    # Store the launch waiter event globally so handle_frame can access it
    launch_waiter_event[] = _launch_waiter_event
    is_precompilemode[] = precompilemode

    global data_path
    if isnothing(data_path)
        data_path = config("general", "data_path")
    end

    if gui_active[]
        error("Cannot run two main GUIs simultaneously. Close the existing window first.")
    end

    # Set backend
    ig.set_backend(:GlfwOpenGL3)
    
    # Create context
    ctx = ig.CreateContext()
    p_ctx =ImPlot.CreateContext()
    
    # Configure ImGui
    io = ig.GetIO()
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.ImGuiConfigFlags_DockingEnable
    # io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.ImGuiConfigFlags_ViewportsEnable
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.ImGuiConfigFlags_NavEnableKeyboard
    unsafe_store!(io.ConfigWindowsMoveFromTitleBarOnly, true)
    unsafe_store!(io.ConfigDragClickToInputText, true)
    
    # Set style
    ig.StyleColorsDark()
    
    # Add fonts
    fonts = unsafe_load(io.Fonts)
    gui_state.font_default = ig.AddFontFromFileTTF(fonts, joinpath(@__DIR__, "fonts/Inter-Regular.ttf"), 14)
    gui_state.font_small = ig.AddFontFromFileTTF(fonts, joinpath(@__DIR__, "fonts/Inter-Regular.ttf"), 8)
    gui_state.font_large = ig.AddFontFromFileTTF(fonts, joinpath(@__DIR__, "fonts/Inter-Regular.ttf"), 18)
    
    gui_active[] = true
    
    # Reset GUI state for fresh start
    gui_state.frame_i = 0
    gui_state.trigger_revision = false
    gui_state.world = Base.get_world_counter()
    gui_state.time_start = 0.0
    gui_state.frame_draw_time = 0.0
    
    try
        # Use the new render function with a callback
        ig.render(ctx; 
            window_size=(3840, 2048), 
            window_title="SPIDER-MAN",
            opengl_version=v"3.3",  # Specify OpenGL version if needed
            clear_color=clear_color,
            on_exit=() -> ImPlot.DestroyContext(p_ctx)
        ) do
            # This callback is called for each frame
            handle_frame()
        end
        
    finally
        gui_active[] = false
        launch_waiter_event[] = nothing
        is_precompilemode[] = false
        # Note: ImPlot context cleanup would go here if using ImPlot
    end
end

function handle_frame()
    gui_state.frame_i += 1
    gui_state.time_start = time_ns()
    
    # During the first sequence of frames, we set things in motion one frame at a time
    # First few frames: show loading screen
    # Frame 2: Handle revision if triggered
    # Frame 4: Fill component panel map
    # Frame 5: Notify launch waiter
    # Frame 6+: Normal operation
    
    # Handle revision at frame 2
    # This happens after trigger_revision is set and frame_i was reset to 1
    if gui_state.trigger_revision && gui_state.frame_i == 2
        @info "Revising code..."
        Revise.revise(throw=true)
        @info "Revision complete"
        # Update world age and clear the trigger
        gui_state.world = Base.get_world_counter()
        gui_state.trigger_revision = false
    end
    
    # Fill component panel map after loading screen
    if gui_state.frame_i == 4
        Base.invoke_in_world(gui_state.world, fill_component_panel_map!, component_panel_map)
    end
    
    # Notify launch waiter after GUI is visible
    if gui_state.frame_i == 5 && !isnothing(launch_waiter_event[])
        notify(launch_waiter_event[])
        launch_waiter_event[] = nothing  # Clear it after use
    end
    
    # Exit early if precompiling
    if gui_state.frame_i == 6 && is_precompilemode[]
        return false
    end
    
    # Main drawing - invoke in the correct world age
    # This ensures that all GUI drawing code sees a consistent version of the code,
    # even if the user modifies code on the REPL while the GUI is running
    gui_state.time_info = @timed begin
        trigger_revision_this_frame = Base.invoke_in_world(gui_state.world, draw_gui_content, gui_state.frame_i)
        
        # Handle trigger revision from menu
        if trigger_revision_this_frame
            gui_state.trigger_revision = true
        end
    end
    
    curr_time = time_ns()
    gui_state.frame_draw_time = curr_time - gui_state.time_start
    
    # Reset frame counter if revision was requested
    # Set to 1 so that after increment at the start of next frame, it will be 2
    if gui_state.trigger_revision
        gui_state.frame_i = 1
    end
    
    return true  # Continue rendering
end

# Separate function for drawing GUI content that can be invoked in a specific world
function draw_gui_content(frame_i)
    trigger_revision = false
    
    # Create docking space
    ig.DockSpaceOverViewport()
    
    # Note: ImPlot style pushing would go here
    
    # Draw main menu bar
    if ig.BeginMainMenuBar()
        if ig.BeginMenu("Application")
            if ig.MenuItem("Reload config file")
                config("general", refresh=true)
                availcomponents(refresh=true)
                fill_component_panel_map!(component_panel_map)
            end
            if ig.MenuItem("Export config file")
                writeconfig()
            end
            if ig.MenuItem("Revise")
                trigger_revision = true
            end
            if ig.MenuItem("Close windows (leave Julia running)")
                ig.EndMenu()
                ig.EndMainMenuBar()
                # Need to handle this differently since we can't return from here
                throw(InterruptException())
            end
            if ig.MenuItem("Quit")
                exit()
            end
            ig.EndMenu()
        end
        
        if ig.BeginMenu("Tools")
            for k in sort(collect(keys(component_panel_map)), by=k->k[2])
                v = component_panel_map[k]
                (type, name) = k
                (func, visible) = v
                if ig.MenuItem(name, C_NULL, visible[])
                    component_panel_map[k] = [func, Ref(!visible[]), Ref(false)]
                end
            end
            ig.EndMenu()
        end
        
        ig.SameLine(ig.GetWindowWidth() - 100)
        fps = unsafe_load(ig.GetIO().Framerate)
        ig.Text(@sprintf("GUI FPS: %3.0f", fps))
        ig.EndMainMenuBar()
    end
    
    # Show loading screen for first few frames
    if frame_i < 5
        ig.SetNextWindowFocus()
        ig.Begin("##loading")
        ig.TextWrapped("Loading...")
        ig.End()
    else
        # Show components
        show_components()
        
        # Draw main panel
        info = (
            gui_state.time_info,
            gui_state.alloc_hist,
            gui_state.time_start,
            gui_state.time_hist,
            gui_state.frame_draw_time,
            frame_i,
            component_panel_map
        )
        Base.invoke_in_world(gui_state.world, main_panel_draw, info)
    end
    
    # Note: ImPlot style popping would go here
    
    return trigger_revision
end

function show_components()
    # Handle component showing logic
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
    
    # Draw component panels
    active = activecomponents()
    for component_config in availcomponents()
        component = nothing
        for maybe_component in active
            if name(maybe_component) == component_config["name"]
                component = maybe_component
            end
        end
        
        key = (component_config["type"], component_config["name"])
        if haskey(component_panel_map, key) && !isnothing(component_panel_map[key]) && component_panel_map[key][2][]
            if component_panel_map[key][3][]
                ig.SetNextWindowFocus()
                component_panel_map[key][3][] = false
            end
            
            try
                component_panel_map[key][1](component, component_panel_map[key][2])
            catch err
                if err isa InterruptException
                    rethrow(err)
                end
                handle_panel_error(err, component_config, key)
            end
        end
    end
end

function handle_panel_error(err, component_config, key)
    bt = catch_backtrace()
    bts = sprint(showerror, err, bt)
    if length(bts) > 2048
        bts = bts[begin:begin+2048] * "...\n error message truncated."
    end
    
    component_panel_map[key][1] = function(a, b=nothing, visible=nothing)
        ig.Begin(component_config["name"])
        if ig.Button("Reset")
            @info "Resetting component" type=component_config["type"] name=component_config["name"]
            component_panel_map[key][1] = gui_panel(component_config["type"], component_config)
        end
        ig.TextColored(ImVec4(0.8, 0.13, 0.13, 1.0), "ERROR:")
        ig.SameLine()
        ig.TextWrapped(bts)
        ig.End()
    end
    component_panel_map[key][2][] = true
    component_panel_map[key][3][] = true
    @error "Error in GUI panel" exception=(err, bt) name=component_config["name"] typeof(err) _module=nothing _file=nothing _line=0
end

function fill_component_panel_map!(components_panel_map)
    # Keep any visibility statuses
    visibles = Dict{String,Bool}()
    for (key, value) in pairs(components_panel_map)
        type, name = key
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
    end
end

to_show_component = []
to_show_component_lock = ReentrantLock()

function showcomponent(component_name::AbstractString, visible=true)
    @lock to_show_component_lock push!(to_show_component, (component_name, visible))
end