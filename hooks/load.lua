local loadfilecache = {}
local _loadfile = loadfile
local loadfile = function(f)
    local cached = loadfilecache[f]
    if not cached then
        cached = { _loadfile(f) }
        loadfilecache[#loadfilecache + 1] = cached
        loadfilecache[f] = cached
    end
    return unpack(cached)
end

local Particles = require "engine.Particles"
local Shader = require "engine.Shader"

Particles.loaded = setfenv(Particles.loaded, setmetatable({
    _M = Particles,
    loadfile = loadfile
}, { __index = _G }))
Shader.loaded = setfenv(Shader.loaded, setmetatable({
    _M = Shader,
    loadfile = loadfile
}, { __index = _G }))


local CacheList = require"engine.CacheList"
local printlog = CacheList.new(5000)
local oprint = print
local otruncate_printlog = truncate_printlog
local oget_printlog = get_printlog

_G.print = function(...)
    oprint(...)
    printlog:append(oget_printlog())
    otruncate_printlog(0)
end

_G.get_printlog = function()
    return printlog:enumerate()
end

_G.truncate_printlog = function(nb) end
