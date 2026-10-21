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
local RAND_Tool = require("ReaNvelopes_RAND")
local OSC_Tool  = nil
local DRAW_Tool = nil

local EXT_KEY = "ReaNvelopes_MAIN"
local popupText = nil   -- the message in the open popup window
local ctx = reaper.ImGui_CreateContext(script_name)

local function loop()
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, 510, 500, 900, 1400)   -- 50 % wider than the first version (340, 600)
  reaper.ImGui_SetNextWindowSize(ctx, 570, 900, reaper.ImGui_Cond_FirstUseEver())
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), Theme.hx(Theme.C_BG_MAIN))

  local visible, open = reaper.ImGui_Begin(ctx, ReaSnap.windowTitle(script_name), true)

  -- ReaSnap's Close All: checked outside the visible gate, so it also works while the window is collapsed.
  if ReaSnap.shouldClose() then open = false end

  if visible then
    if reaper.ImGui_BeginTabBar(ctx, "ReaNvelopesTabs") then
      if reaper.ImGui_BeginTabItem(ctx, "RAND") then
        RAND_Tool.drawUI(ctx)
        reaper.ImGui_EndTabItem(ctx)
      end
      if reaper.ImGui_BeginTabItem(ctx, "OSC") then
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
      if reaper.ImGui_BeginTabItem(ctx, "DRAW") then
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
    reaper.defer(loop)
  elseif reaper.ImGui_DestroyContext then
    reaper.ImGui_DestroyContext(ctx)
  end
end

reaper.defer(loop)
