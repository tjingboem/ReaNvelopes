-- ============================================================
--   RANDPanel.lua
--   Composed UI panels for the Random Generator.
-- ============================================================

local M = {}

local Theme           = require("Theme")
local Widgets         = require("Widgets")
local Anim            = require("Anim")
local GeneratorState  = require("RANDState")
local GeneratorConfig = require("RANDConfig")
local GeneratorWrite  = require("RANDWrite")
local Logger          = require("Logger")
local Slider          = require("Slider")
local Toggle          = require("Toggle")
local RANDPresets     = require("RANDPresets")

local T = Theme
local S = GeneratorState
local cfg = GeneratorConfig

-- Initialise preset directory immediately on module load
RANDPresets.init()

-- ── Preset state ──────────────────────────────────────────────
local _preset_list        = {}
local _preset_sel         = ""
local _preset_name_buf    = ""
local _preset_list_dirty  = true
local _preset_modified    = false
local _preset_snapshot    = ""
local _snapshot_ready     = false
local _unsaved_action     = nil
local _preset_overwrite_name = nil

-- ── Fade Duration ────────────────────────────────────────────

local FADE_DURATION  = 0.35  -- Duration in seconds
local _mode_switch_t = 0     -- Timestamp of the last switch
local _last_mode     = nil   -- To detect mode changes

-- ── Violet palette ────────────────────────────────────────────
local VI_ON_BG  = Widgets.VI_BG
local VI_ON_HOV = Widgets.VI_HOV
local VI_ON_BRD = Widgets.VI_BRD

-- ── State fingerprint for modified detection ──────────────────
local function stateFingerprint()
    return string.format("%d|%d|%s|%d|%d|%.3f|%d|%s|%d|%.3f|%.3f",
        S.seed, S.shape_seed, S.gen_mode, S.num_points, S.shape,
        S.tension, S.amp_range, tostring(S.amp_free), S.quant_steps,
        S.amp_scale or 1.0, S.amp_offset or 0.0)
end

-- ── Randomize ─────────────────────────────────────────────────
local function rnd(lo, hi) return lo + (hi - lo) * math.random() end
local function rndInt(lo, hi) return math.floor(lo + math.random() * (hi - lo + 1)) end

local function randomizeAll()
    S.seed        = math.floor(math.random() * 2147483647)
    S.shape_seed  = math.floor(math.random() * 2147483647)
    S.shape       = rndInt(0, 6)
    S.tension     = (S.shape == 5) and rnd(-1, 1) or 0.0
    S.amp_range   = rndInt(1, #cfg.AMP_RANGES)
    S.amp_scale   = rnd(0.3, 1.0)
    S.amp_offset  = rnd(-0.3, 0.3)
    S.invalidatePreview()
end

-- ── Dice icon ─────────────────────────────────────────────────
local function drawDiceIcon(dl, bx, by, bw, bh, col)
    local m  = math.floor(math.min(bw, bh) * 0.68)
    local rx = math.floor(bx + (bw - m) * 0.5)
    local ry = math.floor(by + (bh - m) * 0.5)
    local r  = math.floor(m * 0.18)
    reaper.ImGui_DrawList_AddRectFilled(dl, rx, ry, rx+m, ry+m, col, r)
    reaper.ImGui_DrawList_AddRect(dl, rx, ry, rx+m, ry+m, 0xFFFFFFFF, r, 0, 1.0)
    local dot = math.max(1, math.floor(m * 0.10))
    local function dot2(fx, fy)
        local px = rx + math.floor(m * fx)
        local py = ry + math.floor(m * fy)
        reaper.ImGui_DrawList_AddCircleFilled(dl, px, py, dot, 0xFFFFFFFF)
    end
    dot2(0.25, 0.25); dot2(0.75, 0.25)
    dot2(0.50, 0.50)
    dot2(0.25, 0.75); dot2(0.75, 0.75)
end

-- ── Folder icon ───────────────────────────────────────────────
local function drawFolderIcon(dl, x, y, h, col)
    local w  = math.floor(h * 1.2)
    local th = math.floor(h * 0.35)
    local tw = math.floor(w * 0.45)
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y+th, x+w, y+h, col, 1.0)
    reaper.ImGui_DrawList_AddRectFilled(dl, x, y+th, x+tw, y+th+1, col, 1.0)
end

