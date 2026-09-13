-- GPL-3.0-or-later. Shared native fixture build, always from the pinned engine.
return function(root, repo)
    local commit = "624a67329fe2ad440c5b344785a9c73fcf22ae63"
    local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
    local function output(command)
        local p = assert(io.popen(command)); local s = p:read("*a"); assert(p:close()); return s
    end
    local function pinned(path) return output("git -C " .. quote(repo) .. " show " .. quote(commit .. ":" .. path)) end
    local function section(source, first, last)
        local a = assert(source:find(first, 1, true))
        local b = last and assert(source:find(last, a, true)) or #source + 1
        local _, lines = source:sub(1, a - 1):gsub("\n", "")
        return string.rep("\n", lines) .. source:sub(a, b - 1)
    end
    local function write(path, s) local f = assert(io.open(path, "wb")); assert(f:write(s)); assert(f:close()) end
    local build = output("mktemp -d /tmp/tome-wait-refresh.XXXXXX"):gsub("\n$", "")
    assert(build:match("^/tmp/tome%-wait%-refresh%.[%w]+$"))
    local function cleanup() os.execute("rm -rf -- " .. quote(build)) end
    local function compile()
        write(build .. "/pinned_wait.c", section(pinned("src/wait.c"), "extern SDL_Window *window;"))
        write(build .. "/pinned_redraw.c", section(pinned("src/main.c"), "void call_draw(int nb_keyframes)", "void redraw_now(redraw_type_t rtype)"))
        write(build .. "/pinned_event_filter.c", section(pinned("src/main.c"), "int event_filter(void *userdata, SDL_Event* event)", "#define MIN(a,b)"))
        write(build .. "/pinned_web_external.h", pinned("src/web-external.h"))
        write(build .. "/pinned_web_dispatch.c", section(pinned("src/web.c"), "int browsers_count = 0;", "void te4_web_init(lua_State *L)"))
        local headers = os.getenv("TOME_LUA_INCLUDE")
        local flags = headers and ("-I" .. quote(headers)) or output(
            "if pkg-config --exists luajit; then pkg-config --cflags luajit; else pkg-config --cflags lua5.1; fi")
        local command = quote(os.getenv("CC") or "cc") .. " -shared -fPIC -O2 " .. flags:gsub("\n", " ") ..
            " -I" .. quote(build) .. " " .. quote(root .. "/tests/wait_refresh_fixture.c") ..
            " -o " .. quote(build .. "/wait_refresh_fixture.so") .. " -lm"
        local status = os.execute(command)
        assert(status == 0 or status == true, "native wait fixture compilation failed")
        return assert(package.loadlib(build .. "/wait_refresh_fixture.so", "luaopen_wait_refresh_fixture"))()
    end
    local ok, native = xpcall(compile, debug.traceback)
    if not ok then cleanup(); error(native) end
    return native, cleanup, pinned, section
end
