

"""
config(...)

This function reads configuration information from the `config.toml` file
as a dictionary. Passing additional strng keys allows you to read one particular 
part of the config file.
"""

loaded_config_toml = nothing
loaded_config_toml_lock = ReentrantLock()
function config(keys...; refresh=false)
    # Load config file upon first request for a parameter
    @lock loaded_config_toml_lock if isnothing(loaded_config_toml) || refresh
        global loaded_config_toml = TOML.parsefile(joinpath(@__DIR__, "..", "spidergui-config.toml"))
    end
    dict = loaded_config_toml
    for key in keys
        dict = dict[key]
    end
    dict
end
function config(subdict::Dict, keys...;)
    dict = subdict
    for key in keys
        dict = dict[key]
    end
    dict
end
export config
function setconfig(keys_new_value...)
    newvalue = last(keys_new_value)
    keys = keys_new_value[begin:end-1]
    # Load config file upon first request for a parameter
    dict = loaded_config_toml
    for key in keys[1:end-1]
        dict = dict[key]
    end
    dict[last(keys)] = newvalue
end
function setconfig(subdict::Dict, keys_new_value...)
    newvalue = last(keys_new_value)
    keys = keys_new_value[begin:end-1]
    # Load config file upon first request for a parameter
    dict = subdict
    for key in keys[1:end-1]
        dict = dict[key]
    end
    dict[last(keys)] = newvalue
end
export setconfig

function writeconfig()

    # Come up with the file name
    t = Dates.now()
    data_path = config("general", "data_path")
    dir = joinpath(data_path, Dates.format(t, "Y-mm-dd"))
    fname = Dates.format(t, "HH.MM.SS.s") * ".config.toml"
    @info "Writing sine waves to FITS cube." dir fname
    mkpath(dir)

    converter(T::DataType) = string(T)
    converter(T::UnionAll) = string(T)
    converter(arr::AbstractVector) = collect(arr)
    converter(arr::AbstractArray) = vec(arr)


    fpath = joinpath(dir, fname)
    open(fpath, "w") do file
        TOML.print(converter, file, config())
    end
    @info "Saved current settings" fpath
end
export writeconfig