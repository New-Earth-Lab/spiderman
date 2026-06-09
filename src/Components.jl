#=
A component is a general class of object throughout the GUI.

Components are loaded dynamically from the config.toml file. Multiple
components of the same type can be created with different names (which are unique IDs).

Active components are tracked by the VENOMS run time.
If the GUI is open, components can draw an interface to the screen. 
They is accomplished by registering a `draw()` method.

Components can also report their current status as a nested dictionary
by defining `?` method. All active components are queried for their
status whenever an image is written, whioch then become the FITS headers.
=#

"""
    name(component)

Return a unique string identifier  (like a serial number) of any
component object
"""
function name end

# Keep track of all active components
const active_components = Any[]
const active_components_lock = ReentrantLock()
function push_component!(component)
    return lock(active_components_lock) do 
        return push!(active_components, component)
    end
end
function pop_component!(component)
    lock(active_components_lock) do 
        I = findfirst(==(component), active_components)
        if isnothing(I)
            @warn "Can't pop_component!, no matching object" component
        end
        splice!(active_components, I)
    end
    return nothing
end


const config_components = Any[]
const config_loaded = Ref{Bool}(false)
const config_components_lock = ReentrantLock()
"""
    availcomponents([refresh=false])

Return a list of component info from the configuration 
file. If refresh=true is passed, reload from the config
file. Otherwise, use a cached copy.

Technical note: this function is not inferrable, since components
are resolved to their types using `eval`.
Security note: one could in theory abuse this by creating a component whose
type is any valid Julia expression
"""
function availcomponents(;refresh::Bool=!config_loaded[])
    if refresh
        @info "Loading configuration"
        @lock config_components_lock begin
            config_loaded[] = true
            empty!(config_components)
            if haskey(config(), "component")
                for conf in config("component")
                    # Parse out the device type key into a Julia type in our software
                    if !haskey(conf, "type")
                        @warn "component configuration did not have \"type\" key specified. Skipping." name=conf["name"]
                        continue
                    end
                    type = conf["type"]
                    if !(type isa DataType)
                    try
                            T = eval(Meta.parse(type))
                            conf["type"] = T
                    catch err
                            @error "Component type not recognized. Skipping." name=conf["name"] type exception=err
                            continue
                        end
                    end
                    push!(config_components, conf)
                    found = false
                    for component in activecomponents()
                        if name(component) == conf["name"]
                            found = true
                            break
                        end
                    end
                    if !found
                        push_component!(conf["type"](conf))
                    end
                end
            end
        end
    end
    return config_components
end
export availcomponents

function availcomponent(component_name;refresh::Bool=!config_loaded[])
    comps = availcomponents(;refresh)
    for comp in comps
        if comp["name"] == component_name
            return comp
        end
    end
    return nothing
end
export availcomponent

function getcomponent(component_name::AbstractString)
    for this_component in activecomponents()
        if name(this_component) == component_name
            return this_component
        end
    end
    return nothing
end
getcomponent(::Nothing) = nothing
export getcomponent


"""
activecomponents()

Returns a vector of active components.
"""
function activecomponents()
    return active_components
end
"""
activecomponents(type)

Returns a vector of active components of that type.
"""
function activecomponents(type)
    return filter(active_components) do component
        typeof(component) <: type
    end
end
export activecomponents
