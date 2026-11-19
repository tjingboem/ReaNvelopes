-- hub_smoke.lua (19 November 2026): runs the real ReaNvelopes.lua hub for a number of frames inside a REAPER of its own that has
-- ReaImGui, SWS and js_ReaScriptAPI (RT_EXT=1 in the runner), and checks (1) the hub starts and draws without a script error, (2) a
-- second hub started while the first is open does not open a window but hands its settings over, (3) a pinned first window is left alone.
-- RT_NV = the ReaNvelopes folder, RT_OUT = results folder.
local NV = os.getenv("RT_NV")
local out_dir = os.getenv("RT_OUT")
local lines, pass, fail = {}, 0, 0
local function report(ok, name, detail)
  if ok then pass = pass + 1 else fail = fail + 1 end
  lines[#lines + 1] = string.format("%s  %s%s", ok and "PASS" or "FAIL", name, detail and ("  -- " .. tostring(detail)) or "")
end
local function finish()
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("RESULT: %d passed, %d failed", pass, fail)
  lines[#lines + 1] = "DONE"
  local f = io.open(out_dir .. "/results.txt", "w"); f:write(table.concat(lines, "\n"), "\n"); f:close()
end
if not (reaper.ImGui_CreateContext and reaper.SNM_GetIntConfigVar and reaper.JS_ReaScriptAPI_Version) then
  report(false, "the extensions ReaImGui, SWS and js_ReaScriptAPI are loaded in the test REAPER")
  finish(); return
end

-- the hub finds its folder through get_action_context
local real_ctx = reaper.get_action_context
reaper.get_action_context = function() return true, NV .. "/ReaNvelopes.lua", 0, 0, 0, 0, 0 end
-- the hub runs by reaper.defer(loop): drive it here, frame by frame
local queue = {}
local real_defer = reaper.defer
reaper.defer = function(f) queue[#queue + 1] = f end
local function frames(n)
  for _ = 1, n do
    local q = queue; queue = {}
    for _, f in ipairs(q) do
      local ok, err = pcall(f)
      if not ok then report(false, "a frame ran without error", err); return false end
    end
  end
  return true
end
local function fresh_modules()    -- a second hub is a second script run: its own pending state, its own registry object
  for _, m in ipairs{ "ReaSnap_Integration" } do package.loaded[m] = nil end
end

-- 1. the first hub (started as ReaSnap starts a window: with a project identity, so it follows the selection)
reaper.SetExtState("ReaSculpt_Registry", "pending_ReaNvelopes_project_identity", "/test/project.rpp", false)
local ok, err = pcall(dofile, NV .. "/ReaNvelopes.lua")
report(ok, "the hub starts", err)
local Registry = package.loaded["WindowRegistry"]
report(Registry ~= nil and #queue == 1, "the hub registered its frame loop")
report(frames(30), "30 frames are drawn without a script error")
local ids = reaper.GetExtState("ReaNvelopes_Windows", "ids")
report(ids ~= "", "the open window is in the registry", ids)

-- 1b. follow: select an item that carries ReaNvelopes settings, and the window loads them
do
  local Serial1 = package.loaded["ReaNvelopes_Serial"]
  reaper.InsertTrackAtIndex(0, true)
  local tr = reaper.GetTrack(0, 0)
  local item = reaper.CreateNewMIDIItemInProj(tr, 0, 4, false)
  local st = Serial1.encode({ tool = "OSC", gen = { sides = 7, cycles = 3 }, out = { target = 3 } })
  reaper.GetSetMediaItemInfo_String(item, "P_EXT:ReaNvelopes_ItemSettings", "b64:" .. Serial1.b64_encode(st), true)
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(item, true)
  report(frames(5), "frames run after selecting the item")
  local OSCState = package.loaded["OSCState"]
  report(OSCState ~= nil and OSCState.sides == 7 and OSCState.cycles == 3, "a ReaSnap-launched window follows the selection: the item's settings are loaded", OSCState and OSCState.sides)
  local Out = package.loaded["OutputPanel"]
  report(Out ~= nil and Out.state.target == 3, "and the OUTPUT settings", Out and Out.state.target)
end

-- 2. a second hub while the first is open: it must not open, and must hand its settings over
local Serial = package.loaded["ReaNvelopes_Serial"]
local handed = Serial.encode({ tool = "DRAW", gen = { shape_mode = "step", points = { { tn = 0, v = 0.2 }, { tn = 1, v = 0.9 } } }, out = {} })
reaper.SetExtState("ReaSculpt_Registry", "pending_ReaNvelopes_settings", handed, false)   -- what ReaSnap's S leaves
fresh_modules()
local n_before = #queue
local ok2, err2 = pcall(dofile, NV .. "/ReaNvelopes.lua")
report(ok2, "a second hub starts without an error", err2)
report(#queue == n_before, "the second hub did not open a window (no frame loop of its own)", #queue - n_before)
report(frames(10), "the first window runs on")
local DRAWState = package.loaded["DRAWState"]
report(DRAWState and DRAWState.shape_mode == "step" and #DRAWState.points == 2, "the first window took over the settings handed to it", DRAWState and DRAWState.shape_mode)

-- 3. pin the first window (the label click is a mouse click, so set it through the registry the way the window does) and start a third
-- hub: with the open window pinned it must open its own window. The pin lives in the hub's local variable, so stand in with the stamp.
local id = reaper.GetExtState("ReaNvelopes_Windows", "ids"):match("[^;]+")
reaper.SetExtState("ReaNvelopes_Windows", "w_" .. id, string.format("%.3f|1", reaper.time_precise()), false)
fresh_modules()
n_before = #queue
local ok3, err3 = pcall(dofile, NV .. "/ReaNvelopes.lua")
report(ok3 and #queue == n_before + 1, "with the open window pinned, a new hub opens its own window", err3 or (#queue - n_before))
report(frames(10), "both windows run")

reaper.get_action_context = real_ctx
finish()
