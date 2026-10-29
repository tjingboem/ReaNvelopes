-- ============================================================
--   CurveShare.lua
--   Sends the current curve to the other tools of the family.
--   The format is plain text, the same for every tool:
--
--     ReaCurve 1
--     name=ReaNvelopes: RAND
--     0.000000,0.500000,2
--     ...
--     1.000000,0.250000,0
--
--   t and v are both 0..1, t ascending, first t = 0 and last t = 1. The optional third
--   number is the shape of the segment that leaves the point: 0 straight line (also
--   when it is missing), 1 step (holds the value, then jumps), 2 slow start and end,
--   3 fast start, 4 fast end. A receiver lays the curve over the whole X axis and the
--   whole Y axis of its active envelope: v = 0 is the bottom, v = 1 the top, taken
--   as sent. What the values mean is the user's choice, made here.
--   It travels through REAPER's ExtState (section "ReaCurve", key "current",
--   persistent, so it survives a restart).
-- ============================================================

local M = {}

M.SECTION, M.KEY = "ReaCurve", "current"


-- Ramer-Douglas-Peucker: drops the points that lie within `tol` (in value) of the straight
-- line between their neighbours. Used for a curve that comes as many samples (OSC).
local function simplify(p, tol)
  local keep = { [1] = true, [#p] = true }
  local function rec(a, b)
    local maxd, idx = 0, nil
    for i = a + 1, b - 1 do
      local t  = (p[i].t - p[a].t) / math.max(p[b].t - p[a].t, 1e-12)
      local d  = math.abs(p[i].v - (p[a].v + (p[b].v - p[a].v) * t))
      if d > maxd then maxd, idx = d, i end
    end
    if idx and maxd > tol then keep[idx] = true ; rec(a, idx) ; rec(idx, b) end
  end
  rec(1, #p)
  local out = {}
  for i, q in ipairs(p) do if keep[i] then out[#out + 1] = q end end
  return out
end

-- Control points with their segment shapes: [{tn, v, shape}] (RAND, DRAW).
function M.encodeControl(ctrl, name)
  if not ctrl or #ctrl < 2 then return nil, "no curve yet: generate a shape first" end
  local p = {}
  for i, q in ipairs(ctrl) do p[i] = { t = q.tn, v = q.v, shape = q.shape or 0 } end
  table.sort(p, function(a, b) return a.t < b.t end)
  for _, q in ipairs(p) do
    q.t = math.max(0.0, math.min(1.0, q.t))
    q.v = math.max(0.0, math.min(1.0, q.v))
  end
  p[1].t, p[#p].t = 0.0, 1.0
  p[#p].shape = 0
  local lines = { "ReaCurve 1", "name=" .. (tostring(name or ""):gsub("[\r\n]", " ")) }
  for _, q in ipairs(p) do lines[#lines + 1] = string.format("%.6f,%.6f,%d", q.t, q.v, q.shape) end
  return table.concat(lines, "\n") .. "\n", #p
end

-- points: [{tn, v}] (tn 0..1). hold: a staircase, kept as straight lines by
-- adding the point where each step ends.
function M.encode(points, hold, name)
  if not points or #points < 2 then return nil, "no curve yet: generate a shape first" end
  local p = {}
  for i, q in ipairs(points) do p[i] = { t = q.tn, v = q.v } end
  table.sort(p, function(a, b) return a.t < b.t end)
  local out = {}
  for i, q in ipairs(p) do
    if hold and i > 1 then out[#out + 1] = { t = q.t, v = p[i - 1].v } end
    out[#out + 1] = { t = q.t, v = q.v }
  end
  for _, q in ipairs(out) do
    q.t = math.max(0.0, math.min(1.0, q.t))
    q.v = math.max(0.0, math.min(1.0, q.v))
  end
  out[1].t, out[#out].t = 0.0, 1.0     -- the curve covers the whole X axis
  if #out > 40 and not hold then out = simplify(out, 0.002) end   -- samples: keep what the eye can see
  local lines = { "ReaCurve 1", "name=" .. tostring(name or ""):gsub("[\r\n]", " ") }
  for _, q in ipairs(out) do lines[#lines + 1] = string.format("%.6f,%.6f", q.t, q.v) end
  return table.concat(lines, "\n") .. "\n", #out
end

-- control: [{tn, v, shape}] when the tool has real control points, else nil (dense samples are used)
function M.send(points, hold, name, control)
  local text, n
  if control and #control >= 2 then text, n = M.encodeControl(control, name)
  else text, n = M.encode(points, hold, name) end
  if not text then return false, n end
  reaper.SetExtState(M.SECTION, M.KEY, text, true)
  return true, n
end

return M