-- ── Preset bar ────────────────────────────────────────────────
function M.drawPresetBar(ctx)
    local dl  = reaper.ImGui_GetWindowDrawList(ctx)
    local avw = select(1, reaper.ImGui_GetContentRegionAvail(ctx))

    if _preset_list_dirty then
        _preset_list = RANDPresets.list()
        _preset_list_dirty = false
        local found = false
        for _, n in ipairs(_preset_list) do
            if n == _preset_sel then found = true; break end
        end
        if not found and _preset_sel ~= "" then _preset_sel = "" end
    end
    if not _snapshot_ready then
        _preset_snapshot = stateFingerprint()
        _snapshot_ready  = true
    end
    _preset_modified = (stateFingerprint() ~= _preset_snapshot)

    local btn_w  = 52; local gap = 4; local dice_w = 42
    local combo_w = math.max(60, avw - btn_w*2 - dice_w - gap*3)
    local open_save_popup     = false
    local _open_unsaved_popup = false

    local function saveWithFileDialog()
        if not reaper.JS_Dialog_BrowseForSaveFile then return nil, "no_js_api" end
        local dir     = RANDPresets.getDir() or ""
        local initial = (_preset_sel ~= "") and (_preset_sel:match("([^/]+)$") or _preset_sel) or ""
        local ok, path = reaper.JS_Dialog_BrowseForSaveFile("Save RAND Preset", dir, initial, "Lua preset\0*.lua\0\0")
        if ok ~= 1 or not path or path == "" then return nil, "cancelled" end
        local dir_n  = dir:gsub("\\", "/")
        local path_n = path:gsub("\\", "/")
        local rel
        if dir_n ~= "" and path_n:sub(1, #dir_n):lower() == dir_n:lower() then
            rel = path_n:sub(#dir_n + 1)
        else
            rel = path_n:match("([^/]+)$") or ""
        end
        rel = rel:gsub("%.lua$", ""):gsub("^/+", "")
        if rel == "" then return nil, "empty" end
        local saved, err = RANDPresets.save(rel, true)
        if saved then
            _preset_sel = saved; _preset_modified = false
            _preset_list_dirty = true; _preset_snapshot = stateFingerprint()
            Logger.ok("Saved '" .. saved .. "'")
            return saved
        end
        Logger.error("Save failed: " .. (err or "?"))
        return nil, err
    end

    Widgets.pushComboStyle(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, combo_w)
    local pfx_cur = _preset_modified and "* " or (_preset_sel ~= "" and "> " or "")
    local preview = pfx_cur .. (_preset_sel ~= "" and _preset_sel or "Default")

    if reaper.ImGui_BeginCombo(ctx, "##rpcombo", preview) then
        local root_items  = {}
        local folder_map  = {}
        local folder_order = {}
        for _, name in ipairs(_preset_list) do
            local folder = name:match("^(.+)/[^/]+$")
            if folder then
                if not folder_map[folder] then
                    folder_map[folder] = {}
                    folder_order[#folder_order+1] = folder
                end
                folder_map[folder][#folder_map[folder]+1] = name
            else
                root_items[#root_items+1] = name
            end
        end

        local sel_folder = _preset_sel ~= "" and _preset_sel:match("^(.+)/[^/]+$") or nil

        local function doLoad(name)
            if _preset_modified then
                _unsaved_action = {type="load", arg=name}
                _open_unsaved_popup = true
            else
                local ok, err = RANDPresets.load(name)
                if ok then
                    _preset_sel = name; _preset_snapshot = stateFingerprint()
                else
                    Logger.error("Load: " .. (err or "?"))
                end
            end
        end

        local dl2     = reaper.ImGui_GetWindowDrawList(ctx)
        local fh2     = reaper.ImGui_GetFrameHeight(ctx)
        local icon_h  = math.floor(fh2 * 0.52)
        local icon_col = T.hx(T.C_CFG_BASE, 0.55)

        for _, folder in ipairs(folder_order) do
            local has_sel = (sel_folder == folder)
            local pfx = has_sel and (_preset_modified and "* " or "> ") or "  "
            if reaper.ImGui_BeginMenu(ctx, "     " .. pfx .. folder) then
                for _, name in ipairs(folder_map[folder]) do
                    local display_name = name:match("[^/]+$") or name
                    local is_cur = (name == _preset_sel)
                    local p = is_cur and (_preset_modified and "* " or "> ") or "  "
                    if is_cur then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.hx("#FFFFFF")) end
                    if reaper.ImGui_Selectable(ctx, p..display_name.."##rps_"..name, is_cur) then doLoad(name) end
                    if is_cur then reaper.ImGui_PopStyleColor(ctx); reaper.ImGui_SetItemDefaultFocus(ctx) end
                end
                reaper.ImGui_EndMenu(ctx)
            end
            local bx2, by2 = reaper.ImGui_GetItemRectMin(ctx)
            local _, bh2   = reaper.ImGui_GetItemRectSize(ctx)
            drawFolderIcon(dl2, bx2 + 2, by2 + math.floor((bh2 - icon_h) * 0.5), icon_h, icon_col)
        end

        if #folder_order > 0 and #root_items > 0 then reaper.ImGui_Separator(ctx) end
        for _, name in ipairs(root_items) do
            local is_cur = (name == _preset_sel)
            local p = is_cur and (_preset_modified and "* " or "> ") or "  "
            if is_cur then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.hx("#FFFFFF")) end
            if reaper.ImGui_Selectable(ctx, p..name.."##rps_"..name, is_cur) then doLoad(name) end
            if is_cur then reaper.ImGui_PopStyleColor(ctx); reaper.ImGui_SetItemDefaultFocus(ctx) end
        end

        if #_preset_list == 0 then reaper.ImGui_TextDisabled(ctx, "(no presets)") end
        reaper.ImGui_Separator(ctx)
        if reaper.ImGui_Selectable(ctx, "+ Save as...##rpsas", false) then
            local _, reason = saveWithFileDialog()
            if reason == "no_js_api" then _preset_name_buf = ""; open_save_popup = true end
        end
        reaper.ImGui_EndCombo(ctx)
    end

    Widgets.popComboStyle(ctx)
    if _open_unsaved_popup then reaper.ImGui_OpenPopup(ctx, "##runsaved_warn") end
    reaper.ImGui_SameLine(ctx, 0, gap)

    reaper.ImGui_PushStyleVar(ctx,   reaper.ImGui_StyleVar_FrameRounding(),   4)
    reaper.ImGui_PushStyleVar(ctx,   reaper.ImGui_StyleVar_FrameBorderSize(), 1.0)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.hx(T.C_BG_PANEL2))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.hx(VI_ON_BRD, 0.85))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.hx(VI_ON_HOV, 0.72))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.hx(VI_ON_BRD, 0.35))

    -- Init button
    do
        local fh = reaper.ImGui_GetFrameHeight(ctx)
        local ibx, iby = reaper.ImGui_GetCursorScreenPos(ctx)
        local i_hov = reaper.ImGui_IsMouseHoveringRect(ctx, ibx, iby, ibx+btn_w, iby+fh)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
            i_hov and T.hx(T.C_TXT_PRI) or T.hx(T.C_CFG_BASE, 0.88))
        if reaper.ImGui_Button(ctx, "Init##rinitbtn", btn_w, 0) then
            if _preset_modified then
                _unsaved_action = {type="init"}
                reaper.ImGui_OpenPopup(ctx, "##runsaved_warn")
            else
                RANDPresets.initDefaults()
                _preset_sel = ""; _preset_snapshot = stateFingerprint()
                Logger.ok("Reset to defaults")
            end
        end
        reaper.ImGui_PopStyleColor(ctx, 1)
    end

    reaper.ImGui_SameLine(ctx, 0, gap)

    -- Save button
    do
        local fh = reaper.ImGui_GetFrameHeight(ctx)
        local sbx, sby = reaper.ImGui_GetCursorScreenPos(ctx)
        local s_hov = reaper.ImGui_IsMouseHoveringRect(ctx, sbx, sby, sbx+btn_w, sby+fh)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
            s_hov and T.hx(T.C_TXT_PRI) or T.hx(T.C_CFG_BASE, 0.88))
        if reaper.ImGui_Button(ctx, "Save##rpsavebtn", btn_w, 0) then
            local _, reason = saveWithFileDialog()
            if reason == "no_js_api" then _preset_name_buf = ""; open_save_popup = true end
        end
        reaper.ImGui_PopStyleColor(ctx, 1)
    end

    reaper.ImGui_SameLine(ctx, 0, gap)

    -- Dice button
    do
        local bx2, by2 = reaper.ImGui_GetCursorScreenPos(ctx)
        local clicked  = reaper.ImGui_Button(ctx, "##rrnd_btn", dice_w, 0)
        local bh2      = select(2, reaper.ImGui_GetItemRectSize(ctx))
        local is_hov   = reaper.ImGui_IsItemHovered(ctx)
        drawDiceIcon(dl, bx2, by2, dice_w, bh2, T.hx(VI_ON_BRD, is_hov and 0.85 or 0.42))
        if clicked then
            math.randomseed(math.floor(reaper.time_precise() * 1000))
            randomizeAll()
            Logger.ok("Randomized!")
        end
    end

    reaper.ImGui_PopStyleColor(ctx, 4)
    reaper.ImGui_PopStyleVar(ctx, 2)

    -- Unsaved changes popup
    if reaper.ImGui_BeginPopup(ctx, "##runsaved_warn") then
        reaper.ImGui_Text(ctx, "Unsaved changes — discard?")
        reaper.ImGui_Separator(ctx)
        if reaper.ImGui_Button(ctx, "Discard##rdiscard", 80, 0) then
            if _unsaved_action then
                if _unsaved_action.type == "load" then
                    local ok, err = RANDPresets.load(_unsaved_action.arg)
                    if ok then
                        _preset_sel = _unsaved_action.arg
                        _preset_snapshot = stateFingerprint()
                    else Logger.error("Load: " .. (err or "?")) end
                elseif _unsaved_action.type == "init" then
                    RANDPresets.initDefaults()
                    _preset_sel = ""; _preset_snapshot = stateFingerprint()
                end
                _unsaved_action = nil
            end
            reaper.ImGui_CloseCurrentPopup(ctx)
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Cancel##rcancel", 80, 0) then
            _unsaved_action = nil
            reaper.ImGui_CloseCurrentPopup(ctx)
        end
        reaper.ImGui_EndPopup(ctx)
    end

    -- Save modal (fallback when no js_ReaScriptAPI)
    if open_save_popup then reaper.ImGui_OpenPopup(ctx, "##rpsave_modal") end
    if reaper.ImGui_BeginPopupModal(ctx, "##rpsave_modal", nil,
        reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
        reaper.ImGui_Text(ctx, "Preset name:")
        reaper.ImGui_SetNextItemWidth(ctx, 200)
        local changed, new_buf = reaper.ImGui_InputText(ctx, "##rpname", _preset_name_buf)
        if changed then _preset_name_buf = new_buf end
        reaper.ImGui_Separator(ctx)
        if reaper.ImGui_Button(ctx, "Save##rpmodalsave", 80, 0) then
            if _preset_name_buf ~= "" then
                if RANDPresets.exists(_preset_name_buf) then
                    _preset_overwrite_name = _preset_name_buf
                else
                    local saved, err = RANDPresets.save(_preset_name_buf, false)
                    if saved then
                        _preset_sel = saved; _preset_modified = false
                        _preset_list_dirty = true; _preset_snapshot = stateFingerprint()
                        Logger.ok("Saved '" .. saved .. "'")
                    else Logger.error("Save failed: " .. (err or "?")) end
                    reaper.ImGui_CloseCurrentPopup(ctx)
                end
            end
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Cancel##rpmodalcancel", 80, 0) then
            reaper.ImGui_CloseCurrentPopup(ctx)
        end
        if _preset_overwrite_name then
            reaper.ImGui_Text(ctx, "'" .. _preset_overwrite_name .. "' exists. Overwrite?")
            if reaper.ImGui_Button(ctx, "Overwrite##rpow", 80, 0) then
                local s2, e2 = RANDPresets.save(_preset_overwrite_name, true)
                if s2 then
                    _preset_sel = s2; _preset_list_dirty = true
                    _preset_snapshot = stateFingerprint()
                else Logger.error("Overwrite failed: " .. (e2 or "?")) end
                _preset_overwrite_name = nil
                reaper.ImGui_CloseCurrentPopup(ctx)
            end
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_Button(ctx, "Cancel##rpowcancel", 80, 0) then
                _preset_overwrite_name = nil
            end
        end
        reaper.ImGui_EndPopupModal(ctx)
    end
end

-- ── Teal palette (RND shape button) ──────────────────────────
local RND_ON_BG  = "#0E6B8C"
local RND_ON_HOV = "#1A84AD"
local RND_ON_BRD = "#3FBCDD"

-- ── Toggle wrapper ───────────────────────────────────────────
local function drawToggle(ctx, id, w, h, label_a, label_b, is_a_active, scheme)
  return Toggle.draw(ctx, id, w, h, label_a, label_b, is_a_active)
end

-- ── Slider wrappers ──────────────────────────────────────────
local function drawIntSlider(ctx, id, label, value, v_min, v_max, w, disabled, default_val, ui_alpha)
  return Slider.drawInt(ctx, id, label, value, v_min, v_max, w, disabled, default_val,
    { sld_h=26, gap=8, alpha=ui_alpha or 1.0 })
end
local function drawFloatSlider(ctx, id, label, value, v_min, v_max, fmt, w, disabled, default_val, ui_alpha)
  return Slider.drawFloat(ctx, id, label, value, v_min, v_max, fmt, w, disabled, default_val,
    { sld_h=26, gap=8, alpha=ui_alpha or 1.0 })
end

-- ── Amplitude range bar icon ──────────────────────────────────
-- Draws a vertical "meter" bar showing where [lo,hi] sits in [0,1].
local function drawAmpRangeIcon(dl, bx, by, bw, bh, lo, hi, active)
  local bar_w = 10
  local bar_h = bh - 8
  local bar_x = math.floor(bx + (bw - bar_w) * 0.5)
  local bar_y = by + 4
  reaper.ImGui_DrawList_AddRectFilled(dl, bar_x, bar_y, bar_x+bar_w, bar_y+bar_h,
    T.hx(T.C_BG_MAIN, 0.88), 2)
  local y_top = bar_y + math.floor(bar_h * (1 - hi))
  local y_bot = bar_y + math.floor(bar_h * (1 - lo))
  local fill  = active and T.hx(VI_ON_BRD, 0.95) or T.hx(T.C_DISABLED, 0.55)
  if y_bot > y_top then
    reaper.ImGui_DrawList_AddRectFilled(dl, bar_x+1, y_top, bar_x+bar_w-1, y_bot, fill, 2)
  end
  reaper.ImGui_DrawList_AddRect(dl, bar_x, bar_y, bar_x+bar_w, bar_y+bar_h,
    active and T.hx(VI_ON_BRD, 0.55) or T.hx(T.C_BORDER, 0.45), 2, 0, 0.8)
end

-- ── MODE panel ───────────────────────────────────────────────

function M.drawModePanel(ctx)
  local S   = GeneratorState
  local avw = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  if drawToggle(ctx, "gen_mode", avw, 28, "Free", "Grid",
      S.gen_mode == "free", "violet") then
    S.gen_mode = (S.gen_mode == "free") and "grid" or "free"
    S.invalidatePreview()
  end
end

-- ── PREVIEW graph ─────────────────────────────────────────────
-- The Y axis ALWAYS covers the full bipolar range [-100%, +100%]
-- (normalized 0.0 to 1.0). The amplitude range and quantization
-- lines are drawn as overlays within that fixed coordinate space.
function M.drawPreviewGraph(ctx, dl, px, py, pw, ph, amp_lo, amp_hi, amp_free, quant_steps)
  local S = GeneratorState

  -- 1. Detect mode switch (fix: gen_mode instead of mode)
  local current_mode = S.gen_mode
  if current_mode ~= _last_mode then
    _mode_switch_t = reaper.time_precise()
    _last_mode = current_mode
  end

  -- 2. Compute progress (0.0 to 1.0) and alpha via easing
  local elapsed = reaper.time_precise() - _mode_switch_t
  local progress = math.min(elapsed / FADE_DURATION, 1.0)
  local alpha = Anim.easeInOut(progress)

  -- Internal utility to apply transition alpha to hex colors
  local function applyAlpha(hex, base_alpha)
    return T.hx(hex, (base_alpha or 1.0) * alpha)
  end

  -- 3. Layout parameters
  local gutter_w = 45
  local margin_r = gutter_w / 2
  local gx = px + gutter_w
  local gw = pw - gutter_w - margin_r

  -- Background (kept static to avoid a black flash)
  reaper.ImGui_DrawList_AddRectFilled(dl, gx, py, gx+gw, py+ph, T.hx(T.C_BG_PANEL))

  -- Apply alpha to text elements (via StyleVar)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), alpha)

  -- 4. Grille Verticale
  local n_v = 4
  if S.gen_mode == "grid" then
    local ts_s, ts_e = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
    if ts_e > ts_s + 0.001 then
      local ok, grid_div = reaper.GetSetProjectGrid(0, false)
      if not ok or not grid_div or grid_div <= 0 then grid_div = 0.25 end
      local qn_s  = reaper.TimeMap2_timeToQN(0, ts_s)
      local qn_e  = reaper.TimeMap2_timeToQN(0, ts_e)
      local dur_qn = qn_e - qn_s
      local grid_qn = grid_div * 4
      if grid_qn > 0 then
        n_v = math.max(1, math.min(64, math.floor(dur_qn / grid_qn + 0.5)))
      end
    end
  end

  local gc = applyAlpha("#FFFFFF", 0.06) 
  for i = 0, n_v do
    reaper.ImGui_DrawList_AddLine(dl, gx+gw*i/n_v, py, gx+gw*i/n_v, py+ph, gc)
  end

  local function toY(v)
    return py + ph - math.max(0, math.min(1, v)) * ph
  end

  -- 5. Y-axis: Ticks et Labels
  local fh = reaper.ImGui_GetTextLineHeight(ctx)
  local ref_levels = {
    { txt = "+100%", v = 1.00, major = true },
    { txt = "+50%",  v = 0.75, major = true },
    { txt = "0%",    v = 0.50, major = true },
    { txt = "-50%",  v = 0.25, major = true },
    { txt = "-100%", v = 0.00, major = true },
  }
  
  for _, lb in ipairs(ref_levels) do
    local ry = toY(lb.v)
    -- Ligne horizontale
    reaper.ImGui_DrawList_AddLine(dl, gx, ry, gx+gw, ry, applyAlpha("#FFFFFF", lb.major and 0.14 or 0.06), 0.8)
    -- Tick
    reaper.ImGui_DrawList_AddLine(dl, gx - 5, ry, gx, ry, applyAlpha("#9AA4B2", lb.major and 0.60 or 0.38), 1.2)
    -- Label
    local tw = reaper.ImGui_CalcTextSize(ctx, lb.txt)
    local lx = px + (gutter_w - tw) - 8 
    local ly = math.max(py, math.min(py + ph - fh, ry - fh * 0.5))
    reaper.ImGui_DrawList_AddText(dl, lx, ly, applyAlpha("#9AA4B2", lb.major and 0.72 or 0.48), lb.txt)
  end

  -- 6. Amplitude range band
  local band_y_top = toY(amp_hi)
  local band_y_bot = toY(amp_lo)
  reaper.ImGui_DrawList_AddRectFilled(dl, gx, band_y_top, gx+gw, band_y_bot, applyAlpha(T.C_MRF_SEL, 0.025))
  reaper.ImGui_DrawList_AddLine(dl, gx, band_y_top, gx+gw, band_y_top, applyAlpha(T.C_MRF_SEL, 0.18), 1.0)
  reaper.ImGui_DrawList_AddLine(dl, gx, band_y_bot, gx+gw, band_y_bot, applyAlpha(T.C_MRF_SEL, 0.18), 1.0)

  -- 7. Quantize level lines
  if not amp_free and quant_steps and quant_steps >= 2 then
    local q_col = applyAlpha("#E8844A", 0.30)
    for q = 0, quant_steps - 1 do
      local qv = amp_lo + (amp_hi - amp_lo) * (q / (quant_steps - 1))
      local qy = toY(qv)
      reaper.ImGui_DrawList_AddLine(dl, gx, qy, gx+gw, qy, q_col, 0.8)
    end
  end

  -- 8. Courbe (Preview points)
  if #S.preview_pts >= 2 then
    local color = applyAlpha(T.C_MRF_BASE, 0.90)
    local prev_x, prev_y
    for _, sp in ipairs(S.preview_pts) do
      local fx = gx + sp.tn * gw
      local fy = toY(sp.v)
      if prev_x then
        reaper.ImGui_DrawList_AddLine(dl, prev_x, prev_y, fx, fy, color, 2.0)
      end
      prev_x, prev_y = fx, fy
    end
  end

  -- 9. Control points
  if #S.gen_pts >= 2 then
    local dot_col = applyAlpha("#FFFFFF", 0.75)
    for _, p in ipairs(S.gen_pts) do
      if (p.shape or 0) ~= 1 then
        local fx = gx + p.tn * gw
        local fy = toY(p.v)
        if fy >= py - 1 and fy <= py + ph + 1 then
          reaper.ImGui_DrawList_AddCircleFilled(dl, fx, fy, 1.8, dot_col)
        end
      end
    end
  end

  -- Border
  reaper.ImGui_DrawList_AddRect(dl, gx, py, gx+gw, py+ph, applyAlpha("#FFFFFF", 0.12))

  reaper.ImGui_PopStyleVar(ctx) -- On retire l'alpha global
