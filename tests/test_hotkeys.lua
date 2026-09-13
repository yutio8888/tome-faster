-- GPL-3.0-or-later. Execute the actual pinned display/toScreen, without fake
-- debug source locations. The C adapter below tests native method boundaries;
-- actual engine glyph pixels and GL state are checked by the native evidence.
assert(_VERSION == "Lua 5.1", "Lua 5.1 / LuaJIT required")
local root, repo = arg[1] or ".", assert(arg[2], "pass a local engine Git clone")
local commit = "624a67329fe2ad440c5b344785a9c73fcf22ae63"
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function output(command)
    local p = assert(io.popen(command)); local s = p:read("*a"); assert(p:close()); return s
end
local function read(path) local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s end
local function write(path, s) local f = assert(io.open(path, "wb")); assert(f:write(s)); f:close() end
local function pinned(path) return output("git -C " .. quote(repo) .. " show " .. quote(commit .. ":" .. path)) end
local function section(s, first, last)
    local a = assert(s:find(first, 1, true)); local b = assert(s:find(last, a, true))
    local _, n = s:sub(1, a - 1):gsub("\n", "")
    return string.rep("\n", n) .. s:sub(a, b - 1)
end
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local build = output("mktemp -d /tmp/tome-hotkeys-tests.XXXXXX"):gsub("\n$", "")
assert(build:match("^/tmp/tome%-hotkeys%-tests%.[%w]+$"))
local function main()
    write(build .. "/adapter.c", [[
#include <lua.h>
#include <lauxlib.h>
static int method(lua_State *L) {
    int n=lua_gettop(L); lua_getfenv(L,1);
    lua_getfield(L,-1,lua_tostring(L,lua_upvalueindex(1))); lua_remove(L,-2);
    lua_insert(L,1); lua_call(L,n,LUA_MULTRET); return lua_gettop(L);
}
static int wrap_call(lua_State *L) {
    int n=lua_gettop(L); lua_pushvalue(L,lua_upvalueindex(1));
    lua_insert(L,1); lua_call(L,n,LUA_MULTRET); return lua_gettop(L);
}
static int wrap(lua_State *L) { luaL_checktype(L,1,LUA_TFUNCTION); lua_pushvalue(L,1); lua_pushcclosure(L,wrap_call,1); return 1; }
static int object(lua_State *L) {
    const char *name=luaL_checkstring(L,1); luaL_checktype(L,2,LUA_TTABLE);
    lua_newuserdata(L,1); luaL_getmetatable(L,name); lua_setmetatable(L,-2);
    lua_pushvalue(L,2); lua_setfenv(L,-2); return 1;
}
static void klass(lua_State *L,const char *name,const char **methods) {
    luaL_newmetatable(L,name); lua_newtable(L); lua_pushstring(L,name); lua_setfield(L,-2,"class");
    for (;*methods;methods++) {lua_pushstring(L,*methods); lua_pushcclosure(L,method,1); lua_setfield(L,-2,*methods);}
    lua_setfield(L,-2,"__index"); lua_pop(L,1);
}
int luaopen_hotkeys_adapter(lua_State *L) {
    const char *fonts[]={"draw","getStyle","setStyle","size","height","lineSkip",NULL};
    const char *textures[]={"bind","toScreenFull",NULL};
    const char *surfaces[]={"erase","merge","glTexture",NULL};
    klass(L,"sdl{font}",fonts); klass(L,"gl{texture}",textures); klass(L,"sdl{surface}",surfaces);
    lua_newtable(L); lua_pushcfunction(L,object); lua_setfield(L,-2,"object");
    lua_pushcfunction(L,wrap); lua_setfield(L,-2,"wrap"); return 1;
}
]])
    local include = os.getenv("TOME_LUA_INCLUDE")
    local flags = include and "-I" .. quote(include) or output("if pkg-config --exists luajit; then pkg-config --cflags luajit; else pkg-config --cflags lua5.1; fi"):gsub("\n", " ")
    local status = os.execute(quote(os.getenv("CC") or "cc") .. " -shared -fPIC -O2 " .. flags .. " " .. quote(build .. "/adapter.c") .. " -o " .. quote(build .. "/adapter.so"))
    assert(status == 0 or status == true, "C adapter requires compiler and Lua 5.1 headers")
    local native = assert(package.loadlib(build .. "/adapter.so", "luaopen_hotkeys_adapter"))()
    local source = pinned("game/engines/default/engine/HotkeysIconsDisplay.lua")
    local code = section(source, "local page_to_hotkey =", "--- Call when a mouse event arrives")
    local helperSource = read(root .. "/overload/engine/FasterHotkeys.lua")
    local body = section(source, "function _M:display()", "--- Our toScreen override"):gsub("^\n+", "")
    body = body:gsub("function _M:display%(%)", "local function display(self)")
        :gsub("self%.font:draw%(", "cachedDraw(self, self.font, ")
        :gsub("self%.fontbig:draw%(", "cachedDraw(self, self.fontbig, "):gsub("%s+$", "")
    check(helperSource:find(body, 1, true), "production body equals pinned display with only three raster expressions changed")

    local function world(optimized)
        local w = {events = {}, raster = 0, binds = 0, screen_w = 1280, screen_h = 800, zoom = 1,
            split = false, blended = true, bindings = {}, textures = setmetatable({}, {__mode = "k"})}
        local function record(...)
            local values = {}; for i = 1, select("#", ...) do values[i] = tostring(select(i, ...)) end
            w.events[#w.events+1] = table.concat(values, "|")
        end
        w.record = record
        local function texture(value)
            local tex = native.object("gl{texture}", {
                bind = function(self, unit) w.binds = w.binds + 1; check(unit == 0, "hit restores current-unit binding"); w.bound = w.textures[self] end,
                toScreenFull = function(self, ...) w.bound = w.textures[self]; record("texture", w.textures[self], ...) end,
            }); w.textures[tex] = value; return tex
        end
        local function font(id, height)
            local style = "normal"
            return native.object("sdl{font}", {
                getStyle = function() return style end,
                setStyle = function(_, s) style = s; record("style", id, s) end,
                size = function(_, text) record("size", id, style, text); return #text * (style == "bold" and 7 or 6), height end,
                height = function() return height end, lineSkip = function() return height end,
                draw = function(_, text, width, r, g, b, wrap, uid)
                    w.raster = w.raster + 1
                    local label = table.concat({id, style, text, tostring(width), tostring(r), tostring(g), tostring(b), tostring(wrap), tostring(uid), tostring(w.split), tostring(w.blended)}, ":")
                    local tw, th = 1, 1; while tw < width do tw = tw * 2 end; while th < height do th = th * 2 end
                    local tex = texture(label); w.bound = label
                    local line = {_tex = tex, _tex_w = tw, _tex_h = th, w = width, h = height, realw = #text * 6, line = 1}
                    if w.malformed then line._dduids = {} end
                    return {line}, 1, line.realw
                end,
            })
        end
        w.font = font
        local display = {
            size = native.wrap(function() return w.screen_w / w.zoom, w.screen_h / w.zoom, false, false, w.screen_w, w.screen_h end),
            getBreakTextAllCharacter = native.wrap(function() return w.split end),
            getTextBlended = native.wrap(function() return w.blended end),
            newSurface = native.wrap(function(width,height)
                check(width==1 and height==1,"binding sentinel has fixed one-pixel allocation")
                return native.object("sdl{surface}",{glTexture=function()return texture("binding-sentinel"),1,1 end})
            end),
            drawQuad = function(...) record("quad", ...) end,
            drawQuadPart = function(...) record("quadpart", ...) end,
        }
        local Class = {}
        local e = setmetatable({_M = Class, core = {display = display}, config = {settings = {screen_zoom = 1, font_scale = 100, locale = "en"}},
            colors = {WHITE = {r=255,g=255,b=255}, ANTIQUE_WHITE = {r=250,g=235,b=215}},
            Shader = {default = {}}, UI = {drawFrame = function(_, ...) record("frame", ...) end}}, {__index = _G})
        local key = {}
        function key:findBoundKeys(name) record("bound", name); return name end
        function key:formatKeyString(name) record("format", name); if w.key_sideeffect then w.key_sideeffect() end; return w.bindings[name] or name end
        e.game = {key = key, mouse = {}}
        setfenv(assert(loadstring(code, "@/engine/HotkeysIconsDisplay.lua")), e)()
        local Faster = setfenv(assert(loadfile(root .. "/overload/engine/FasterHotkeys.lua")), e)()
        local original, originalScreen = Class.display, Class.toScreen
        if optimized then check(Faster.install(Class), "install actual pinned hotkey display") end
        check(Class.toScreen == originalScreen, "toScreen remains original")
        local a = {changed = true, hotkey_page = 1, hotkey = {}, talents = {}, talents_cd = {}, inventory = {}, active = {}, unavailable = {}}
        function a:getTalentFromId(id) record("talent", id); return self.talents[id] end
        function a:isTalentCoolingDown(t) record("cooling", t.id); return self.talents_cd[t.id] end
        function a:preUseTalent(t, ...) record("preUse", t.id, ...); self.uses = (self.uses or 0) + 1; return not self.unavailable[t.id] end
        function a:getTalentCooldown(t) record("cooldown", t.id); return t.cooldown end
        function a:isTalentActive(id) record("active", id); return self.active[id] end
        function a:findInAllInventories(id, options)
            record("inventory", id, options.no_add_name, options.force_id, options.no_count); return self.inventory[id]
        end
        local function entity(id) return {id = id, toScreen = function(_, _, ...) record("entity", id, ...) end} end
        local h = setmetatable({actor = a, font = font("small", 10), fontbig = font("big", 20), bgcolor = {1,2,3},
            surface = native.object("sdl{surface}", {erase = function(_, ...) record("erase", ...) end, merge = function(_, ...) record("merge", ...) end}),
            frames = {w=40,h=40,fx=4,fy=4,base="base"}, max_cols=6,max_rows=2,w=240,h=80,icon_w=32,icon_h=32,
            display_x=10,display_y=20,default_entity=entity("default"),tiles={}, items = {},clics={},dragclics={}}, {__index=Class})
        for i = 1, 8 do a.talents[i] = {id=i,cooldown=20,display_entity=entity("talent"..i)} end
        local function item(id, properties)
            local o = properties or {}; o.id=id; o.count=o.count or 1
            function o:getNumber() record("number", id); return self.count end
            function o:getObjectCooldown(actor) check(actor == a, "object cooldown gets actual actor"); record("object-cd", id); return self.cd end
            o.toScreen = entity("item"..id).toScreen
            return o
        end
        w.Faster,w.h,w.a,w.env,w.Class,w.original,w.originalScreen,w.item = Faster,h,a,e,Class,original,originalScreen,item
        return w
    end
    local function normalize(w, value, seen)
        if type(value) == "userdata" then return w.textures[value] or "native-resource" end
        if type(value) == "function" then return "function" end
        if type(value) ~= "table" then return tostring(value) end
        seen = seen or {}; if seen[value] then return "cycle" end; seen[value] = true
        local keys={}; for k in pairs(value) do keys[#keys+1]=k end
        table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
        local out={}; for _,k in ipairs(keys) do out[#out+1]=tostring(k).."="..normalize(w,value[k],seen) end
        seen[value]=nil; return "{"..table.concat(out,",").."}"
    end
    local function snapshot(w)
        local h=w.h
        return normalize(w,{items=h.items,clics=h.clics,dragclics=h.dragclics,font=h.font:getStyle(),fontbig=h.fontbig:getStyle(),uses=w.a.uses,bound=w.bound})
    end
    local before,after=world(false),world(true)
    local function step(name, change)
        for _,w in ipairs{before,after} do
            w.events={}; if change then change(w) end; w.h:toScreen()
        end
        check(table.concat(before.events,"\n")==table.concat(after.events,"\n"), name..": business/style/layout/final draw sequence")
        check(snapshot(before)==snapshot(after), name..": complete item/click state and final texture binding")
    end
    step("empty drag slots")
    step("empty repeated")
    check(after.Faster.stats().hits>=12 and after.raster<before.raster,"stable empty key rasterizations reused")
    step("background merge",function(w)w.h.bg_surface="background" end)
    step("talents and inventory",function(w)
        local a=w.a
        for i=1,8 do a.hotkey[i]={"talent",i} end
        a.talents_cd[1]=1;a.talents_cd[2]=10;a.talents_cd[3]=0;a.unavailable[2]=true;a.unavailable[4]=true;a.active[5]=true
        a.hotkey[9]={"inventory","potion"};a.inventory.potion=w.item("potion",{use_power=true,power=5,max_power=10,cd=2})
        a.hotkey[10]={"inventory","gone"};a.hotkey[11]={"inventory","wand"}
        a.inventory.wand=w.item("wand",{use_talent={id=6},wielded=true,talent_cooldown=1})
        a.hotkey[12]={"talent","unknown"};w.h.cur_sel=2
    end)
    step("unchanged talent business calls still execute")
    step("cooldown changes and item removal",function(w)
        w.a.talents_cd[1]=nil;w.a.talents_cd[2]=0.5;w.a.inventory.potion.count=0;w.a.inventory.potion.cd=false;w.a.inventory.wand=nil
    end)
    step("replacement and multi-digit object cooldown",function(w)
        w.a.inventory.potion=w.item("replacement",{use_power=true,power=10,max_power=20,cd=123.25})
        w.a.inventory.wand=w.item("newwand",{use_talent={id=2},wielded=true,power=1,max_power=3,cd=0})
    end)
    step("Chinese changed key",function(w) w.bindings.HOTKEY_1="控制+一" end)
    step("Chinese repeated")
    step("formatted dynamic bypass",function(w) w.bindings.HOTKEY_1="#UID:123#";w.bindings.HOTKEY_2="#RED#A#LAST#" end)
    step("formatted repeats stay fresh")
    step("external fontbig style mutation",function(w) w.h.fontbig:setStyle("italic") end)
    step("style stays italic")
    step("key formatting changes shared font style",function(w) w.key_sideeffect=function() w.h.font:setStyle("underline") end end)
    step("shared font restored",function(w) w.key_sideeffect=nil end)
    for _,field in ipairs{"screen","zoom","scale","locale","split","blended","surface","font","fontbig","icons"} do
        step("invalidate "..field,function(w)
            if field=="screen" then w.screen_w=1920;w.screen_h=1080
            elseif field=="zoom" then w.zoom=1.25;w.env.config.settings.screen_zoom=1.25
            elseif field=="scale" then w.env.config.settings.font_scale=120
            elseif field=="locale" then w.env.config.settings.locale="zh_HANS"
            elseif field=="split" then w.split=true
            elseif field=="blended" then w.blended=false
            elseif field=="surface" then w.h.surface=native.object("sdl{surface}",{erase=function(_,...)w.record("erase",...)end,merge=function(_,...)w.record("merge",...)end})
            elseif field=="font" or field=="fontbig" then w.h[field]=w.font(field.."-new",field=="font" and 12 or 24)
            else w.h.frames.w=50;w.h.icon_w=42;w.h.w=300 end
        end)
    end
    step("drag with shader shadows",function(w)
        w.a.hotkey[2]=nil;w.env.game.mouse.drag=true;w.h.shadow=128
        w.env.Shader.default.textoutline={shad={use=function(_,...)w.record("shader-use",...)end,
            uniOutlineSize=function(_,...)w.record("outline",...)end,uniTextSize=function(_,...)w.record("text-size",...)end}}
    end)
    step("fallback shadow draw",function(w) w.env.Shader.default.textoutline=nil end)
    for _,orient in ipairs{"down","up","left","right"} do
        step("orientation "..orient,function(w)w.h.orient=orient end)
    end
    step("second page",function(w)w.a.hotkey_page=2;w.a.hotkey[13]={"talent",1} end)
    step("last page partial grid",function(w)w.a.hotkey_page=7;w.h.max_cols=8;w.h.max_rows=2 end)
    step("beyond pages",function(w)w.a.hotkey_page=8 end)
    step("actor replacement",function(w)
        w.h.actor=setmetatable({changed=true,hotkey_page=1,hotkey={{"talent",8}},talents=w.a.talents,talents_cd={}}, {__index=w.a})
    end)
    step("no actor",function(w)w.h.actor=nil end)
    step("unchanged actor early return",function(w)w.h.actor=w.a;w.a.changed=false end)
    check(after.Faster.stats().entries<=512 and after.Faster.stats().bytes<=4*1024*1024,"scenario cache bounded")

    local w=world(true);local h,F=w.h,w.Faster
    local function draw(text,width,r,g,b,wrap,uid) return F.draw(h,h.fontbig,text or "12",width or 40,r or 255,g or 255,b or 255,wrap==nil and true or wrap,uid) end
    local a,n,m=draw(); local b,nn,mm=draw()
    check(a~=b and a[1]~=b[1] and a[1]._tex==b[1]._tex and n==nn and m==mm,"fresh result tables share only texture and preserve all returns")
    a[1].fw=123;a[1].fh=999;a[1].w=-1;a[1].extra={}
    b[1]._tex=nil;b[1].line_extra="bad"
    local c=draw();check(c[1].w==40 and c[1].fw==nil and c[1].fh==nil and c[1].extra==nil and c[1].line_extra==nil and c[1]._tex,"caller metadata writes cannot poison cache")
    for _,style in ipairs{"normal","bold","italic","underline","normal"} do h.fontbig:setStyle(style);local t=draw();check(w.textures[t[1]._tex]:find(":"..style..":",1,true),"current style "..style) end
    for _,values in ipairs{{"12",50},{"12",40,200},{"12",40,255,200},{"12",40,255,255,200},{"13",40}} do
        local prior=w.raster;draw(unpack(values));check(w.raster==prior+1,"text/width/RGB variants miss")
    end
    for _,values in ipairs{{"12",40,255,255,255,false},{"12",40,255,255,255,true,true},{"#RED#12",40},{"x\n12",40},{string.rep("a",257),40},{"12",40.5}} do
        local prior=w.raster;draw(unpack(values));draw(unpack(values));check(w.raster==prior+2,"unsafe text/options are always delegated")
    end
    F.clear(h);w.malformed=true;local prior=w.raster;draw();draw();check(w.raster==prior+2 and F.stats(h).entries==0,"mutable unexpected return metadata not cached");w.malformed=false
    for i=1,1200 do draw("unique"..i) end
    check(F.stats().entries<=512 and F.stats().evictions>0,"global entry FIFO bound")
    F.clear();for i=1,400 do draw("wide"..i,4096) end
    check(F.stats().bytes<=F.stats().max_bytes and F.stats().evictions>0,"power-of-two texture byte bound")
    local cached=draw("wide400",4096);check(cached[1].w==4096,"eviction leaves valid raster output")
    F.clear();check(F.stats().entries==0 and F.stats().bytes==0,"explicit clear releases all cache-owned resources")
    local owners={}
    for i=1,700 do
        owners[i]={font=h.font,fontbig=h.fontbig,surface=h.surface,w=1,h=1}
        F.draw(owners[i],h.font,"owner"..i,20,255,255,255,true)
    end
    check(F.stats().entries<=512,"entry limit is global across many live owners")
    F.clear(owners[700]);check(F.stats(owners[700]).entries==0,"owner clear releases only its entries")
    check(F.stats(owners[699]).entries==1,"other owner remains cached")
    F.clear()
    local prior=w.raster;draw("option-false",40,255,255,255,true,false);draw("option-false",40,255,255,255,true,false)
    check(w.raster==prior+1,"explicit false UID option is keyed and cached")
    draw("option-false",40);check(w.raster==prior+2,"nil and false UID calls preserve exact argument identity")
    local weak=setmetatable({h},{__mode="v"});draw();w.h=nil;h=nil;collectgarbage("collect");collectgarbage("collect")
    check(weak[1]==nil,"global FIFO entries never retain their display owner")

    w=world(false);local original=w.Class.display
    check(not w.Faster.install(w.Class,{hotkey_text_cache=false}) and w.Class.display==original,"explicit opt-out")
    local custom=function()return "custom"end;w.Class.display=custom
    check(not w.Faster.install(w.Class) and w.Class.display==custom,"unknown display source rejected")
    w.Class.display=original;w.Class.toScreen=custom
    check(not w.Faster.install(w.Class) and w.Class.display==original,"unknown toScreen override rejected")
    w=world(true);w.h:display();local prior=w.raster;w.h.toScreen=custom;w.h:display()
    check(w.raster==prior+12 and w.Faster.stats(w.h).entries==0,"late instance toScreen override uses original fresh text")
    w=world(true);w.h:display();local methods=debug.getregistry()["sdl{font}"].__index;local nativeDraw=methods.draw
    methods.draw=function(...) return nativeDraw(...) end
    prior=w.raster;w.h:display();check(w.raster==prior+12 and w.Faster.stats(w.h).entries==0,"late font draw override delegates and releases stale entries")
    methods.draw=nativeDraw
    local nativeSize=methods.size
    methods.size=function(...)return nativeSize(...)end
    local wrappedSizeWorld=world(false)
    check(wrappedSizeWorld.Faster.install(wrappedSizeWorld.Class),"stock-style Lua font measurement wrapper is compatible")
    wrappedSizeWorld.h:display();prior=wrappedSizeWorld.raster;wrappedSizeWorld.h:display()
    check(wrappedSizeWorld.raster==prior,"measurement calls remain dynamic while actual widths are cached")
    methods.size=nativeSize
    local luaFont={draw=function()return {{custom=true}},1,1 end,setStyle=function()end,size=function()return 1,1 end}
    local v=w.Faster.draw(w.h,luaFont,"custom",10,255,255,255,true)
    check(v[1].custom,"custom table font delegates intact")
    local badEnv=setmetatable({core={display={}},config={settings={}}},{__index=_G})
    local bad=setfenv(assert(loadfile(root.."/overload/engine/FasterHotkeys.lua")),badEnv)()
    local pinnedWorld=world(false);check(not bad.install(pinnedWorld.Class),"unknown native display API rejected")
    local saved=debug.getregistry()["sdl{font}"].__index.getStyle
    debug.getregistry()["sdl{font}"].__index.getStyle=function()return "normal"end
    local badStyle=setfenv(assert(loadfile(root.."/overload/engine/FasterHotkeys.lua")),pinnedWorld.env)()
    check(not badStyle.install(pinnedWorld.Class),"unknown style method rejected without spoofing debug metadata")
    debug.getregistry()["sdl{font}"].__index.getStyle=saved
    print("PASS "..checks.." hotkey checks: pinned display, business/style/draw parity, bounded cache, lifecycle and override fallback")
end
local ok,err=xpcall(main,debug.traceback)
os.remove(build.."/adapter.c");os.remove(build.."/adapter.so");os.execute("rmdir -- "..quote(build))
if not ok then error(err,0) end
