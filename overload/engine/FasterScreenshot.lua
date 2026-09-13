-- GPL-3.0-or-later. Added 2026-09-13 by the Faster ToME4 fork maintainers.
-- Lossless RGB8 save screenshots through public desktop GL/SDL and embedded
-- lzlib APIs. No engine patch, userdata layout access, or bundled binary.
local M = {}
local prepared = setmetatable({}, {__mode="k"})
local MAX_PIXELS, MAX_SIDE = 2*1024*1024, 4096
local SIGNATURE, IEND = "\137PNG\13\10\26\10", "\0\0\0\0IEND\174\66\96\130"
local totals = {captures=0, bypasses=0, failures=0, raw_bytes=0, png_bytes=0}
local storage, capacity, busy = nil, 0, false

local function native(f)
    return type(f) == "function" and debug.getinfo(f, "S").what == "C"
end
local function integer(n, low, high)
    return type(n) == "number" and n >= low and n <= high and n == math.floor(n)
end
local function be32(n)
    return string.char(math.floor(n/16777216)%256, math.floor(n/65536)%256,
        math.floor(n/256)%256, n%256)
end
local function loadAPI()
    local ffi = require "ffi"
    if ffi.arch ~= "x64" and ffi.arch ~= "x86" then return end
    if ffi.os ~= "Linux" and ffi.os ~= "Windows" then return end
    ffi.cdef[[typedef struct SDL_Window SDL_Window;]]
    local api = {ffi=ffi, ints=ffi.new("int[3]")}
    if ffi.os == "Linux" then
        ffi.cdef[[
            SDL_Window *SDL_GL_GetCurrentWindow(void);
            void SDL_GetWindowSize(SDL_Window *, int *, int *);
            const unsigned char *glGetString(unsigned int);
            void glGetIntegerv(unsigned int, int *);
            void glPixelStorei(unsigned int, int);
            void glReadPixels(int, int, int, int, unsigned int, unsigned int, void *);
        ]]
        local C = ffi.C
        api.window, api.size = C.SDL_GL_GetCurrentWindow, C.SDL_GetWindowSize
        api.version, api.get, api.pack, api.read = C.glGetString, C.glGetIntegerv, C.glPixelStorei, C.glReadPixels
    else
        -- Windows ffi.C searches kernel32, but not SDL2/opengl32. Resolve only
        -- these already-loaded engine dependencies: never load a new DLL.
        -- SDL uses cdecl; Win32 and GL use stdcall on x86 (ignored on x64).
        ffi.cdef[[
            void * __stdcall GetModuleHandleA(const char *);
            void * __stdcall GetProcAddress(void *, const char *);
        ]]
        local module, address = ffi.C.GetModuleHandleA, ffi.C.GetProcAddress
        local sdl, gl = module("SDL2.dll"), module("opengl32.dll")
        if sdl == nil or gl == nil then return end
        local function symbol(handle, name, signature)
            local ptr = address(handle, name)
            if ptr == nil then return end
            return ffi.cast(signature, ptr)
        end
        api.window = symbol(sdl, "SDL_GL_GetCurrentWindow", "SDL_Window * (__cdecl *)(void)")
        api.size = symbol(sdl, "SDL_GetWindowSize", "void (__cdecl *)(SDL_Window *, int *, int *)")
        api.version = symbol(gl, "glGetString", "const unsigned char * (__stdcall *)(unsigned int)")
        api.get = symbol(gl, "glGetIntegerv", "void (__stdcall *)(unsigned int, int *)")
        api.pack = symbol(gl, "glPixelStorei", "void (__stdcall *)(unsigned int, int)")
        api.read = symbol(gl, "glReadPixels", "void (__stdcall *)(int, int, int, int, unsigned int, unsigned int, void *)")
        if not api.window or not api.size or not api.version or not api.get or not api.pack or not api.read then return end
    end
    api.original_window = api.window()
    if api.original_window == nil then return end
    return api
end

