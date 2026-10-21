-- ============================================================
--   RANDPresets.lua  — file-based presets in RANDPresets/
--   One .lua file per preset, stored in a "RANDPresets/" folder
--   located next to this script file (stable across projects).
-- ============================================================
local M = {}
local S = require("RANDState")

local _preset_dir = nil

function M.init()
    local script_path = ""
    if reaper.get_action_context then
        local _, sp = reaper.get_action_context()
        script_path = sp:match("^(.+[/\\])") or ""
    end
    if script_path == "" then
        script_path = reaper.GetResourcePath() .. "/"
    end
    _preset_dir = script_path .. "RANDPresets/"
    if reaper.RecursiveCreateDirectory then
        reaper.RecursiveCreateDirectory(_preset_dir, 0)
    end
    return _preset_dir
end

function M.getDir() return _preset_dir end

local function presetPath(name)
    return _preset_dir .. name .. ".lua"
end

local function sanitizeName(name)
    local parts = {}
    for seg in (name .. "/"):gmatch("([^/]*)/") do
        seg = seg:gsub('[\\:*?"<>|]', "_"):gsub("^%s+", ""):gsub("%s+$", "")
        if seg ~= "" then parts[#parts+1] = seg end
    end
    return table.concat(parts, "/")
end

local function serialize()
    local t = {
        "return {",
        ("  seed=%d,"):format(S.seed or 0),
        ("  shape_seed=%d,"):format(S.shape_seed or 0),
        ("  gen_mode='%s',"):format(S.gen_mode or "free"),
        ("  num_points=%d,"):format(S.num_points or 8),
        ("  pts_per_div=%d,"):format(S.pts_per_div or 2),
        ("  shape=%d,"):format(S.shape or 0),
        ("  tension=%.6f,"):format(S.tension or 0),
        ("  amp_range=%d,"):format(S.amp_range or 1),
        ("  amp_free=%s,"):format(tostring(S.amp_free ~= false)),
        ("  quant_steps=%d,"):format(S.quant_steps or 4),
        ("  amp_scale=%.6f,"):format(S.amp_scale or 1.0),
        ("  amp_offset=%.6f,"):format(S.amp_offset or 0.0),
        "  gen_pts={",
    }
    for _, p in ipairs(S.gen_pts or {}) do
        t[#t+1] = ("    { tn=%.6f, v=%.6f, shape=%d, tension=%.6f },"):format(
            p.tn, p.v, p.shape or 0, p.tension or 0)
    end
    t[#t+1] = "  },"
    t[#t+1] = "}"
    return table.concat(t, "\n")
end

local function applyData(d)
    if type(d) ~= "table" then return false end
    S.seed        = d.seed        or S.seed
    S.shape_seed  = d.shape_seed  or S.shape_seed
    S.gen_mode    = d.gen_mode    or S.gen_mode
    S.num_points  = d.num_points  or S.num_points
    S.pts_per_div = d.pts_per_div or S.pts_per_div
    S.shape       = d.shape       or S.shape
    S.tension     = d.tension     or S.tension
    S.amp_range   = d.amp_range   or S.amp_range
    S.amp_free    = (d.amp_free ~= false)
    S.quant_steps = d.quant_steps or S.quant_steps
    S.amp_scale   = d.amp_scale   or 1.0
    S.amp_offset  = d.amp_offset  or 0.0
    -- Restore gen_pts if present (allows deterministic geometric shapes)
    if type(d.gen_pts) == "table" and #d.gen_pts > 0 then
        S.gen_pts = {}
        for _, p in ipairs(d.gen_pts) do
            S.gen_pts[#S.gen_pts+1] = {
                tn      = p.tn      or 0,
                v       = p.v       or 0.5,
                shape   = p.shape   or 0,
                tension = p.tension or 0,
            }
        end
        S.preview_dirty = true
    else
        S.invalidatePreview()
    end
    return true
end

function M.exists(name)
    if not _preset_dir or name == "" then return false end
    local f = io.open(presetPath(name), "r")
    if f then f:close(); return true end
    return false
end

function M.save(name, overwrite)
    if not _preset_dir then return nil, "not initialized" end
    name = sanitizeName(name)
    if name == "" then return nil, "empty name" end
    if not overwrite and M.exists(name) then return nil, "exists" end
    local path = presetPath(name)
    local dir  = path:match("^(.+[/\\])")
    if dir and reaper.RecursiveCreateDirectory then
        reaper.RecursiveCreateDirectory(dir, 0)
    end
    local f = io.open(path, "w")
    if not f then return nil, "cannot write to: " .. path end
    f:write(serialize()); f:close()
    return name
end

function M.load(name)
    if not _preset_dir then return false, "not initialized" end
    local fn, err = loadfile(presetPath(name))
    if not fn then return false, err end
    local ok, data = pcall(fn)
    if not ok then return false, tostring(data) end
    return applyData(data)
end

function M.delete(name)
    if not _preset_dir or name == "" then return false end
    os.remove(presetPath(name))
    return true
end

function M.list()
    if not _preset_dir then return {} end
    local names = {}
    if reaper.EnumerateFiles then
        local function scan(dir, prefix)
            local i = 0
            while true do
                local f = reaper.EnumerateFiles(dir, i)
                if not f then break end
                if f:match("%.lua$") then
                    names[#names+1] = prefix .. f:sub(1, -5)
                end
                i = i + 1
            end
            if reaper.EnumerateSubdirectories then
                local j = 0
                while true do
                    local d = reaper.EnumerateSubdirectories(dir, j)
                    if not d then break end
                    scan(dir .. d .. "/", prefix .. d .. "/")
                    j = j + 1
                end
            end
        end
        scan(_preset_dir, "")
    end
    table.sort(names, function(a, b)
        local af = a:match("^.+/")
        local bf = b:match("^.+/")
        if not af and not bf then return a < b end
        if af and not bf then return true end
        if not af and bf then return false end
        return a < b
    end)
    return names
end

function M.initDefaults()
    S.seed        = os.time()
    S.shape_seed  = os.time()
    S.gen_mode    = "free"
    S.num_points  = 8
    S.pts_per_div = 2
    S.shape       = 0
    S.tension     = 0.0
    S.amp_range   = 1
    S.amp_free    = true
    S.quant_steps = 4
    S.amp_scale   = 1.0
    S.amp_offset  = 0.0
    S.invalidatePreview()
end

return M
