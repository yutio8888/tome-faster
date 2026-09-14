-- ToME / T-Engine4, GPL-3.0-or-later; see COPYING. No warranty.
-- Fixed engine: 1.7.6, commit 624a67329fe2ad440c5b344785a9c73fcf22ae63.
-- Keep standard inventory ownership in the stock reader's numeric-id form.
local M = {}
local installed = setmetatable({}, {__mode = "k"})
local getters = setmetatable({}, {__mode = "k"})

local function upstream(f, path, first, last)
    if type(f) ~= "function" then return false end
    local info = debug.getinfo(f, "S")
    return info.source == path and info.linedefined == first and info.lastlinedefined == last
end

local function stockGetter(f)
    if type(f) ~= "function" then return false end
    local known = getters[f]
    if known == nil then
        known = upstream(f, "@/engine/interface/ActorInventory.lua", 92, 100)
        getters[f] = known
    end
    return known
end

local function plain(t) return type(t) == "table" and getmetatable(t) == nil end

-- Resolve ordinary class inheritance without invoking addon __index callbacks.
-- Multiple-base copies and the stock NPC's single-base lookup both work.
local function method(t, key)
    for _ = 1, 16 do
        local value = rawget(t, key)
        if value ~= nil then return value end
        local mt = getmetatable(t)
        if type(mt) ~= "table" then return nil end
        t = rawget(mt, "__index")
        if type(t) ~= "table" then return nil end
    end
end

local function compact(self, o, inven)
    if type(self) ~= "table" or type(o) ~= "table" or not plain(inven)
        or not stockGetter(method(self, "getInven")) then return end
    local invens, id = rawget(self, "inven"), rawget(inven, "id")
    if not plain(invens) or type(id) ~= "number" or id < 1 or id >= math.huge
        or id ~= math.floor(id) or not rawequal(rawget(invens, id), inven) then return end
    local owner = rawget(o, "in_inven")
    if not plain(owner) or not rawequal(rawget(owner, "actor"), self) or not rawequal(rawget(owner, "id"), inven) then return end
    -- Callbacks may remove, transfer or replace the ownership record. Leave
    -- all nonstandard records alone, including an otherwise valid extension.
    for key in pairs(owner) do if key ~= "actor" and key ~= "id" then return end end
    owner.id = id
end

function M.install(Inventory, Actor, Player, options)
    if options and options.compact_inventory ~= nil and options.compact_inventory ~= true then return false, "compact_inventory disabled" end
    if type(Inventory) ~= "table" or type(Actor) ~= "table" or type(Player) ~= "table" then
        return false, "inventory, actor or player class not loaded"
    end
    local inventoryAdd, actorAdd, playerAdd = rawget(Inventory, "onAddObject"), rawget(Actor, "onAddObject"), rawget(Player, "onAddObject")
    local token = installed[inventoryAdd]
    if token and token == installed[actorAdd] and token == installed[playerAdd]
        and stockGetter(method(Inventory, "getInven")) and stockGetter(method(Actor, "getInven"))
        and stockGetter(method(Player, "getInven")) then return true end
    if not upstream(inventoryAdd, "@/engine/interface/ActorInventory.lua", 306, 320)
        or not upstream(actorAdd, "@/mod/class/Actor.lua", 4911, 4943)
        or not upstream(playerAdd, "@/mod/class/Player.lua", 1581, 1610)
        or not stockGetter(method(Inventory, "getInven")) or not stockGetter(method(Actor, "getInven"))
        or not stockGetter(method(Player, "getInven")) then
        return false, "unknown inventory ownership or lookup method; keeping existing records"
    end

    local inventoryWrapper, actorWrapper, playerWrapper
    local function unchanged()
        return rawget(Inventory, "onAddObject") == inventoryWrapper and rawget(Actor, "onAddObject") == actorWrapper
            and rawget(Player, "onAddObject") == playerWrapper
    end
    local function wrap(original)
        local wrapper
        wrapper = function(self, o, inven_id, item, ...)
            -- Numeric/string ids and calls beneath another method use the
            -- original directly. Unknown outer addon wrappers are untouched.
            if type(inven_id) ~= "table" or type(self) ~= "table" or method(self, "onAddObject") ~= wrapper then
                return original(self, o, inven_id, item, ...)
            end
            original(self, o, inven_id, item, ...)
            -- All three pinned methods have zero returns. Finish only after
            -- ALL original hooks, talents, achievements and hotkeys complete;
            -- callbacks see their original parameters and table-id record.
            if unchanged() and method(self, "onAddObject") == wrapper then compact(self, o, inven_id) end
        end
        return wrapper
    end
    inventoryWrapper, actorWrapper, playerWrapper = wrap(inventoryAdd), wrap(actorAdd), wrap(playerAdd)
    Inventory.onAddObject, Actor.onAddObject, Player.onAddObject = inventoryWrapper, actorWrapper, playerWrapper
    -- Registry values never refer to their weak function keys or classes.
    -- There is no per-actor/object cache and no save/load graph traversal.
    token = {}
    installed[inventoryWrapper], installed[actorWrapper], installed[playerWrapper] = token, token, token
    return true
end

return M
