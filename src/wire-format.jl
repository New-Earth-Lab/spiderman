
"""
Represents the header of a VENOMS frame sent over an Aeron stream.
Given a buffer or view, provide property access to the underlying
fields without copying
"""
struct VenomsWireFormat{T<:AbstractArray{UInt8}}
    buffer::T
end

Version(vfh::VenomsWireFormat) = reinterpret(Int32, @view vfh.buffer[ 1:4 ])[] 
Version!(vfh::VenomsWireFormat, value) = reinterpret(Int32, @view vfh.buffer[ 1:4 ])[] = value
PayloadType(vfh::VenomsWireFormat) = reinterpret(Int32, @view vfh.buffer[ 5:8 ])[] 
PayloadType!(vfh::VenomsWireFormat, value) = reinterpret(Int32, @view vfh.buffer[ 5:8 ])[] = value
TimestampNs(vfh::VenomsWireFormat) = reinterpret(UInt64, @view vfh.buffer[ 9:16])[] 
TimestampNs!(vfh::VenomsWireFormat, value) = reinterpret(Int64, @view vfh.buffer[ 9:16])[] = value
Format(vfh::VenomsWireFormat) = reinterpret(Int32, @view vfh.buffer[17:20])[] 
Format!(vfh::VenomsWireFormat, value) = reinterpret(Int32, @view vfh.buffer[17:20])[] = value
SizeX(vfh::VenomsWireFormat) = reinterpret(Int32, @view vfh.buffer[21:24])[] 
SizeX!(vfh::VenomsWireFormat, value) = reinterpret(Int32, @view vfh.buffer[21:24])[] = value
SizeY(vfh::VenomsWireFormat) = reinterpret(Int32, @view vfh.buffer[25:28])[] 
SizeY!(vfh::VenomsWireFormat, value) = reinterpret(Int32, @view vfh.buffer[25:28])[] = value
OffsetX(vfh::VenomsWireFormat) = reinterpret(Int32, @view vfh.buffer[29:32])[] 
OffsetX!(vfh::VenomsWireFormat, value) = reinterpret(Int32, @view vfh.buffer[29:32])[] = value
OffsetY(vfh::VenomsWireFormat) = reinterpret(Int32, @view vfh.buffer[33:36])[] 
OffsetY!(vfh::VenomsWireFormat, value) = reinterpret(Int32, @view vfh.buffer[33:36])[] = value
PaddingX(vfh::VenomsWireFormat) = reinterpret(Int32, @view vfh.buffer[37:40])[] 
PaddingX!(vfh::VenomsWireFormat, value) = reinterpret(Int32, @view vfh.buffer[37:40])[] = value
PaddingY(vfh::VenomsWireFormat) = reinterpret(Int32, @view vfh.buffer[41:44])[] 
PaddingY!(vfh::VenomsWireFormat, value) = reinterpret(Int32, @view vfh.buffer[41:44])[] = value
MetadataLength(vfh::VenomsWireFormat) = reinterpret(Int32, @view vfh.buffer[45:48])[] 
MetadataLength!(vfh::VenomsWireFormat, value) = reinterpret(Int32, @view vfh.buffer[45:48])[] = value
MetadataBuffer(vfh::VenomsWireFormat) = @view vfh.buffer[49:49+MetadataLength(vfh)-1] # TODO: 4-byte alignment
ImageBufferLength(vfh::VenomsWireFormat) = reinterpret(Int32, @view vfh.buffer[49+MetadataLength(vfh):49+MetadataLength(vfh)+3])[]
ImageBufferLength!(vfh::VenomsWireFormat, value) = reinterpret(Int32, @view vfh.buffer[49+MetadataLength(vfh):49+MetadataLength(vfh)+3])[]= value
function ImageBuffer(vfh::VenomsWireFormat)
    start = 49+MetadataLength(vfh)+4
    len = ImageBufferLength(vfh)
    return @view vfh.buffer[start:start+len-1]
end
function Image(vfh::VenomsWireFormat)
    Fmt = if Format(vfh) == 0x01100007
        Int16
    elseif Format(vfh) == 9
        Float32
    elseif Format(vfh) == 10
        Float64
    else
        error(lazy"Format not yet supported. Format=$(Format(vfh))")
    end
    return reshape(reinterpret(Fmt, ImageBuffer(vfh)), Int64(SizeX(vfh)), Int64(SizeY(vfh)))
end


function Base.show(io::IO, ::MIME"text/plain", vfh::VenomsWireFormat)

    println(io, "VenomsWireFormat message")
    println(io, "Version(..)        = ", Version(vfh))
    println(io, "PayloadType(..)    = ", PayloadType(vfh))
    println(io, "TimestampNs(..)    = ", TimestampNs(vfh))
    println(io, "Format(..)         = ", Format(vfh))
    println(io, "SizeX(..)          = ", SizeX(vfh))
    println(io, "SizeY(..)          = ", SizeY(vfh))
    println(io, "OffsetX(..)        = ", OffsetX(vfh))
    println(io, "OffsetY(..)        = ", OffsetY(vfh))
    println(io, "PaddingX(..)       = ", PaddingX(vfh))
    println(io, "PaddingY(..)       = ", PaddingY(vfh))
    println(io, "MetadataLength(..) = ", MetadataLength(vfh))
    println(io, "ImageBufferLength(..) = ", ImageBufferLength(vfh))
end