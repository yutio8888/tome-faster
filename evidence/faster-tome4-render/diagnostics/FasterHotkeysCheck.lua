-- Local full-engine pixel and return-structure comparison; no player output.
local M = {}
function M.run(realgame)
    local Cache = require "engine.FasterHotkeys"
    local Pixels = require "engine.FasterRenderPixels"
    local oldAA = core.display.getTextBlended()
    local oldBreak = core.display.getBreakTextAllCharacter()
    local owner, cases, frames = {}, 0, 0
    local function pack(...) return {n = select("#", ...), ...} end
    local function shape(value)
        if type(value) ~= "table" then return value end
        local out = {}
        for k, v in pairs(value) do
            if k == "_tex" then out[k] = Pixels.texture(v)
            elseif k ~= "_dduids" then out[k] = shape(v) end
        end
        return out
    end
    local fonts = {}
    for _, size in ipairs{10, 14, 20} do
        fonts[#fonts+1] = core.display.newFont("/data/font/DroidSansMono.ttf", size, true)
    end
    local decoySurface = core.display.newSurface(8, 8)
    decoySurface:erase(50, 100, 150, 200)
    local decoy = decoySurface:glTexture()
    local function compare(font, text, width, r, g, b, direct)
        local style = font:getStyle()
        decoy:bind(0)
        local before = pack(font:draw(text, width, r, g, b, true, direct))
        local beforeGL, beforeBound = Pixels.state(), Pixels.boundTexture()
        local beforeShape, afterStyle = shape(before), font:getStyle()
        font:setStyle(style)
        decoy:bind(0)
        local after = pack(Cache.draw(owner, font, text, width, r, g, b, true, direct))
        local afterGL, afterBound = Pixels.state(), Pixels.boundTexture()
        assert(Pixels.equal(beforeShape, shape(after)), "glyph pixels/metadata differ: " .. text)
        assert(Pixels.equal(beforeGL, afterGL), "font draw GL state differs")
        assert(Pixels.equal(beforeBound, afterBound), "font draw leaves different texture pixels bound")
        assert(afterStyle == font:getStyle(), "font style changed")
        if after[1][1] then after[1][1].fw = -100; after[1][1].test_mutation = true end
        font:setStyle(style)
        decoy:bind(0)
        local hit = pack(Cache.draw(owner, font, text, width, r, g, b, true, direct))
        local hitGL, hitBound = Pixels.state(), Pixels.boundTexture()
        assert(Pixels.equal(beforeShape, shape(hit)), "cache metadata aliases caller mutation")
        assert(Pixels.equal(beforeGL, hitGL) and Pixels.equal(beforeBound, hitBound), "cache hit GL state differs")
        assert(afterStyle == font:getStyle(), "cache hit font style changed")
        cases = cases + 1
    end
    local ok, err = pcall(function()
        Cache.clear()
        for _, aa in ipairs{false, true} do
            core.display.setTextBlended(aa)
            for _, split in ipairs{false, true} do
                core.display.breakTextAllCharacter(split)
                for _, font in ipairs(fonts) do
                    for _, style in ipairs{"normal", "bold", "italic", "underline"} do
                        font:setStyle(style)
                        for _, text in ipairs{"1", "Ctrl+F1", "Shift+9", "中文按键", "100", "9999", "#RED#F1#LAST#"} do
                            compare(font, text, 160, 250, 235, 215)
                        end
                    end
                end
            end
        end
        -- A continuously changing label/cooldown sequence, repeated through
        -- the exact native entry. Rebinding decoy on every hit checks GL state.
        core.display.setTextBlended(oldAA)
        core.display.breakTextAllCharacter(oldBreak)
        for frame = 1, 120 do
            local font = fonts[frame % #fonts + 1]
            font:setStyle(frame % 2 == 0 and "bold" or "normal")
            owner.w = frame <= 60 and 800 or 1024
            compare(font, frame % 7 == 0 and "中文键" or "Ctrl+1", 100, 255, 255, 255)
            compare(font, tostring(math.floor((120-frame)/3)), 40, 255, 255, 255)
            frames = frames + 1
        end
        -- The engine caches one texture ID across texture units. Binding the
        -- cached glyph on unit 1 can otherwise make unit 0's bind skip falsely.
        local font = fonts[1]
        font:setStyle("normal")
        local first = Cache.draw(owner, font, "unit-check", 100, 255, 255, 255, true)
        local expected = shape(pack(font:draw("unit-check", 100, 255, 255, 255, true)))
        local expectedBound = Pixels.boundTexture()
        decoy:bind(0)
        first[1]._tex:bind(1, false)
        local hit = pack(Cache.draw(owner, font, "unit-check", 100, 255, 255, 255, true))
        assert(Pixels.equal(expectedBound, Pixels.boundTexture()), "cross-unit cache left wrong texture bound")
        assert(Pixels.equal(expected, shape(hit)), "cross-unit cache glyph mismatch")
        Pixels.checkGL()
        local stats = Cache.stats(owner)
        assert(stats.hits > 0 and stats.entries <= stats.max_entries and stats.bytes <= stats.max_bytes,
            "native cache never hit or exceeded capacity")
        print("[HotkeysPixels] PASS " .. json.encode{cases = cases, sequence_frames = frames,
            glyph_pixels_equal = true, metadata_equal = true, gl_state_equal = true,
            returned_tables_independent = true, aa_and_split_invalidation = true, cache = stats,
            cross_texture_unit_binding_equal = true, runtime = jit.version})
    end)
    core.display.setTextBlended(oldAA)
    core.display.breakTextAllCharacter(oldBreak)
    Cache.clear(owner)
    if not ok then error(err, 0) end
end
return M
