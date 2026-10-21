-- ============================================================
--   ReaNvelopes_DRAW.lua
--   Direct shape drawing, from ReaComposeM's DRAW.
--   Drag on an empty spot to draw a freehand stroke (it replaces the points,
--   simplified to the Resolution), drag a point to move it, right-click a
--   point to delete it.
--   Its OUTPUT section sends the drawn shape to an envelope, a MIDI CC
--   lane or note velocity.
-- ============================================================

local DRAW_Tool = {}

local _script_path = ({reaper.get_action_context()})[2]:match('^.+[/\\\\]'):gsub('\\\\','/')

local paths = {
    "lib/?.lua",
    "lib/DRAW/?.lua",
    "lib/UI/?.lua",
    "lib/CommonFunction/?.lua",
    "lib/CommonFunction/UI/?.lua"
}
for _, p in ipairs(paths) do
    local full_p = _script_path .. p .. ";"
    if not package.path:find(full_p, 1, true) then
        package.path = full_p .. package.path
    end
end

-- Status bar helper
local function Logger_ok(msg)
    local ok, Logger = pcall(require, "Logger")
    if ok and Logger and Logger.ok then Logger.ok(msg) end
end

local function getModules()
    return {
        DRAWState  = package.loaded["DRAWState"]  or require("DRAWState"),
        DRAWPanel  = package.loaded["DRAWPanel"]  or require("DRAWPanel"),
        Widgets    = package.loaded["Widgets"]    or require("Widgets"),
        OutputPanel = package.loaded["OutputPanel"] or require("OutputPanel"),
    }
end

function DRAW_Tool.drawUI(ctx)
    local ok, mods = pcall(getModules)
    if not ok then
        reaper.ImGui_TextColored(ctx, 0xFF0000FF, "DRAW Load Error:")
        reaper.ImGui_TextWrapped(ctx, tostring(mods))
        return
    end

    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local P  = mods.DRAWPanel
    local W  = mods.Widgets
    local S  = mods.DRAWState

    if SLK_HUB_IN_USE then reaper.ImGui_Dummy(ctx, 1, 4) end

    -- ── Presets ───────────────────────────────────────────────
    W.drawSectionSep(ctx, dl, "PRESETS")
    P.drawPresetBar(ctx)

    -- ── Shape mode ────────────────────────────────────────────
    W.drawSectionSep(ctx, dl, "SHAPE MODE")
    P.drawShapeModePanel(ctx)

    -- ── Canvas ────────────────────────────────────────────────
    W.drawSectionSep(ctx, dl, "DRAW")
    P.drawCanvas(ctx)

    -- ── Resolution ────────────────────────────────────────────
    W.drawSectionSep(ctx, dl, "GENERATION")
    P.drawResolutionPanel(ctx)

    -- ── OUTPUT ─────────────────────────────────────────────
    W.drawSectionSep(ctx, dl, "OUTPUT")
    mods.OutputPanel.draw(ctx, "ReaNvelopes: DRAW",
        function()
            local out = {}
            if #S.points < 2 then return out end
            if S.shape_mode == "smooth" then
                -- Smooth is a curve between the points (smoothstep), not straight lines: write the curve itself,
                -- sampled finely (the thinning in the OUTPUT section drops what is not needed).
                local N = 256
                for i = 0, N do
                    local t = i / N
                    out[#out + 1] = { tn = t, v = S.sampleAt(t) }
                end
                return out
            end
            for i, p in ipairs(S.toSendPts()) do out[i] = { tn = p.x, v = p.y } end
            return out, (S.shape_mode == "step")   -- steps: a value is held until the next point
        end,
        nil)

    reaper.ImGui_Dummy(ctx, 1, 2)
end

return DRAW_Tool
