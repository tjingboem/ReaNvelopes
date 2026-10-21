-- ============================================================
--   DRAWPanel.lua
--   Canvas-based shape editor for ReaCompose DRAW module.
-- ============================================================
local M = {}

local Theme      = require("Theme")
local Widgets    = require("Widgets")
local Logger     = require("Logger")
local S          = require("DRAWState")
local DRAWPresets = require("DRAWPresets")

local T = Theme

-- Initialise preset directory on module load
DRAWPresets.init()

-- ── Preset state ──────────────────────────────────────────────
local _preset_list       = {}
local _preset_sel        = ""
local _preset_name_buf   = ""
local _preset_list_dirty = true
local _preset_modified   = false
local _preset_snapshot   = ""
local _snapshot_ready    = false
local _unsaved_action    = nil
local _preset_overwrite_name = nil

-- ── Canvas constants ──────────────────────────────────────────
local CANVAS_H    = 200
local PAD_L       = 42   -- left padding includes label gutter
local PAD_R       = 8
local PAD_T       = 8
local PAD_B       = 8
local POINT_R     = 6    -- hit radius for point interaction
local ANCHOR_R    = 5    -- visual radius for anchor points
local POINT_VIS_R = 5    -- visual radius for regular points

-- ── Interaction state ─────────────────────────────────────────
local _drag_idx   = nil  -- index of point being dragged
local _hover_idx  = nil  -- index of point being hovered