end

local function sliderPair(ctx, avw, gap, fn_a, fn_b)
  gap = gap or 8
  local half = math.floor((avw - gap) / 2)
  reaper.ImGui_BeginGroup(ctx)
    fn_a(half)
  reaper.ImGui_EndGroup(ctx)
  reaper.ImGui_SameLine(ctx, 0, gap)
  reaper.ImGui_BeginGroup(ctx)
    fn_b(half)
  reaper.ImGui_EndGroup(ctx)
end

-- ── GENERATION panel (Points slider only) ────────────────────

function M.drawGenerationPanel(ctx)
  local S    = GeneratorState
  local avw  = select(1, reaper.ImGui_GetContentRegionAvail(ctx))

  -- Ease in/out fade when mode switches — alpha passed to DrawList calls via ui_alpha
  local elapsed  = reaper.time_precise() - _mode_switch_t
  local progress = math.min(elapsed / FADE_DURATION, 1.0)
  local alpha    = Anim.easeInOut(progress)

  if S.gen_mode == "free" then
    local new_n = drawIntSlider(ctx, "num_points", "Points", S.num_points, 2, 64, avw, nil, 8, alpha)
    if new_n ~= S.num_points then S.num_points = new_n ; S.invalidatePreview() end
  else
    local new_p = drawIntSlider(ctx, "pts_per_div", "Pts / div", S.pts_per_div, 1, 16, avw, nil, 2, alpha)
    if new_p ~= S.pts_per_div then S.pts_per_div = new_p ; S.invalidatePreview() end
  end
