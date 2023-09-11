# This precompile script triggers the GUI for just a few frames so that the package is precompiled.
# Only included it in the main project if you are not actively editting the source files
# and want a little boost in startup speed.
using PrecompileTools
using Aeron
@setup_workload begin
    @show Threads.nthreads()
    @compile_workload begin
        spiderman(bg=false,precompilemode=true)
        # prevent dangling watcher task from hanging precompile
        Aeron.unwatchall()
        # Ensure we don't keep our current list of components compiled into the package-image.
        empty!(config_components)
        config_loaded[] = false
        empty!(active_components)
    end
end