-- ── Helpers ──────────────────────────────────────────────────
local function stateFingerprint()
    local parts = {}
    for _, p in ipairs(S.points) do
        parts[#parts+1] = string.format("%.3f:%.3f", p.tn, p.v)
    end
    return S.shape_mode .. "|" .. table.concat(parts, "|")
end

local function canvasToNorm(cx, cy, bx, by, bw, bh)
    local tn = math.max(0, math.min(1, (cx - bx - PAD_L) / (bw - PAD_L - PAD_R)))
    local v  = math.max(0, math.min(1, 1 - (cy - by - PAD_T) / (bh - PAD_T - PAD_B)))
    return tn, v
end

local function normToCanvas(tn, v, bx, by, bw, bh)
    local cx = bx + PAD_L + tn * (bw - PAD_L - PAD_R)
    local cy = by + PAD_T + (1 - v) * (bh - PAD_T - PAD_B)
    return cx, cy
end

local function findNearestPoint(mx, my, bx, by, bw, bh)
    local best_idx, best_dist = nil, math.huge
    for i, p in ipairs(S.points) do
        local px, py = normToCanvas(p.tn, p.v, bx, by, bw, bh)
        local dist   = math.sqrt((mx - px)^2 + (my - py)^2)
        if dist < best_dist then
            best_dist = dist
            best_idx  = i
        end
    end
    if best_dist <= POINT_R * 2 then return best_idx end
    return nil
end

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
        _preset_list = DRAWPresets.list()
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

    local btn_w  = 52; local gap = 4
    local combo_w = math.max(60, avw - btn_w*2 - gap*2)
    local open_save_popup     = false
    local _open_unsaved_popup = false

    local VI_ON_BRD = Widgets.VI_BRD
    local VI_ON_HOV = Widgets.VI_HOV

    local function saveWithFileDialog()
        if not reaper.JS_Dialog_BrowseForSaveFile then return nil, "no_js_api" end
        local dir     = DRAWPresets.getDir() or ""
        local initial = (_preset_sel ~= "") and (_preset_sel:match("([^/]+)$") or _preset_sel) or ""
        local ok, path = reaper.JS_Dialog_BrowseForSaveFile("Save DRAW Preset", dir, initial, "Lua preset\0*.lua\0\0")
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
        local saved, err = DRAWPresets.save(rel, true)
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

    if reaper.ImGui_BeginCombo(ctx, "##dpcombo", preview) then
        local root_items   = {}
        local folder_map   = {}
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
                local ok, err = DRAWPresets.load(name)
                if ok then
                    _preset_sel = name; _preset_snapshot = stateFingerprint()
                else Logger.error("Load: " .. (err or "?")) end
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
                    if reaper.ImGui_Selectable(ctx, p..display_name.."##dps_"..name, is_cur) then doLoad(name) end
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
            if reaper.ImGui_Selectable(ctx, p..name.."##dps_"..name, is_cur) then doLoad(name) end
            if is_cur then reaper.ImGui_PopStyleColor(ctx); reaper.ImGui_SetItemDefaultFocus(ctx) end
        end

        if #_preset_list == 0 then reaper.ImGui_TextDisabled(ctx, "(no presets)") end
        reaper.ImGui_Separator(ctx)
        if reaper.ImGui_Selectable(ctx, "+ Save as...##dpsas", false) then
            local _, reason = saveWithFileDialog()
            if reason == "no_js_api" then _preset_name_buf = ""; open_save_popup = true end
        end
        reaper.ImGui_EndCombo(ctx)
    end

    Widgets.popComboStyle(ctx)
    if _open_unsaved_popup then reaper.ImGui_OpenPopup(ctx, "##dunsaved_warn") end
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
        if reaper.ImGui_Button(ctx, "Init##dinitbtn", btn_w, 0) then
            if _preset_modified then
                _unsaved_action = {type="init"}
                reaper.ImGui_OpenPopup(ctx, "##dunsaved_warn")
            else
                DRAWPresets.initDefaults()
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
        if reaper.ImGui_Button(ctx, "Save##dpsavebtn", btn_w, 0) then
            local _, reason = saveWithFileDialog()
            if reason == "no_js_api" then _preset_name_buf = ""; open_save_popup = true end
        end
        reaper.ImGui_PopStyleColor(ctx, 1)
    end

    reaper.ImGui_PopStyleColor(ctx, 4)
    reaper.ImGui_PopStyleVar(ctx, 2)

    -- Unsaved popup
    if reaper.ImGui_BeginPopup(ctx, "##dunsaved_warn") then
        reaper.ImGui_Text(ctx, "Unsaved changes — discard?")
        reaper.ImGui_Separator(ctx)
        if reaper.ImGui_Button(ctx, "Discard##ddiscard", 80, 0) then
            if _unsaved_action then
                if _unsaved_action.type == "load" then
                    local ok, err = DRAWPresets.load(_unsaved_action.arg)
                    if ok then
                        _preset_sel = _unsaved_action.arg
                        _preset_snapshot = stateFingerprint()
                    else Logger.error("Load: " .. (err or "?")) end
                elseif _unsaved_action.type == "init" then
                    DRAWPresets.initDefaults()
                    _preset_sel = ""; _preset_snapshot = stateFingerprint()
                end
                _unsaved_action = nil
            end
            reaper.ImGui_CloseCurrentPopup(ctx)
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Cancel##dcancel", 80, 0) then
            _unsaved_action = nil
            reaper.ImGui_CloseCurrentPopup(ctx)
        end
        reaper.ImGui_EndPopup(ctx)
    end

    -- Save modal fallback
    if open_save_popup then reaper.ImGui_OpenPopup(ctx, "##dpsave_modal") end
    if reaper.ImGui_BeginPopupModal(ctx, "##dpsave_modal", nil,
        reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
        reaper.ImGui_Text(ctx, "Preset name:")
        reaper.ImGui_SetNextItemWidth(ctx, 200)
        local changed, new_buf = reaper.ImGui_InputText(ctx, "##dpname", _preset_name_buf)
        if changed then _preset_name_buf = new_buf end
        reaper.ImGui_Separator(ctx)
        if reaper.ImGui_Button(ctx, "Save##dpmodalsave", 80, 0) then
            if _preset_name_buf ~= "" then
                if DRAWPresets.exists(_preset_name_buf) then
                    _preset_overwrite_name = _preset_name_buf
                else
                    local saved, err = DRAWPresets.save(_preset_name_buf, false)
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
        if reaper.ImGui_Button(ctx, "Cancel##dpmodalcancel", 80, 0) then
            reaper.ImGui_CloseCurrentPopup(ctx)
        end
        if _preset_overwrite_name then
            reaper.ImGui_Text(ctx, "'" .. _preset_overwrite_name .. "' exists. Overwrite?")
            if reaper.ImGui_Button(ctx, "Overwrite##dpow", 80, 0) then
                local s2, e2 = DRAWPresets.save(_preset_overwrite_name, true)
                if s2 then
                    _preset_sel = s2; _preset_list_dirty = true
                    _preset_snapshot = stateFingerprint()
                else Logger.error("Overwrite failed: " .. (e2 or "?")) end
                _preset_overwrite_name = nil
                reaper.ImGui_CloseCurrentPopup(ctx)
            end
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_Button(ctx, "Cancel##dpowcancel", 80, 0) then
                _preset_overwrite_name = nil
            end
        end
        reaper.ImGui_EndPopupModal(ctx)
    end
end

-- ── Shape mode panel ──────────────────────────────────────────
function M.drawShapeModePanel(ctx)
    local avw = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    local modes = { "linear", "smooth", "step" }
    local labels = { "Linear", "Smooth", "Step" }
    local gap = 4
    local btn_w = math.floor((avw - gap * (#modes - 1)) / #modes)

    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), gap, 0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 3)

    for i, mode in ipairs(modes) do
        local sel = (S.shape_mode == mode)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
            sel and T.hx(Widgets.VI_BRD, 0.55) or T.hx(T.C_BG_PANEL2))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),
            T.hx(Widgets.VI_BRD, 0.35))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
            sel and T.hx(T.C_TXT_PRI) or T.hx(T.C_CFG_BASE, 0.85))   -- the label colours of OSC's Curve buttons

        if reaper.ImGui_Button(ctx, labels[i].."##dmode_"..mode, btn_w, 22) then
            S.shape_mode = mode
            S.dirty      = true
        end

        reaper.ImGui_PopStyleColor(ctx, 3)
        if i < #modes then reaper.ImGui_SameLine(ctx) end
    end

    reaper.ImGui_PopStyleVar(ctx, 2)