end

-- ── NEW SEED panel ────────────────────────────────────────────

function M.drawNewSeedPanel(ctx)
  local S   = GeneratorState
  local dl  = reaper.ImGui_GetWindowDrawList(ctx)
  local avw = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local bh  = 30

  -- Same pattern as Widgets insert buttons: dark bg at rest, mid on hover, bright on active
  reaper.ImGui_PushStyleVar(ctx,   reaper.ImGui_StyleVar_FramePadding(),    10, 12)
  reaper.ImGui_PushStyleVar(ctx,   reaper.ImGui_StyleVar_FrameRounding(),    8)
  reaper.ImGui_PushStyleVar(ctx,   reaper.ImGui_StyleVar_FrameBorderSize(), 1.5)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.hx(T.C_MRF_BG))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.hx("#253608"))   -- slightly lighter dark
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.hx(T.C_MRF_SEL))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.hx(T.C_MRF_HOV))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.hx(T.C_MRF_SEL))

  -- Marges gauche/droite : le bouton ne prend pas toute la largeur
  local margin_h = 16
  local cur_x = reaper.ImGui_GetCursorPosX(ctx)
  reaper.ImGui_SetCursorPosX(ctx, cur_x + margin_h)
  local pressed = reaper.ImGui_Button(ctx, "##new_seed", avw - margin_h * 2, bh)

  do
    local bx, by = reaper.ImGui_GetItemRectMin(ctx)
    local bw, _  = reaper.ImGui_GetItemRectSize(ctx)
    local ic_col = T.hx(T.C_MRF_HOV, 0.92)
    local lbl    = "NEW SEED"
    local lbl_w, lbl_h = reaper.ImGui_CalcTextSize(ctx, lbl)
    -- Icon: two arcs forming a circle with an arrow (drawn as arc + triangle)
    local ic_r   = 8
    local gap    = 12
    local total_block_w = ic_r * 2 + gap + lbl_w
    local ic_cx  = bx + (bw - total_block_w) * 0.5 + ic_r
    local mid_y  = by + bh * 0.5
    -- Circle arc (270° = most of a circle)
    reaper.ImGui_DrawList_AddCircle(dl, math.floor(ic_cx), math.floor(mid_y), ic_r, ic_col, 24, 1.8)
    -- Arrow head on top-right of circle
    local ax, ay = ic_cx + ic_r * 0.7, mid_y - ic_r * 0.7
    reaper.ImGui_DrawList_AddTriangleFilled(dl,
      math.floor(ax),         math.floor(ay - 4),
      math.floor(ax + 5),     math.floor(ay + 1),
      math.floor(ax - 2),     math.floor(ay + 3),
      ic_col)
    -- Label
    local tx = bx + (bw - total_block_w) * 0.5 + ic_r * 2 + gap
    reaper.ImGui_DrawList_AddText(dl, math.floor(tx), math.floor(mid_y - lbl_h * 0.5), ic_col, lbl)
  end

  reaper.ImGui_PopStyleColor(ctx, 5)
  reaper.ImGui_PopStyleVar(ctx, 3)

  if pressed then
    S.newSeed()
    S.amp_scale  = 1.0
    S.amp_offset = 0.0
  end
