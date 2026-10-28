-- ============================================================
--   CurveShare.lua
--   Sends the current curve to the other tools of the family.
--   The format is plain text, the same for every tool:
--
--     ReaCurve 1
--     name=ReaNvelopes: RAND
--     0.000000,0.500000
--     ...
--     1.000000,0.250000
--
--   t and v are both 0..1, t ascending, first t = 0 and last t = 1, straight lines
--   between the points. A receiver lays the curve over the whole X axis and the
--   whole Y axis of its active envelope: v = 0 is the bottom, v = 1 the top, taken
--   as sent. What the values mean is the user's choice, made here.
--   It travels through REAPER's ExtState (section "ReaCurve", key "current",
--   persistent, so it survives a restart).
-- ============================================================

local M = {}

M.SECTION, M.KEY = "ReaCurve", "current"

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
  local lines = { "ReaCurve 1", "name=" .. tostring(name or ""):gsub("[\r\n]", " ") }
  for _, q in ipairs(out) do lines[#lines + 1] = string.format("%.6f,%.6f", q.t, q.v) end
  return table.concat(lines, "\n") .. "\n", #out
end

function M.send(points, hold, name)
  local text, n = M.encode(points, hold, name)
  if not text then return false, n end
  reaper.SetExtState(M.SECTION, M.KEY, text, true)
  return true, n
end

return M
