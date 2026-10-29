-- ============================================================
--   OutputPanel.lua
--   The "OUTPUT" section of every ReaNvelopes tool: where the
--   generated curve goes.
--
--     1  Parameter envelope   the tool's own writer (automation item
--                             on the selected envelope lane)
--     2  MIDI CC / pitch bend / channel pressure   into the selected
--                             MIDI item (or a new one at the cursor)
--     3  Note value           one value of the notes of the selected MIDI
--                             item (velocity, lift = note-off velocity,
--                             duration, pitch, channel, mute) follows the
--                             curve, each note reading it at its start
--                             (lift: at its end)
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

local CurveShare = require("CurveShare")
local Curve    = require("Curve")
local CurveOut = require("CurveOut")
local EnvWriter = require("EnvWriter")
local Logger   = require("Logger")

local S = {
  target = 1, kind = 1, cc = 1, channel = 0,
  thinPct = 0.5, clear = true,
  value = 1,                                   -- 1 velocity, 2 lift, 3 duration, 4 pitch, 5 channel, 6 mute
  durMode = 1, durFactorLo = 25, durFactorHi = 200, durAbsLo = 0.0625, durAbsHi = 1.0, durShiftLo = -0.25, durShiftHi = 0.25,
  pitchMode = 1, pitchShiftLo = -12, pitchShiftHi = 12, pitchAbsLo = 36, pitchAbsHi = 84,
  chLo = 1, chHi = 16, threshold = 50, invert = false,
}
M.state = S

local TARGETS = "Parameter envelope (automation item)\0MIDI CC / pitch bend / pressure\0Note value (selected MIDI item)\0Send to ReaMaskM / ReaShapeM\0"
local VALUES  = "Velocity\0Velocity off (lift)\0Duration\0Pitch\0Channel\0Mute\0"
local VALUE_KEYS = { "velocity", "lift", "duration", "pitch", "channel", "mute" }
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

