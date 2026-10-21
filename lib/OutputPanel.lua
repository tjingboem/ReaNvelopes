-- ============================================================
--   OutputPanel.lua
--   The "OUTPUT" section of every ReaNvelopes tool: where the
--   generated curve goes.
--
--     1  Parameter envelope   the tool's own writer (automation item
--                             on the selected envelope lane)
--     2  MIDI CC / pitch bend / channel pressure   into the selected
--                             MIDI item (or a new one at the cursor)
--     3  Note velocity        the notes of the selected MIDI item read
--                             the curve at their start
--
--   Where in time: the time selection if there is one, otherwise
--   the selected item (EnvWriter.getEffectiveRange). The curve is
--   stretched over that range. The MIDI channel is this panel's own
--   Channel slider, so the result never depends on which tool made
--   the curve.
--
--   A tool calls  OutputPanel.draw(ctx, name, getPoints, writeEnvelope)
--     getPoints()      -> list of { tn = 0..1, v = 0..1 }  (the curve), and optionally true as a second value
--                         when the curve is steps (a value is held until the next point)
--     writeEnvelope()  -> the tool's own "write to the envelope" call; nil = use the generic one (CurveOut)
-- ============================================================

local M = {}

local Curve    = require("Curve")
local CurveOut = require("CurveOut")
local EnvWriter = require("EnvWriter")
local Logger   = require("Logger")

local S = {
  target = 1, kind = 1, cc = 1, channel = 0,
  loPct = 0, hiPct = 100, thinPct = 0.5, clear = true,
}
M.state = S

local TARGETS = "Parameter envelope (automation item)\0MIDI CC / pitch bend / pressure\0Note velocity (selected MIDI item)\0"
local KINDS   = "CC\0Pitch bend\0Channel pressure\0"

-- The curve over the current range, and where in the MIDI item it starts. Returns curve, startBeats, rangeStart,
-- rangeEnd (seconds), or nil and a message.
local function buildCurve(points, hold)
  if not points or #points == 0 then return nil, "no curve yet: generate a shape first" end
  local ts_s, ts_e = EnvWriter.getEffectiveRange()
  if not ts_s then return nil, "set a time selection (or select an item) first" end
  local qS, qE = reaper.TimeMap_timeToQN(ts_s), reaper.TimeMap_timeToQN(ts_e)
  local lengthBeats = math.max(qE - qS, 1e-6)
  local startBeats = 0
  if reaper.CountSelectedMediaItems(0) > 0 then
    local item = reaper.GetSelectedMediaItem(0, 0)
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local itemQN = reaper.TimeMap_timeToQN(reaper.GetMediaItemInfo_Value(item, "D_POSITION"))
      startBeats = math.max(0, qS - itemQN)
    end
  end
  local pts = {}
  for i, p in ipairs(points) do pts[i] = { t = p.tn * lengthBeats, v = p.v } end
  return Curve.new(pts, lengthBeats, hold and true or false), startBeats, ts_s, ts_e
end

local function doCommit(name, points, writeEnvelope, hold)
  if S.target == 1 and writeEnvelope then
    writeEnvelope()
    return
  end
  local curve, startBeats, rangeS, rangeE = buildCurve(points, hold)
  if not curve then Logger.error("⚠  " .. tostring(startBeats)); return end
  local opts = {
    name = name, kind = ({ "cc", "bend", "pressure" })[S.kind] or "cc", cc = S.cc, channel = S.channel,
    thin = S.thinPct / 100.0, lo = S.loPct / 100.0, hi = S.hiPct / 100.0, clear = S.clear, startBeats = startBeats,
    rangeStart = rangeS, rangeEnd = rangeE,
  }
  if S.target == 1 then   -- a tool without an envelope writer of its own: the generic one, into the selected lane
    local ok, err, envName, count, madeAI = CurveOut.commitEnvelope(curve, { name = name, thin = S.thinPct / 100.0,
      clear = true, automationItem = true, rangeStart = rangeS, rangeEnd = rangeE })
    if ok then Logger.ok(string.format("✔ %d points to \"%s\"%s", count, tostring(envName), madeAI and " (automation item)" or ""))
    else Logger.error("⚠  " .. tostring(err)) end
    return
  end
  if S.target == 3 then
    local ok, err, _, count = CurveOut.commitVelocity(curve, opts)
    if ok then Logger.ok(string.format("✔ Velocity set on %d notes", count)) else Logger.error("⚠  " .. tostring(err)) end
  else
    local ok, err, _, count = CurveOut.commitCC(curve, opts)
    if ok then Logger.ok(string.format("✔ %d MIDI events written", count)) else Logger.error("⚠  " .. tostring(err)) end
  end
end

-- Every write runs inside a capture: whatever went wrong (no envelope selected, no time selection, no curve ...) is
-- shown in a window the user has to close with OK, because the status bar line is too easy to miss.
local function commit(name, points, writeEnvelope, hold)
  Logger.capture = {}
  doCommit(name, points, writeEnvelope, hold)
  local errs = Logger.capture
  Logger.capture = nil
  if #errs > 0 then
    local lines = {}
    for i, e in ipairs(errs) do lines[i] = (e:gsub("^%s*⚠%s*", "")) end
    if S.target == 1 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Select the envelope lane first (click its name in the track panel)."
    end
    Logger.popup(table.concat(lines, "\n"))
  end
end
M._commit = function(...) return commit(...) end   -- for the offline tests
M._buildCurve = function(...) return buildCurve(...) end

function M.draw(ctx, name, getPoints, writeEnvelope)
  local _
  _, S.target = reaper.ImGui_Combo(ctx, "Target##outtarget", S.target - 1, TARGETS)
  S.target = S.target + 1
  if S.target == 2 then
    _, S.kind = reaper.ImGui_Combo(ctx, "Message##outkind", S.kind - 1, KINDS)
    S.kind = S.kind + 1
    if S.kind == 1 then _, S.cc = reaper.ImGui_SliderInt(ctx, "CC number##outcc", S.cc, 0, 127) end
    local disp
    _, disp = reaper.ImGui_SliderInt(ctx, "Channel##outch", S.channel + 1, 1, 16)
    S.channel = disp - 1
  end
  if S.target ~= 1 then
    _, S.loPct = reaper.ImGui_SliderInt(ctx, "Range low %##outlo", S.loPct, 0, 100)
    _, S.hiPct = reaper.ImGui_SliderInt(ctx, "Range high %##outhi", S.hiPct, 0, 100)
    if S.target == 2 then
      _, S.thinPct = reaper.ImGui_SliderDouble(ctx, "Thinning %##outthin", S.thinPct, 0.0, 5.0)
      _, S.clear = reaper.ImGui_Checkbox(ctx, "Replace range##outclear", S.clear)
    end
  end

  local cur, hold = getPoints()
  local has_points = cur and #cur > 0
  if not has_points then reaper.ImGui_BeginDisabled(ctx) end
  local label = (S.target == 1) and "WRITE TO ENVELOPE" or (S.target == 2) and "WRITE MIDI" or "SET VELOCITY"
  if reaper.ImGui_Button(ctx, label .. "##outwrite", -1, 36) then
    commit(name, cur, writeEnvelope, hold)
  end
  if not has_points then reaper.ImGui_EndDisabled(ctx) end
  if S.target == 2 then
    reaper.ImGui_Text(ctx, "Into the selected MIDI item, on the channel above.")
  elseif S.target == 3 then
    reaper.ImGui_Text(ctx, "Each note of the selected MIDI item reads the curve.")
  end
end

return M
