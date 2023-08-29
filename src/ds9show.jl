#=
This file defines a function `ds9show` that saves an array or array of arrays to
a temporary FITS file and launches the SAO DS9 application in the background.
This is a handy way to display / interact / save large files interactively.
=#
using AstroImages

"""
    ds9show(images..., [lock=true], [pad=nothing])

Open one or more images in a SAO DS9 window.
By default, the scales and zooms of the images are locked.
Pass lock=false to disable.

If you pass `pad=true`, the images are padded with NaN
so that they have equal axes. By default (pad=nothing),
padding will be applied when all images are 2D and
locked.
"""
function ds9show(
    # Accept any number of images
    imgs...;
    # Flags
    lock=true,
    pad=nothing,
    setscale=nothing,
    setcmap=nothing,
    loadcmap=nothing,
    τ=nothing,
    regions=String[]
)
    # See this link for DS9 Command reference
    # http://ds9.si.edu/doc/ref/command.html#fits

    # If lock is true (deafult) and the images have different sizes (and are 2D), and
    # padding has not been disabled, turn padding on.
    if length(imgs) > 1 && isnothing(pad) && lock && all(==(2), length.(size.(imgs))) && !all(i -> size(i) == size(first(imgs)), imgs)
        @warn "Padding images so that locked axes work correctly. Disable with either `pad=false` or `lock=false`"
        pad = true
    else
        pad = false
    end

    imgs = map(imgs) do img
        if typeof(img) <: SubArray
            collect(img)
        else
            img
        end
    end

    # If pad is set, pad out the images with NaN to be the same size.
    if pad
        # Sort of an ungly line. paddedviews returns a tuple of views.
        # We need to convert to a vector of arrays.
        imgs = [collect.(Images.paddedviews(NaN, imgs...))...]
    end

    # Detect images with complex values, and just show the power
    imgs = map(imgs) do img
        if eltype(img) <: Complex
            return abs.(img)
        end
        if eltype(img) <: Bool
            return Int8.(img)
        end
        return img
    end

    # For each image, write a temporary file.
    # We clean these up after DS9 exits.
    fnames = String[]
    for img in imgs
        tempfile = tempname()*".fits"
        @show tempfile
        save(tempfile, AstroImage(img))
        push!(fnames, tempfile)
    end

    # Decide where to look to open DS9 depending on the platform
    if Sys.iswindows()
        cmd = `C:\\SAOImageDS9\\ds9.exe $fnames`        
    elseif Sys.isapple() && isdir("/Applications/SAOImageDS9.app")
        cmd = `open -W /Applications/SAOImageDS9.app --args $fnames`
    elseif Sys.isapple() && isdir("/Applications/SAOImage DS9.app")
        cmd = `open -W /Applications/SAOImage\ DS9.app --args $fnames`
    else
        @warn "Untested system for ds9show. Assuming ds9 is in PATH." maxlog=1
        cmd = `ds9 $fnames`
    end

    if !isnothing(setscale) 
        cmd =  `$cmd -scale mode $setscale`
    end

    if !isnothing(loadcmap) 
        cmd =  `$cmd -cmap load $loadcmap`
    elseif !isnothing(setcmap) 
        cmd =  `$cmd -cmap $setcmap`
    end

    if !isnothing(τ)
        σ = std(filter(isfinite, view(last(imgs),:,:,1,1,1)))
        l1 = -0.5τ*σ
        l2 = +1τ*σ
        cmd = `$cmd -scale limits $l1 $l2`
    end

    # If lock=true, then add almost all possible lock flags to the command
    if lock
        cmd = `$cmd -lock frame image -lock crosshair image -lock crop image -lock slice image -lock bin yes -lock axes yes -lock scale yes -lock scalelimits yes -lock colorbar yes -lock block yes -lock smooth yes `
    end

    for region in regions
        cmd = `$cmd -regions command "$region"`
    end

    # Open DS9 asyncronously.
    # When it finishes or errors, delete the temporary FITS files.
    task = @async begin
        try
            # Open DS9
            run(cmd)
        finally
            # Then delete files whenever it's done
            println()
            @info "cleaning up tmp. files from DS9" fnames
            rm.(fnames)
        end
        return nothing
    end

    # Return the async task, in case the user wants to run something when they are done.
    return task
end

# If called with a vector of images, expand and call the function above
ds9show(imgs::AbstractArray{<:AbstractArray}; kwargs...) = ds9show(imgs...;kwargs...)
export ds9show