-- selftest_item22.lua (19 November 2026): corrections list item 22. (1) a selected track envelope decides, also when a media item is still selected;
-- (2) a write into a lane that has an automation item over the same time REPLACES it (the generic writer and the generators' own writer).
-- Inside a REAPER of its own with ReaImGui, SWS and js_ReaScriptAPI (RT_EXT=1). RT_NV = the ReaNvelopes folder, RT_OUT = results folder.
local NV = os.getenv("RT_NV")
package.path = NV .. "/lib/?.lua;" .. NV .. "/lib/CommonFunction/?.lua;" .. NV .. "/lib/CommonFunction/UI/?.lua;" .. package.path
local lines, pass, fail = {}, 0, 0
local function report(ok, name, detail)
  if ok then pass = pass + 1 else fail = fail + 1 end
  lines[#lines + 1] = string.format("%s  %s%s", ok and "PASS" or "FAIL", name, detail and ("  -- " .. tostring(detail)) or "")
end
local function finish()
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("RESULT: %d passed, %d failed", pass, fail)
  lines[#lines + 1] = "DONE"
  local f = io.open(os.getenv("RT_OUT") .. "/results.txt", "w"); f:write(table.concat(lines, "\n"), "\n"); f:close()
end
local EnvWriter = require("EnvWriter")
local CurveOut = require("CurveOut")
local Curve = require("Curve")
local Logger = require("Logger")

-- a project: one track with a visible Volume and Pan lane, and a MIDI item
reaper.InsertTrackAtIndex(0, true)
local tr = reaper.GetTrack(0, 0)
reaper.SetOnlyTrackSelected(tr)
reaper.Main_OnCommand(40406, 0)                         -- show the volume envelope
reaper.Main_OnCommand(40407, 0)                         -- show the pan envelope
local vol = reaper.GetTrackEnvelopeByName(tr, "Volume")
local pan = reaper.GetTrackEnvelopeByName(tr, "Pan")
report(vol ~= nil and pan ~= nil, "the track has a Volume and a Pan lane")
local item = reaper.CreateNewMIDIItemInProj(tr, 20, 24, false)

local function ai(env, pos, len, npts)
  local i = reaper.InsertAutomationItem(env, -1, pos, len)
  for k = 0, (npts or 3) - 1 do reaper.InsertEnvelopePointEx(env, i, k * len / math.max((npts or 3) - 1, 1), 0.5, 0, 0, false, true) end
  reaper.Envelope_SortPointsEx(env, i)
  return i
end
local function describe(env)
  local t = {}
  for i = 0, reaper.CountAutomationItems(env) - 1 do
    t[#t + 1] = string.format("%.1f-%.1f(%d pts)", reaper.GetSetAutomationItemInfo(env, i, "D_POSITION", 0, false),
      reaper.GetSetAutomationItemInfo(env, i, "D_POSITION", 0, false) + reaper.GetSetAutomationItemInfo(env, i, "D_LENGTH", 0, false),
      reaper.CountEnvelopePointsEx(env, i))
  end
  return table.concat(t, " ")
end
local function select_env(env) reaper.SetCursorContext(2, env) end

-- ---------------------------------------------------------------- 1. the selected envelope decides
reaper.SelectAllMediaItems(0, false); reaper.SetMediaItemSelected(item, true)           -- a leftover selected item
select_env(vol)
reaper.GetSet_LoopTimeRange2(0, true, false, 2, 6, false)
Logger.capture = {}
local env, ts_s, ts_e, off = EnvWriter.resolveTarget()
report(env == vol and ts_s == 2 and ts_e == 6 and off == 0, "a track envelope is selected and a media item is still selected: the envelope and the time selection are used",
  env and string.format("%.1f-%.1f", ts_s, ts_e) or table.concat(Logger.capture or {}, " / "))
reaper.GetSet_LoopTimeRange2(0, true, false, 0, 0, false)                               -- no time selection: the item's own length
env, ts_s, ts_e = EnvWriter.resolveTarget()
report(env == vol and ts_s == 20 and ts_e == 24, "no time selection: the selected item's length is the range", env and string.format("%.1f-%.1f", ts_s, ts_e) or "nil")
reaper.SelectAllMediaItems(0, false)
env = EnvWriter.resolveTarget()
report(env == nil, "no time selection and no item: it refuses (and says so)")
Logger.capture = nil

-- ---------------------------------------------------------------- 2. replace, the generators' writer (RAND / OSC)
reaper.GetSet_LoopTimeRange2(0, true, false, 2, 6, false)
local a_old = ai(vol, 2, 4, 3)                 -- exactly where the write goes: it is replaced
local b = ai(vol, 10, 4, 3)                    -- elsewhere: stays
local c = ai(vol, 5, 4, 3)                     -- overlaps the range only partly (5-9): stays
local p = ai(pan, 2, 4, 3)                     -- another lane, selected by the user: stays and stays selected
reaper.GetSetAutomationItemInfo(pan, p, "D_UISEL", 1, true)
report(reaper.GetSetAutomationItemInfo(pan, 0, "D_UISEL", 0, false) > 0, "(set-up) the Pan item is selected before the write", reaper.GetSetAutomationItemInfo(pan, 0, "D_UISEL", 0, false))
local before = describe(vol)
local pts = { { tn = 0, v = 0.2, shape = 0, tension = 0 }, { tn = 1, v = 0.8, shape = 0, tension = 0 } }
local removed = EnvWriter.removeAutomationItemsIn(vol, 2, 6)
report(removed == 1, "removing the items inside 2-6 deletes exactly one (the old one)", removed)
report(reaper.GetSetAutomationItemInfo(pan, 0, "D_UISEL", 0, false) > 0, "the selection of an automation item on another lane is put back after the removal")
local idx = EnvWriter.commitAutomationItem(vol, pts, 2, 6)
local after = describe(vol)
report(idx >= 0, "the write makes an automation item", idx)
local has26, n26 = false, 0
for i = 0, reaper.CountAutomationItems(vol) - 1 do
  local pos = reaper.GetSetAutomationItemInfo(vol, i, "D_POSITION", 0, false)
  local len = reaper.GetSetAutomationItemInfo(vol, i, "D_LENGTH", 0, false)
  if math.abs(pos - 2) < 0.01 and math.abs(len - 4) < 0.01 then n26 = n26 + 1; has26 = (reaper.CountEnvelopePointsEx(vol, i) == 2) end
end
report(n26 == 1 and has26, "exactly one automation item over 2-6 s, and it holds the NEW curve (2 points), not the old one added to it", before .. "  ->  " .. after)
report(reaper.CountAutomationItems(vol) == 3, "the item elsewhere (10-14) and the partly overlapping one (5-9) are still there, plus the new one", after)
report(reaper.CountAutomationItems(pan) == 1, "the automation item of another lane is still there")
-- (REAPER's own InsertAutomationItem selects the new item and drops the selection of the others: that is not ours to keep)

-- ---------------------------------------------------------------- 3. replace, the generic writer (CurveOut.commitEnvelope)
select_env(vol)
local curve = Curve.new({ { t = 0, v = 0.1 }, { t = 4, v = 0.9 } }, 4, false)
local ok, err, envName, count, madeAI, aiEnv, aiIdx = CurveOut.commitEnvelope(curve, { name = "test", clear = true, automationItem = true, rangeStart = 2, rangeEnd = 6 })
report(ok == true and madeAI, "the generic writer makes an automation item", err)
local n26b = 0
for i = 0, reaper.CountAutomationItems(vol) - 1 do
  local pos = reaper.GetSetAutomationItemInfo(vol, i, "D_POSITION", 0, false)
  local len = reaper.GetSetAutomationItemInfo(vol, i, "D_LENGTH", 0, false)
  if math.abs(pos - 2) < 0.01 and math.abs(len - 4) < 0.01 then n26b = n26b + 1 end
end
report(n26b == 1, "written again over the same time: still ONE automation item there (replaced, not added)", describe(vol))
report(reaper.CountAutomationItems(vol) == 3, "the others are still there", describe(vol))

finish()
