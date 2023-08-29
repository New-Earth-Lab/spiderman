using LinearAlgebra
using Aeron
struct DMOffsetTool1
    name::String
    aeron_config::AeronConfig
    pub::Aeron.AeronPublication
    pubhead::VenomsWireFormat{Vector{UInt8}}
    modemat::Matrix{Float32}
end
function DMOffsetTool1(conf)
    aeron_config = AeronConfig(conf["output-channel"], conf["output-stream"])

    modemat = Float32.(load(conf["modes"]))

    # Scale modes to be in units of 1nm RMS
    rmsnm = mapslices(modemat,dims=2) do actuator_volts
        actuator_nm = actuator_volts .* 10 .* 1e3
        sqrt(mean(px^2 for px in vec(actuator_nm)))
    end
    modemat ./= rmsnm

    # This is a byte buffer where we store our messages we want to send over Aeron
    # We can view into it to see the last command we sent.
    buffer = zeros(UInt8, 468*8+60*4)

    # This header holds the buffer along with metadata to send over the wire
    pubhead = VenomsWireFormat(buffer)
    SizeX!(pubhead, 468)
    SizeY!(pubhead, 1)
    Format!(pubhead, 10) # Float64
    MetadataLength!(pubhead,  0)
    ImageBufferLength!(pubhead, 468*8)
    ImageBufferLength(pubhead)

    aeronpub = Aeron.publisher(aeron_config)

    feed = DMOffsetTool1(conf["name"], aeron_config, aeronpub, pubhead, modemat)

    return feed
end
name(dm::DMOffsetTool1) = dm.name


"""
    setact!(dm::DMOffsetTool1, [0.1, 0.2, -0.1, ...])

Send a command to an ALPAO DM using PCI card.
"""
function setact!(dmoff::DMOffsetTool1, command_vec::AbstractVector{<:Number})
    for v in command_vec
        if !(-0.5 < v < 0.5)
            error("Provided DM command exceeds valid range (-0.5 < cmd < 0.5)")
        end
    end
    current_time = round(UInt64, time()*1e9) # TODO: this is messy. Unclear if the accuarcy is good.
    TimestampNs!(dmoff.pubhead, current_time)
    Image(dmoff.pubhead) .= command_vec
    status = Aeron.publication_offer(dmoff.pub, dmoff.pubhead.buffer)
end


function gui_panel(::Type{DMOffsetTool1}, component_config)

    err_msg = nothing

    # Embeded image viewer panel
    child_imview = ImageViewer(Dict("name"=>component_config["name"]))
    child_imview_draw = gui_panel(ImageViewer, Dict{String,Any}(
        "name"=>component_config["name"]
    ); ischild=true, child_size=(-1,-30))

    first_view = true

    dm_tt_coarse = false
    mode_amplitudes_nm_rms = nothing
    cmd = nothing

    modenames = [
        "Focus",
        "Astig 1",
        "Astig 2"
    ]

    function draw(dmoff, visible)

        if first_view
            mode_amplitudes_nm_rms = zeros(Float32, size(dmoff.modemat,1))
            cmd = zeros(Float32, size(dmoff.modemat,2))
            first_view=false
        end

        if !CImGui.Begin(component_config["name"], visible)#, ImGuiWindowFlags_MenuBar)
            return
        end

        @c CImGui.Checkbox("Coarse", &dm_tt_coarse);


        changed = false

        CImGui.SameLine()
        if CImGui.SmallButton("Reset")
            changed = true
            mode_amplitudes_nm_rms .= 0f0
        end

        tt_range = Float32( dm_tt_coarse ? 50 : 5)
        CImGui.Text("Tip (nm RMS)")
        t = mode_amplitudes_nm_rms[1]
        changed |= @c CImGui.SliderFloat("##Tip", &t, -tt_range, tt_range)
        CImGui.SameLine()
        changed |=  @c CImGui.InputFloat("##tip-num", &t)
        mode_amplitudes_nm_rms[1] = t
        CImGui.Text("Tilt (nm RMS)")
        t = mode_amplitudes_nm_rms[2]
        changed |= @c CImGui.SliderFloat("##Tilt", &t, -tt_range, tt_range)
        CImGui.SameLine()
        changed |=  @c CImGui.InputFloat("##tilt-num", &t)
        mode_amplitudes_nm_rms[2] = t

        for (modename, modenum) in zip(modenames, 3:size(dmoff.modemat,1))
            CImGui.Text("$modename (nm RMS)")
            t = mode_amplitudes_nm_rms[modenum]
            changed |= @c CImGui.SliderFloat("##$modename", &t, -tt_range, tt_range)
            CImGui.SameLine()
            changed |=  @c CImGui.InputFloat("##$modename-num", &t)
            mode_amplitudes_nm_rms[modenum] = t
        end

        if changed
            mul!(cmd, dmoff.modemat', mode_amplitudes_nm_rms)
            setact!(dmoff,cmd)
        end

        CImGui.End()

        return
    end
end
