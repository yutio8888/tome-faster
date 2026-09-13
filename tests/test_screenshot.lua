-- GPL-3.0-or-later. Actual pinned screenshot/lzlib, public API fixtures,
-- and independent libpng decoding. No spoofed function source metadata.
assert(_VERSION == "Lua 5.1", "LuaJIT required")
local root = arg[1] or "."
local repo = assert(arg[2], "pass a local ToME source Git clone as argument 2")
local commit = "624a67329fe2ad440c5b344785a9c73fcf22ae63"
local ffi = require "ffi"
local function quote(s) return "'"..s:gsub("'", "'\\''").."'" end
local function output(command)
    local p=assert(io.popen(command,"r")); local text=p:read("*a"); assert(p:close()); return text
end
local function pinned(path) return output("git -C "..quote(repo).." show "..quote(commit..":"..path)) end
local function section(source, first, last)
    local a=assert(source:find(first,1,true)); local b=last and assert(source:find(last,a,true)) or #source+1
    local _,lines=source:sub(1,a-1):gsub("\n","")
    return string.rep("\n",lines)..source:sub(a,b-1)
end
local function write(path, text)
    local f=assert(io.open(path,"wb")); assert(f:write(text)); assert(f:close())
end
local function success(status) return status == 0 or status == true end
local checks=0
local function check(value, message) assert(value,message); checks=checks+1 end
local function pack(...) return {n=select("#",...),...} end
local build=output("mktemp -d /tmp/tome-screenshot-tests.XXXXXX"):gsub("\n$","")
assert(build:match("^/tmp/tome%-screenshot%-tests%.[%w]+$"))
local function main()
    write(build.."/pinned_lzlib.c",pinned("src/lzlib/lzlib.c"))
    write(build.."/pinned_screenshot.c",section(pinned("src/core_lua.c"),
        "static void screenshot_apply_gamma", "static int gl_fbo_to_png"))
    local headers=os.getenv("TOME_LUA_INCLUDE")
    local cflags=headers and ("-I"..quote(headers)) or output(
        "if pkg-config --exists luajit; then pkg-config --cflags luajit; else pkg-config --cflags lua5.1; fi")
    cflags=(cflags.." "..output("pkg-config --cflags sdl2 libpng")):gsub("\n"," ")
    local libs=output("pkg-config --libs sdl2 libpng"):gsub("\n"," ")
    assert(success(os.execute(quote(os.getenv("CC") or "cc").." -shared -fPIC -O2 "..cflags..
        " -I"..quote(build).." "..quote(root.."/tests/screenshot_fixture.c").." -o "..
        quote(build.."/screenshot_fixture.so").." "..libs.." -lz")), "native screenshot fixture build failed")
    local handle=ffi.load(build.."/screenshot_fixture.so",true)
    local native=assert(package.loadlib(build.."/screenshot_fixture.so","luaopen_screenshot_fixture"))()
    local previousZlib,loadedZlib=_G.zlib,package.loaded.zlib
    _G.zlib,package.loaded.zlib=nil,nil
    local actual=native.register_zlib()
    _G.zlib,package.loaded.zlib=previousZlib,loadedZlib
    local code=section(pinned("game/modules/tome/class/Game.lua"),
        "function _M:takeScreenshot(for_savefile)", "function _M:isAllowedBuild(what)")
    local function world(optimized, overrides)
        native.reset()
        local Game={}
        local env=setmetatable({_M=Game}, {__index=_G}); env._G=env
        env.core={display={getScreenshot=native.capture,forceRedrawForScreenshot=native.redraw,
            redrawingForSavefileScreenshot=native.save_mode}}
        env.zlib={}; for key,value in pairs(actual) do env.zlib[key]=value end
        env.zlib.compress,env.zlib.decompress,env.zlib.crc32=native.compress,native.decompress,native.crc32
        env.util={bound=function(n,a,b) return math.max(a,math.min(b,n)) end}
        if overrides then for key,value in pairs(overrides) do env[key]=value end end
        setfenv(assert(loadstring(code,"@/mod/class/Game.lua")),env)()
        local Faster=setfenv(assert(loadfile(root.."/overload/engine/FasterScreenshot.lua")),env)()
        local original=Game.takeScreenshot
        local w={env=env,Game=Game,original=original,Faster=Faster}
        w.game=setmetatable({w=1280,h=800}, {__index=Game})
        if optimized then
            local fast,reason=Faster.prepareScreenshot(original)
            check(type(fast)=="function", "prepare pinned screenshot: "..tostring(reason)); Game.takeScreenshot=fast
        end
        return w
    end
    local function inspect(png)
        check(png:sub(1,8)=="\137PNG\13\10\26\10","standard PNG signature")
        local at,chunks=9,{}
        local function u32(s) local a,b,c,d=s:byte(1,4); return ((a*256+b)*256+c)*256+d end
        while at<=#png do
            local len=u32(png:sub(at,at+3)); local kind=png:sub(at+4,at+7)
            local data=png:sub(at+8,at+7+len)
            check(native.crc32(native.crc32(0,kind),data)==u32(png:sub(at+8+len,at+11+len)),"valid "..kind.." CRC")
            chunks[#chunks+1]=kind
            at=at+len+12
        end
        check(at==#png+1,"exact PNG chunk framing")
        return table.concat(chunks,",")
    end
    local function compare(w, width, height, sx, sy, with_level)
        w.game.w,w.game.h=width*2,height*2
        native.setup("window_width",width*4+64); native.setup("window_height",height*4+64)
        if with_level then
            w.game.player={x=11,y=19}
            w.game.level={map={getTileToScreen=function(_,x,y,exact)
                check(x==11 and y==19 and exact==true,"original player crop arguments")
                return sx+width/2,sy+height/2
            end}}
        else w.game.level=nil end
        native.setup("alignment",8)
        local before=native.stats()
        local baseline=w.original(w.game,true)
        local expected=pack(native.decode(baseline))
        local original_env=getfenv(w.original)
        native.setup("alignment",4)
        local png=w.game:takeScreenshot(true)
        local actualImage=pack(native.decode(png)); local after=native.stats()
        check(after.captures==before.captures+1,"optimized capture avoids native PNG encoder")
        check(after.reads==before.reads+2 and after.redraws==before.redraws+2,"one original redraw/read per capture")
        check(after.alignment==1 and after.errors==0,"native alignment postcondition; no GL error calls")
        check(actualImage.n==expected.n,"same decoded return shape")
        for i=1,expected.n do check(actualImage[i]==expected[i],"same decoded RGB/dimensions/color field "..i) end
        check(actualImage[2]==width and actualImage[3]==height and actualImage[4]==8 and actualImage[5]==2
            and actualImage[6]==0,"RGB8 dimensions and noninterlaced metadata")
        local oldChunks=inspect(baseline):gsub("IDAT,IDAT","IDAT")
        check(oldChunks=="IHDR,IDAT,IEND" and inspect(png)=="IHDR,IDAT,IEND","same color/profile metadata absence")
        check(getfenv(w.original)==original_env and w.env.core.display.getScreenshot==native.capture
            and w.env.core.display.forceRedrawForScreenshot==native.redraw,"original environment and global API untouched")
        local st=w.Faster.stats(); check(st.buffer_bytes<=st.max_buffer_bytes,"bounded retained pixel memory")
        return #baseline,#png
    end
    do
        local w=world(true)
        for _,shape in ipairs{{1,1},{3,7},{7,3},{17,11},{96,47},{7,23},{128,33},{3,1},{18,10}} do
            compare(w,shape[1],shape[2],0,0,true)
            compare(w,shape[1],shape[2],0,shape[2],true)
            compare(w,shape[1],shape[2],shape[1],0,true)
        end
        compare(w,96,48,0,0,false)
        local old,fast=compare(w,640,400,83,127,true)
        print(("PNG fixture 640x400: native=%d bytes, level1/filter0=%d bytes, ratio=%.3f (synthetic gradient)"):format(old,fast,fast/old))
    end
    print("PASS screenshot: pinned RGB equality, odd widths, vertical orientation, crop edges, buffer reuse and PNG metadata")

    for _,flag in ipairs{false,0,"save"} do
        local w=world(true); native.setup("gamma",1.7)
        local expected=w.original(w.game,flag); local before=native.stats()
        local got=w.game:takeScreenshot(flag); local after=native.stats()
        check(got==expected and after.captures==before.captures+1,"non-true save flag uses exact original capture")
    end
    do
        local w=world(true); native.setup("gamma",1.7)
        compare(w,101,37,19,7,true)
        local before=native.stats(); w.game:takeScreenshot()
        check(native.stats().captures==before.captures+1,"nil flag preserves original user gamma path")
    end
    for _,setting in ipairs{{"framebuffer",8},{"pbo",9},{"row_length",20},{"skip_rows",1},{"skip_pixels",1},
        {"read_buffer",0},{"have_window",0},{"window_id",9876},
        {"gl_version","2.1 Fixture"},{"gl_version","OpenGL ES 3.2 Fixture"}} do
        local w=world(true); w.game.w,w.game.h=32,24; native.setup(setting[1],setting[2])
        local before=native.stats(); local png=w.game:takeScreenshot(true); local after=native.stats()
        check(type(png)=="string" and after.captures==before.captures+1,"unsafe state delegates: "..setting[1])
        check(after.reads==before.reads+1 and after.errors==0,"guard does not read or query invalid GL enum: "..setting[1])
        if setting[1]=="gl_version" then check(after.gets==before.gets,"unsupported version does not query GL3 state") end
    end
    for _,shape in ipairs{{63,47},{10000,2},{8192,2048}} do
        local w=world(true); w.game.w,w.game.h=shape[1],shape[2]
        -- Keep fallback memory bounded; fixture's replacement is a C entrypoint
        -- with the same ABI, while the optimization guard runs before readback.
        if shape[1]>1000 then native.setup("window_width",shape[1]); native.setup("window_height",shape[2]) end
        local before=native.stats(); w.game:takeScreenshot(true)
        check(native.stats().captures==before.captures+1,"fractional/oversized geometry delegates")
    end
    print("PASS screenshot: save/user gamma distinction and platform/GL/geometry fallback")

    do
        local w=world(true); w.game.w,w.game.h=48,32; native.setup("gamma",1.7)
        native.setup("redraw_callback",function()
            native.setup("redraw_callback",nil); native.redraw(false)
        end)
        local before=native.stats(); local png=w.game:takeScreenshot(true)
        check(native.stats().captures==before.captures+1,"nested user redraw disables save-only PNG path")
        local expected=native.capture(12,8,24,16)
        check(native.decode(png)==native.decode(expected),"nested redraw retains native gamma behavior")
    end

    for _,mode in ipairs{1,2,3} do
        local w=world(true); w.game.w,w.game.h=48,32
        native.setup("marker",{}); native.setup("compress_mode",mode)
        local before=native.stats(); local png=w.game:takeScreenshot(true)
        check(type(png)=="string" and native.stats().captures==before.captures+1,"encode failure retries original capture")
        native.setup("compress_mode",0); before=native.stats(); w.game:takeScreenshot(true)
        check(native.stats().captures==before.captures,"failure clears reentry guard")
    end
    for _,which in ipairs{"getScreenshot","forceRedrawForScreenshot","redrawingForSavefileScreenshot","compress","decompress","crc32"} do
        local w=world(true); w.game.w,w.game.h=48,32
        local t=(which=="getScreenshot" or which=="forceRedrawForScreenshot" or which=="redrawingForSavefileScreenshot")
            and w.env.core.display or w.env.zlib
        local old=t[which]; local calls=0
        t[which]=function(...) calls=calls+1; return old(...) end
        local before=native.stats(); w.game:takeScreenshot(true)
        check(native.stats().captures==before.captures+1,"changed binding bypasses: "..which)
        if which=="getScreenshot" or which=="forceRedrawForScreenshot" then check(calls==1,"current override remains effective") end
    end
    do
        local w=world(true); w.game.w,w.game.h=48,32
        local token={}; local calls=0
        native.setup("redraw_callback",function()
            w.env.core.display.getScreenshot=function(...)
                calls=calls+1; check(select("#",...)==4,"mid-redraw replacement receives original crop args")
                return token,nil,"tail",nil
            end
        end)
        local result=pack(w.game:takeScreenshot(true))
        check(result.n==4 and result[1]==token and result[2]==nil and result[3]=="tail" and result[4]==nil,
            "binding mutation during redraw preserves exact fallback returns")
        check(calls==1 and native.stats().reads==0,"mid-redraw binding bypass occurs before readback")
    end
    for _,tableName in ipairs{"core","display","zlib"} do
        local w=world(true); w.game.w,w.game.h=48,32
        local t=tableName=="display" and w.env.core.display or w.env[tableName]
        setmetatable(t,{__index=function() error("unknown metatable must not be inspected") end})
        local before=native.stats(); w.game:takeScreenshot(true)
        check(native.stats().captures==before.captures+1,"metatable mutation bypasses: "..tableName)
    end
    print("PASS screenshot: encoding failure cleanup, dynamic override fallback and exact return arity")

    for _,state in ipairs{"framebuffer","pbo"} do
        local proxy=setmetatable({}, {__index=ffi})
        proxy.new=function(ctype,...)
            local value=ffi.new(ctype,...)
            if ctype=="unsigned char[?]" then native.setup(state,77) end
            return value
        end
        local w=world(true,{require=function(name) if name=="ffi" then return proxy end; return require(name) end})
        w.game.w,w.game.h=48,32
        local before=native.stats(); w.game:takeScreenshot(true)
        check(native.stats().captures==before.captures+1,"final GL guard follows allocation: "..state)
    end
    do
        local proxy=setmetatable({}, {__index=ffi}); local reenter
        proxy.copy=function(...)
            if reenter then local f=reenter; reenter=nil; f() end
            return ffi.copy(...)
        end
        local w=world(true,{require=function(name) if name=="ffi" then return proxy end; return require(name) end})
        w.game.w,w.game.h=80,48
        local expected=native.decode(w.original(w.game,true)); local before=native.stats()
        reenter=function()
            native.setup("color_offset",99)
            local nested=w.game:takeScreenshot(true)
            check(native.decode(nested)~=expected,"nested capture uses its own current pixels")
            native.setup("color_offset",0)
        end
        local result=w.game:takeScreenshot(true)
        check(native.decode(result)==expected,"reentrant capture cannot overwrite outer pixel storage")
        check(native.stats().captures==before.captures+1,"nested capture delegates once while outer uses fast path")
    end
    for _,failure in ipairs{"allocation","copy"} do
        local proxy=setmetatable({}, {__index=ffi})
        if failure=="allocation" then proxy.new=function(ctype,...)
            if ctype=="unsigned char[?]" then error("allocation fixture") end
            return ffi.new(ctype,...)
        end else proxy.copy=function() error("copy fixture") end end
        local w=world(true,{require=function(name) if name=="ffi" then return proxy end; return require(name) end})
        w.game.w,w.game.h=48,32; local before=native.stats(); w.game:takeScreenshot(true)
        check(native.stats().captures==before.captures+1,"protected "..failure.." failure delegates")
    end
    print("PASS screenshot: allocation-driven GL changes, reentry isolation and memory errors")

    -- Execute the Windows resolver against controlled already-loaded handles
    -- and the same public C fixture. This verifies resolver behavior/prototype
    -- declarations on Linux, not the Windows loader or machine ABI itself.
    local function windows(missing, arch)
        local declarations,casts,lookups,modules={},{},{},{}
        local sdl,gl=ffi.cast("void *",0x1001),ffi.cast("void *",0x1002)
        local known={SDL_GL_GetCurrentWindow="SDL2.dll",SDL_GetWindowSize="SDL2.dll",
            glGetString="opengl32.dll",glGetIntegerv="opengl32.dll",
            glPixelStorei="opengl32.dll",glReadPixels="opengl32.dll"}
        local pending
        local C={
            GetModuleHandleA=function(name)
                check(name=="SDL2.dll" or name=="opengl32.dll","resolve only known already-loaded DLL names")
                modules[#modules+1]=name
                if missing==name then return ffi.cast("void *",0) end
                return name=="SDL2.dll" and sdl or gl
            end,
            GetProcAddress=function(handle,name)
                check(known[name]~=nil,"resolve only documented public entry points")
                check(handle==(known[name]=="SDL2.dll" and sdl or gl),"resolve symbol from its original module")
                lookups[#lookups+1]=name; pending=name
                if missing==name then return ffi.cast("void *",0) end
                return ffi.cast("void *",ffi.C[name])
            end,
        }
        local proxy=setmetatable({os="Windows",arch=arch or "x64",C=C}, {__index=ffi})
        proxy.cdef=function(text) declarations[#declarations+1]=text; return ffi.cdef(text) end
        proxy.cast=function(signature,address) casts[pending]=signature; return ffi.cast(signature,address) end
        proxy.load=function() error("Windows resolver must never load a DLL") end
        local overrides={require=function(name) if name=="ffi" then return proxy end; return require(name) end}
        return overrides,{declarations=declarations,casts=casts,lookups=lookups,modules=modules}
    end
    do
        local overrides,observed=windows()
        local w=world(true,overrides)
        compare(w,17,11,3,5,true)
        check(#observed.modules==2 and #observed.lookups==6,"Windows resolver checks two modules and six exports")
        local declarations=table.concat(observed.declarations,"\n")
        check(declarations:find("void * __stdcall GetModuleHandleA(const char *);",1,true)
            and declarations:find("void * __stdcall GetProcAddress(void *, const char *);",1,true),
            "Win32 resolver prototypes explicitly use stdcall")
        for name,signature in pairs(observed.casts) do
            local convention=name:find("^SDL_") and "__cdecl" or "__stdcall"
            check(signature:find(convention,1,true),name.." uses documented calling convention")
        end
    end
    for _,missing in ipairs{"SDL2.dll","opengl32.dll","SDL_GL_GetCurrentWindow","SDL_GetWindowSize",
        "glGetString","glGetIntegerv","glPixelStorei","glReadPixels"} do
        local overrides=windows(missing)
        local w=world(false,overrides)
        check(w.Faster.prepareScreenshot(w.original)==nil,"missing Windows module/export delegates: "..missing)
        check(native.stats().reads==0,"missing Windows API never attempts pixel read")
    end
    for _,setting in ipairs{{"framebuffer",8},{"pbo",9},{"row_length",20},{"skip_rows",1},{"skip_pixels",1},
        {"read_buffer",0},{"gl_version","2.1 Fixture"},{"gl_version","OpenGL ES 3.2 Fixture"}} do
        local overrides=windows()
        local w=world(true,overrides); w.game.w,w.game.h=48,32; native.setup(setting[1],setting[2])
        local before=native.stats(); w.game:takeScreenshot(true)
        check(native.stats().captures==before.captures+1,"Windows-resolved API retains GL guard: "..setting[1])
        check(native.stats().errors==0,"Windows-resolved guard does not alter GL error state")
    end
    do
        local overrides=windows(nil,"x86")
        local w=world(false,overrides); native.setup("crc_mode",1)
        check(w.Faster.prepareScreenshot(w.original)==nil,"Windows x86 branch retains high-bit CRC preflight")
        native.setup("crc_mode",0)
        local fast=assert(w.Faster.prepareScreenshot(w.original)); w.Game.takeScreenshot=fast
        compare(w,17,11,3,5,true)
    end
    print("PASS screenshot: Windows loaded-module resolver, every missing export, explicit ABI declarations and shared guards (Linux fixture)")

    for _,failure in ipairs{"noffi","platform","arch","symbol"} do
        local proxy=setmetatable({}, {__index=ffi})
        if failure=="platform" then proxy.os="OSX" end
        if failure=="arch" then proxy.arch="arm64" end
        if failure=="symbol" then proxy.C=setmetatable({}, {__index=function() error("missing public symbol") end}) end
        local w=world(false,{require=function(name)
            if name=="ffi" then if failure=="noffi" then error("no FFI") end; return proxy end
            return require(name)
        end})
        check(w.Faster.prepareScreenshot(w.original)==nil,"unsupported API preflight: "..failure)
    end
    do
        local w=world(false)
        native.setup("crc_mode",1)
        check(w.Faster.prepareScreenshot(w.original)==nil,"high-bit incremental CRC preflight rejects incompatible conversion")
        native.setup("crc_mode",0)
        check(w.Faster.prepareScreenshot(w.original,{screenshot_png=false})==nil,"setting disables candidate")
        check(w.Faster.prepareScreenshot(function() end)==nil,"unknown Lua method rejected")
        check(w.Faster.prepareScreenshot(native.capture)==nil,"unknown C method rejected")
        local altered=setfenv(assert(loadstring("\n"..code,"@/mod/class/Game.lua")),w.env)
        altered(); check(w.Faster.prepareScreenshot(w.Game.takeScreenshot)==nil,"shifted source layout rejected")
        local fast=assert(w.Faster.prepareScreenshot(w.original)); check(w.Faster.prepareScreenshot(fast)==fast,"prepared wrapper is idempotent")
        check(getfenv(w.original)==w.env,"prepare never mutates original environment")
    end
    check(handle~=nil,"retain fixture's public-symbol handle")
    print("PASS screenshot: "..checks.." checks")
end
local ok,err=xpcall(main,debug.traceback)
assert(success(os.execute("rm -rf "..quote(build))))
if not ok then error(err,0) end
