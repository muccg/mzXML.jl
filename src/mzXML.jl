module mzXML

using LightXML, Unitful, Codecs

struct MSscan{T<:AbstractFloat,TI<:Real}
    polarity::Char
    msLevel::Int
    retentionTime::typeof(1.0u"s")
    lowMz::Float64
    highMz::Float64
    basePeakMz::Float64
    totIonCurrent::Float64
    mz::Vector{T}
    I::Vector{TI}
    children::Vector{MSscan{T,TI}}
end

const empty32 = Array{MSscan{Float32,Float32}}[]
const empty64 = Array{MSscan{Float64,Float64}}[]

function index(filename)
    scanpositions = open(filename) do file
        # Find the indexOffset element
        seekend(file)
        p = position(file)
        l = 200
        if p < l
            error("Too short to be mzXML")
        end
        skip(file, -l)
        str = loadrest(file)
        m = match(r"<indexOffset>([0-9].*)</indexOffset>", str)
        if m == nothing
            error("Cannot find indexOffset element")
        end
        length(m.captures) == 1 || error("indexOffset should contain a single number")
        indexpos = parse(Int, m.captures[1])
        length_tail = l - m.offset
        # Read the index
        seek(file, indexpos)
        str = loadrest(file)
        xindex = parse_string(str[1:end-length_tail-1])
        xroot = root(xindex)
        scanpositions = Array{Int}(0)
        for c in child_elements(xroot)
            name(c) == "offset" || error("index could not be parsed")
            push!(scanpositions, parse(Int, content(c)))
        end
        scanpositions
    end
    scanpositions
end

function load(filename; maxlevel = 1)
    xdoc = parse_file(filename)
    xroot = root(xdoc)
    if name(xroot) != "mzXML" || name(xroot) != "indexedmzML"
        error("Not an mzXML file")
    end

    # Find the msRun node
    msRun = find_element(xroot, "msRun")

    props = Dict{Symbol,Any}()
    props[:startTime] = parse_time(attribute(msRun, "startTime"))
    props[:endTime] = parse_time(attribute(msRun, "endTime"))
    el = find_element(msRun, "msInstrument")
    el = find_element(el, "msModel")
    props[:msModel] = attribute(el, "value")

    load_scans(msRun, maxlevel-1), props
end

function load_scans(elm, ndeeper=0)
    # First we discover the data type
    local T
    local TI
    for c in child_elements(elm)
        n = name(c)
        if n != "scan"
            continue
        end
        peak = find_element(c, "peaks")
        TI, T, nochildren = precisiondict[attribute(peak, "precision")]
        break
    end
    # Now load the data
    scans = Array{MSscan{T,TI}}(0)
    load_scans!(scans, elm, ndeeper)
end

function load_scans!(scans, elm, ndeeper)
    for c in child_elements(elm)
        n = name(c)
        if n != "scan"
            continue
        end
        push!(scans, load_scan(c, ndeeper)::eltype(scans))
    end
    scans
end

polaritydict = Dict("+" => '+', "-" => '-')
precisiondict = Dict("32" => (Float32, Float32, empty32), "64" => (Float64, Float64, empty64))

function load_scan(elm, ndeeper)
    polarity = polaritydict[attribute(elm, "polarity")]
    retentionTime = parse_time(attribute(elm, "retentionTime"))
    lMza, hMza = attribute(elm, "lowMz"), attribute(elm, "highMz")
    if lMza != nothing
        lowMz, highMz = parse(Float64, lMza), parse(Float64, hMza)
    else
        lowMz = highMz = NaN
    end
    msLevela = attribute(elm, "msLevel")
    msLevel = msLevela == nothing ? 1 : parse(Int, msLevela)
    basePeakMz = parse(Float64, attribute(elm, "basePeakMz"))
    totIonCurrent = parse(Float64, attribute(elm, "totIonCurrent"))
    npeaks = parse(Int, attribute(elm, "peaksCount"))
    peak = find_element(elm, "peaks")
    data = decode(Base64, content(peak))
    TI, T, nochildren = precisiondict[attribute(peak, "precision")]
    A = reinterpret(TI, data)
    bo = attribute(peak, "byteOrder")
    if bo == "network"
        ntoh!(A)
    else
        error("Don't know what to do with byteOrder $bo")
    end
    po = attribute(peak, "pairOrder")
    if po == nothing
        po = attribute(peak, "contentType")
    end
    po == "m/z-int" || error("Don't know what to do with pairOrder/contentType $po")
    I = A[2:2:end]
    mz = reinterpret(T, A[1:2:end])
    children = ndeeper > 0 ? load_scans!(Array{MSscan{T,TI}}(0), elm, ndeeper-1) : nochildren
    MSscan{T,TI}(polarity, msLevel, retentionTime, lowMz, highMz, basePeakMz, totIonCurrent, mz, I, children)
end

function loadrest(file::IOStream)
    nb = filesize(file) - position(file)
    b = read(file, nb)
    return String(b)
end

function parse_time(tstr)
    if startswith(tstr, "PT") && endswith(tstr, "S")
        return parse(Float64, tstr[3:end-1])*u"s"
    end
    error("Time string $tstr not recognized")
end

function ntoh!(A)
    for i = 1:length(A)
        A[i] = ntoh(A[i])
    end
end

end
