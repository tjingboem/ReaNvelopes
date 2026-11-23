-- test_reacat_send.lua: "Send to ReaCat and the world" (lib/ReaCatSend.lua), offline with a stand-in reaper. Run from the ReaNvelopes folder:
--   lua5.4 tests/test_reacat_send.lua      (TMPDIR chooses the scratch folder)
package.path = "lib/?.lua;lib/CommonFunction/?.lua;" .. package.path
local root = (os.getenv("TMPDIR") or "/tmp") .. "/nv_reacat_" .. os.time() .. "_" .. math.random(100000)
os.execute("mkdir -p '" .. root .. "'")
local ext = {}
reaper = {
  GetResourcePath = function() return root end,
  RecursiveCreateDirectory = function(p) os.execute("mkdir -p '" .. p .. "'") return 1 end,
  EnumerateFiles = function(dir, i)
    if i < 0 then return nil end
    local p = io.popen("find '" .. dir .. "' -maxdepth 1 -type f 2>/dev/null | sort")
    local k = 0
    for path in p:lines() do if k == i then p:close() return (path:match("([^/]+)$")) end k = k + 1 end
    p:close()
    return nil
  end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetProjectName = function() return "Night Piece.RPP" end,
}
local Send = require("ReaCatSend")
local Cat = require("ReaCat")

local passed, failed = 0, 0
local function check(name, cond, detail)
  if cond then passed = passed + 1 else failed = failed + 1 print("FAIL: " .. name .. (detail and (" -- " .. tostring(detail)) or "")) end
end

-- control points as RAND hands them over: a bezier segment travels as samples
local samples = {}
for k = 0, 48 do local t = 0.25 + 0.5 * k / 48 samples[#samples + 1] = { t = t, v = 0.2 + 0.6 * (0.5 - 0.5 * math.cos(math.pi * (t - 0.25) / 0.5)) } end
local control = {
  { tn = 0, v = 0.5, shape = 2 },
  { tn = 0.25, v = 0.2, shape = 5, samples = samples },
  { tn = 0.75, v = 0.8, shape = 1 },
  { tn = 1, v = 0.4, shape = 0 },
}
local ok, n, id = Send.send({}, false, "ReaNvelopes: RAND", control)
check("send with control points succeeds", ok == true and id ~= nil, tostring(n))
local e = Cat.get(id)
check("source and name come from 'ReaNvelopes: RAND'", e and e.source == "ReaNvelopes" and e.name == "RAND")
check("the points are in the catalogue, first t 0, last t 1", e and e.points[1].t == 0 and e.points[#e.points].t == 1 and #e.points == n, e and #e.points)
check("shapes survive (ease first, a step later)", e and e.points[1].shape == 2 and (function() for _, p in ipairs(e.points) do if p.shape == 1 then return true end end end)())
check("the bezier segment becomes a cubic piece or more", (function() for _, p in ipairs(e.points) do if p.shape == 5 and p.c1 and p.c2 then return true end end end)())
check("the project name is on it", e and e.project == "Night Piece")
check("the tool tag and a shape word are on it", (function()
  local have = {}
  for _, t in ipairs(e.tags) do have[t:lower()] = true end
  return have.reanvelopes and have.rand and (have.step or have.smooth)
end)())
check("the old one-slot place is gone: nothing is written there", (ext["tjingboem_curve/current"] or "") == "")

-- dense samples (OSC) without control points
local dense = {}
for i = 0, 200 do local t = i / 200 dense[#dense + 1] = { tn = t, v = 0.5 + 0.4 * math.sin(t * 6.2832 * 3) } end
local ok2, n2, id2 = Send.send(dense, false, "ReaNvelopes: OSC", nil)
check("dense samples are fitted and sent", ok2 == true and id2 ~= nil and n2 < 201, n2)
check("OSC has its own name", Cat.get(id2).name == "OSC")

-- a staircase (hold) from DRAW
local stairs = { { tn = 0, v = 0.1 }, { tn = 0.5, v = 0.9 }, { tn = 1, v = 0.4 } }
local ok3, n3, id3 = Send.send(stairs, true, "ReaNvelopes: DRAW", nil)
check("a hold curve is sent", ok3 == true and id3 ~= nil)

-- nothing to send
local ok4, msg = Send.send({}, false, "ReaNvelopes: RAND", nil)
check("no curve: a message, nothing stored", ok4 == false and type(msg) == "string" and #Cat.list() == 3, msg)

-- the same curve again: stored once
local before = #Cat.list()
Send.send({}, false, "ReaNvelopes: RAND", control)
check("the same curve again is not stored twice", #Cat.list() == before)
-- a name without a colon
local ok5, _, id5 = Send.send(stairs, true, "Something", nil)
check("a name without a tool part", ok5 and Cat.get(id5).source == "ReaNvelopes" and Cat.get(id5).name == "Something")

os.execute("rm -rf '" .. root .. "'")
print(string.format("%d checks passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
