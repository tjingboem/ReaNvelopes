-- ============================================================
--   ReaCatSend.lua  —  "Send to ReaCat and the world" for ReaNvelopes' OUTPUT section.
--   The curve is fitted by CurveFit (control points with their shapes, bezier segments as cubic pieces), then stored in the
--   ReaCat catalogue (lib/ReaCat.lua, spec: ReaCat/doc/ReaCat_Spec.md).
-- ============================================================

local CurveFit = require("CurveFit")
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

local function encoded(points, hold, name, control)
  local text, n
  if control and #control >= 2 then text, n = CurveFit.encodeControl(control, name)
  else text, n = CurveFit.encode(points, hold, name) end
  return text, n
end

-- points / hold / name / control: the preview points, whether it is a staircase, "ReaNvelopes: RAND", and the control points of the shape (or nil). Returns true, number of points, id  or  false, message.
function M.send(points, hold, name, control)
  local text, n = encoded(points, hold, name, control)
  if not text then return false, n end
  local source, short = splitName(name)
  local id, err = ReaCat.send{ kind = "curve", source = source, name = short, points = pointsOf(text) }
  if not id then return false, err end
  -- What is sent comes out of this project, so ReaCat shows where it is used (red border, "used in this project: ReaNvelopes: in ReaNvelopes").
  local entry = ReaCat.get(id)
  if entry and entry.hash and ReaCat.useAdd then
    pcall(ReaCat.useAdd, { hash = entry.hash, what = "param", guid = "send/" .. tostring(source) .. "/" .. tostring(short), tool = "ReaNvelopes",
                           label = tostring(source) .. " " .. tostring(short) })
  end
  return true, n, id
end

-- A curve that was WRITTEN into the project (an automation item, MIDI CC, note values) is filed in ReaCat too (tag "written") and marked as used
-- by the place it went to (spec section 11). place = { what = "item", item = <MediaItem> }  or  { what = "ai", env = <envelope>, idx = <index> }
-- or { what = "param", key = "..." }. Never makes trouble for the write: returns id, or nil and the reason.
function M.fileWritten(points, hold, name, control, place)
  local text, n = encoded(points, hold, name, control)
  if not text then return nil, n end
  local source, short = splitName(name)
  local id, err = ReaCat.send{ kind = "curve", source = source, name = short, points = pointsOf(text), tags = "written" }
  if not id then return nil, err end
  local entry = ReaCat.get(id)
  if not entry or not place then return id end
  if place.what == "item" and place.item then
    ReaCat.markItem(place.item, entry, { tool = "ReaNvelopes" })
  else
    local key = place.key
    if place.what == "ai" and place.env then
      local g = ""
      if reaper.GetSetEnvelopeInfo_String then
        for _, v in ipairs({ reaper.GetSetEnvelopeInfo_String(place.env, "GUID", "", false) }) do if type(v) == "string" then g = v end end
      end
      key = "ai:" .. g .. ":" .. tostring(place.idx or 0)
    end
    ReaCat.useAdd{ hash = entry.hash, what = place.what or "param", guid = key or "", tool = "ReaNvelopes", label = entry.source .. " " .. entry.name }
  end
  return id
end

return M
