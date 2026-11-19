-- selftest_window.lua (19 November 2026): ReaNvelopes' "one window unless pinned" (WindowRegistry) and what a window follows
-- (ItemFollow), run inside a REAPER of its own with REAPER's real ExtState (RT_NV = the ReaNvelopes folder, RT_OUT = results folder).
local NV = os.getenv("RT_NV")
package.path = NV .. "/lib/?.lua;" .. package.path
local Registry = require("WindowRegistry")
local Follow = require("ItemFollow")
local Serial = require("ReaNvelopes_Serial")

local lines, pass, fail = {}, 0, 0
local function report(ok, name, detail)
  if ok then pass = pass + 1 else fail = fail + 1 end
  lines[#lines + 1] = string.format("%s  %s%s", ok and "PASS" or "FAIL", name, detail and ("  -- " .. tostring(detail)) or "")
end
local function run(name, fn) local ok, err = pcall(fn); if not ok then report(false, name .. " (script error)", err) end end

run("one window unless pinned", function()
  local A, B = Registry.new(), Registry.new()
  report(B.other_unpinned_alive() == nil, "nothing open: a new window opens")
  A.register()
  report(B.other_unpinned_alive() == A.id, "an unpinned window is open: a new window sees it (and would hand over and end)")
  A.heartbeat(true)
  report(B.other_unpinned_alive() == nil, "the open window is pinned: a new window opens next to it")
  A.heartbeat(false)
  report(B.other_unpinned_alive() == A.id, "unpinned again: a new window would hand over")
  Registry.hand_over(A.id, "settings-text")
  report(A.take_handover() == "settings-text", "the window receives what was handed over")
  report(A.take_handover() == nil, "and only once")
  Registry.hand_over(A.id, "")
  report(A.take_handover() == "", "a hand-over without settings (just bring the window forward) arrives as an empty text")
  reaper.SetExtState(Registry.SECTION, "w_" .. A.id, "1.000|0", false)       -- a stamp from long ago: the window crashed
  report(B.other_unpinned_alive() == nil, "a stale stamp (a crashed window) does not count as open")
  A.stamp()
  report(B.other_unpinned_alive() == A.id, "a fresh stamp counts again")
  local C = Registry.new()
  C.register()
  report(A.other_unpinned_alive() == C.id or B.other_unpinned_alive() ~= nil, "a second window can register while the first is open")
  A.unregister(); C.unregister()
  report(B.other_unpinned_alive() == nil, "closed windows are gone")
  report(reaper.GetExtState(Registry.SECTION, "ids") == "", "the list of windows is empty again", reaper.GetExtState(Registry.SECTION, "ids"))
end)

run("what a window follows", function()
  reaper.InsertTrackAtIndex(0, true)
  local tr = reaper.GetTrack(0, 0)
  local item = reaper.CreateNewMIDIItemInProj(tr, 0, 4, false)
  local plain = reaper.CreateNewMIDIItemInProj(tr, 5, 9, false)
  local text = Serial.encode({ tool = "RAND", gen = { seed = 5 } })
  reaper.GetSetMediaItemInfo_String(item, "P_EXT:ReaNvelopes_ItemSettings", "b64:" .. Serial.b64_encode(text), true)
  reaper.SelectAllMediaItems(0, false)
  report(Follow.read_current() == nil, "nothing selected: nothing to follow")
  reaper.SetMediaItemSelected(item, true)
  local key, enc = Follow.read_current()
  report(key and key:match("^item:") and enc == text, "a selected item with settings: its key and its settings", key)
  local st = Serial.decode(enc)
  report(st.tool == "RAND" and st.gen.seed == 5, "the settings decode to what the tool wrote")
  reaper.SelectAllMediaItems(0, false); reaper.SetMediaItemSelected(plain, true)
  local key2, enc2 = Follow.read_current()
  report(key2 and key2 ~= key and enc2 == nil, "an item without settings: a different key and no settings (so the window is left as it is)")

  reaper.SelectAllMediaItems(0, false)
  reaper.SetOnlyTrackSelected(tr)
  reaper.Main_OnCommand(40406, 0)                                           -- show the volume envelope
  local env = reaper.GetTrackEnvelopeByName(tr, "Volume")
  local ai = reaper.InsertAutomationItem(env, -1, 2, 4)
  reaper.InsertEnvelopePointEx(env, ai, 0, 0.5, 0, 0, false, false)
  local text2 = Serial.encode({ tool = "OSC", gen = { sides = 6 } })
  reaper.GetSetAutomationItemInfo_String(env, ai, "P_POOL_EXT:ReaNvelopes_ItemSettings", "b64:" .. Serial.b64_encode(text2), true)
  reaper.SetCursorContext(2, env)
  for i = 0, reaper.CountAutomationItems(env) - 1 do reaper.GetSetAutomationItemInfo(env, i, "D_UISEL", (i == ai) and 1 or 0, true) end
  local key3, enc3 = Follow.read_current()
  report(key3 and key3:match("^ai:") and enc3 == text2, "a selected automation item: its key and its settings", key3)
  reaper.SetMediaItemSelected(plain, true)
  report(Follow.read_current():match("^item:") ~= nil, "a selected media item wins over an automation item")
end)

lines[#lines + 1] = ""
lines[#lines + 1] = string.format("RESULT: %d passed, %d failed", pass, fail)
lines[#lines + 1] = "DONE"
local f = io.open(os.getenv("RT_OUT") .. "/results.txt", "w"); f:write(table.concat(lines, "\n"), "\n"); f:close()
