--[[----------------------------------------------------------------------------
  Curve.lua — the unified CURVE format (family copy of ReaAC's core/reaac_curve.lua), every tool can output besides
  notes (a sibling of reaac_note.lua)

    curve = { lengthBeats = <number>, hold = <bool>, points = { {t, v}, ... } }

  t is in beats from the start of the curve, ascending, the first point at 0
  and the last at lengthBeats. v is normalized 0..1; the writers in
  reaac_curveout.lua map it to a CC value or to the range of an envelope.
  hold = true means a value is kept until the next point (sample and hold, a
  staircase); false means straight lines between the points.

  Pure logic, no REAPER calls, so it can be tested offline with lua5.4.

  Why a curve and not only notes: a module generates a series. Notes are one
  view of it (the series sampled at the step of the notes); a MIDI CC lane or
  a parameter envelope is the series itself, at whatever resolution the module
  generated it. Writing the curve out directly keeps the resolution.
--------------------------------------------------------------------------------]]

local M = {}

-- points: list of {t, v}; lengthBeats defaults to the last point's t.
function M.new(points, lengthBeats, hold)
  local pts = {}
  for i, p in ipairs(points) do
    pts[i] = { t = p.t, v = math.max(0.0, math.min(1.0, p.v)) }
  end
  local len = lengthBeats or (#pts > 0 and pts[#pts].t or 0.0)
  return { points = pts, lengthBeats = len, hold = hold and true or false }
end

-- Value of the curve at beat t (clamped to the first and last point).
function M.eval(curve, t)
  local pts = curve.points
  local n = #pts
  if n == 0 then return 0.0 end
  if t <= pts[1].t then return pts[1].v end
  if t >= pts[n].t then return pts[n].v end
  -- binary search for the segment [lo, lo+1] that contains t
  local lo, hi = 1, n
  while hi - lo > 1 do
    local mid = (lo + hi) // 2
    if pts[mid].t <= t then lo = mid else hi = mid end
  end
  local a, b = pts[lo], pts[hi]
  if curve.hold then return a.v end
  local span = b.t - a.t
  if span <= 0 then return b.v end
  return a.v + (b.v - a.v) * ((t - a.t) / span)
end

-- A new curve of `count` (>= 2) points spread evenly over the whole length,
-- read from `curve` (linear or hold, as the source curve says).
function M.resample(curve, count)
  count = math.max(2, math.floor(count))
  local len = curve.lengthBeats
  local pts = {}
  for i = 1, count do
    local t = len * (i - 1) / (count - 1)
    pts[i] = { t = t, v = M.eval(curve, t) }
  end
  return M.new(pts, len, curve.hold)
end

-- The same series read only at multiples of `stepBeats`, kept as a staircase
-- (hold). This is the curve a row of notes shows.
function M.sampleAtSteps(curve, stepBeats)
  local len = curve.lengthBeats
  local pts = {}
  local k = 0
  while true do
    local t = k * stepBeats
    if t > len + 1e-9 then break end
    pts[#pts + 1] = { t = math.min(t, len), v = M.eval(curve, t) }
    k = k + 1
  end
  return M.new(pts, len, true)
end

-- Fewer points for the same shape. Linear curves: Ramer-Douglas-Peucker with
-- `tolerance` as the largest allowed distance in v (0..1). Hold curves:
-- points whose value equals the one before are dropped. The first and last
-- points always stay. tolerance <= 0 returns a copy unchanged.
function M.thin(curve, tolerance)
  local pts = curve.points
  local n = #pts
  if n <= 2 or not tolerance or tolerance <= 0 then
    return M.new(pts, curve.lengthBeats, curve.hold)
  end

  local keep = {}
  if curve.hold then
    keep[1] = true
    for i = 2, n - 1 do
      if math.abs(pts[i].v - pts[i - 1].v) > tolerance then keep[i] = true end
    end
    keep[n] = true
  else
    keep[1], keep[n] = true, true
    -- iterative RDP (an explicit stack, so a long curve cannot overflow the Lua stack)
    local stack = { { 1, n } }
    while #stack > 0 do
      local seg = table.remove(stack)
      local a, b = seg[1], seg[2]
      local ta, va, tb, vb = pts[a].t, pts[a].v, pts[b].t, pts[b].v
      local worst, worstIdx = 0.0, nil
      for i = a + 1, b - 1 do
        local expect
        if tb - ta <= 0 then expect = va
        else expect = va + (vb - va) * ((pts[i].t - ta) / (tb - ta)) end
        local d = math.abs(pts[i].v - expect)
        if d > worst then worst, worstIdx = d, i end
      end
      if worstIdx and worst > tolerance then
        keep[worstIdx] = true
        stack[#stack + 1] = { a, worstIdx }
        stack[#stack + 1] = { worstIdx, b }
      end
    end
  end

  local out = {}
  for i = 1, n do
    if keep[i] then out[#out + 1] = { t = pts[i].t, v = pts[i].v } end
  end
  return M.new(out, curve.lengthBeats, curve.hold)
end

-- Curves read from a finished note list (reaac_note.lua notes), for modules whose output is a rhythm or a pattern and
-- has no continuous series of its own (L-System, Euclidean, GA Rhythm, Sieve). Returns { {name, curve, hold}, ... }:
--   Gate      1 while a note sounds, 0 between (a square curve): the rhythm itself
--   Pitch     the highest pitch that starts at each note time, normalized to the lowest..highest pitch of the list
--   Velocity  the mean velocity of the notes that start at each time, / 127
-- All three are hold curves (a value stays until the next note) from beat 0 to the end of the last note.
function M.fromNotes(notes)
  local n = #notes
  if n == 0 then return {} end
  local sorted = {}
  for i, nt in ipairs(notes) do sorted[i] = nt end
  table.sort(sorted, function(a, b) return a.start < b.start end)
  local endBeat, pLo, pHi = 0.0, 127, 0
  for _, nt in ipairs(sorted) do
    endBeat = math.max(endBeat, nt.start + nt.duration)
    pLo, pHi = math.min(pLo, nt.pitch), math.max(pHi, nt.pitch)
  end
  local pSpan = pHi - pLo

  -- Gate: merge overlapping notes into intervals
  local gate = {}
  local curS, curE = nil, nil
  local function flush()
    if curS then
      if #gate == 0 and curS > 0 then gate[#gate + 1] = { t = 0, v = 0 } end
      gate[#gate + 1] = { t = curS, v = 1 }
      gate[#gate + 1] = { t = curE, v = 0 }
    end
  end
  for _, nt in ipairs(sorted) do
    local s0, e0 = nt.start, nt.start + nt.duration
    if curS and s0 <= curE + 1e-9 then curE = math.max(curE, e0)
    else flush(); curS, curE = s0, e0 end
  end
  flush()

  -- Pitch and velocity: one point per distinct start time
  local pitch, vel = {}, {}
  local i = 1
  while i <= n do
    local t = sorted[i].start
    local hiP, sumV, cnt = 0, 0, 0
    while i <= n and sorted[i].start <= t + 1e-9 do
      hiP = math.max(hiP, sorted[i].pitch); sumV = sumV + sorted[i].velocity; cnt = cnt + 1; i = i + 1
    end
    pitch[#pitch + 1] = { t = t, v = (pSpan > 0) and (hiP - pLo) / pSpan or 0.5 }
    vel[#vel + 1]     = { t = t, v = (sumV / cnt) / 127 }
  end
  for _, list in ipairs({ pitch, vel }) do
    if list[1].t > 0 then table.insert(list, 1, { t = 0, v = list[1].v }) end
    if list[#list].t < endBeat then list[#list + 1] = { t = endBeat, v = list[#list].v } end
  end
  return {
    { name = "Gate",     curve = M.new(gate,  endBeat, true) },
    { name = "Pitch",    curve = M.new(pitch, endBeat, true) },
    { name = "Velocity", curve = M.new(vel,   endBeat, true) },
  }
end

-- Lowest and highest v in the curve (for display).
function M.range(curve)
  local lo, hi = 1.0, 0.0
  for _, p in ipairs(curve.points) do
    if p.v < lo then lo = p.v end
    if p.v > hi then hi = p.v end
  end
  if hi < lo then return 0.0, 0.0 end
  return lo, hi
end

return M