end

-- ── SHAPE panel ──────────────────────────────────────────────

function M.drawShapePanel(ctx)
  local S   = GeneratorState
  local cfg = GeneratorConfig
  local dl  = reaper.ImGui_GetWindowDrawList(ctx)
  local avw = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local n   = #cfg.SHAPES
  local gap = 3
  local sw  = math.floor((avw - gap * (n - 1)) / n)

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),   5)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 1.0)

  for i, sh in ipairs(cfg.SHAPES) do
    local active = (S.shape == sh.id)
    -- RND (id=6) gets its own teal palette; all other shapes use the standard AI2 scheme.
    if sh.id == 6 then
      if active then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.hx("#1A2840"))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.hx("#2A3A5A"))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.hx("#3A4A6A"))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.hx(T.C_TXT_PRI))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.hx("#4A7AAD"))
      else
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.hx(T.C_BG_PANEL2))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.hx(T.C_AI2_BG))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.hx(T.C_AI2_SEL, 0.55))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.hx(T.C_DISABLED))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.hx(T.C_BORDER))
      end
    elseif active then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.hx(T.C_AI2_SEL))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.hx(T.C_AI2_SEL))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.hx(T.C_AI2_HOV))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.hx(T.C_TXT_PRI))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.hx(T.C_AI2_BASE))
    else
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.hx(T.C_BG_PANEL2))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.hx(T.C_AI2_BG))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.hx(T.C_AI2_BG))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.hx(T.C_DISABLED))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.hx(T.C_BORDER))
    end
    -- Toutes les shapes : label invisible + contenu via DrawList (comme ManipulatorPanels)
    local btn_label = "##sh"..i
    if reaper.ImGui_Button(ctx, btn_label, sw, 30) then
      if sh.id == 6 then
        -- RND: always re-roll the shape seed on every click (independent of main seed)
        S.shape = sh.id
        S.newShapeSeed()   -- invalidatePreview() is called inside newShapeSeed()
      elseif S.shape ~= sh.id then
        S.shape = sh.id
        if sh.id ~= 5 then S.tension = 0.0 end
        S.invalidatePreview()
      end
    end
    -- Draw icon/text overlay pour toutes les shapes (y compris RND via DrawList)
    do
      local bx, by   = reaper.ImGui_GetItemRectMin(ctx)
      local bw2, bh2 = reaper.ImGui_GetItemRectSize(ctx)
      local ic_col   = active and T.hx(T.C_TXT_PRI, 0.95) or T.hx(T.C_DISABLED, 0.75)
      if sh.id == 6 then
        local lbl    = "RND"
        local lw, lh = reaper.ImGui_CalcTextSize(ctx, lbl)
        reaper.ImGui_DrawList_AddText(dl,
          math.floor(bx + (bw2 - lw) * 0.5),
          math.floor(by  + (bh2 - lh) * 0.5), ic_col, lbl)
      else
        Widgets.drawShapeIcon(dl, ctx, bx, by, bw2, bh2, sh.id, ic_col)
      end
    end
    reaper.ImGui_PopStyleColor(ctx, 5)
    if i < n then reaper.ImGui_SameLine(ctx, 0, gap) end
  end

  reaper.ImGui_PopStyleVar(ctx, 2)

  -- Tension slider (Bezier only) — no Spacing, value resets to 0 on double-click
  local avw2  = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local is_bz = (S.shape == 5)
  local new_tn = drawFloatSlider(ctx, "tension",
    "Tension", S.tension, -1.0, 1.0, "%.2f", avw2, not is_bz, 0.0)
  if is_bz and new_tn ~= S.tension then
    S.tension = new_tn ; S.invalidatePreview()
  end
