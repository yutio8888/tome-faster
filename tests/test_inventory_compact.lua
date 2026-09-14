-- GPL-3.0-or-later. Actual pinned inventory, stack and ToME callbacks.
assert(_VERSION == "Lua 5.1", "Lua 5.1 / LuaJIT required")
local root, repo = arg[1] or ".", assert(arg[2], "pass local engine Git clone")
local commit = "624a67329fe2ad440c5b344785a9c73fcf22ae63"
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function output(command)
    local p = assert(io.popen(command)); local s = p:read("*a"); assert(p:close()); return s
end
local function pinned(path) return output("git -C " .. quote(repo) .. " show " .. quote(commit .. ":" .. path)) end
local function section(source, first, last)
    local a = assert(source:find(first, 1, true)); local b = assert(source:find(last, a, true))
    local _, lines = source:sub(1, a - 1):gsub("\n", "")
    return string.rep("\n", lines) .. source:sub(a, b - 1)
end
local function run(code, name, env) return setfenv(assert(loadstring(code, name)), env)() end
local Faster = assert(loadfile(root .. "/overload/engine/FasterInventory.lua"))()
local inventoryCode = pinned("game/engines/default/engine/interface/ActorInventory.lua")
local actorCode = pinned("game/modules/tome/class/Actor.lua")
local playerCode = pinned("game/modules/tome/class/Player.lua")
local objectCode = pinned("game/engines/default/engine/Object.lua")
local classCode = pinned("game/engines/default/engine/class.lua")
local checks, cases = 0, 0
local function check(ok, why) assert(ok, why); checks = checks + 1 end
local function pack(...) return {n = select("#", ...), ...} end
local function collect() collectgarbage("collect"); collectgarbage("collect") end

