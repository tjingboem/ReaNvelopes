-- ============================================================
--   DRAWState.lua
--   Shared mutable state for the DRAW shape editor.
-- ============================================================

local M = {}

-- ── Shape mode ────────────────────────────────────────────────
-- "linear" : straight lines between points
-- "smooth" : bezier/spline between points
-- "step"   : flat horizontal until next point, instant jump
M.shape_mode   = "linear"
M.resolution   = 8      -- target point count after freehand simplification (2–64)
M.freehand_pts = nil    -- raw stroke [{tn,v}] while drawing, nil when idle

-- ── Control points ────────────────────────────────────────────
-- Each point: { tn=0..1, v=0..1 }
-- Always has anchor at tn=0 and tn=1
-- User can add/move/delete points in between
M.points = {
    { tn=0.0, v=0.5 },   -- left anchor
    { tn=1.0, v=0.5 },   -- right anchor
}

-- ── Preview cache ─────────────────────────────────────────────
M.preview_pts = {}   -- dense [{tn, v}] for display
M.dirty       = true -- needs redraw

-- ── Helpers ──────────────────────────────────────────────────

-- Sort points by tn, keeping anchors at 0 and 1
function M.sortPoints()
    table.sort(M.points, function(a, b) return a.tn < b.tn end)
    -- Ensure anchors exist
    if M.points[1].tn > 0.001 then
        table.insert(M.points, 1, { tn=0.0, v=M.points[1].v })
    end
    if M.points[#M.points].tn < 0.999 then
        M.points[#M.points+1] = { tn=1.0, v=M.points[#M.points].v }
    end
end

-- Add a point at tn, v (sampled from current shape)
function M.addPoint(tn, v)
    tn = math.max(0.001, math.min(0.999, tn))
    -- Don't add if too close to existing point
    for _, p in ipairs(M.points) do
        if math.abs(p.tn - tn) < 0.01 then return false end
    end
    M.points[#M.points+1] = { tn=tn, v=v }
    M.sortPoints()
    M.dirty = true
    return true
end

-- Delete point at index (cannot delete anchors at index 1 and #points)
function M.deletePoint(idx)
    if idx <= 1 or idx >= #M.points then return false end
    table.remove(M.points, idx)
    M.dirty = true
    return true
end

-- Sample current shape at normalized time t
function M.sampleAt(t)
    local pts = M.points
    if #pts == 0 then return 0.5 end
    if t <= pts[1].tn then return pts[1].v end
    if t >= pts[#pts].tn then return pts[#pts].v end
    for i = 1, #pts - 1 do
        if pts[i].tn <= t and t <= pts[i+1].tn then
            local span = pts[i+1].tn - pts[i].tn
            if span < 1e-9 then return pts[i].v end
            if M.shape_mode == "step" then
                return pts[i].v
            else
                local frac = (t - pts[i].tn) / span
                if M.shape_mode == "smooth" then
                    -- Smoothstep
                    frac = frac * frac * (3 - 2 * frac)
                end
                return pts[i].v + frac * (pts[i+1].v - pts[i].v)
            end
        end
    end
    return pts[#pts].v
end

-- Build dense preview points for display
function M.buildPreview()
    local N   = 128
    local out = {}
    for i = 0, N do
        local t = i / N
        out[#out+1] = { tn=t, v=M.sampleAt(t) }
    end
    M.preview_pts = out
    M.dirty       = false
end

-- Convert points to {x, y, s} format for Editor
-- s: 0=linear, 1=step, 2=smooth
function M.toSendPts()
    local shape_id = M.shape_mode == "step" and 1
                  or M.shape_mode == "smooth" and 2
                  or 0
    local pts = {}
    for _, p in ipairs(M.points) do
        pts[#pts+1] = { x=p.tn, y=p.v, s=shape_id }
    end
    return pts
end

-- Convert points to gen_pts format for preset saving
function M.toGenPts()
    local shape_id = M.shape_mode == "step" and 1 or 0
    local pts = {}
    for _, p in ipairs(M.points) do
        pts[#pts+1] = { tn=p.tn, v=p.v, shape=shape_id, tension=0.0 }
    end
    return pts
end

-- Convert gen_pts format back to DRAW points
function M.fromGenPts(gen_pts)
    if not gen_pts or #gen_pts == 0 then return end
    M.points = {}
    for _, p in ipairs(gen_pts) do
        M.points[#M.points+1] = { tn=p.tn, v=p.v }
    end
    M.dirty = true
end

-- Reset to flat line at center
function M.reset()
    M.points = {
        { tn=0.0, v=0.5 },
        { tn=1.0, v=0.5 },
    }
    M.shape_mode = "linear"
    M.dirty      = true
end

-- Distance of pts[i] from the line pts[a] -> pts[b]
local function devFrom(pts, a, b, i)
    local ax, ay, bx, by = pts[a].tn, pts[a].v, pts[b].tn, pts[b].v
    local dx, dy = bx - ax, by - ay
    local len2 = dx*dx + dy*dy
    local px, py = pts[i].tn, pts[i].v
    if len2 < 1e-12 then return math.sqrt((px-ax)^2 + (py-ay)^2) end
    local t = math.max(0, math.min(1, ((px-ax)*dx + (py-ay)*dy) / len2))
    return math.sqrt((px - ax - t*dx)^2 + (py - ay - t*dy)^2)
end

-- Commit a freehand stroke: keep exactly M.resolution points (fewer only if the
-- stroke has fewer) and replace current points (anchors at 0 and 1).
-- Best-first: start with the two ends, then repeatedly add the stroke point
-- that lies farthest from the line through its neighbours. (The earlier
-- epsilon loop dropped equal-sized peaks all at once and could jump from
-- many points to 2.)
function M.commitFreehand(raw_pts)
    if not raw_pts or #raw_pts < 2 then return end
    local target = math.max(2, math.min(64, M.resolution))
    local n = #raw_pts
    local keep = { [1] = true, [n] = true }
    local kept = 2
    -- segments { a, b, worstIdx, worstDev }
    local function segment(a, b)
        local wi, wd = nil, 0
        for i = a + 1, b - 1 do
            local d = devFrom(raw_pts, a, b, i)
            if d > wd then wi, wd = i, d end
        end
        return { a, b, wi, wd }
    end
    local segs = { segment(1, n) }
    while kept < target do
        local bestK, bestD = nil, 1e-9
        for k, sg in ipairs(segs) do
            if sg[3] and sg[4] > bestD then bestK, bestD = k, sg[4] end
        end
        if not bestK then break end
        local sg = table.remove(segs, bestK)
        keep[sg[3]] = true
        kept = kept + 1
        segs[#segs+1] = segment(sg[1], sg[3])
        segs[#segs+1] = segment(sg[3], sg[2])
    end
    local simplified = {}
    for i = 1, n do if keep[i] then simplified[#simplified+1] = raw_pts[i] end end
    -- Strip X-reversals: remove any point whose tn is not strictly
    -- greater than the previous one (handles Z-strokes, backtracking).
    local monotone = { simplified[1] }
    for i = 2, #simplified do
        if simplified[i].tn > monotone[#monotone].tn then
            monotone[#monotone+1] = simplified[i]
        end
    end
    if #monotone < 2 then return end  -- degenerate after filtering

    -- Build new points with anchors
    M.points = {}
    for i, p in ipairs(monotone) do
        local tn = (i == 1) and 0.0 or (i == #monotone) and 1.0
                   or math.max(0.001, math.min(0.999, p.tn))
        M.points[#M.points+1] = { tn=tn, v=math.max(0, math.min(1, p.v)) }
    end
    -- Ensure anchors at 0 and 1
    M.points[1].tn = 0.0
    M.points[#M.points].tn = 1.0
    M.dirty = true
end

return M