local function doCommit(name, points, writeEnvelope, hold, getControl)
  if S.target == 4 then   -- Send to ReaMaskM / ReaShapeM: the curve as shown (flips included), no time selection needed
    local ok, n = CurveShare.send(points, hold, name, getControl and getControl())
    if ok then Logger.ok(string.format("✔ curve sent (%d points) — use Take Curve from ReaNvelopes in ReaMaskM or ReaShapeM", n))
    else Logger.error("⚠  " .. tostring(n)) end
    return
  end
  if S.target == 1 and writeEnvelope then
    writeEnvelope()
    return
  end
  local curve, startBeats, rangeS, rangeE = buildCurve(points, hold)
  if not curve then Logger.error("⚠  " .. tostring(startBeats)); return end
  local opts = {
    name = name, kind = ({ "cc", "bend", "pressure" })[S.kind] or "cc", cc = S.cc, channel = S.channel,
    thin = S.thinPct / 100.0, clear = S.clear, startBeats = startBeats,   -- no range sliders: the curve fills the whole range of the target
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
    opts.value     = VALUE_KEYS[S.value]
    opts.durMode   = (S.durMode == 2) and "absolute" or (S.durMode == 3) and "shift" or "factor"
    opts.durLo     = (S.durMode == 2) and S.durAbsLo or (S.durMode == 3) and S.durShiftLo or S.durFactorLo / 100.0
    opts.durHi     = (S.durMode == 2) and S.durAbsHi or (S.durMode == 3) and S.durShiftHi or S.durFactorHi / 100.0
    opts.pitchMode = (S.pitchMode == 2) and "absolute" or "shift"
    opts.pitchLo   = (S.pitchMode == 2) and S.pitchAbsLo or S.pitchShiftLo
    opts.pitchHi   = (S.pitchMode == 2) and S.pitchAbsHi or S.pitchShiftHi
    opts.chLo, opts.chHi = S.chLo - 1, S.chHi - 1
    opts.threshold, opts.invert = S.threshold / 100.0, S.invert
    local ok, err, _, count = CurveOut.commitNoteValue(curve, opts)
    if ok then Logger.ok(string.format("✔ %s set on %d notes", (VALUES:match("^" .. string.rep("[^%z]*%z", S.value - 1) .. "([^%z]*)%z") or "Value"), count))
    else Logger.error("⚠  " .. tostring(err)) end
  else
    local ok, err, _, count = CurveOut.commitCC(curve, opts)
    if ok then Logger.ok(string.format("✔ %d MIDI events written", count)) else Logger.error("⚠  " .. tostring(err)) end
  end
end

-- Every write runs inside a capture: whatever went wrong (no envelope selected, no time selection, no curve ...) is
-- shown in a window the user has to close with OK, because the status bar line is too easy to miss.
local function commit(name, points, writeEnvelope, hold, getControl)
  Logger.capture = {}
  doCommit(name, points, writeEnvelope, hold, getControl)
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

function M.draw(ctx, name, getPoints, writeEnvelope, getControl)
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
  if S.target == 3 then
    _, S.value = reaper.ImGui_Combo(ctx, "Value##outvalue", S.value - 1, VALUES)
    S.value = S.value + 1
  end
  if S.target == 2 then
    _, S.thinPct = reaper.ImGui_SliderDouble(ctx, "Thinning %##outthin", S.thinPct, 0.0, 5.0)
    _, S.clear = reaper.ImGui_Checkbox(ctx, "Replace range##outclear", S.clear)
  end
  if S.target == 3 and S.value == 3 then
    _, S.durMode = reaper.ImGui_Combo(ctx, "Length##outdurmode", S.durMode - 1, "Factor of the note's length\0Absolute (beats)\0Shift (+/- beats)\0")
    S.durMode = S.durMode + 1
    if S.durMode == 1 then
      _, S.durFactorLo = reaper.ImGui_SliderInt(ctx, "Factor min %##outdfl", S.durFactorLo, 5, 400)
      _, S.durFactorHi = reaper.ImGui_SliderInt(ctx, "Factor max %##outdfh", S.durFactorHi, 5, 400)
    elseif S.durMode == 2 then
      _, S.durAbsLo = reaper.ImGui_SliderDouble(ctx, "Length min (beats)##outdal", S.durAbsLo, 0.0078125, 4.0)
      _, S.durAbsHi = reaper.ImGui_SliderDouble(ctx, "Length max (beats)##outdah", S.durAbsHi, 0.0078125, 4.0)
    else
      _, S.durShiftLo = reaper.ImGui_SliderDouble(ctx, "Shift min (beats)##outdsl", S.durShiftLo, -2.0, 2.0)
      _, S.durShiftHi = reaper.ImGui_SliderDouble(ctx, "Shift max (beats)##outdsh", S.durShiftHi, -2.0, 2.0)
    end
  elseif S.target == 3 and S.value == 4 then
    _, S.pitchMode = reaper.ImGui_Combo(ctx, "Pitch##outpmode", S.pitchMode - 1, "Shift (semitones)\0Absolute\0")
    S.pitchMode = S.pitchMode + 1
    if S.pitchMode == 1 then
      _, S.pitchShiftLo = reaper.ImGui_SliderInt(ctx, "Shift min##outpsl", S.pitchShiftLo, -48, 48)
      _, S.pitchShiftHi = reaper.ImGui_SliderInt(ctx, "Shift max##outpsh", S.pitchShiftHi, -48, 48)
    else
      _, S.pitchAbsLo = reaper.ImGui_SliderInt(ctx, "Pitch min##outpal", S.pitchAbsLo, 0, 127)
      _, S.pitchAbsHi = reaper.ImGui_SliderInt(ctx, "Pitch max##outpah", S.pitchAbsHi, 0, 127)
    end
  elseif S.target == 3 and S.value == 5 then
    _, S.chLo = reaper.ImGui_SliderInt(ctx, "Channel min##outcl", S.chLo, 1, 16)
    _, S.chHi = reaper.ImGui_SliderInt(ctx, "Channel max##outch2", S.chHi, 1, 16)
  elseif S.target == 3 and S.value == 6 then
    _, S.threshold = reaper.ImGui_SliderInt(ctx, "Threshold % (intensity)##outthr", S.threshold, 0, 100)
    _, S.invert = reaper.ImGui_Checkbox(ctx, "Mute high intensity instead of low##outinv", S.invert)
  end

  local cur, hold = getPoints()
  local has_points = cur and #cur > 0
  if not has_points then reaper.ImGui_BeginDisabled(ctx) end
  local label = (S.target == 1) and "WRITE TO ENVELOPE" or (S.target == 2) and "WRITE MIDI" or (S.target == 4) and "SEND CURVE" or "SET NOTE VALUES"
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 8)   -- round edges
  if reaper.ImGui_Button(ctx, label .. "##outwrite", -1, 36) then
    commit(name, cur, writeEnvelope, hold, getControl)
  end
  reaper.ImGui_PopStyleVar(ctx)
  if not has_points then reaper.ImGui_EndDisabled(ctx) end
  -- No remarks under the button: what goes wrong is reported in the message window (see commit).
end

return M