end

-- ── Resolution slider ─────────────────────────────────────────
function M.drawResolutionPanel(ctx)
    local Slider = require("Slider")
    local avw    = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    local new_r  = Slider.drawInt(ctx, "draw_resolution", "Resolution",
        S.resolution, 2, 64, avw, nil, 8, { sld_h=26, gap=8, alpha=1.0 })
    if new_r ~= S.resolution then S.resolution = new_r end
end

-- ── Canvas ────────────────────────────────────────────────────
function M.drawCanvas(ctx)
    local dl  = reaper.ImGui_GetWindowDrawList(ctx)
    local avw = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    local fh  = reaper.ImGui_GetTextLineHeight(ctx)

    local bx, by = reaper.ImGui_GetCursorScreenPos(ctx)
    local bw, bh = avw, CANVAS_H

    reaper.ImGui_InvisibleButton(ctx, "##draw_canvas", bw, bh)
    local hov     = reaper.ImGui_IsItemHovered(ctx)
    local mx, my  = reaper.ImGui_GetMousePos(ctx)
    local in_canvas = mx >= bx and mx < bx+bw and my >= by and my < by+bh

    -- Rebuild preview if dirty
    if S.dirty then S.buildPreview() end

    -- ── Background ────────────────────────────────────────────
    reaper.ImGui_DrawList_AddRectFilled(dl,
        bx, by, bx+bw, by+bh, 0x111111FF, 4)
    reaper.ImGui_DrawList_AddRect(dl,
        bx, by, bx+bw, by+bh, T.hx(T.C_BORDER, 0.5), 4, 0, 0.8)

    -- ── Reference grid ────────────────────────────────────────
    local ref_levels = { 1.0, 0.75, 0.5, 0.25, 0.0 }
    local ref_labels = { "+100%", "+50%", "0%", "-50%", "-100%" }
    local label_gutter = 38  -- left margin for labels
    for i, v in ipairs(ref_levels) do
        local ly      = by + PAD_T + (1 - v) * (bh - PAD_T - PAD_B)
        local is_zero = (v == 0.5)
        -- Horizontal grid line
        reaper.ImGui_DrawList_AddLine(dl,
            bx + label_gutter, ly, bx + bw - PAD_R, ly,
            is_zero and 0xFFFFFF24 or 0xFFFFFF14, 0.8)
        -- Tick mark
        reaper.ImGui_DrawList_AddLine(dl,
            bx + label_gutter - 5, ly, bx + label_gutter, ly,
            is_zero and 0x9AA4B299 or 0x9AA4B261, 1.2)
        -- Label right-aligned in gutter
        local lbl = ref_labels[i]
        local lw  = reaper.ImGui_CalcTextSize(ctx, lbl)
        local lx  = bx + label_gutter - lw - 8
        local ly2 = math.max(by + 2, math.min(by + bh - fh - 2, ly - fh * 0.5))
        reaper.ImGui_DrawList_AddText(dl,
            lx, ly2,
            is_zero and 0x9AA4B2F2 or 0x9AA4B27A, lbl)
    end

    -- ── Shape curve ───────────────────────────────────────────
    local prev_x, prev_y
    for _, p in ipairs(S.preview_pts) do
        local px, py = normToCanvas(p.tn, p.v, bx, by, bw, bh)
        if prev_x then
            reaper.ImGui_DrawList_AddLine(dl,
                prev_x, prev_y, px, py,
                T.hx(Widgets.VI_BRD, 0.85), 2.0)
        end
        prev_x, prev_y = px, py
    end

    -- ── Interaction ───────────────────────────────────────────
    _hover_idx = in_canvas and findNearestPoint(mx, my, bx, by, bw, bh) or nil
    local shift = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())

    -- Start interaction
    if hov and reaper.ImGui_IsMouseClicked(ctx, 0) then
        if _hover_idx then
            -- Drag existing point
            _drag_idx = _hover_idx
            S.freehand_pts = nil
        else
            -- Start freehand stroke
            local tn, v = canvasToNorm(mx, my, bx, by, bw, bh)
            S.freehand_pts = { { tn=tn, v=v } }
            _drag_idx = nil
        end
    end

    -- Continue drag / freehand
    if reaper.ImGui_IsMouseDown(ctx, 0) then
        if _drag_idx then
            -- Move existing point
            local tn, v = canvasToNorm(mx, my, bx, by, bw, bh)
            if shift then
                -- Snap Y to nearest 25%
                v = math.floor(v * 4 + 0.5) / 4
            end
            local p = S.points[_drag_idx]
            if p then
                if _drag_idx == 1 or _drag_idx == #S.points then
                    p.v = v
                else
                    p.tn = math.max(0.001, math.min(0.999, tn))
                    p.v  = v
                end
                S.sortPoints()
                S.dirty = true
                _preset_modified = true
            end
        elseif S.freehand_pts then
            -- Accumulate freehand stroke (skip if too close to last point)
            local tn, v = canvasToNorm(mx, my, bx, by, bw, bh)
            local last = S.freehand_pts[#S.freehand_pts]
            local dist = math.sqrt((tn - last.tn)^2 + (v - last.v)^2)
            if dist > 0.005 then
                S.freehand_pts[#S.freehand_pts+1] = { tn=tn, v=v }
            end
        end
    else
        -- Mouse released
        if S.freehand_pts and #S.freehand_pts >= 2 then
            S.commitFreehand(S.freehand_pts)
            _preset_modified = true
        end
        S.freehand_pts = nil
        _drag_idx = nil
    end

    -- Right-click: delete point
    if hov and reaper.ImGui_IsMouseClicked(ctx, 1) and _hover_idx then
        S.deletePoint(_hover_idx)
        _hover_idx = nil
        _preset_modified = true
    end

    -- ── Draw freehand stroke preview ─────────────────────────
    if S.freehand_pts and #S.freehand_pts >= 2 then
        local prev_x2, prev_y2
        for _, p in ipairs(S.freehand_pts) do
            local px2, py2 = normToCanvas(p.tn, p.v, bx, by, bw, bh)
            if prev_x2 then
                reaper.ImGui_DrawList_AddLine(dl,
                    prev_x2, prev_y2, px2, py2,
                    T.hx(Widgets.VI_BRD, 0.45), 1.5)
            end
            prev_x2, prev_y2 = px2, py2
        end
    end

    -- ── Draw control points ───────────────────────────────────
    for i, p in ipairs(S.points) do
        local px, py = normToCanvas(p.tn, p.v, bx, by, bw, bh)
        local is_anchor = (i == 1 or i == #S.points)
        local is_hov    = (i == _hover_idx)
        local is_drag   = (i == _drag_idx)
        local r = is_anchor and ANCHOR_R or POINT_VIS_R

        -- Fill
        local fill_col = is_drag  and T.hx(Widgets.VI_BRD, 1.0)
                      or is_hov   and T.hx(Widgets.VI_BRD, 0.75)
                      or is_anchor and 0x888888CC
                      or             T.hx(Widgets.VI_BRD, 0.55)
        reaper.ImGui_DrawList_AddCircleFilled(dl, px, py, r, fill_col)

        -- Border
        reaper.ImGui_DrawList_AddCircle(dl, px, py, r, 0xFFFFFFCC, 12, 1.0)

        -- Value label on hover/drag
        if is_hov or is_drag then
            local lbl = string.format("%.0f%%  t=%.2f",
                (p.v * 2 - 1) * 100, p.tn)
            local lw  = reaper.ImGui_CalcTextSize(ctx, lbl)
            local lx  = math.min(px + 8, bx + bw - lw - 4)
            local ly2 = math.max(by + 2, py - fh - 4)
            reaper.ImGui_DrawList_AddRectFilled(dl,
                lx - 2, ly2 - 1, lx + lw + 2, ly2 + fh + 1,
                0x000000CC, 3)
            reaper.ImGui_DrawList_AddText(dl,
                lx, ly2, 0xFFFFFFFF, lbl)
        end
    end
end

return M
