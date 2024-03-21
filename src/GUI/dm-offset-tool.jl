using Printf
using LinearAlgebra
using Aeron
using SpidersMessageEncoding

struct DMOffsetTool
    name::String
    aeron_config::AeronConfig
    pub::Aeron.AeronPublication
    pubhead::ArrayMessage{Float32,1,Vector{UInt8}}
    actuator_map::BitMatrix
    valid_actuator_map::BitMatrix
    modemat::Matrix{Float32}
    lmodemat::Matrix{Float32}
    fmodemat::Matrix{Float32}
    cyc_xs
    cyc_ys
    phases
end
function DMOffsetTool(conf)
    aeron_config = AeronConfig(conf["output-channel"], conf["output-stream"])

    modemat = Float32.(load(conf["zern-modes"]))
    lmodemat = Float32.(load(conf["lowfs-modes"]))
    fmodemat, cyc_xs, cyc_ys, phases = load(conf["fourier-modes"],:)
    fmodemat = Float32.(fmodemat)
    actuator_map = BitMatrix(load(conf["actuator-map"]))
    valid_actuator_map = BitMatrix(load(conf["valid-actuator-map"]))

    # Scale modes to be in units of 1nm RMS
    rmsnm = mapslices(modemat,dims=2) do actuator_volts
        actuator_nm = actuator_volts .* 10 .* 1e3
        sqrt(mean(px^2 for px in vec(actuator_nm)))
    end
    modemat ./= rmsnm

    # Scale modes to be in units of 1nm RMS
    rmsnm = mapslices(lmodemat,dims=2) do actuator_volts
        actuator_nm = actuator_volts .* 10 .* 1e3
        sqrt(mean(px^2 for px in vec(actuator_nm)))
    end
    lmodemat ./= rmsnm


    # Scale modes to be in units of 1nm RMS
    rmsnm = mapslices(fmodemat,dims=2) do actuator_volts
        actuator_nm = actuator_volts .* 10 .* 1e3
        sqrt(mean(px^2 for px in vec(actuator_nm)))
    end
    fmodemat ./= rmsnm

    # This is a byte buffer where we store our messages we want to send over Aeron
    # We can view into it to see the last command we sent.
    buffer = zeros(UInt8, 468*8+60*4)
    pubhead = ArrayMessage{Float32,1}(buffer)
    arraydata!(pubhead, zeros(Float32, 468))
    pubhead.header.description = conf["output-key"]

    aeronpub = Aeron.publisher(aeron, aeron_config)

    feed = DMOffsetTool(
        conf["name"],
        aeron_config,
        aeronpub,
        pubhead,
        actuator_map,
        valid_actuator_map,
        modemat,
        lmodemat,
        fmodemat, cyc_xs, cyc_ys, phases
    )

    return feed
end
name(dm::DMOffsetTool) = dm.name


"""
    setact!(dm::DMOffsetTool, [0.1, 0.2, -0.1, ...])

Send a command to an ALPAO DM using PCI card.
"""
function setact!(dmoff::DMOffsetTool, command_vec::AbstractVector{<:Number})
    for v in command_vec
        if !(-0.5 < v < 0.5)
            error("Provided DM command exceeds valid range (-0.5 < cmd < 0.5)")
        end
    end
    current_time = round(UInt64, time()*1e9) # TODO: this is messy. Unclear if the accuarcy is good.
    dmoff.pubhead.header.TimestampNs = current_time
    SpidersMessageEncoding.arraydata(dmoff.pubhead) .= command_vec
    status = Aeron.publication_offer(dmoff.pub, parent(dmoff.pubhead))
end


