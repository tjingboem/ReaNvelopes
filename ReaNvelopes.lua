-- ============================================================
--   ReaNvelopes.lua
--   Envelope generators for REAPER: make a curve (RAND: random
--   shapes, OSC: polygon LFO, DRAW: draw it by hand) and send it where it is needed:
--   a parameter envelope (automation item), a MIDI CC / pitch
--   bend / pressure lane, or the velocity of the notes of a MIDI
--   item. Everything is edited afterwards in REAPER itself.
--
--   From ReaComposeM's generating part (its editor is gone), which
--   carries code derived from sailok's ReaCurve, with his permission.
-- ============================================================

local script_name = "ReaNvelopes"

do
  local missing = {}
  if not reaper.ImGui_CreateContext then missing[#missing+1] = "ReaImGui" end
  if not reaper.SNM_GetIntConfigVar then missing[#missing+1] = "SWS Extension" end
  if not reaper.JS_ReaScriptAPI_Version then missing[#missing+1] = "js_ReaScriptAPI" end
  if #missing > 0 then
    reaper.MB("Missing: " .. table.concat(missing, ", "), "ReaNvelopes", 0)
    return
  end
end

-- Hub flag for the tools (they draw a little less chrome inside the hub)
SLK_HUB_IN_USE = true

local _script_path = ({reaper.get_action_context()})[2]:match('^.+[/\\\\]'):gsub('\\','/')

package.path =
    _script_path .. "?.lua;" ..
    _script_path .. "lib/?.lua;" ..
    _script_path .. "lib/OSC/?.lua;" ..
    _script_path .. "lib/RAND/?.lua;" ..
    _script_path .. "lib/DRAW/?.lua;" ..
    _script_path .. "lib/CommonFunction/?.lua;" ..
    _script_path .. "lib/CommonFunction/UI/?.lua;" ..
    package.path

local Theme     = require("Theme")
local Logger    = require("Logger")
local ReaSnap   = require("ReaSnap_Integration")   -- window title and Close All (ReaSnap Integration Contract pieces 2, 5)
local Serial       = require("ReaNvelopes_Serial")
local WindowRegistry = require("WindowRegistry")
local ItemFollow   = require("ItemFollow")

-- One window is enough, except when pinned (tjingboem, 19 November 2026). A window that is started while another, UNPINNED window is
-- open does not open: it hands what it was started with over to that window and ends. A pinned window is left alone. See WindowRegistry.
local reg = WindowRegistry.new()
do
  local other = reg.other_unpinned_alive()
  if other then
    WindowRegistry.hand_over(other, ReaSnap.pending_state and Serial.encode(ReaSnap.pending_state) or "")
    return
  end
end
reg.register()
reaper.atexit(reg.unregister)
local RAND_Tool = require("ReaNvelopes_RAND")
local OSC_Tool  = nil
local DRAW_Tool = nil

-- ReaSnap Integration Contract piece 4: a launch by ReaSnap with settings (S button, Restore): the generator's settings
-- and the OUTPUT settings are applied before the first frame, and the tab of that generator is the one shown first.
-- The same function loads the settings of an item the window follows (see ItemFollow), and what another window hands over.
local select_tab = nil
local function apply_state(st)
  if type(st) ~= "table" then return end
  local preset_module = ({ RAND = "RANDPresets", OSC = "OSCPresets", DRAW = "DRAWPresets" })[st.tool]
  if preset_module then
    local ok, P = pcall(require, preset_module)
    if ok and P and P.applyData and type(st.gen) == "table" then P.applyData(st.gen) end
    local ok_o, OutputPanel = pcall(require, "OutputPanel")
    if ok_o and OutputPanel.applyState then OutputPanel.applyState(st.out) end
    select_tab = st.tool
  end
end
apply_state(ReaSnap.pending_state)

local function tab_flags(tool)   -- the selected tab for the first frame only
  if select_tab == tool then
    select_tab = nil
    return reaper.ImGui_TabItemFlags_SetSelected()
  end
  return 0
end

local pinned = false        -- the title-bar label toggles it
local shown_key = nil       -- what the window last followed (ItemFollow)
local EXT_KEY = "ReaNvelopes_MAIN"
local popupText = nil   -- the message in the open popup window
local ctx = reaper.ImGui_CreateContext(script_name)

local function loop()
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, 510, 500, 900, 1400)   -- 50 % wider than the first version (340, 600)
  reaper.ImGui_SetNextWindowSize(ctx, 570, 900, reaper.ImGui_Cond_FirstUseEver())
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), Theme.hx(Theme.C_BG_MAIN))

  -- what another window handed over (a window that was started while this one was open): load it and come to the front
  do
    local payload = reg.take_handover()
    if payload then
      if payload ~= "" then
        local ok_d, st = pcall(Serial.decode, payload)
        if ok_d then apply_state(st) end
      end
      reaper.ImGui_SetNextWindowFocus(ctx)
    end
  end

  local visible, open = reaper.ImGui_Begin(ctx, ReaSnap.windowTitle(script_name), true)

  -- ReaSnap's Close All: checked outside the visible gate, so it also works while the window is collapsed.
  if ReaSnap.shouldClose() then open = false end

  if visible then
    ----------------------------------------------------------------------
    -- "tjingboem productions" in the title bar, right: also the PIN (19 Nov 2026, as in ReaMaskM, ReaShapeM, ReaGestM). A click pins
    -- the window (it stops following the selection and stays open next to a new window); another click lets go. Blue when pinned.
    ----------------------------------------------------------------------
    do
      local label     = "tjingboem productions"
      local label_col = reaper.ImGui_ColorConvertDouble4ToU32(0.55, 0.55, 0.55, 1.0)
      if pinned then label_col = reaper.ImGui_ColorConvertDouble4ToU32(0.30, 0.60, 0.95, 1.0) end
      local dl        = reaper.ImGui_GetForegroundDrawList(ctx)
      local wx, wy    = reaper.ImGui_GetWindowPos(ctx)
      local ww        = reaper.ImGui_GetWindowWidth(ctx)
      local lw, lh    = reaper.ImGui_CalcTextSize(ctx, label)
      local title_h   = reaper.ImGui_GetFrameHeight(ctx)
      local tx        = wx + ww - lw - 30
      local ty        = wy + (title_h - lh) * 0.5
      if reaper.ImGui_IsMouseClicked(ctx, 0) and reaper.ImGui_IsWindowHovered(ctx) then
        local mx, my = reaper.ImGui_GetMousePos(ctx)
        if mx >= tx and mx <= tx + lw and my >= ty and my <= ty + lh then pinned = not pinned end
      end
      reaper.ImGui_DrawList_AddText(dl, tx, ty, label_col, label)
    end

    -- Follow the selection (19 Nov 2026, as ReaMaskM and ReaGestM): a window that ReaSnap launched (it has a project identity) loads the
    -- settings of the selected item, or of the selected automation item, when the selection changes. Pinned, it does not. A window opened
    -- from the Actions list never follows, so what is being edited is not replaced because some other item was selected.
    if ReaSnap.project_identity and not pinned then
      local key, encoded = ItemFollow.read_current()
      if key ~= shown_key then
        shown_key = key
        if encoded and encoded ~= "" then
          local ok_d, st = pcall(Serial.decode, encoded)
          if ok_d then apply_state(st) end
        end
      end
    end

    if reaper.ImGui_BeginTabBar(ctx, "ReaNvelopesTabs") then
      if reaper.ImGui_BeginTabItem(ctx, "RAND", nil, tab_flags("RAND")) then
        RAND_Tool.drawUI(ctx)
        reaper.ImGui_EndTabItem(ctx)
      end
      if reaper.ImGui_BeginTabItem(ctx, "OSC", nil, tab_flags("OSC")) then
        if not OSC_Tool then
          local ok, res = pcall(require, "ReaNvelopes_OSC")
          if ok then OSC_Tool = res
          else
            reaper.ImGui_TextColored(ctx, 0xFF0000FF, "Error loading OSC:")
            reaper.ImGui_TextWrapped(ctx, tostring(res))
          end
        end
        if OSC_Tool and OSC_Tool.drawUI then OSC_Tool.drawUI(ctx) end
        reaper.ImGui_EndTabItem(ctx)
      end
      if reaper.ImGui_BeginTabItem(ctx, "DRAW", nil, tab_flags("DRAW")) then
        if not DRAW_Tool then
          local ok, res = pcall(require, "ReaNvelopes_DRAW")
          if ok then DRAW_Tool = res
          else
            reaper.ImGui_TextColored(ctx, 0xFF0000FF, "Error loading DRAW:")
            reaper.ImGui_TextWrapped(ctx, tostring(res))
          end
        end
        if DRAW_Tool and DRAW_Tool.drawUI then DRAW_Tool.drawUI(ctx) end
        reaper.ImGui_EndTabItem(ctx)
      end
      reaper.ImGui_EndTabBar(ctx)
    end

    -- A message the user has to close with OK (set by Logger.popup, e.g. when a write failed).
    local pending = Logger.peekPopup()
    if pending then
      popupText = pending
      Logger.clearPopup()
      reaper.ImGui_OpenPopup(ctx, "ReaNvelopes##msg")
    end
    if popupText then
      local wx, wy = reaper.ImGui_GetWindowPos(ctx)
      local ww, wh = reaper.ImGui_GetWindowSize(ctx)
      reaper.ImGui_SetNextWindowPos(ctx, wx + ww * 0.5, wy + wh * 0.35, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
      if reaper.ImGui_BeginPopupModal(ctx, "ReaNvelopes##msg", nil, reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
        for line in (popupText .. "\n"):gmatch("(.-)\n") do reaper.ImGui_Text(ctx, line) end
        reaper.ImGui_Spacing(ctx)
        if reaper.ImGui_Button(ctx, "OK", 120, 0) then
          reaper.ImGui_CloseCurrentPopup(ctx)
          popupText = nil
        end
        reaper.ImGui_EndPopup(ctx)
      else
        popupText = nil   -- the popup is gone (closed some other way)
      end
    end
    -- ReaImGui's top-level End() is skipped together with the content when the window is collapsed
    -- (the same rule ReaComposeM's hub found).
    reaper.ImGui_End(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx)

  if open then
    reg.heartbeat(pinned)
    reaper.defer(loop)
  else
    reg.unregister()
  end
  if not open and reaper.ImGui_DestroyContext then
    reaper.ImGui_DestroyContext(ctx)
  end
end

reaper.defer(loop)
