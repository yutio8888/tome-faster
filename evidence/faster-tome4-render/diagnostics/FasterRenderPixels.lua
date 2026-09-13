-- Local diagnostic only. Read GL through documented APIs, never userdata memory.
local M = {}
local ffi = require "ffi"
ffi.cdef[[
void glGetIntegerv(unsigned int, int *);
void glGetFloatv(unsigned int, float *);
void glGetTexLevelParameteriv(unsigned int, int, unsigned int, int *);
void glGetTexImage(unsigned int, int, unsigned int, unsigned int, void *);
void glActiveTexture(unsigned int);
unsigned int glGetError(void);
]]
local gl = ffi.load("libGL.so.1")
local function ints(name, n)
    local data = ffi.new("int[?]", n or 1)
    gl.glGetIntegerv(name, data)
    local result = {}
    for i = 0, (n or 1)-1 do result[#result+1] = tonumber(data[i]) end
    return result
end
local function floats(name, n)
    local data = ffi.new("float[?]", n)
    gl.glGetFloatv(name, data)
    local result = {}
    for i = 0, n-1 do result[#result+1] = tonumber(data[i]) end
    return result
end
function M.boundTexture()
    local dim = ffi.new("int[2]")
    gl.glGetTexLevelParameteriv(0x0DE1, 0, 0x1000, dim)
    gl.glGetTexLevelParameteriv(0x0DE1, 0, 0x1001, dim+1)
    local w, h = tonumber(dim[0]), tonumber(dim[1])
    assert(w >= 0 and h >= 0 and w*h <= 16777216, "unexpected texture dimensions")
    if w*h == 0 then return {w = w, h = h, pixels = ""} end
    local pixels = ffi.new("unsigned char[?]", w*h*4)
    gl.glGetTexImage(0x0DE1, 0, 0x1908, 0x1401, pixels)
    return {w = w, h = h, pixels = ffi.string(pixels, w*h*4)}
end
function M.texture(tex)
    tex:bind(0)
    return M.boundTexture()
end
function M.state()
    return {program = ints(0x8B8D), framebuffer = ints(0x8CA6), viewport = ints(0x0BA2, 4),
        active_texture = ints(0x84E0), matrix_mode = ints(0x0BA0),
        modelview = floats(0x0BA6, 16), projection = floats(0x0BA7, 16),
        clear_color = floats(0x0C22, 4), current_color = floats(0x0B00, 4),
        blend = ints(0x0BE2), blend_src = ints(0x0BE1), blend_dst = ints(0x0BE0),
        scissor_enabled = ints(0x0C11), scissor = ints(0x0C10, 4)}
end
function M.equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not M.equal(v, b[k]) then return false, k end end
    for k in pairs(b) do if a[k] == nil then return false, k end end
    return true
end
function M.checkGL() assert(gl.glGetError() == 0, "OpenGL diagnostic error") end
return M
