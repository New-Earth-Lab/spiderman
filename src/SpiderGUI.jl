"""
This is the top level file for all of the lab software.
"""
module SpiderGUI
using TOML

include("config-io.jl")

# Special logging facilities for console, GUI, and telemetry files
include("logging.jl")

include("wire-format.jl")

# Component system
include("Components.jl")

# GUI for optionally controlling it all.
include("GUI/GUI.jl")


const gui_logger = Ref{GuiLogger}(GuiLogger(1))
const flush_log = Ref{Function}(identity)

function __init__()

    out = setup_logging()
    gui_logger[] = out[1]
    flush_log[] = out[2]
end


end
