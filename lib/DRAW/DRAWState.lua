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
M.resolution   = 8      -- target point count after freehand simplification (2–32)
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

-- ── Ramer-Douglas-Peucker simplification ─────────────────────
-- Reduces a polyline to at most max_pts points while preserving shape.
local function rdpReduce(pts, epsilon)
    if #pts <= 2 then return pts end
    -- Find point with max distance from line (pts[1] → pts[#pts])
    local ax, ay = pts[1].tn, pts[1].v
    local bx, by = pts[#pts].tn, pts[#pts].v
    local max_d, max_i = 0, 1
    local dx, dy = bx - ax, by - ay
    local len2 = dx*dx + dy*dy
    for i = 2, #pts - 1 do
        local px, py = pts[i].tn, pts[i].v
        local d
        if len2 < 1e-12 then
            d = math.sqrt((px-ax)^2 + (py-ay)^2)
        else
            local t = math.max(0, math.min(1, ((px-ax)*dx + (py-ay)*dy) / len2))
            local qx, qy = ax + t*dx, ay + t*dy
            d = math.sqrt((px-qx)^2 + (py-qy)^2)
        end
        if d > max_d then max_d = d; max_i = i end
    end
    if max_d > epsilon then
        local left  = rdpReduce({table.unpack(pts, 1, max_i)},   epsilon)
        local right = rdpReduce({table.unpack(pts, max_i, #pts)}, epsilon)
        local result = {}
        for _, p in ipairs(left)  do result[#result+1] = p end
        for i = 2, #right do result[#result+1] = right[i] end
        return result
    else
        return { pts[1], pts[#pts] }
    end
end

-- Commit a freehand stroke: simplify to M.resolution points and
-- replace current points (keeping anchors at 0 and 1).
function M.commitFreehand(raw_pts)
    if not raw_pts or #raw_pts < 2 then return end
    -- Start with a small epsilon and iterate until we're near resolution
    local target = math.max(2, math.min(32, M.resolution))
    local epsilon = 0.001
    local simplified = raw_pts
    for _ = 1, 20 do
        simplified = rdpReduce(raw_pts, epsilon)
        if #simplified <= target then break end
        epsilon = epsilon * 1.5
    end
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
