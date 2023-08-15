using Dates
using Logging
using Logging: Info, Debug, BelowMinLevel, Error
using LoggingExtras: TeeLogger
using Alert
using ImageMagick
using Images
using FileIO
using Printf


struct TextLogger{T<:IO} <: AbstractLogger
    io::T
end
Logging.min_enabled_level(::TextLogger) = Info
Logging.shouldlog(::TextLogger, level, _module, group, id) = true



function Logging.handle_message(log::TextLogger, level, message, _module, group, id, file, line; kwargs...)
    print(
        log.io,
        now(UTC),'\t',
        uppercase(string(level)),'\t',
        (isnothing(file) ? "\t" : basename(file)*':'), '\t',
        '"', escape_string(message),"\"\t",
    )
    for (k,v) in pairs(kwargs)
        print(log.io, k, '=',v,'\t')
    end
    println(log.io)
end



struct GuiLogger <: AbstractLogger
    message_count::Int
    max_character_count::Int
    last_messages::Vector{Tuple{String,LogLevel}}
    lock::ReentrantLock
end
GuiLogger(message_count, max_character_count=1024) = GuiLogger(message_count, max_character_count, Tuple{String,LogLevel}[], ReentrantLock())
Logging.min_enabled_level(::GuiLogger) = Info
Logging.shouldlog(::GuiLogger, level, _module, group, id) = true

function Logging.handle_message(log::GuiLogger, level, message, _module, group, id, file, line; kwargs...)
    kv = join([
        "$k=$v\t"
        for (k,v) in pairs(kwargs)
    ], ' ')
    out = @sprintf("%-8s %-13s %s %s", uppercase(string(level)), (isnothing(file) ? "\t" : basename(file)), escape_string(message), kv)
    lock(log.lock) do
        if length(log.last_messages) ≥ log.message_count
            popfirst!(log.last_messages)
        end
        if length(out) > log.max_character_count
            out = out[begin:begin+log.max_character_count-1]
        end
        push!(log.last_messages, (out, level))
    end
    return
end




struct AlertLogger <: AbstractLogger end
Logging.min_enabled_level(::AlertLogger) = Logging.Error
Logging.shouldlog(::AlertLogger, args...) = true
function Logging.handle_message(log::AlertLogger, level, message, _module, group, id, file, line; kwargs...)
    # This causes security errors on NRC Windows 10 machines since it executes something in Powershell to show the desktop notification.
    # @async alert("VENOM: "*string(message))
    return
end


"""
    screenshot()

Take a screenshot of all monitors. Returns
an array of images for each monitor.
"""
function screenshot()
    data = ImageMagick.load("screenshot:");
    monitors = Matrix{eltype(data)}[]
    for i in axes(data,3)
        push!(monitors, @view data[:,:,i])
    end
    return monitors
end
export screenshot

"""
    writescreenshot()

Take a screenshot and save it in the default location.
See also `screenshot`
"""
function writescreenshot()
    images = screenshot()
    t = Dates.now()
    dir = joinpath(config("general", "data_path"), Dates.format(t, "Y-mm-dd"))
    for (i, image) in enumerate(images)
        fname = Dates.format(t, "HH.MM.SS.s") * ".screenshot-$i.png"
        path = joinpath(dir, fname)
        save(path, image)
        @info "Wrote screenshot" path
    end
end
export writescreenshot


"""
Configure a global logger.
This will use the TeeLogger from LoggingExtras to redirect
logs to the log file with one format while allowing
the usual messages to appear in the console as well.
"""
logging_filename = ""

function setup_logging()

    data_path = config("general", "data_path")
    t = now()
    dir = joinpath(data_path, Dates.format(t, "Y-mm-dd"))
    fname = "VENOM.log"
    mkpath(dir)
    logfilename = joinpath(dir,fname)
    logfile = open(logfilename,append=true)

    global logging_filename
    logging_filename = logfilename

    file_logger = TextLogger(logfile)
    gui_logger = GuiLogger(15, 1024)
    desktop_alert_logger = AlertLogger()
    default_logger = global_logger()
    
    
    tee_logger = TeeLogger(default_logger, file_logger, gui_logger, desktop_alert_logger)

    global_logger(tee_logger)

    flush_log() = flush(logfile)

    atexit() do
        flush(logfile)
        close(logfile)
    end

    return gui_logger, flush_log
end