function gui_panel(::Type{DMOffsetTool}, component_config)

    err_msg = nothing

    # Embeded image viewer panel
    child_imview = ImageViewer(Dict("name"=>component_config["name"]))
    child_imview_draw = gui_panel(ImageViewer, Dict{String,Any}(
        "name"=>component_config["name"]
    ); ischild=true, child_size=(-1,-30))

    first_view = true

    dm_tt_coarse = false
    mode_amplitudes_nm_rms = nothing
    lmode_amplitudes_nm_rms = nothing
    cmd = nothing
    fmode_i = 1

    modenames = [
        "Tip",
        "Tilt",
        "Focus",
        "Astig 1",
        "Astig 2",
        "Coma 1",
        "Coma 2",
        "Sphere",
        #TODO : Wyant numbering
    ]
    modenames = [modenames; string.(10:30)]

    manual_offset = nothing

    cyc_x = Ref(Int32(6))
    cyc_y = Ref(Int32(6))
    phase_i = Ref(Int32(1))
    famp = Ref(0f0)

    function draw(dmoff, visible)

        if first_view
            mode_amplitudes_nm_rms = zeros(Float32, size(dmoff.modemat,1))
            lmode_amplitudes_nm_rms = zeros(Float32, size(dmoff.lmodemat,1))
            cmd = zeros(Float32, size(dmoff.modemat,2))
            manual_offset  = zeros(Float32, size(dmoff.modemat,2))
            famp[] = 0
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
            lmode_amplitudes_nm_rms .= 0f0
            manual_offset .= 0
            famp[] = 0
        end

        tt_range = Float32( dm_tt_coarse ? 750 : 150)

        if CImGui.CollapsingHeader("LOWFS")

            for (modename, modenum) in zip(modenames, 1:size(dmoff.lmodemat,1))
                CImGui.Text("pseudo-$modename (nm RMS)")
                t = lmode_amplitudes_nm_rms[modenum]
                changed |= @c CImGui.SliderFloat("##pseudo-$modename", &t, -tt_range, tt_range)
                CImGui.SameLine()
                changed |=  @c CImGui.InputFloat("##pseudo-$modename-num", &t)
                lmode_amplitudes_nm_rms[modenum] = t
            end
        end
        if CImGui.CollapsingHeader("Pure Zernikes")

            for (modename, modenum) in zip(modenames, 1:size(dmoff.modemat,1))
                CImGui.Text("$modename (nm RMS)")
                t = mode_amplitudes_nm_rms[modenum]
                changed |= @c CImGui.SliderFloat("##$modename", &t, -tt_range, tt_range)
                CImGui.SameLine()
                changed |=  @c CImGui.InputFloat("##$modename-num", &t)
                mode_amplitudes_nm_rms[modenum] = t
            end
        end
        if CImGui.CollapsingHeader("Fourier")
            CImGui.Text("Mode selector")
            CImGui.Text("X (Cyc./pupil)")
            changed |= CImGui.SliderInt("##X", cyc_x, -12, 12)
            CImGui.Text("Y (Cyc./pupil)")
            changed |= CImGui.SliderInt("##Y", cyc_y, 0, 12)
            CImGui.Text("Phase (arb + 0 or pi/4)")
            changed |= CImGui.SliderInt("##Phasei", phase_i, 1, 2)
            CImGui.Text("Amplitude (nm rms)")
            changed |= CImGui.SliderFloat("##Amp", famp, -800, 800)
            

            if changed
                fmode_i = findall(
                    dmoff.cyc_xs .== cyc_x .&&
                    dmoff.cyc_ys .== cyc_y
                )[phase_i[]]
            end
        end
        if CImGui.CollapsingHeader("Manual Control")
            CImGui.PushFont(font_small)
            nrow, ncol = size(dmoff.actuator_map)
            CImGui.Columns(ncol, "dm-poke-grid", false);
            actu_i = 0
            for coli in 1:ncol
                for rowi in 1:nrow
                    if dmoff.actuator_map[rowi,coli]
                        actu_i += 1
                    end
                    if !dmoff.actuator_map[rowi,coli]
                    elseif !dmoff.valid_actuator_map[rowi,coli]
                    else
                        amp = Ref(manual_offset[actu_i])
                        if @c CImGui.DragFloat("##$rowi$coli", amp, 0.01, -0.5, 0.5, "%0.2f")
                            manual_offset[actu_i] = amp[]
                            @info "actuator poke" actu_i amp
                            changed = true
                        end
                    end


                    CImGui.NextColumn();
                end

            end
            CImGui.PopFont()
            CImGui.Columns(1, "dm-poke-grid", false);
            if CImGui.SmallButton("Reset##manual")
                changed = true
                manual_offset .= 0
            end
    
        end


        if changed
            mul!(cmd, dmoff.modemat', mode_amplitudes_nm_rms)
            cmd .+= dmoff.lmodemat' * lmode_amplitudes_nm_rms
            @views cmd .+= famp[] .* dmoff.fmodemat[fmode_i,:]

            cmd .+= manual_offset
            setact!(dmoff,cmd)
        end

        CImGui.End()

        return
    end
end