end

-- ── AMPLITUDE RANGE panel ────────────────────────────────────

function M.drawAmplitudeRangePanel(ctx)
  local S   = GeneratorState
  local cfg = GeneratorConfig
  local dl  = reaper.ImGui_GetWindowDrawList(ctx)
  local avw = select(1, reaper.ImGui_GetContentRegionAvail(ctx))

  local function pct(v)
    local p = math.floor(v * 200 - 100 + 0.5)
    if p > 0 then return "+"..p elseif p == 0 then return "0" else return tostring(p) end
  end
  local items = {}
  for i, r in ipairs(cfg.AMP_RANGES) do
    items[i] = { id = i, label = pct(r.lo).."/"..pct(r.hi) }
  end
  local new = Widgets.drawViButtonRow(ctx, dl, items, S.amp_range,
    { bh=26, gap=3, rounding=4, prefix="##ar" })
  if new ~= S.amp_range then S.amp_range = new ; S.invalidatePreview() end

  -- ── Amplitude scale + offset sliders (on the same line) ──────
  -- Initialize with default values if absent
  if S.amp_scale  == nil then S.amp_scale  = 1.0 end
  if S.amp_offset == nil then S.amp_offset = 0.0 end

  reaper.ImGui_Dummy(ctx, 1, 4)
  local avw2 = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  sliderPair(ctx, avw2, 4,
    function(w)
      local v = drawFloatSlider(ctx, "amp_scale",  "Amplitude", S.amp_scale,  0.0, 1.0, "%.2f", w, false, 1.0)
      if v ~= S.amp_scale  then S.amp_scale  = v ; S.invalidatePreview() end
    end,
    function(w)
      local v = drawFloatSlider(ctx, "amp_offset", "Offset",    S.amp_offset, -1.0, 1.0, "%.2f", w, false, 0.0)
      if v ~= S.amp_offset then S.amp_offset = v ; S.invalidatePreview() end
    end)
