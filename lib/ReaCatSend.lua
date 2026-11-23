-- ============================================================
--   ReaCatSend.lua  —  "Send to ReaCat and the world" for ReaNvelopes' OUTPUT section.
--   The curve is fitted by CurveShare (control points with their shapes, bezier segments as cubic pieces), then stored in the
--   ReaCat catalogue (lib/ReaCat.lua, spec: ReaCat/doc/ReaCat_Spec.md).
--
--   TEMPORARY: the same curve is also put in the old one-slot place (CurveShare.send) until ReaMaskM and ReaShapeM take their
--   curves from ReaCat (migration step 5); then that call and CurveShare.lua go (step 6).
-- ============================================================

local CurveShare = require("CurveShare")
local ReaCat = require("ReaCat")

local M = {}

-- "ReaNvelopes: RAND" -> "ReaNvelopes", "RAND"
local function splitName(name)
  name = tostring(name or "")
  local a, b = name:match("^(.-):%s*(.+)$")
  if a and a ~= "" then return a, b end
  return "ReaNvelopes", (name ~= "" and name or "curve")
end

-- the points of an encoded ReaCurve text: lines "t,v[,shape[,c1,c2]]"
local function pointsOf(text)
  local pts = {}
  for line in text:gmatch("[^\r\n;]+") do
    if not line:find("=", 1, true) then
      local a = {}
      for f in (line .. ","):gmatch("([^,]*),") do a[#a + 1] = tonumber(f) end
      if a[1] and a[2] then pts[#pts + 1] = { a[1], a[2], a[3] or 0, a[4], a[5] } end
    end
  end
  return pts
end

-- points / hold / name / control as CurveShare.send takes them. Returns true, number of points, id  or  false, message.
function M.send(points, hold, name, control)
  local text, n
  if control and #control >= 2 then text, n = CurveShare.encodeControl(control, name)
  else text, n = CurveShare.encode(points, hold, name) end
  if not text then return false, n end
  local source, short = splitName(name)
  local id, err = ReaCat.send{ kind = "curve", source = source, name = short, points = pointsOf(text) }
  if not id then return false, err end
  CurveShare.send(points, hold, name, control)          -- TEMPORARY, see the header
  return true, n, id
end

return M