function M.stats()
    local out = {buffer_bytes=capacity, max_pixels=MAX_PIXELS,
        max_buffer_bytes=MAX_PIXELS*6+MAX_SIDE}
    for k, v in pairs(totals) do out[k] = v end
    return out
end

function M.prepareScreenshot(original, options)
    if options and options.screenshot_png == false then return nil, "disabled in faster_tome settings" end
    if prepared[original] then return original end
    if type(original) ~= "function" then return nil, "unknown screenshot method" end
    local info = debug.getinfo(original, "Su")
    if info.source ~= "@/mod/class/Game.lua" or info.linedefined ~= 2890
        or info.lastlinedefined ~= 2903 or info.nups ~= 0 then
        return nil, "unknown screenshot method; keeping existing capture"
    end
    local environment = getfenv(original)
    local core, zlib = environment.core, environment.zlib
    local display = type(core) == "table" and rawget(core, "display")
    if type(core) ~= "table" or getmetatable(core) ~= nil
        or type(display) ~= "table" or getmetatable(display) ~= nil or not native(display.getScreenshot)
        or not native(display.forceRedrawForScreenshot) or not native(display.redrawingForSavefileScreenshot)
        or type(zlib) ~= "table"
        or getmetatable(zlib) ~= nil or (zlib._VERSION ~= nil and zlib._VERSION ~= "lzlib 0.3")
        or not native(zlib.compress) or not native(zlib.decompress) or not native(zlib.crc32) then
        return nil, "unknown native screenshot or PNG binding; keeping existing capture"
    end
    local capture, redraw = display.getScreenshot, display.forceRedrawForScreenshot
    local saveMode = display.redrawingForSavefileScreenshot
    local compress, decompress, crc32 = zlib.compress, zlib.decompress, zlib.crc32
    local ok, api = pcall(loadAPI)
    if not ok or not api then return nil, "public desktop GL/SDL FFI unavailable; keeping existing capture" end
    ok = pcall(function()
        assert(crc32() == 0 and crc32(0, "123456789") == 3421780262)
        assert(crc32(crc32(0, "1234"), "56789") == 3421780262)
        for _, text in ipairs{"", "Faster ToME4\0PNG\255"} do
            local encoded, status = compress(text, 1, 8, 15, 8, 0)
            assert(type(encoded) == "string" and status == 1)
            local decoded, finished = decompress(encoded, 15)
            assert(decoded == text and finished == 1)
        end
    end)
    if not ok then return nil, "PNG compression preflight failed; keeping existing capture" end

    local function bindingsValid()
        return environment.core == core and getmetatable(core) == nil
            and core.display == display and getmetatable(display) == nil
            and display.getScreenshot == capture and display.forceRedrawForScreenshot == redraw
            and display.redrawingForSavefileScreenshot == saveMode
            and environment.zlib == zlib and getmetatable(zlib) == nil and zlib.compress == compress
            and zlib.decompress == decompress and zlib.crc32 == crc32
    end
    local function encode(x, y, width, height)
        if not integer(x, 0, MAX_SIDE) or not integer(y, 0, MAX_SIDE)
            or not integer(width, 1, MAX_SIDE) or not integer(height, 1, MAX_SIDE)
            or width*height > MAX_PIXELS then return end
        local ffi, ints = api.ffi, api.ints
        local version = api.version(0x1F02) -- GL_VERSION
        if version == nil then return end
        local major = tonumber(ffi.string(version):match("^(%d+)%.") or "")
        -- GL 3 guarantees all queried enums below, including separate read FBO
        -- and pixel-pack-buffer bindings. Do not query unsupported extensions.
        if not major or major < 3 then return end
        local window = api.window()
        if window == nil or window ~= api.original_window then return end
        api.size(window, ints, ints+1)
        local sw, sh = tonumber(ints[0]), tonumber(ints[1])
        if x+width > sw or y+height > sh then return end
        local row_bytes, pixels = width*3, width*height*3
        local size = pixels*2+height
        if size > capacity then
            storage = ffi.new("unsigned char[?]", size)
            capacity = size
        end
        local rows = storage+pixels
        if api.window() ~= window then return end
        api.size(window, ints, ints+1)
        if ints[0] ~= sw or ints[1] ~= sh then return end
        -- A nested redraw from a display hook can change the engine's mode.
        -- Native PNG applies gamma in user mode, so that path must delegate.
        if saveMode() ~= true then return end
        -- Allocate all cdata/pointers before the final state check. Native FBO
        -- finalizers can run during allocation and change framebuffer binding.
        -- No glGetError: querying/clearing the caller's error flag is a change.
        api.get(0x8CAA, ints) -- GL_READ_FRAMEBUFFER_BINDING
        if ints[0] ~= 0 then return end
        api.get(0x0C02, ints) -- GL_READ_BUFFER
        if ints[0] ~= 0x0405 and ints[0] ~= 0x0404 then return end -- BACK / FRONT
        api.get(0x88ED, ints) -- GL_PIXEL_PACK_BUFFER_BINDING
        if ints[0] ~= 0 then return end
        api.get(0x0D02, ints) -- GL_PACK_ROW_LENGTH
        if ints[0] ~= 0 then return end
        api.get(0x0D03, ints) -- GL_PACK_SKIP_ROWS
        if ints[0] ~= 0 then return end
        api.get(0x0D04, ints) -- GL_PACK_SKIP_PIXELS
        if ints[0] ~= 0 then return end
        -- Match the native call's postcondition: PACK_ALIGNMENT stays at 1.
        api.pack(0x0D05, 1)
        api.read(x, sh-(y+height), width, height, 0x1907, 0x1401, storage) -- RGB/U8
        for row = 0, height-1 do
            local offset = row*(row_bytes+1)
            rows[offset] = 0 -- PNG filter None
            ffi.copy(rows+offset+1, storage+(height-1-row)*row_bytes, row_bytes)
        end
        local packed, status = compress(ffi.string(rows, pixels+height), 1, 8, 15, 8, 0)
        if status ~= 1 or type(packed) ~= "string" then return end
        local header = be32(width)..be32(height).."\8\2\0\0\0"
        local png = table.concat{SIGNATURE, be32(#header), "IHDR", header,
            be32(crc32(crc32(0, "IHDR"), header)), be32(#packed), "IDAT", packed,
            be32(crc32(crc32(0, "IDAT"), packed)), IEND}
        totals.captures = totals.captures+1
        totals.raw_bytes = totals.raw_bytes+pixels
        totals.png_bytes = totals.png_bytes+#png
        return png
    end
    local function getScreenshot(...)
        if busy or not bindingsValid() then
            totals.bypasses = totals.bypasses+1
            return environment.core.display.getScreenshot(...)
        end
        busy = true
        local success, png = pcall(encode, ...)
        busy = false
        if success and png then return png end
        if not success then totals.failures = totals.failures+1 end
        totals.bypasses = totals.bypasses+1
        return environment.core.display.getScreenshot(...)
    end
    -- A bytecode copy retains the exact known method body and its crop/redraw
    -- order. Its globals inherit the original environment; only this copy's
    -- getScreenshot lookup is private. The public display table is untouched.
    local privateDisplay = setmetatable({getScreenshot=getScreenshot}, {__index=function(_, key)
        return environment.core.display[key]
    end})
    local privateCore = setmetatable({display=privateDisplay}, {__index=function(_, key)
        return environment.core[key]
    end})
    local copy, reason = loadstring(string.dump(original))
    if not copy then return nil, reason end
    setfenv(copy, setmetatable({core=privateCore}, {__index=environment}))
    local function takeScreenshot(self, for_savefile, ...)
        if for_savefile ~= true or not bindingsValid() then return original(self, for_savefile, ...) end
        return copy(self, for_savefile, ...)
    end
    prepared[takeScreenshot] = true
    return takeScreenshot
end

return M
