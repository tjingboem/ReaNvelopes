-- ============================================================
--   DRAWPresets.lua  — file-based presets in DRAWPresets/
--   One .lua file per preset, stored in a "DRAWPresets/" folder
--   located next to this script file.
-- ============================================================
local M = {}
local S = require("DRAWState")

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
    _preset_dir = script_path .. "DRAWPresets/"
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
        ("  shape_mode='%s',"):format(S.shape_mode or "linear"),
        "  points={",
    }
    for _, p in ipairs(S.points or {}) do
        t[#t+1] = ("    { tn=%.6f, v=%.6f },"):format(p.tn, p.v)
    end
    t[#t+1] = "  },"
    t[#t+1] = "}"
    return table.concat(t, "\n")
end

local function applyData(d)
    if type(d) ~= "table" then return false end
    S.shape_mode = d.shape_mode or "linear"
    if type(d.points) == "table" and #d.points >= 2 then
        S.points = {}
        for _, p in ipairs(d.points) do
            S.points[#S.points+1] = { tn=p.tn or 0, v=p.v or 0.5 }
        end
    end
    S.dirty = true
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
    S.reset()
end

return M
