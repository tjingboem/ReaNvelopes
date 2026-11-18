-- ============================================================
--   ReaSnap_Integration.lua
--   Pieces 2 and 5 of the ReaSnap Integration Contract, for ReaNvelopes:
--   the window title with an instance number (cosmetic) and Close All.
--   Since 19 November 2026 it speaks the item-settings pieces too: 1 (own serializer, lib/ReaNvelopes_Serial.lua),
--   3 (the settings are written ONTO the item that got the MIDI CC / note values, M.writeItemState; an item copy
--   carries them) and 4 (a launch by ReaSnap with settings: M.pending_state, applied by the hub at startup).
--   Written after ReaComposeM's version of the same module.
--
--   Used by ReaNvelopes.lua:
--     ReaSnap.windowTitle("ReaNvelopes")  the window title
--     ReaSnap.shouldClose()               true once ReaSnap's Close All
--                                         asked this instance to close
-- ============================================================

local TOOL_NAME = "ReaNvelopes"

local Serial = require("ReaNvelopes_Serial")

local M = {}

-- Piece 4: settings put there by ReaSnap's launcher (read once, then cleared). nil when launched any other way.
M.pending_state = nil
if reaper.HasExtState("ReaSculpt_Registry", "pending_" .. TOOL_NAME .. "_settings") then
  local raw = reaper.GetExtState("ReaSculpt_Registry", "pending_" .. TOOL_NAME .. "_settings")
  reaper.DeleteExtState("ReaSculpt_Registry", "pending_" .. TOOL_NAME .. "_settings", false)
  local ok, state = pcall(Serial.decode, raw)
  if ok and type(state) == "table" then M.pending_state = state end
end

-- Piece 3: the settings that made this item, onto the item itself (copies carry them). Never raises.
function M.writeItemState(item, state)
  if not item then return false end
  local ok, err = pcall(function() Serial.write_item_state(item, TOOL_NAME, Serial.encode(state)) end)
  return ok
end

-- Piece 2: instance number, put there by ReaSnap's launcher (read once, then cleared).
M.instance_number = nil
if reaper.HasExtState("ReaSculpt_Registry", "pending_" .. TOOL_NAME .. "_instance_number") then
  M.instance_number = reaper.GetExtState("ReaSculpt_Registry", "pending_" .. TOOL_NAME .. "_instance_number")
  reaper.DeleteExtState("ReaSculpt_Registry", "pending_" .. TOOL_NAME .. "_instance_number", false)
end

-- Piece 5: Close All. Only an instance launched through ReaSnap has a project identity and can be closed this way.
M.project_identity = nil
if reaper.HasExtState("ReaSculpt_Registry", "pending_" .. TOOL_NAME .. "_project_identity") then
  M.project_identity = reaper.GetExtState("ReaSculpt_Registry", "pending_" .. TOOL_NAME .. "_project_identity")
  reaper.DeleteExtState("ReaSculpt_Registry", "pending_" .. TOOL_NAME .. "_project_identity", false)
end

M.birth_time = reaper.time_precise()

-- Cheap enough to call every frame (checked at most every 0.25 s). True only if the signal is for this
-- instance's project and is newer than this instance, so an old signal never closes a new window.
local _last_close_check = 0
function M.shouldClose()
  if not M.project_identity then return false end
  local now = reaper.time_precise()
  if now - _last_close_check < 0.25 then return false end
  _last_close_check = now

  local raw = reaper.GetExtState("ReaSculpt_Registry", "close_" .. TOOL_NAME .. "_signal")
  if raw == "" then return false end
  local sig_project, sig_time = raw:match("^(.-)|([%d%.]+)$")
  sig_time = tonumber(sig_time)
  if not (sig_project and sig_time) then return false end
  if sig_project ~= M.project_identity then return false end
  if sig_time <= M.birth_time then return false end
  return true
end

function M.windowTitle(base_name)
  if M.instance_number then return base_name .. " #" .. M.instance_number end
  return base_name
end

return M
