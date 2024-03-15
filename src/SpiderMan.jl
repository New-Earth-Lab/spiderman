"""
This is the top level file for all of the lab software.
"""
module SpiderMan
using TOML
using Aeron
using SpidersMessageEncoding
using SpidersMessageSender

include("config-io.jl")

# Special logging facilities for console, GUI, and telemetry files
include("logging.jl")

include("wire-format.jl")

# Component system
include("Components.jl")


const gui_logger = Ref{GuiLogger}(GuiLogger(1))
const flush_log = Ref{Function}(identity)
aeron::AeronContext = AeronContext()

# GUI for optionally controlling it all.
include("GUI/GUI.jl")

include("ds9show.jl")

# include("precompile.jl")

function __init__()

    out = setup_logging()
    gui_logger[] = out[1]
    flush_log[] = out[2]
    global aeron = AeronContext()
end


end
