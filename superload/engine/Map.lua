local _M = loadPrevious(...)

local _particleEmitter = _M.particleEmitter
function _M:particleEmitter(x, y, radius, def, args, shader, zdepth)
    if def == "hit_warning" then return end
    return _particleEmitter(self, x, y, radius, def, args, shader, zdepth)
end

return _M