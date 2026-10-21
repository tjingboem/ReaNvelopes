-- ============================================================
--   ReaNvelopes_OSC.lua
--   The OSC generator (polygon LFO), from ReaComposeM's OSC, itself derived
--   from sailok's ReaCurve LFO. Its OUTPUT section takes OSCPanel.getSendPts()
--   (exactly the data of the OSC Preview, normalised to [0,1]) to an envelope,
--   a MIDI CC lane or note velocity.
-- ============================================================

local script_name = "ReaNvelopes OSC"
local OSC_Tool = {}

local _script_path = ({reaper.get_action_context()})[2]:match('^.+[/\\\\]'):gsub('\\\\','/')

local paths = {
    "lib/?.lua",
    "lib/OSC/?.lua",
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

local function getModules()
    return {
        OSCState    = package.loaded["OSCState"]  or require("OSCState"),
        OSCPanels   = package.loaded["OSCPanel"]  or require("OSCPanel"),
        Widgets     = package.loaded["Widgets"]   or require("Widgets"),
        ReaperUtils = package.loaded["ReaperUtils"] or require("ReaperUtils"),
        OutputPanel = package.loaded["OutputPanel"] or require("OutputPanel"),
        OSCWrite    = package.loaded["OSCWrite"]    or require("OSCWrite"),
    }
end

function OSC_Tool.drawUI(ctx)
    local ok, mods = pcall(getModules)
    if not ok then
        reaper.ImGui_TextColored(ctx, 0xFF0000FF, "OSC Load Error:")
        reaper.ImGui_TextWrapped(ctx, tostring(mods))
        return
    end

    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local S  = mods.OSCState
    local P  = mods.OSCPanels
    local W  = mods.Widgets

    if SLK_HUB_IN_USE then reaper.ImGui_Dummy(ctx, 1, 4) end

    W.drawSectionSep(ctx, dl, "PRESETS")
    P.drawPresetBar(ctx)
    P.drawUIMode(ctx)

    W.drawSectionSep(ctx, dl, "POLYGON")
    P.drawPolygonPanel(ctx)
    P.drawRadarPanel(ctx)

    if P.shouldShowCurve then
        local a, vis = P.sectionAlpha("lfo_curve", P.shouldShowCurve())
        if vis then
            P.setDrawAlpha(a)
            if a < 1.0 then
                reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), a)
            end
            W.drawSectionSep(ctx, dl, "CURVE", a)
            P.drawCurvePanel(ctx)
            if a < 1.0 then reaper.ImGui_PopStyleVar(ctx) end
            P.setDrawAlpha(1.0)
        end
    end

    W.drawSectionSep(ctx, dl, "SEGMENT SHAPE")
    P.drawShapePanel(ctx)

    W.drawSectionSep(ctx, dl, "PREVIEW")
    P.drawPreviewPanel(ctx)

    W.drawSectionSep(ctx, dl, "AMPLITUDE")
    P.drawAmplitudePanel(ctx)

    W.drawSectionSep(ctx, dl, "AMP RANGE")
    P.drawAmpRangePanel(ctx)

    W.drawSectionSep(ctx, dl, "CYCLES")
    P.drawCyclesPanel(ctx)

    if P.isAdvanced then
        local a, vis = P.sectionAlpha("lfo_advanced", P.isAdvanced())
        if vis then
            P.setDrawAlpha(a)
            if a < 1.0 then
                reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), a)
            end
            W.drawSectionSep(ctx, dl, "QUANTIZE", a)
            P.drawQuantizePanel(ctx)
            W.drawSectionSep(ctx, dl, "PRECISION", a)
            P.drawPrecisionPanel(ctx)
            if a < 1.0 then reaper.ImGui_PopStyleVar(ctx) end
            P.setDrawAlpha(1.0)
        end
    end

    -- ── OUTPUT ─────────────────────────────────────────────
    W.drawSectionSep(ctx, dl, "OUTPUT")
    mods.OutputPanel.draw(ctx, "ReaNvelopes: OSC",
        function()
            local pts, out = P.getSendPts(), {}
            for i, p in ipairs(pts or {}) do out[i] = { tn = p.x, v = p.y } end
            return out
        end,
        mods.OSCWrite.generateAutomationItem)

    reaper.ImGui_Dummy(ctx, 1, 2)
    if P.drawStatusBar then P.drawStatusBar(ctx, dl) end
end

return OSC_Tool
