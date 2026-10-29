-- ============================================================
--   ReaNvelopes_RAND.lua
--   The RAND generator (random envelope shapes), from ReaComposeM's RAND,
--   itself derived from sailok's ReaCurve RAND. Its OUTPUT section takes the
--   dense preview curve (preview_pts) to an envelope, a MIDI CC lane or note
--   velocity.
-- ============================================================

local RAND_Tool = {}

local _script_path = ({reaper.get_action_context()})[2]
                       :match('^.+[/\\\\]')
                       :gsub('\\\\', '/')

package.path = _script_path .. "lib/?.lua;"
            .. _script_path .. "lib/RAND/?.lua;"
            .. _script_path .. "lib/UI/?.lua;"
            .. _script_path .. "lib/CommonFunction/?.lua;"
            .. _script_path .. "lib/CommonFunction/UI/?.lua;"
            .. package.path

local RANDConfig  = require("RANDConfig")
local RANDState   = require("RANDState")
local RANDWrite   = require("RANDWrite")
local Generator   = require("Generator")
local Logger      = require("Logger")
local Theme       = require("Theme")
local ReaperUtils = require("ReaperUtils")
local RANDPanel   = require("RANDPanel")
local Widgets     = require("Widgets")
local OutputPanel = require("OutputPanel")

math.randomseed(os.time())

-- ── MAIN DRAW ─────────────────────────────────────────────────
function RAND_Tool.drawUI(ctx)
    local dl       = reaper.ImGui_GetWindowDrawList(ctx)
    local S        = RANDState
    local cfg      = RANDConfig
    local ctx_info = ReaperUtils.getContextInfo()

    local range      = cfg.AMP_RANGES[S.amp_range] or cfg.AMP_RANGES[1]
    local amp_scale  = S.amp_scale  or 1.0
    local amp_offset = S.amp_offset or 0.0
    local center     = (range.lo + range.hi) * 0.5
    local half       = (range.hi - range.lo) * 0.5 * amp_scale
    local shift      = amp_offset * 0.5
    local eff_lo     = math.max(0, math.min(1, center - half + shift))
    local eff_hi     = math.max(0, math.min(1, center + half + shift))

    local params = {
        seed        = S.seed,
        shape_seed  = S.shape_seed,
        n_points    = S.num_points,
        pts_per_div = S.pts_per_div,
        shape       = S.shape,
        tension     = S.tension,
        amp_lo      = eff_lo,
        amp_hi      = eff_hi,
        amp_free    = S.amp_free,
        quant_steps = S.quant_steps,
    }
    RANDWrite.refreshPreview(S, params)
    if S.shape == 5 then
        RANDWrite.rebuildPreviewCurve(S, params)
    end

    Widgets.drawSectionSep(ctx, dl, "PRESETS")
    RANDPanel.drawPresetBar(ctx)

    Widgets.drawSectionSep(ctx, dl, "MODE")
    RANDPanel.drawModePanel(ctx)

    Widgets.drawSectionSep(ctx, dl, "PREVIEW")
    do
        local aw     = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
        local gh     = math.max(cfg.GRAPH_HEIGHT, 160)
        local gx, gy = reaper.ImGui_GetCursorScreenPos(ctx)
        reaper.ImGui_InvisibleButton(ctx, "##preview_rand", aw, gh)
        RANDPanel.drawPreviewGraph(ctx, dl, gx, gy, aw, gh,
            eff_lo, eff_hi, S.amp_free, S.quant_steps)
    end

    reaper.ImGui_Dummy(ctx, 1, 2)
    Widgets.drawSectionSep(ctx, dl, "GENERATION")
    RANDPanel.drawGenerationPanel(ctx)
    reaper.ImGui_Dummy(ctx, 1, 4)
    RANDPanel.drawNewSeedPanel(ctx)

    Widgets.drawSectionSep(ctx, dl, "SHAPE")
    RANDPanel.drawShapePanel(ctx)

    Widgets.drawSectionSep(ctx, dl, "AMPLITUDE RANGE")
    RANDPanel.drawAmplitudeRangePanel(ctx)

    Widgets.drawSectionSep(ctx, dl, "QUANTIZED AMPLITUDE")
    RANDPanel.drawAmplitudeTypePanel(ctx)

    -- ── OUTPUT ─────────────────────────────────────────────
    Widgets.drawSectionSep(ctx, dl, "OUTPUT")
    OutputPanel.draw(ctx, "ReaNvelopes: RAND",
        function() return RANDState.preview_pts end,
        function()
            -- One undo step for the write (RANDWrite itself opens none).
            reaper.Undo_BeginBlock()
            RANDWrite.generateAutomationItem()
            reaper.Undo_EndBlock("ReaNvelopes: RAND to envelope", -1)
        end,
        function()   -- SEND CURVE: the control points with their shapes, not the 256 samples
            return require("Generator").controlForSend(RANDState.gen_pts or {}, 16)
        end)

    reaper.ImGui_Dummy(ctx, 1, 2)
end

return RAND_Tool
