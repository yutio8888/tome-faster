-- Local Linux diagnostic only. Never included in the installed addon.
-- Exercise the installed exporter on a disposable full-game save; capture all
-- outgoing profile orders before simulating authentication.
local M = {}

function M.run(realgame)
    local ffi = require "ffi"
    ffi.cdef[[
    struct faster_gzip_check_mallinfo { size_t arena,ordblks,smblks,hblks,hblkhd,usmblks,fsmblks,uordblks,fordblks,keepcost; };
    struct faster_gzip_check_mallinfo mallinfo2(void);
    struct faster_gzip_check_ts { long tv_sec, tv_nsec; };
    ]]
    local ts = ffi.new("struct faster_gzip_check_ts[1]")
    local clock = ffi.cast("int (*)(int, void *)", ffi.C.clock_gettime)
    local function now() clock(1, ts); return tonumber(ts[0].tv_sec)*1000 + tonumber(ts[0].tv_nsec)/1e6 end
    local function memory() local m = ffi.C.mallinfo2(); return tonumber(m.uordblks + m.hblkhd) end
    local original = require("engine.interface.PlayerDumpJSON").saveUUID
    local env = getfenv(original)
    local profile, jsonlib = env.profile, env.json
    local consumer = profile.registerSaveChardump
    local consumerenv = getfenv(consumer)
    local info = debug.getinfo(consumer, "S")
    assert(info.source == "@/engine/PlayerProfile.lua" and info.linedefined == 928)
    assert(realgame.player.__te4_uuid, "existing UUID required")
    local method = realgame.player.saveUUID
    local delegate
    for i = 1, 20 do
        local name, value = debug.getupvalue(method, i)
        if not name then break end
        if name == "delegate" then delegate = value end
    end
    assert(delegate, "expected installed offline wrapper")
    local optimized = config.settings.faster_tome.export_gzip ~= false
    local dinfo = debug.getinfo(delegate, "S")
    assert((dinfo.source:find("FasterGzip.lua", 1, true) ~= nil) == optimized,
        "gzip installation does not match experiment")
    local exportenv = getfenv(delegate)
    local oldgame, oldauth, oldhash, oldpush = _G.game, profile.auth, profile.hash_valid, core.profile.pushOrder
    local encode = jsonlib.encode
    local state = require("engine.FasterSaveState")
    local before = state.capture(realgame)
    local snapshot = require("engine.class").cloneForSave(realgame)
    local snapshotBefore = state.capture(snapshot)
    local rawJSON, lastOrder, count, unexpected = nil, nil, 0, 0
    local result
    local function restore()
        profile.auth, profile.hash_valid = oldauth, oldhash
        setfenv(consumer, consumerenv)
        setfenv(delegate, exportenv)
        core.profile.pushOrder = oldpush
        _G.game = oldgame
    end
    local ok, err = pcall(function()
        core.profile.pushOrder = function()
            unexpected = unexpected + 1
            error("unexpected outgoing profile order blocked by gzip diagnostic")
        end
        local capture = setmetatable({pushOrder = function(value)
            local order = value:unserialize()
            assert(order.o == "SaveChardump", "unexpected order type")
            count = count + 1
            lastOrder = order
        end}, {__index = core.profile})
        setfenv(consumer, setmetatable({core = setmetatable({profile = capture}, {__index = core}),
            print = function() end}, {__index = consumerenv}))
        setfenv(delegate, setmetatable({json = setmetatable({encode = function(value)
            rawJSON = encode(value)
            return rawJSON
        end}, {__index = jsonlib})}, {__index = exportenv}))
        _G.game = snapshot
        profile.auth, profile.hash_valid = {login = "local-capture-only"}, true
        local function export() snapshot.player:saveUUID(nil) end
        export()
        assert(count == 1 and rawJSON and lastOrder)
        local decoded, status = zlib.decompress(lastOrder.data, 47)
        assert(status == 1 and decoded == rawJSON, "actual exported gzip does not roundtrip")
        local baseline = assert(core.zlib.compress(rawJSON))
        local candidate, finished = zlib.compress(rawJSON, 9, 8, 31, 8, 0)
        assert(finished == 1 and baseline == candidate and lastOrder.data == baseline,
            "gzip bytes differ on actual character JSON")
        local rawBytes, compressedBytes = #rawJSON, #lastOrder.data
        local title = lastOrder.metadata:unserialize().title
        assert(type(title) == "string" and #title > 0)
        baseline, candidate, decoded, rawJSON, lastOrder = nil, nil, nil, nil, nil
        -- Warm descriptions and JIT, then release every retained output before
        -- native readings. This is full export timing, not compressor-only CPU.
        for i = 1, 5 do export() end
        local batches = {}
        for batch = 1, 2 do
            rawJSON, lastOrder = nil, nil
            collectgarbage("collect")
            local m0, t0, c0 = memory(), now(), count
            for i = 1, 50 do export() end
            local elapsed = now() - t0
            rawJSON, lastOrder = nil, nil
            collectgarbage("collect")
            batches[#batches + 1] = {calls = count-c0, wall_ms = elapsed,
                native_allocated_delta_bytes = memory()-m0}
        end
        assert(state.check(snapshotBefore, snapshot), "export changed selected snapshot state")
        assert(state.check(before, realgame), "export changed selected live state")
        assert(unexpected == 0)
        result = {optimized = optimized, exporter_source = dinfo.source,
            runtime = jit.version, raw_json_bytes = rawBytes, gzip_bytes = compressedBytes,
            real_gzip_byte_equal = true, real_gzip_roundtrip = true,
            selected_live_and_snapshot_state_equal = true, real_network_calls = 0,
            captured_exports = count, batches = batches,
            memory_method = "glibc mallinfo2 uordblks+hblkhd; full Lua GC before/after each batch, outputs discarded"}
    end)
    restore()
    if not ok then error(err, 0) end
    print("[GzipCheck] PASS " .. encode(result))
    return result
end

return M
