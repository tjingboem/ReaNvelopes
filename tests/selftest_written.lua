-- selftest_written.lua (23 November 2026): a curve that ReaNvelopes WRITES into the project (MIDI CC into an item, the generic envelope writer into an
-- automation item) is also filed in the ReaCat catalogue (tag "written") and marked as used by the place it went to (spec section 11).
-- Inside a REAPER of its own (RT_EXT=1). RT_NV = the ReaNvelopes folder, RT_OUT = results folder.
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
local ok0, err0 = pcall(function()
  local OutputPanel = require("OutputPanel")
  local Cat = require("ReaCat")
  local Logger = require("Logger")

  reaper.InsertTrackAtIndex(0, true)
  local tr = reaper.GetTrack(0, 0)
  reaper.SetOnlyTrackSelected(tr)
  reaper.Main_OnCommand(40406, 0)                       -- the volume lane
  local vol = reaper.GetTrackEnvelopeByName(tr, "Volume")
  local item = reaper.CreateNewMIDIItemInProj(tr, 20, 24, false)

  local pts = { { tn = 0, v = 0.2 }, { tn = 0.5, v = 0.9 }, { tn = 1, v = 0.4 } }
  local control = { { tn = 0, v = 0.2, shape = 0 }, { tn = 0.5, v = 0.9, shape = 0 }, { tn = 1, v = 0.4, shape = 0 } }
  local function getControl() return control end
  local function toolState() return { a = 1 } end

  -- 1. a write that fails files nothing: no item selected, no time selection
  reaper.SelectAllMediaItems(0, false)
  reaper.GetSet_LoopTimeRange2(0, true, false, 0, 0, false)
  OutputPanel.applyState({ target = 2, kind = 1, cc = 1, channel = 0 })
  local before = #Cat.list()
  Logger.clearPopup()
  OutputPanel._commit("ReaNvelopes: RAND", pts, nil, false, getControl, toolState)
  local errs = { Logger.peekPopup() }
  Logger.clearPopup()
  report(#errs > 0 and #Cat.list() == before, "a write that fails files nothing in ReaCat", #errs .. " errors, " .. (#Cat.list() - before) .. " new entries")

  -- 2. MIDI CC into the selected item
  reaper.SetMediaItemSelected(item, true)
  Logger.clearPopup()
  OutputPanel._commit("ReaNvelopes: RAND", pts, nil, false, getControl, toolState)
  errs = { Logger.peekPopup() }
  Logger.clearPopup()
  report(#errs == 0, "the MIDI CC write works", errs[1])
  local list = Cat.list()
  local e = list[1] and Cat.get(list[1].id)
  report(e and e.source == "ReaNvelopes" and e.name == "RAND" and #list == before + 1, "the written curve is in the catalogue", #list)
  local tagged = false
  for _, t in ipairs(e and e.tags or {}) do if t == "written" then tagged = true end end
  report(tagged, "tagged 'written'")
  local used = e and Cat.usedBy(e.hash) or {}
  report(#used == 1 and used[1].what == "item" and used[1].tool == "ReaNvelopes", "marked as used by the item", #used)
  local _, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
  report(notes:find("ReaCat: ReaNvelopes RAND, taken ", 1, true) ~= nil, "the item's notes have the ReaCat line", notes)
  report(not Cat.nameSuffixOn(), "the name suffix setting is off by default")

  -- 3. the same curve written again: still one entry, still one usage line for the item
  OutputPanel._commit("ReaNvelopes: RAND", pts, nil, false, getControl, toolState)
  report(#Cat.list() == before + 1 and #Cat.usedBy(e.hash) == 1, "written again: the same entry, the same usage line")

  -- 4. the generic envelope writer into an automation item of the selected lane
  reaper.SelectAllMediaItems(0, false)
  reaper.SetCursorContext(2, vol)
  reaper.GetSet_LoopTimeRange2(0, true, false, 2, 6, false)
  OutputPanel.applyState({ target = 1 })
  Logger.clearPopup()
  OutputPanel._commit("ReaNvelopes: RAND", pts, nil, false, getControl, toolState)
  errs = { Logger.peekPopup() }
  Logger.clearPopup()
  report(#errs == 0, "the envelope write works", errs[1])
  local used2 = Cat.usedBy(e.hash)
  local hasAI = false
  for _, u in ipairs(used2) do if u.what == "ai" and u.guid:find("^ai:") then hasAI = true end end
  report(#used2 == 2 and hasAI, "the same curve is now used by an automation item too", #used2)
  report(#Cat.list() == before + 1, "and it is still one catalogue entry")
end)
if not ok0 then report(false, "the test ran without a script error", err0) end
finish()
