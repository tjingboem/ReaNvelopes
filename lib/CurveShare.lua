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
--   3 fast start, 4 fast end, 5 a cubic curve whose two handle levels follow as the fourth and
--   fifth number ("t,v,5,c1,c2": the handles sit a third and two thirds across the segment, at the
--   levels c1 and c2, all 0..1). A receiver lays the curve over the whole X axis and the
--   whole Y axis of its active envelope: v = 0 is the bottom, v = 1 the top, taken
--   as sent. What the values mean is the user's choice, made here.
--   It travels through REAPER's ExtState (section "ReaCurve", key "current",
--   persistent, so it survives a restart).
-- ============================================================

local M = {}

M.SECTION, M.KEY = "ReaCurve", "current"


-- Cubic fit. One segment of the samples p[a..b] becomes a cubic bezier with its handles a third and
-- two thirds across (levels c1, c2, least squares); a curve is cut where the fit is worst until every
-- piece is within `tol` (in value). Returns the breakpoints without the last sample, each with the
-- shape of the segment that leaves it: 0 when it is a straight line, else 5 with c1 and c2.
local function clamp01(x) return math.max(0.0, math.min(1.0, x)) end

local function fitSegment(p, a, b)
  local ta, va, vb = p[a].t, p[a].v, p[b].v
  local span = math.max(p[b].t - ta, 1e-12)
  local s11, s12, s22, r1, r2 = 0, 0, 0, 0, 0
  for i = a + 1, b - 1 do
    local u = (p[i].t - ta) / span
    local w = 1 - u
    local b1, b2 = 3 * w * w * u, 3 * w * u * u
    local r = p[i].v - va * w * w * w - vb * u * u * u
    s11, s12, s22 = s11 + b1 * b1, s12 + b1 * b2, s22 + b2 * b2
    r1, r2 = r1 + b1 * r, r2 + b2 * r
  end
  local det = s11 * s22 - s12 * s12
  local c1, c2 = va + (vb - va) / 3, va + (vb - va) * 2 / 3
  if b - a >= 3 and math.abs(det) > 1e-12 then
    c1 = math.max(-0.5, math.min(1.5, (r1 * s22 - r2 * s12) / det))   -- a handle may reach past 0..1 at a peak;
    c2 = math.max(-0.5, math.min(1.5, (s11 * r2 - s12 * r1) / det))   -- the curve itself must not (checked below)
  end
  local err, at = 0, nil
  for i = a + 1, b - 1 do
    local u = (p[i].t - ta) / span
    local w = 1 - u
    local d = math.abs(w * w * w * va + 3 * w * w * u * c1 + 3 * w * u * u * c2 + u * u * u * vb - p[i].v)
    if d > err then err, at = d, i end
  end
  for k = 1, 15 do                               -- a piece that leaves 0..1 does not count as a good fit
    local u = k / 16
    local w = 1 - u
    local y = w * w * w * va + 3 * w * w * u * c1 + 3 * w * u * u * c2 + u * u * u * vb
    local out = math.max(y - 1.0, -y)
    if out > 0.002 then err = math.max(err, out + M.TOLERANCE) ; at = at or (a + math.max(1, math.floor((b - a) * u))) end
  end
  return c1, c2, err, at
end

local function fit(p, tol)
  local out = {}
  local function rec(a, b)
    local c1, c2, err, at = fitSegment(p, a, b)
    if err <= tol or b - a <= 1 or not at then
      local va, vb = p[a].v, p[b].v
      local straight = math.abs(c1 - (va + (vb - va) / 3)) < 1e-3 and math.abs(c2 - (va + (vb - va) * 2 / 3)) < 1e-3
      if straight then out[#out + 1] = { t = p[a].t, v = va, shape = 0 }
      else out[#out + 1] = { t = p[a].t, v = va, shape = 5, c1 = c1, c2 = c2 } end
    else
      rec(a, at) ; rec(at, b)
    end
  end
  -- Cut first at the peaks and valleys of the samples, so a wave becomes one cubic per half period
  -- instead of being cut wherever the fit happens to be worst.
  local cuts, last_dir = { 1 }, 0
  for i = 2, #p do
    local d = p[i].v - p[i - 1].v
    if math.abs(d) > 1e-6 then
      local dir = d > 0 and 1 or -1
      if last_dir ~= 0 and dir ~= last_dir then cuts[#cuts + 1] = i - 1 end
      last_dir = dir
    end
  end
  if cuts[#cuts] ~= #p then cuts[#cuts + 1] = #p end
  for k = 1, #cuts - 1 do rec(cuts[k], cuts[k + 1]) end
  return out
end

-- Control points with their segment shapes: [{tn, v, shape}] (RAND, DRAW).
function M.encodeControl(ctrl, name)
  if not ctrl or #ctrl < 2 then return nil, "no curve yet: generate a shape first" end
  local p = {}
  for _, q in ipairs(ctrl) do
    if q.shape == 5 and q.samples then       -- a bezier segment: a few cubic pieces instead of its samples
      for _, f in ipairs(fit(q.samples, M.TOLERANCE_SEGMENT)) do p[#p + 1] = f end
    else
      p[#p + 1] = { t = q.tn, v = q.v, shape = q.shape or 0, c1 = q.c1, c2 = q.c2 }
    end
  end
  table.sort(p, function(a, b) return a.t < b.t end)
  for _, q in ipairs(p) do
    q.t, q.v = clamp01(q.t), clamp01(q.v)
  end
  p[1].t, p[#p].t = 0.0, 1.0
  p[#p].shape = 0
  local lines = { "ReaCurve 1", "name=" .. (tostring(name or ""):gsub("[\r\n]", " ")) }
  for _, q in ipairs(p) do
    if q.shape == 5 and q.c1 and q.c2 then
      lines[#lines + 1] = string.format("%.6f,%.6f,5,%.6f,%.6f", q.t, q.v, q.c1, q.c2)
    else
      lines[#lines + 1] = string.format("%.6f,%.6f,%d", q.t, q.v, (q.shape == 5) and 0 or q.shape)
    end
  end
  return table.concat(lines, "\n") .. "\n", #p
end

M.TOLERANCE = 0.004           -- a dense curve (OSC) may differ from its fit by this much (0..1 scale)
M.TOLERANCE_SEGMENT = 0.01   -- a bezier segment of RAND: 1%, it is a random curve anyway

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
  if #out > 8 and not hold then                -- many samples (OSC): a few cubic pieces
    local f = fit(out, M.TOLERANCE)
    f[#f + 1] = { t = 1.0, v = out[#out].v, shape = 0 }
    local ctrl = {}
    for i, q in ipairs(f) do ctrl[i] = { tn = q.t, v = q.v, shape = q.shape, c1 = q.c1, c2 = q.c2 } end
    return M.encodeControl(ctrl, name)
  end
  local lines = { "ReaCurve 1", "name=" .. (tostring(name or ""):gsub("[\r\n]", " ")) }
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