end

-- ── AMPLITUDE TYPE Y panel ────────────────────────────────────

function M.drawAmplitudeTypePanel(ctx)
  local S   = GeneratorState
  local avw = select(1, reaper.ImGui_GetContentRegionAvail(ctx))

  if drawToggle(ctx, "amp_type", avw, 26, "Free", "Quantized", S.amp_free, "violet") then
    S.amp_free = not S.amp_free ; S.invalidatePreview()
  end

  -- Steps slider: always visible; disabled when Free; double-click resets to 4
  local avw2   = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local new_qs = drawIntSlider(ctx, "quant_steps", "Steps",
    S.quant_steps, 2, 32, avw2, S.amp_free, 4)
  if not S.amp_free and new_qs ~= S.quant_steps then
    S.quant_steps = new_qs ; S.invalidatePreview()
  end
end

-- ── INSERT panel ─────────────────────────────────────────────

function M.drawInsertPanel(ctx, dl, ctx_info)
  Widgets.drawInsertPanel(ctx, dl, ctx_info,
    function()
      reaper.Undo_BeginBlock()
      GeneratorWrite.generateEnvelopePoints()
      reaper.Undo_EndBlock("Random Generator – envelope points", -1)
    end,
    function()
      reaper.Undo_BeginBlock()
      GeneratorWrite.generateAutomationItem()
      reaper.Undo_EndBlock("Random Generator – automation item", -1)
    end)
end

-- ── CONTEXT panel ─────────────────────────────────────────────

function M.drawContextPanel(ctx, dl, ctx_info)
  Widgets.drawSimpleContextPanel(ctx, dl, ctx_info)
end

-- ── STATUS BAR ───────────────────────────────────────────────

function M.drawStatusBar(ctx, dl)
  Widgets.drawStatusBar(ctx, dl)
end

return M