local function world(optimized, kind, settings)
    local w = {trace = {}, objects = {}, floor = {}, entities = {}, failure = {}, fail = false}
    local Inventory, Actor, Player, Object, Class = {}, {}, {}, {}, {}
    local env = setmetatable({}, {__index = _G})
    local function token(v)
        if type(v) ~= "table" then return tostring(v) end
        if v == w.failure then return "failure" end
        if v == w.actor then return "actor" end
        if v.name and v.fixture then return "object:" .. v.name end
        if v.id then return "inventory:" .. tostring(v.id) end
        return "table"
    end
    function w.record(name, ...)
        local row = {name}
        for i = 1, select("#", ...) do row[#row + 1] = token(select(i, ...)) end
        w.trace[#w.trace + 1] = table.concat(row, "|")
        if w.fail == name then error(w.failure, 0) end
    end
    function w.observe(name, o, ...)
        local owner = o and o.in_inven
        local id = owner and owner.id
        if w.semantic_owners and type(id) == "table" then id = id.id end
        w.record(name, o, owner and owner.actor, id, ...)
    end
    env.print, env.module = function() end, function() end
    env.class = {make = function() end}
    env.require = function() return {} end
    env.require_first = function() return {makeKeyChar = function(_, i) return tostring(i) end} end
    env._t = function(s) return s end
    env.table = setmetatable({merge = function(dest, src)
        for k, v in pairs(src) do dest[k] = v end; return dest
    end}, {__index = table})
    env.engine = {interface = {ActorInventory = Inventory, PlayerHotkeys = {quickhotkeys = {}}}, Quest = {COMPLETED = "done"}}
    env.mod = {class = {Actor = Actor}}
    env.config = {settings = {tome = {auto_hotkey_object = true}}}
    local map = {attrs = function() end}
    function map:getObject(x, y, i) w.record("floor:get", x, y, i); return w.floor[i] end
    function map:removeObject(x, y, i) w.record("floor:remove", x, y, i); table.remove(w.floor, i) end
    function map:addObject(x, y, o) w.record("floor:add", x, y, o); w.floor[#w.floor + 1] = o; return true, #w.floor end
    env.game = {level = {map = map}, state = {}}
    function env.game:hasEntity(o) w.record("entity:has", o); return w.entities[o] end
    function env.game:addEntity(o) w.record("entity:add", o); w.entities[o] = true end
    function env.game:getPlayer(v) w.record("player:get", v); return w.actor end
    function env.game.log(...) w.record("log", ...) end
    function env.game.logSeen(...) w.record("logSeen", ...) end
    env.world = {gainAchievement = function(_, id, a, o) w.observe("achievement", o, id, a) end}
    env._M = Inventory; run(inventoryCode, "@/engine/interface/ActorInventory.lua", env)
    Inventory:defineInventory("MAINHAND", "Hand", true, "", true)
    Inventory:defineInventory("OFFHAND", "Other hand", true, "", true)
    Inventory:defineInventory("SPECIAL", "Special", false, "", false)
    -- Execute the actual class.inherit behavior, including multiple-base copies.
    local inheritEnv = setmetatable({_M = Class}, {__index = env})
    run(section(classCode, "local skip_key =", "function _M:importInterface"), "@/engine/class.lua", inheritEnv)
    Class.inherit = inheritEnv.inherit
    Class.inherit(Inventory, {})(Actor)
    local actorEnv = setmetatable({_M = Actor}, {__index = env})
    run(section(actorCode, "function _M:onAddObject(", "--- Returns the possible offslot"), "@/mod/class/Actor.lua", actorEnv)
    run(section(actorCode, "function _M:transmoPricemod(", "function _M:transmoGetNumberItems"), "@/mod/class/Actor.lua", actorEnv)
    Class.inherit(Actor, {})(Player)
    run(section(playerCode, "function _M:onAddObject(", "function _M:playerLevelup("), "@/mod/class/Player.lua",
        setmetatable({_M = Player}, {__index = env}))
    run(section(objectCode, "function _M:stackable()", "--- Sorting by type function"), "@/engine/Object.lua",
        setmetatable({_M = Object}, {__index = env}))
    w.Inventory, w.Actor, w.Player, w.Object, w.Class, w.env = Inventory, Actor, Player, Object, Class, env
    w.original = {Inventory.onAddObject, Actor.onAddObject, Player.onAddObject, Inventory.getInven}
    if optimized then check(Faster.install(Inventory, Actor, Player, settings or {compact_inventory = true}), "install pinned ownership methods") end
    local selected = kind == "engine" and Inventory or kind == "actor" and Actor or Player
    local a = setmetatable({__allow_carrier = true, x = 3, y = 5, player = kind ~= "engine" and kind ~= "actor",
        name = "fixture actor", hotkey = {}, nb_hotkey_pages = 1, money = 0, temp = {}, T_DEFILING_TOUCH = "curse",
        body = {INVEN = 10, MAINHAND = 1, OFFHAND = 1, SPECIAL = 5}}, {__index = selected})
    a:init{inven = {}}
    w.actor, env.game.player = a, a
    function a:triggerHook(hook)
        w.observe(hook[1], hook.o or hook.from, hook.inven_id, hook.price, hook.transmo_source)
        if w.hook then return w.hook(hook) end
    end
    function a:check(name, ...) w.record("actor:" .. name, ...); return false end
    function a:knowTalent(id) w.record("knowTalent", id); return id == self.T_DEFILING_TOUCH end
    function a:getTalentFromId(id)
        w.record("getTalent", id)
        return {curseItem = function(_, _, o) w.observe("curseItem", o); o.cursed = true end}
    end
    function a:addTemporaryValue(k, v) w.record("temporary:add", k, v); self.temp[k] = (self.temp[k] or 0) + 1; return self.temp[k] end
    function a:removeTemporaryValue(k, id) w.record("temporary:remove", k, id); self.temp[k] = self.temp[k] - 1 end
    function a:learnItemTalent(o, id, level) w.observe("talent:learn", o, id, level) end
    function a:unlearnItemTalent(o, id, level) w.observe("talent:unlearn", o, id, level) end
    function a:useObjectEnable(o, id, slot) w.observe("use:enable", o, id, slot) end
    function a:useObjectDisable(o, id, slot) w.observe("use:disable", o, id, slot) end
    function a:registerCallbacks(o, b, origin) w.observe("callback:register", o, b, origin) end
    function a:unregisterCallbacks(o, b) w.observe("callback:unregister", o, b) end
    function a:checkEncumbrance() w.record("encumbrance") end
    function a:registerArtifactsPicked(o) w.observe("artifact", o) end
    function a:findQuickHotkey(...) w.record("quickHotkey", ...); return 2 end
    function a:sortInven(...) w.record("sort", ...) end
    function a:canWearObject(...) w.record("canWear", ...); return true end
    function a:incMoney(n) w.record("money", n); self.money = self.money + n end
    function Object:check(name, ...)
        w.observe("object:" .. name, self, ...)
        if self.prevent == name then return true end
        return false
    end
    function Object:canUseObject() w.observe("canUse", self); return true end
    function Object:attr(name) w.observe("object:attr", self, name); return name == "auto_hotkey" end
    function Object:getName() return self.name end
    function Object:wornInven() return self.slot and Inventory["INVEN_" .. self.slot] end
    function Object:getPrice() return self.price or 20 end
    function w.object(name, stack)
        local o = setmetatable({fixture = true, name = name, stacking = stack, unique = true, carrier = {power = 2,
            learn_talent = {example = 1}}, carrier_callbacks = true}, {__index = Object})
        w.objects[#w.objects + 1] = o
        return o
    end
    function w.id(which) return which == "table" and a.inven[1] or which == "string" and "INVEN" or 1 end
    function w.add(o, which, ...) return a:addObject(w.id(which), o, ...) end
    return w
end

local function compare(scenario, kind)
    local a, b = world(false, kind), world(true, kind)
    local before, after = scenario(a, false), scenario(b, true)
    check(table.concat(a.trace, "\n") == table.concat(b.trace, "\n"), "same original callbacks, arguments, visibility and ordering\nold: " ..
        table.concat(a.trace, "\n") .. "\nnew: " .. table.concat(b.trace, "\n"))
    check(before == after, "same scenario results")
    cases = cases + 1
end

for _, kind in ipairs{"engine", "actor", "player"} do
    for _, idtype in ipairs{"table", "string", "number"} do
        compare(function(w, optimized)
            local o, id = w.object("item"), w.id(idtype)
            local result = pack(w.actor:addObject(id, o))
            check(result.n == 3 and result[1] == true and result[2] == 1 and result[3] == nil, "addObject return arity and values")
            check(o.in_inven.actor == w.actor and o.in_inven.id == (optimized and idtype == "table" and 1 or id), "only canonical table id compacted")
            check(w.actor:getInven(o.in_inven.id) == w.actor.inven[1], "stock getInven resolves ownership")
            w.trace = {} -- remove callbacks legitimately see the final representation.
            w.semantic_owners = true
            local result = pack(w.actor:removeObject(id, 1, true))
            check(result.n == 2 and result[1] == o and result[2] == true and o.in_inven == nil, "removeObject owner and return values")
            return tostring(w.actor.temp.power)
        end, kind)
    end
end

-- Full onAddObject callback traces must be identical through Player hotkeys.
for _, kind in ipairs{"engine", "actor", "player"} do
    compare(function(w, optimized)
        local o = w.object("callback-item")
        check(select("#", w.actor:onAddObject(o, w.actor.inven[1], 7, "extra")) == 0, "pinned callback returns zero values")
        check(o.in_inven.id == (optimized and 1 or w.actor.inven[1]), "post-callback canonical id")
        return w.actor.hotkey[2] and w.actor.hotkey[2][2] or "none"
    end, kind)
end

compare(function(w)
    local o = w.object("pickup", "potion")
    o.stacked = {w.object("pickup-stack", "potion")}; w.floor[1] = o
    local result = pack(w.actor:pickupFloor(1, false, true))
    check(result.n == 2 and result[1] == o and result[2] == 2 and #w.floor == 0, "real pickup moves complete stack")
    check(o.in_inven.id == 1, "numeric pickup unchanged")
    return tostring(o:getNumber())
end, "player")

compare(function(w, optimized)
    local a, b = w.actor, w.actor.inven[1]
    b.max, b.stack_limit = 1, 3
    local base = w.object("stack-base", "potion")
    w.add(base, "number")
    local o = w.object("added-stack", "potion")
    o.stacked = {w.object("sub-a", "potion"), w.object("sub-b", "potion")}
    w.trace = {}
    local result = pack(w.add(o, "table"))
    check(result.n == 3 and result[1] and result[2] == 1 and result[3] == base, "pinned partial-stack remainder behavior retained")
    check(base:getNumber() == 3 and o:getNumber() == 1, "actual Object.stack/unstack quantities")
    check(o.in_inven.id == (optimized and 1 or b), "new stack callback compacts only its standard record")
    -- Original engine assigns the record to the incoming stack root even when
    -- the remainder is outside the inventory. Do not invent ownership repair.
    check(a:itemPosition(b, o, true) == nil, "upstream remainder is not silently inserted")
    check(base.stacked[1].in_inven == nil and base.stacked[2].in_inven == nil, "subitems untouched")
    return tostring(base:getNumber()) .. ":" .. tostring(o:getNumber())
end, "player")

compare(function(w, optimized)
    local b = w.actor.inven[1]; b.stack_limit = 2
    local o = w.object("split-root", "potion")
    o.stacked = {w.object("split-a", "potion"), w.object("split-b", "potion")}
    local result = pack(w.add(o, "table"))
    check(result[1] and result[2] == 1 and result[3].name == "split-b" and o:getNumber() == 2, "pinned oversized stack return behavior")
    check(o.in_inven.id == (optimized and 1 or b), "split root owns canonical inventory")
    w.trace = {}
    w.semantic_owners = true
    local removed, finish = w.actor:removeObject(b, 1)
    check(removed.name == "split-a" and not finish and o:getNumber() == 1, "actual single unstack removal")
    check(removed.in_inven == nil and b[1] == o, "split removal clears only removed object")
    return removed.name
end, "player")

compare(function(w, optimized)
    local a, worn = w.actor, w.actor.inven[2]
    local old, o = w.object("old weapon"), w.object("new weapon")
    old.slot, o.slot = "MAINHAND", "MAINHAND"
    check(a:wearObject(old, true, false, worn), "first equip through canonical table")
    check(old.in_inven.id == (optimized and 2 or worn), "equipment table id compacted")
    w.trace = {}
    w.semantic_owners = true
    local replaced, rest = a:wearObject(o, true, false, worn)
    check(replaced == old and rest == nil and old.in_inven == nil and worn[1] == o, "replace/takeoff equipment values")
    -- The before-remove observer can see the intentionally compacted id.
    w.trace = {}
    local removed = a:takeoffObject(worn, 1)
    check(removed == o and o.in_inven == nil and #worn == 0, "actual takeoff clears ownership")
    return tostring(next(o.wielded or {}) == nil)
end, "player")

compare(function(w)
    local o = w.object("transmo", "potion")
    o.stacked = {w.object("transmo-child", "potion")}
    check(w.add(o, "number"), "transmo fixture added")
    w.trace = {}
    check(select("#", w.actor:transmoInven(w.actor.inven[1], 1, o, "fixture")) == 0, "pinned transmogrification returns zero values")
    check(o.in_inven == nil and #w.actor.inven[1] == 0 and w.actor.money == 2, "real transmo removes stack and awards gold")
    return tostring(w.actor.money)
end, "player")

compare(function(w)
    local o = w.object("drop")
    w.add(o, "number"); w.trace = {}
    check(w.actor:dropFloor(1, 1, false, true) == o and o.in_inven == nil and w.floor[1] == o, "drop keeps actual object and clears owner")
    return o.name
end, "actor")

for _, fail in ipairs{"curseItem", "temporary:add", "Actor:onAddObject", "talent:learn", "use:enable", "callback:register", "achievement", "quickHotkey"} do
    compare(function(w)
        local o = w.object("failure-item"); w.fail = fail
        local ok, err = pcall(w.add, o, "table")
        check(not ok and err == w.failure, "original callback error object propagates")
        check(not o.in_inven or o.in_inven.id == w.actor.inven[1], "failed callback never leaves an eagerly compacted record")
        return tostring(ok)
    end, "player")
end

-- Callback mutations and custom inventory semantics must survive unchanged.
for _, case in ipairs{"anonymous", "detached", "metatable", "invens-metatable", "wrong-id", "owner", "record-id", "record-extra", "record-metatable", "remove", "replaced-inventory", "getter", "new-override", "equal-owner"} do
    local w = world(true, "player")
    local o, inv = w.object(case), w.actor.inven[1]
    if case == "anonymous" then inv = {max = 2, stack_limit = 99}
    elseif case == "detached" then inv = {id = 1, max = 2}
    elseif case == "metatable" then setmetatable(inv, {})
    elseif case == "invens-metatable" then setmetatable(w.actor.inven, {})
    elseif case == "wrong-id" then inv.id = 2
    elseif case == "getter" then
        local original = w.actor.getInven; w.actor.getInven = function(self, id) return original(self, id) end
    else
        w.hook = function(h)
            if h[1] ~= "Actor:onAddObject" then return end
            if case == "owner" then o.in_inven.actor = {}
            elseif case == "equal-owner" then
                local mt = getmetatable(w.actor)
                mt.__eq = function() return true end
                o.in_inven.actor = setmetatable({}, mt)
            elseif case == "record-id" then o.in_inven.id = 4
            elseif case == "record-extra" then o.in_inven.extension = true
            elseif case == "record-metatable" then setmetatable(o.in_inven, {})
            elseif case == "remove" then o.in_inven = nil
            elseif case == "new-override" then w.actor.onAddObject = function() end
            elseif case == "replaced-inventory" then w.actor.inven[1] = {id = 1, max = 2} end
        end
    end
    w.actor:onAddObject(o, inv, 1)
    if case == "remove" then check(o.in_inven == nil, "hook removal retained")
    elseif case == "record-id" then check(o.in_inven.id == 4, "hook id retained")
    else check(o.in_inven.id == inv, "unrecognized ownership preserved: " .. case) end
end

for _, point in ipairs{1, 2, 3, 4} do
    local w = world(false)
    local classes = {w.Inventory, w.Actor, w.Player, w.Player}
    local field = point == 4 and "getInven" or "onAddObject"
    local custom = function() return "addon", nil, 8 end
    classes[point][field] = custom
    check(not Faster.install(w.Inventory, w.Actor, w.Player, {compact_inventory = true}) and classes[point][field] == custom, "unknown method prevents installation")
    check(w.Inventory.onAddObject == (point == 1 and custom or w.original[1]), "failed install has no partial mutation")
end
for _, point in ipairs{1, 2, 3} do
    local w = world(true)
    local classes = {w.Inventory, w.Actor, w.Player}
    local prior = classes[point].onAddObject
    classes[point].onAddObject = function(...) prior(...); return "addon", nil, 8 end
    local o = w.object("late")
    w.add(o, "table")
    check(o.in_inven.id == w.actor.inven[1], "late base or outer override prevents compaction")
    check(not Faster.install(w.Inventory, w.Actor, w.Player, {compact_inventory = true}), "late override retained on reinstall")
end
do
    local w = world(true)
    local prior = w.actor.onAddObject
    w.actor.onAddObject = function(...) prior(...); return "addon", nil, 8 end
    local o = w.object("instance-addon")
    local result = pack(w.actor:onAddObject(o, w.actor.inven[1], 1))
    check(result.n == 3 and result[1] == "addon" and result[2] == nil and result[3] == 8, "unknown instance override returns preserved")
    check(o.in_inven.id == w.actor.inven[1], "unknown instance override keeps original record")
end
do
    local w = world(true)
    local prior = w.Player.getInven
    w.Player.getInven = function(...) return prior(...) end
    local o = w.object("late-getter"); w.add(o, "table")
    check(o.in_inven.id == w.actor.inven[1], "late getter keeps original ownership")
    check(not Faster.install(w.Inventory, w.Actor, w.Player, {compact_inventory = true}), "reinstall reports late getter override")
end
compare(function(w)
    local o = w.object("custom-index")
    setmetatable(w.actor, {__index = function(_, key)
        w.record("custom-index", key); return w.Inventory[key]
    end})
    w.actor:onAddObject(o, w.actor.inven[1], 1)
    check(o.in_inven.id == w.actor.inven[1], "custom __index untouched and unoptimized")
    return o.name
end, "engine")
compare(function(w)
    local o = w.object("deleted-class-method")
    w.hook = function(h)
        if h[1] ~= "Actor:onAddObject" then return end
        w.Player.onAddObject = nil
        setmetatable(w.Player, {__index = function(_, key)
            w.record("late-class-index", key); return w.Actor[key]
        end})
    end
    w.actor:onAddObject(o, w.actor.inven[1], 1)
    check(o.in_inven.id == w.actor.inven[1], "deleted class method and new __index remain untouched")
    return o.name
end, "player")
do
    local w = world(false)
    check(not Faster.install(w.Inventory, w.Actor, w.Player, {compact_inventory = false}) and w.Actor.onAddObject == w.original[2], "independent opt-out")
    check(not Faster.install(w.Inventory, w.Actor, w.Player, {compact_inventory = "true"}) and w.Actor.onAddObject == w.original[2], "invalid inventory option keeps original methods")
    check(not Faster.install(w.Inventory, w.Actor, nil, {compact_inventory = true}), "unloaded class skipped")
    check(Faster.install(w.Inventory, w.Actor, w.Player, {compact_inventory = true}), "install after class initialization")
    local method = w.Player.onAddObject
    check(Faster.install(w.Inventory, w.Actor, w.Player, {compact_inventory = true}) and method == w.Player.onAddObject, "idempotent install")
end
for _, omitted in ipairs{"settings", "field"} do
    local w = world(false)
    check(Faster.install(w.Inventory, w.Actor, w.Player, omitted == "field" and {} or nil), "omitted " .. omitted .. " installs inventory compaction")
    local o = w.object("default-enabled")
    w.actor:onAddObject(o, w.actor.inven[1], 1)
    check(o.in_inven.id == 1, "default install writes the stock numeric inventory id")
end
do
    local w = world(false, "actor")
    local copied, dynamic, after = {}, {}, {}
    w.Class.inherit(w.Actor, {})(copied) -- cache old method exactly as engine does
    w.Class.inherit(w.Actor)(dynamic) -- actual NPC inheritance
    check(Faster.install(w.Inventory, w.Actor, w.Player, {compact_inventory = true}), "install with existing subclasses")
    w.Class.inherit(w.Actor, {})(after)
    for _, c in ipairs{copied, dynamic, after} do
        setmetatable(w.actor, {__index = c})
        local o = w.object("inherited")
        w.actor:onAddObject(o, w.actor.inven[1], 1)
        check(o.in_inven.id == (c == copied and w.actor.inven[1] or 1), "pre-copy fallback and dynamic/new inheritance")
    end
end
do
    collect()
    local weak = setmetatable({}, {__mode = "v"})
    do
        local w = world(true)
        local o = w.object("gc"); w.add(o, "table")
        weak[1], weak[2], weak[3], weak[4], weak[5] = w.actor, o, w.Inventory, w.Actor, w.Player
    end
    collect()
    for i = 1, 5 do check(weak[i] == nil, "weak metadata and install registry do not retain graph/classes") end
end

-- Exercise both representations through the pinned C serializer and stock
-- engine.class/Savefile reader. Ordinary inline tables deliberately lose alias
-- identity on load, so a saved table-id is NOT evidence for safe migration.
do
    local build = output("mktemp -d /tmp/tome-inventory-compact.XXXXXX"):gsub("\n$", "")
    assert(build:match("^/tmp/tome%-inventory%-compact%.[%w]+$"))
    local function write(path, data)
        local f = assert(io.open(path, "wb")); assert(f:write(data)); assert(f:close())
    end
    local serialCode = pinned("src/serial.c")
    write(build .. "/pinned_serial.c", section(serialCode, "static int serial_new(lua_State *L)", "static int serial_order_realsave"))
    write(build .. "/pinned_worker.c", section(serialCode, "int thread_save(void *data)", "// Runs on main thread"))
    local flags = output("if pkg-config --exists luajit; then pkg-config --cflags luajit; else pkg-config --cflags lua5.1; fi"):gsub("\n", " ")
    assert(os.execute(quote(os.getenv("CC") or "cc") .. " -shared -fPIC -O2 " .. flags .. " -I" .. quote(build) .. " " ..
        quote(root .. "/tests/save_callbacks_fixture.c") .. " -o " .. quote(build .. "/serial_fixture.so")) == 0)
    local native = assert(package.loadlib(build .. "/serial_fixture.so", "luaopen_serial_fixture"))()
    local saveCode = pinned("game/engines/default/engine/Savefile.lua")
    local Names = assert(loadfile(root .. "/overload/engine/FasterSaveNames.lua"))()
    local function saveWorld(files, optimized, shortNames)
        local w = world(optimized, "engine")
        local Class, Savefile = {}, {}
        local registry = {
            FixtureActor = setmetatable({triggerHook = function() end}, {__index = w.Inventory}),
            FixtureObject = setmetatable({}, {__index = w.Object}),
        }
        local function requireStub(name)
            if name == "engine.class" then return Class end
            if name == "engine.ui.Dialog" then return {} end
            return assert(registry[name], name)
        end
        local env = setmetatable({_M = Class, engine = {Savefile = Savefile}, require = requireStub,
            core = {serial = {new = native.new}}, table = w.env.table}, {__index = _G})
        run(section(classCode, "__zipname_zf_store = {}", "--- \"Reloads\""), "@/engine/class.lua", env)
        Class.load = env.load
        registry.FixtureActor.save, registry.FixtureObject.save = Class.save, Class.save
        local saveEnv = setmetatable({_M = Savefile, module = function() end, class = Class, require = requireStub,
            print = function() end, core = {wait = {manualTick = function() end}}, savefile_pipe = {current_nb = 0},
            fs = {open = function(path)
                local data = files and files[path]; if not data then return end
                local read = false
                return {read = function() if read then return end; read = true; return data end, close = function() end}
            end}}, {__index = _G})
        run(saveCode, "@/engine/Savefile.lua", saveEnv)
        if shortNames then check(Names.installSavefile(Savefile), "compose with existing compact save names") end
        local save = setmetatable({}, {__index = Savefile}); save:init("inventory"); save.load_dir = ""
        w.save, w.Savefile, w.registry = save, Savefile, registry
        return w
    end
    local function graph(w)
        local a = setmetatable({__CLASSNAME = "FixtureActor", inven = {{id = 1, max = 99, name = "INVEN"},
            {id = 2, max = 1, name = "MAINHAND", worn = true}}},
            {__index = w.registry.FixtureActor})
        for i = 1, 12 do
            local o = setmetatable({__CLASSNAME = "FixtureObject", name = "object " .. i, price = 20 + i},
                {__index = w.registry.FixtureObject})
            a.inven[1][i] = o
            a:onAddObject(o, i == 11 and "INVEN" or i == 12 and 1 or a.inven[1], i)
        end
        local equipped = setmetatable({__CLASSNAME = "FixtureObject", name = "equipped", slot = "MAINHAND", wielded = {attack = 9}},
            {__index = w.registry.FixtureObject})
        a.inven[2][1], a.equipped_reference = equipped, equipped
        a:onAddObject(equipped, a.inven[2], 1)
        -- A held stack member shares an old numeric ownership record; it must
        -- retain identity, quantity and metadata across both file forms.
        a.inven[1][1].stacked = {setmetatable({__CLASSNAME = "FixtureObject", name = "stack member", price = 77,
            in_inven = {actor = a, id = 1}}, {__index = w.registry.FixtureObject})}
        return a
    end
    local function serialize(w, a)
        native.reset(); w.Savefile.current_save = w.save
        check(w.save:saveObject(a, "inventory.tmp") == 15, "same root/items/equipment/stack object count")
        local files, bytes = {}, 0
        for _, entry in ipairs(native.entries()) do files[entry.file] = entry.data; bytes = bytes + #entry.data end
        return files, bytes
    end
    for _, shortNames in ipairs{false, true} do
        local oldBytes
        for _, optimized in ipairs{false, true} do
            local writer = saveWorld(nil, optimized, shortNames)
            local original = graph(writer)
            local files, bytes = serialize(writer, original)
            if not optimized then oldBytes = bytes else check(bytes < oldBytes, "native serialized payload smaller with numeric inventory ids") end
            local reader = saveWorld(files, false, false)
            check(reader.Inventory.onAddObject == reader.original[1], "bare reader has no inventory optimization")
            local a = reader.save:loadReal("main")
            check(#a.inven[1] == 12, "bare reader preserves inventory count")
            for i = 1, 12 do
                local o = a.inven[1][i]
                check(o.name == "object " .. i and o.price == 20 + i and o.in_inven.actor == a, "bare reader preserves object fields and owner")
                if i == 11 then check(o.in_inven.id == "INVEN" and a:getInven(o.in_inven.id) == a.inven[1], "mixed legacy string id untouched")
                elseif i == 12 or optimized then check(o.in_inven.id == 1 and a:getInven(o.in_inven.id) == a.inven[1], "bare getter resolves numeric record")
                else check(type(o.in_inven.id) == "table" and o.in_inven.id ~= a.inven[1] and o.in_inven.id[i] == o,
                    "old inline id reloads as detached table with real object references") end
            end
            local equipped = a.inven[2][1]
            check(equipped == a.equipped_reference and equipped.name == "equipped" and equipped.slot == "MAINHAND"
                and equipped.wielded.attack == 9 and equipped.in_inven.actor == a, "equipment identity, state and owner retained")
            if optimized then check(equipped.in_inven.id == 2 and a:getInven(equipped.in_inven.id) == a.inven[2], "bare getter resolves compact equipment")
            else check(type(equipped.in_inven.id) == "table" and equipped.in_inven.id[1] == equipped, "old equipment table id retains real item identity") end
            local stack = a.inven[1][1].stacked[1]
            check(stack.name == "stack member" and stack.price == 77 and stack.in_inven.actor == a and stack.in_inven.id == 1,
                "stack member, price and existing numeric ownership preserved")
            local oldId = a.inven[1][1].in_inven.id
            check(Faster.install(reader.Inventory, reader.Actor, reader.Player, {compact_inventory = true}), "enable addon after stock old/new load")
            check(a.inven[1][1].in_inven.id == oldId, "install performs no detached-table migration")
            local again, againBytes = serialize(reader, a)
            local bare = saveWorld(again, false, false); local loaded = bare.save:loadReal("main")
            check(#loaded.inven[1] == 12 and loaded.inven[1][1].in_inven.actor == loaded and againBytes > 0, "stock re-save loads again without addon")
            check(type(loaded.inven[1][1].in_inven.id) == (optimized and "number" or "table"), "re-save preserves old/new representation")
        end
    end
    collect()
    assert(os.execute("rm -r -- " .. quote(build)) == 0)
end
print("PASS " .. checks .. " inventory compaction checks; " .. cases .. " upstream differential scenarios, native/stock roundtrips, guards and GC")
