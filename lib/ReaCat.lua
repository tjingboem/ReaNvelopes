-- ============================================================
--   ReaCat.lua  —  the catalogue of envelopes (spec: doc/ReaCat_Spec.md, format "ReaCat 1")
--
--   Pure Lua: no ReaImGui. REAPER calls used: GetResourcePath, RecursiveCreateDirectory, EnumerateFiles,
--   GetExtState, SetExtState (all through the global `reaper`, so a stand-in works in tests).
--   An identical copy of this file lives in every tool that sends or receives; never load() file text.
--
--   ReaCat.send{ kind="curve", source=, name=, points=, beats=, range=, unit=, tags=, note= } -> id | nil, message
--   ReaCat.send{ kind="rule",  source=, name=, text=, rulekind= }                              -> id | nil, message
--   ReaCat.list(filter) / get(id) / newest(source, name) / stamp() / tags() / query(text)
--   ReaCat.update(id, {tags=, addtags=, removetags=, note=, fav=}) / delete(id) / undelete(id)
-- ============================================================

local M = {}

M.VERSION = 1
M.EXT = ".reacat"
M.MAX_POINTS = 2048
M.DEFAULT_CLEANUP = 2000

local SECTION = "ReaCat"
local KNOWN = { kind = true, source = true, name = true, saved = true, sent = true, beats = true, range = true,
                unit = true, tags = true, note = true, fav = true, rulekind = true, hash = true, seq = true, project = true, npoints = true, projectid = true }

local dirOverride
function M.setDir(path) dirOverride = path end     -- tests, or a user who wants the catalogue elsewhere
function M.dir() return dirOverride or (reaper.GetResourcePath() .. "/Data/ReaCat") end
local function trashDir() return M.dir() .. "/_trash" end

-- ---------------------------------------------------------------- small helpers

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function oneLine(s) return trim((tostring(s):gsub("[\r\n]+", " "))) end

local function escape(s) return ((tostring(s):gsub("\r", ""):gsub("\\", "\\\\"):gsub("\n", "\\n"))) end
local function unescape(s)
  return ((s:gsub("\\(.)", function(c) if c == "n" then return "\n" elseif c == "\\" then return "\\" end return "\\" .. c end)))
end

local function fnv1a(s)
  local h = 2166136261
  for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xffffffff end
  return string.format("%08x", h)
end

local function fileExists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function renameOver(from, to)
  if os.rename(from, to) then return true end
  os.remove(to)                         -- Windows will not rename over an existing file
  return os.rename(from, to)
end

local function writeFile(path, content)   -- a reader never sees half a file
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "wb")
  if not f then return nil, err end
  local ok, werr = f:write(content)
  f:close()
  if not ok then os.remove(tmp) return nil, werr end
  local rok, rerr = renameOver(tmp, path)
  if not rok then os.remove(tmp) return nil, rerr end
  return true
end

local function ensureDir(path)
  if reaper.RecursiveCreateDirectory then reaper.RecursiveCreateDirectory(path, 0) end
end

-- tags: a list, compared without case, the first spelling stays
local function splitTags(s)
  local out = {}
  for t in ((s or "") .. ","):gmatch("([^,]*),") do t = oneLine(t) if t ~= "" then out[#out + 1] = t end end
  return out
end

local function addTag(list, tag)
  tag = oneLine((tostring(tag):gsub(",", " ")))
  if tag == "" then return end
  local low = tag:lower()
  for _, t in ipairs(list) do if t:lower() == low then return end end
  list[#list + 1] = tag
end

local function removeTag(list, tag)
  local low = tostring(tag):lower()
  for i = #list, 1, -1 do if list[i]:lower() == low then table.remove(list, i) end end
end

-- ---------------------------------------------------------------- points

local function num(x) return string.format("%.6f", x) end

local function normPoint(p)
  local t, v, sh, c1, c2
  if p.t ~= nil then t, v, sh, c1, c2 = p.t, p.v, p.shape, p.c1, p.c2 else t, v, sh, c1, c2 = p[1], p[2], p[3], p[4], p[5] end
  return { t = tonumber(t), v = tonumber(v), shape = tonumber(sh) or 0, c1 = tonumber(c1), c2 = tonumber(c2) }
end

-- Returns the cleaned list, or nil and the reason.
local function checkPoints(points)
  if type(points) ~= "table" then return nil, "no points" end
  local n = #points
  if n < 2 then return nil, "a curve needs at least two points" end
  if n > M.MAX_POINTS then return nil, "a curve holds at most " .. M.MAX_POINTS .. " points" end
  local out = {}
  for i = 1, n do
    local p = normPoint(points[i])
    if not p.t or not p.v then return nil, "point " .. i .. " is not a number" end
    if p.t < -1e-6 or p.t > 1 + 1e-6 then return nil, "point " .. i .. ": t is outside 0..1" end
    if p.v < -1e-6 or p.v > 1 + 1e-6 then return nil, "point " .. i .. ": v is outside 0..1" end
    p.t = math.max(0, math.min(1, p.t))
    p.v = math.max(0, math.min(1, p.v))
    if p.shape < 0 or p.shape > 5 or p.shape ~= math.floor(p.shape) then return nil, "point " .. i .. ": shape must be 0..5" end
    if p.shape == 5 then
      if not p.c1 or not p.c2 then return nil, "point " .. i .. ": shape 5 needs two handle levels" end
      p.c1 = math.max(-0.5, math.min(1.5, p.c1))
      p.c2 = math.max(-0.5, math.min(1.5, p.c2))
    else
      p.c1, p.c2 = nil, nil
    end
    if i > 1 and p.t < out[i - 1].t then return nil, "point " .. i .. ": t does not ascend" end
    out[i] = p
  end
  if math.abs(out[1].t) > 1e-6 then return nil, "the first point must have t = 0" end
  if math.abs(out[n].t - 1) > 1e-6 then return nil, "the last point must have t = 1" end
  out[1].t, out[n].t = 0, 1
  return out
end

local function pointLine(p)
  if p.shape == 5 then return string.format("%s,%s,5,%s,%s", num(p.t), num(p.v), num(p.c1), num(p.c2)) end
  if p.shape and p.shape ~= 0 then return string.format("%s,%s,%d", num(p.t), num(p.v), p.shape) end
  return num(p.t) .. "," .. num(p.v)
end

local function pointsBody(points)
  local lines = {}
  for i, p in ipairs(points) do lines[i] = pointLine(p) end
  return table.concat(lines, "\n")
end

local function parsePointLine(line)
  local a = {}
  for f in (line .. ","):gmatch("([^,]*),") do a[#a + 1] = f end
  local p = { t = tonumber(a[1]), v = tonumber(a[2]), shape = tonumber(a[3]) or 0, c1 = tonumber(a[4]), c2 = tonumber(a[5]) }
  if not p.t or not p.v then return nil end
  return p
end

local function shapeWord(points)
  local step, smooth = false, false
  for i = 1, #points - 1 do
    local s = points[i].shape or 0
    if s == 1 then step = true elseif s >= 2 then smooth = true end
  end
  if step then return "step" elseif smooth then return "smooth" end
  return "straight"
end

-- ---------------------------------------------------------------- the file

local function serialize(e)
  local L = { "ReaCat 1", "kind=" .. e.kind, "source=" .. e.source, "name=" .. e.name, "saved=" .. e.saved, "sent=" .. e.sent }
  if e.project and e.project ~= "" then L[#L + 1] = "project=" .. oneLine(e.project) end
  if e.projectid and e.projectid ~= "" then L[#L + 1] = "projectid=" .. oneLine(e.projectid) end
  if e.npoints then L[#L + 1] = string.format("npoints=%d", e.npoints) end
  if e.beats then L[#L + 1] = string.format("beats=%.10g", e.beats) end
  if e.range then L[#L + 1] = string.format("range=%.10g,%.10g", e.range[1], e.range[2]) end
  if e.unit and e.unit ~= "" then L[#L + 1] = "unit=" .. oneLine(e.unit) end
  if e.tags and #e.tags > 0 then L[#L + 1] = "tags=" .. table.concat(e.tags, ",") end
  if e.note and e.note ~= "" then L[#L + 1] = "note=" .. escape(e.note) end
  if e.fav then L[#L + 1] = "fav=1" end
  if e.rulekind and e.rulekind ~= "" then L[#L + 1] = "rulekind=" .. e.rulekind end
  L[#L + 1] = "hash=" .. e.hash
  if e.seq then L[#L + 1] = "seq=" .. string.format("%d", e.seq) end
  for _, kv in ipairs(e._extra or {}) do L[#L + 1] = kv[1] .. "=" .. kv[2] end
  if e.kind == "rule" then
    L[#L + 1] = "text"
    L[#L + 1] = e.text
  else
    L[#L + 1] = "points"
    L[#L + 1] = pointsBody(e.points)
  end
  return table.concat(L, "\n") .. "\n"
end

-- headerOnly: skip the body (a listing does not need the points). Returns the entry or nil, message.
local function parse(text, headerOnly)
  text = text:gsub("\r", "")
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  local major = (lines[1] or ""):match("^ReaCat (%d+)")
  if not major then return nil, "not a ReaCat file" end
  if tonumber(major) ~= M.VERSION then return nil, "ReaCat " .. major .. " is newer than this tool understands" end
  local e, raw, i, marker = { _extra = {} }, {}, 2, nil
  while i <= #lines do
    local line = lines[i]
    if line == "points" or line == "text" then marker = line break end
    local k, v = line:match("^([^=]+)=(.*)$")
    if k then
      raw[k] = v
      if not KNOWN[k] then e._extra[#e._extra + 1] = { k, v } end
    end
    i = i + 1
  end
  if not marker then return nil, "no body" end
  e.kind = raw.kind or "curve"
  e.source, e.name = raw.source or "", raw.name or ""
  e.saved, e.sent = raw.saved or "", raw.sent or raw.saved or ""
  e.beats = tonumber(raw.beats)
  if raw.range then
    local lo, hi = raw.range:match("^%s*([%-%d%.eE+]+)%s*,%s*([%-%d%.eE+]+)%s*$")
    if lo and tonumber(lo) and tonumber(hi) then e.range = { tonumber(lo), tonumber(hi) } end
  end
  e.unit = raw.unit
  e.tags = splitTags(raw.tags)
  e.note = raw.note and unescape(raw.note) or nil
  e.fav = (raw.fav == "1")
  e.rulekind = raw.rulekind
  e.hash = raw.hash or ""
  e.seq = tonumber(raw.seq)
  e.project = raw.project
  e.projectid = raw.projectid
  e.npoints = tonumber(raw.npoints)
  if headerOnly then return e end
  if e.kind == "rule" then
    if marker ~= "text" then return nil, "a rule needs a text body" end
    local last = #lines
    while last > i and lines[last] == "" do last = last - 1 end
    e.text = table.concat(lines, "\n", i + 1, last)
  elseif e.kind == "curve" then
    if marker ~= "points" then return nil, "a curve needs a points body" end
    e.points = {}
    for j = i + 1, #lines do
      if lines[j] ~= "" then
        local p = parsePointLine(lines[j])
        if not p then return nil, "bad point line: " .. lines[j] end
        e.points[#e.points + 1] = p
      end
    end
    if #e.points < 2 then return nil, "a curve needs at least two points" end
  end                                       -- another kind: the body is not read
  return e
end

-- ---------------------------------------------------------------- the counters

local function bump(key)
  local n = (tonumber(reaper.GetExtState(SECTION, key)) or 0) + 1
  reaper.SetExtState(SECTION, key, tostring(n), false)
  return n
end

function M.stamp() return reaper.GetExtState(SECTION, "stamp") end
function M.editStamp() return reaper.GetExtState(SECTION, "edit") end
function M.last() return reaper.GetExtState(SECTION, "last") end

function M.cleanupLimit()
  local n = tonumber(reaper.GetExtState(SECTION, "cleanup_after"))
  if n == nil then return M.DEFAULT_CLEANUP end
  return math.max(0, math.floor(n))
end
function M.setCleanupLimit(n) reaper.SetExtState(SECTION, "cleanup_after", tostring(math.max(0, math.floor(tonumber(n) or 0))), true) end

-- ---------------------------------------------------------------- reading the folder

local function fileNames(dir)
  local names = {}
  if reaper.EnumerateFiles then
    reaper.EnumerateFiles(dir, -1)          -- REAPER caches a listing; -1 makes it look again
    local i = 0
    while true do
      local f = reaper.EnumerateFiles(dir, i)
      if not f then break end
      if f:sub(-#M.EXT) == M.EXT then names[#names + 1] = f end
      i = i + 1
    end
  end
  return names
end

local function idOf(file) return (file:gsub("%" .. M.EXT .. "$", "")) end
local function pathOf(id) return M.dir() .. "/" .. id .. M.EXT end

local function newer(a, b)                  -- newest first
  if a.sent ~= b.sent then return a.sent > b.sent end
  local sa, sb = a.seq or 0, b.seq or 0              -- sends within one second: the later send counts later
  if sa ~= sb then return sa > sb end
  return a.id > b.id
end

-- filter: { query = match function (ReaCat.query), from = "YYYY-MM-DD", to = "YYYY-MM-DD", kind = "curve" }
function M.list(filter)
  filter = filter or {}
  local out = {}
  for _, f in ipairs(fileNames(M.dir())) do
    local text = readFile(M.dir() .. "/" .. f)
    local e = text and parse(text, true)
    if e then
      e.id = idOf(f)
      local day = e.sent:sub(1, 10)
      local keep = true
      if filter.kind and e.kind ~= filter.kind then keep = false end
      if keep and filter.from and day < filter.from then keep = false end
      if keep and filter.to and day > filter.to then keep = false end
      if keep and filter.query and not filter.query(e) then keep = false end
      if keep then out[#out + 1] = e end
    end
  end
  table.sort(out, newer)
  return out
end

function M.get(id)
  local text = readFile(pathOf(id))
  if not text then return nil, "no entry " .. tostring(id) end
  local e, err = parse(text, false)
  if not e then return nil, err end
  e.id = id
  return e
end

function M.newest(source, name)
  for _, e in ipairs(M.list()) do                       -- newest first
    if e.source == source and e.name == name then return e.id end
  end
  return nil
end

function M.tags()
  local count, spelling, isProject = {}, {}, {}
  for _, e in ipairs(M.list()) do
    if e.project and e.project ~= "" then       -- the project name counts as a tag (a fixed one)
      local pk = e.project:lower()
      count[pk] = (count[pk] or 0) + 1
      spelling[pk] = spelling[pk] or e.project
      isProject[pk] = true
    end
    for _, t in ipairs(e.tags) do
      local k = t:lower()
      count[k] = (count[k] or 0) + 1
      spelling[k] = spelling[k] or t
    end
  end
  local out = {}
  for k, c in pairs(count) do out[#out + 1] = { tag = spelling[k], count = c, project = isProject[k] or nil } end
  table.sort(out, function(a, b) if a.count ~= b.count then return a.count > b.count end return a.tag:lower() < b.tag:lower() end)
  return out
end

-- ---------------------------------------------------------------- sending

-- The name of the REAPER project at this moment, without ".RPP"; "Unsaved Project" when it has no file yet.
function M.projectName()
  local name
  if reaper.GetProjectName then
    local r = { pcall(reaper.GetProjectName, 0) }
    for i = #r, 2, -1 do if type(r[i]) == "string" then name = r[i] break end end
  end
  name = (oneLine(name or ""):gsub("%.[Rr][Pp][Pp]$", ""))
  if name == "" then return "Unsaved Project" end
  return name
end

-- Make an entry the newest without copying anything: "sent" and "seq" move, the stamp goes up (a click in the ReaCat
-- window, or the same content sent again). Returns the id, or nil and the reason.
function M.touch(id)
  local e, err = M.get(id)
  if not e then return nil, err end
  e.sent = os.date("%Y-%m-%d %H:%M:%S")
  e.seq = (tonumber(M.stamp()) or 0) + 1
  local ok, werr = writeFile(pathOf(id), serialize(e))
  if not ok then return nil, "could not write the catalogue: " .. tostring(werr) end
  reaper.SetExtState(SECTION, "last", id, false)
  bump("stamp")
  return id
end

function M.send(t)
  if type(t) ~= "table" then return nil, "nothing to send" end
  local kind = t.kind or "curve"
  local source, name = t.source and oneLine(t.source) or "", t.name and oneLine(t.name) or ""
  if source == "" or name == "" then return nil, "a send needs a source and a name" end
  local e = { kind = kind, source = source, name = name, tags = {}, _extra = {} }
  local body
  if kind == "curve" then
    local pts, err = checkPoints(t.points)
    if not pts then return nil, err end
    e.points, body = pts, pointsBody(pts)
    e.npoints = #pts
    if t.beats ~= nil then
      e.beats = tonumber(t.beats)
      if not e.beats or e.beats <= 0 then return nil, "beats must be a positive number" end
    end
    if t.range then
      local lo, hi = tonumber(t.range[1]), tonumber(t.range[2])
      if not lo or not hi then return nil, "range must be two numbers" end
      e.range = { lo, hi }
    end
    e.unit = t.unit
    addTag(e.tags, source) addTag(e.tags, name) addTag(e.tags, shapeWord(pts))
  elseif kind == "rule" then
    if type(t.text) ~= "string" or trim(t.text) == "" then return nil, "a rule needs a text" end
    e.text, body = (t.text:gsub("\r", "")), (t.text:gsub("\r", ""))
    e.rulekind = t.rulekind
    addTag(e.tags, source) addTag(e.tags, name) addTag(e.tags, "rule")
    if t.rulekind and t.rulekind ~= "" then addTag(e.tags, t.rulekind) end
  else
    return nil, "unknown kind " .. tostring(kind)
  end
  local given = t.tags
  if type(given) == "string" then given = splitTags(given) end
  for _, g in ipairs(given or {}) do addTag(e.tags, g) end
  e.note = t.note and tostring(t.note) or nil
  e.hash = fnv1a(kind .. "\n" .. body)
  e.project = (t.project and oneLine(t.project) ~= "") and oneLine(t.project) or M.projectName()
  e.projectid = (t.projectid and oneLine(t.projectid) ~= "") and oneLine(t.projectid) or M.projectId()

  local dir = M.dir()
  ensureDir(dir)
  local now = os.date("%Y-%m-%d %H:%M:%S")

  for _, h in ipairs(M.list()) do                      -- the same thing again: only "sent" moves
    if h.hash == e.hash and h.source == source and h.name == name and h.kind == kind then
      return M.touch(h.id)
    end
  end

  e.saved, e.sent = now, now
  e.seq = (tonumber(M.stamp()) or 0) + 1
  local id = M.newId()
  local ok, werr = writeFile(pathOf(id), serialize(e))
  if not ok then return nil, "could not write the catalogue: " .. tostring(werr) end
  reaper.SetExtState(SECTION, "last", id, false)
  bump("stamp")
  return id
end

-- ---------------------------------------------------------------- editing, deleting

function M.update(id, ch)
  local e, err = M.get(id)
  if not e then return nil, err end
  ch = ch or {}
  if ch.tags ~= nil then
    e.tags = {}
    local src = ch.tags
    if type(src) == "string" then src = splitTags(src) end
    for _, t in ipairs(src) do addTag(e.tags, t) end
  end
  for _, t in ipairs(ch.addtags or {}) do addTag(e.tags, t) end
  for _, t in ipairs(ch.removetags or {}) do removeTag(e.tags, t) end
  if ch.note ~= nil then e.note = tostring(ch.note) end
  if ch.fav ~= nil then e.fav = ch.fav and true or false end
  local ok, werr = writeFile(pathOf(id), serialize(e))
  if not ok then return nil, "could not write the catalogue: " .. tostring(werr) end
  bump("edit")
  return true
end

function M.delete(id)
  if not fileExists(pathOf(id)) then return nil, "no entry " .. tostring(id) end
  ensureDir(trashDir())
  local ok, err = renameOver(pathOf(id), trashDir() .. "/" .. id .. M.EXT)
  if not ok then return nil, err end
  bump("edit")
  return true
end

function M.undelete(id)
  local from = trashDir() .. "/" .. id .. M.EXT
  if not fileExists(from) then return nil, "nothing to bring back for " .. tostring(id) end
  local ok, err = renameOver(from, pathOf(id))
  if not ok then return nil, err end
  bump("edit")
  return true
end

-- The oldest entries without a star beyond the user's limit (0 = never suggest). Never deletes.
function M.cleanupCandidates(limit)
  limit = limit or M.cleanupLimit()
  local all = M.list()
  local over = #all - limit
  if limit <= 0 or over <= 0 then return {}, #all end
  local out = {}
  for i = #all, 1, -1 do                                 -- oldest first
    if not all[i].fav then
      out[#out + 1] = all[i]
      if #out >= over then break end
    end
  end
  return out, #all
end

-- ---------------------------------------------------------------- project id, restore, usage (spec section 11)

local PROJ = "ReaCat"

-- A hidden id of the REAPER project, made once and kept in the project's own ExtState; every send carries it as `projectid=`.
-- (The visible name is not unique: every unsaved project is "Unsaved Project".) nil when REAPER cannot say.
function M.projectId()
  if not (reaper.GetProjExtState and reaper.SetProjExtState) then return nil end
  local _, id = reaper.GetProjExtState(0, PROJ, "projectid")
  if type(id) == "string" and id ~= "" then return id end
  if reaper.genGuid then id = (reaper.genGuid(""):gsub("[{}]", "")) end
  if type(id) ~= "string" or id == "" then
    id = string.format("%08x%08x", os.time() & 0xffffffff, math.random(0, 0x7fffffff))
  end
  reaper.SetProjExtState(0, PROJ, "projectid", id)
  return id
end

function M.newId()
  local base, n, id = os.date("%Y%m%d_%H%M%S"), 1, nil
  repeat id = string.format("%s_%03d", base, n) n = n + 1 until not fileExists(pathOf(id))
  return id
end

local function contentHash(e)
  if e.kind == "rule" then return fnv1a("rule\n" .. (e.text or "")) end
  return fnv1a("curve\n" .. pointsBody(e.points or {}))
end

-- The text of an entry exactly as it is in its file (a snapshot stores it), or nil.
function M.export(id) return readFile(pathOf(id)) end

-- The entries of one project (by its hidden id) as { id, text }, oldest first: what a snapshot stores.
function M.exportProject(projectid)
  local out = {}
  if not projectid or projectid == "" then return out end
  local all = M.list()
  for i = #all, 1, -1 do
    if all[i].projectid == projectid then
      local text = M.export(all[i].id)
      if text then out[#out + 1] = { id = all[i].id, text = text } end
    end
  end
  return out
end

-- Puts an entry back as it was (id, dates, tags, note, project and all), without making it the newest. Used by a snapshot's Restore.
-- The same content already in the catalogue is not added twice: returns that id and "exists". Returns id, "added"  or  nil, message.
function M.restore(id, text)
  if type(text) ~= "string" then return nil, "no text" end
  local e, err = parse(text, false)
  if not e then return nil, err end
  local hash = (e.hash ~= "" and e.hash) or contentHash(e)
  for _, h in ipairs(M.list()) do
    if h.hash == hash and h.source == e.source and h.name == e.name and h.kind == e.kind then return h.id, "exists" end
  end
  ensureDir(M.dir())
  if type(id) ~= "string" or not id:match("^[%w_%-]+$") or fileExists(pathOf(id)) then id = M.newId() end
  local ok, werr = writeFile(pathOf(id), (text:gsub("\r", "")):gsub("\n*$", "\n"))
  if not ok then return nil, "could not write the catalogue: " .. tostring(werr) end
  bump("edit")
  return id, "added"
end

-- The usage record: which catalogue entry (by its content hash) was taken or written where in THIS project. Kept in the project's own
-- ExtState (saved with the project): records separated by ";", fields by "|", the characters % ; | and line ends written %XX.
local function enc(s) return (tostring(s or ""):gsub("[%%;|\r\n]", function(c) return string.format("%%%02X", c:byte()) end)) end
local function dec(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
local USAGE_MAX = 2000

function M.usage()
  local out = {}
  if not reaper.GetProjExtState then return out end
  local _, raw = reaper.GetProjExtState(0, PROJ, "usage")
  for rec in ((raw or "") .. ";"):gmatch("([^;]*);") do
    local f = {}
    for x in (rec .. "|"):gmatch("([^|]*)|") do f[#f + 1] = dec(x) end
    if f[1] and f[1] ~= "" then out[#out + 1] = { hash = f[1], what = f[2], guid = f[3], tool = f[4], label = f[5], date = f[6] } end
  end
  return out
end

local function writeUsage(list)
  local parts = {}
  for i = math.max(1, #list - USAGE_MAX + 1), #list do
    local r = list[i]
    parts[#parts + 1] = table.concat({ enc(r.hash), enc(r.what), enc(r.guid), enc(r.tool), enc(r.label), enc(r.date) }, "|")
  end
  reaper.SetProjExtState(0, PROJ, "usage", table.concat(parts, ";"))
  bump("edit")
end

-- rec = { hash =, what = "item" | "ai" | "param", guid = (the item's GUID, or any key that names the place), tool =, label = }
-- The same hash + what + guid + tool is one line (its date and label are renewed).
function M.useAdd(rec)
  if type(rec) ~= "table" or type(rec.hash) ~= "string" or rec.hash == "" then return nil, "no hash" end
  if not (reaper.GetProjExtState and reaper.SetProjExtState) then return nil, "no project" end
  local r = { hash = rec.hash, what = rec.what or "item", guid = rec.guid or "", tool = rec.tool or "", label = rec.label or "",
              date = rec.date or os.date("%Y-%m-%d %H:%M:%S") }
  local list = M.usage()
  for i = #list, 1, -1 do
    local x = list[i]
    if x.hash == r.hash and x.what == r.what and x.guid == r.guid and x.tool == r.tool then table.remove(list, i) end
  end
  list[#list + 1] = r
  writeUsage(list)
  return true
end

-- hash -> how many places use it, in this project (what the red borders and `used:` need)
function M.usedHashes()
  local set = {}
  for _, r in ipairs(M.usage()) do set[r.hash] = (set[r.hash] or 0) + 1 end
  return set
end

function M.usedBy(hash)
  local out = {}
  for _, r in ipairs(M.usage()) do if r.hash == hash then out[#out + 1] = r end end
  return out
end

-- Removes the lines whose place is gone. exists(record) -> true | false (the caller knows how to look: an item by its GUID, ...).
function M.usePrune(exists)
  local list, kept, removed = M.usage(), {}, 0
  for _, r in ipairs(list) do
    if exists(r) == false then removed = removed + 1 else kept[#kept + 1] = r end
  end
  if removed > 0 then writeUsage(kept) end
  return removed
end

-- ---- the item side: a line in the item's NOTES, and, when the setting is on, a suffix in the item's name

function M.nameSuffixOn() return reaper.GetExtState(SECTION, "name_suffix") == "1" end
function M.setNameSuffixOn(on) reaper.SetExtState(SECTION, "name_suffix", on and "1" or "0", true) end

local function notePrefix(e) return "ReaCat: " .. oneLine(e.source) .. " " .. oneLine(e.name) .. "," end

-- The notes text with this entry's line in it (one line per curve: a newer take of the same source and name replaces its line).
function M.noteWith(notes, e, date, project)
  local line = notePrefix(e) .. " taken " .. (date or os.date("%Y-%m-%d %H:%M")) .. ", project " .. (project or M.projectName())
  local prefix, out, done = notePrefix(e), {}, false
  for l in ((notes or ""):gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
    if l:sub(1, #prefix) == prefix then
      if not done then out[#out + 1] = line done = true end
    else
      out[#out + 1] = l
    end
  end
  while #out > 0 and out[#out] == "" do out[#out] = nil end
  if not done then out[#out + 1] = line end
  return table.concat(out, "\n")
end

function M.nameWith(name, e)
  local suffix = " + ReaCat: " .. oneLine(e.source) .. " " .. oneLine(e.name)
  name = name or ""
  if name:find(suffix, 1, true) then return name end
  return name .. suffix
end

local function lastString(...)
  local r = { ... }
  for i = #r, 1, -1 do if type(r[i]) == "string" then return r[i] end end
  return ""
end

-- A tool took or wrote this entry into a media item: the usage line, the notes line and, when the setting (or opts.nameSuffix) is on,
-- the name suffix. entry = the entry as ReaCat.get gives it (hash, source, name). opts = { tool = "MinervaCL", nameSuffix = true | false }.
function M.markItem(item, entry, opts)
  opts = opts or {}
  if not item or type(entry) ~= "table" or not entry.hash then return nil, "nothing to mark" end
  local guid = lastString(reaper.GetSetMediaItemInfo_String(item, "GUID", "", false))
  local ok, err = M.useAdd{ hash = entry.hash, what = "item", guid = guid, tool = opts.tool, label = entry.source .. " " .. entry.name }
  if not ok then return nil, err end
  local notes = lastString(reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false))
  reaper.GetSetMediaItemInfo_String(item, "P_NOTES", M.noteWith(notes, entry), true)
  local suffix = opts.nameSuffix
  if suffix == nil then suffix = M.nameSuffixOn() end
  if suffix then
    local take = reaper.GetActiveTake(item)
    if take then
      local name = lastString(reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false))
      reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", M.nameWith(name, entry), true)
    end
  end
  return true, guid
end

-- ---------------------------------------------------------------- boolean search (spec 8.1)

local FIELDS = { tag = true, source = true, name = true, note = true, project = true, used = true }

local function tokenize(s)
  local toks, i, n = {}, 1, #s
  local function quoted(from, field)
    local j = s:find('"', from + 1, true)
    if not j then return nil end
    toks[#toks + 1] = { t = "term", field = field, text = s:sub(from + 1, j - 1) }
    return j + 1
  end
  while i <= n do
    local c = s:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif c == "(" or c == ")" then
      toks[#toks + 1] = { t = c }
      i = i + 1
    elseif c == '"' then
      i = quoted(i, nil)
      if not i then return nil, "a quote is never closed" end
    elseif c == "-" and i < n and not s:sub(i + 1, i + 1):match("[%s%)]") then
      toks[#toks + 1] = { t = "NOT" }
      i = i + 1
    else
      local j = i
      while j <= n and not s:sub(j, j):match('[%s%(%)"]') do j = j + 1 end
      local w = s:sub(i, j - 1)
      local field, rest = w:match("^(%a+):(.*)$")
      field = field and field:lower()
      if field and FIELDS[field] then
        if rest == "" and field == "used" then
          toks[#toks + 1] = { t = "term", field = "used", text = "" }       -- `used:` alone: used in this project
          i = j
        elseif rest == "" then
          if s:sub(j, j) == '"' then
            i = quoted(j, field)
            if not i then return nil, "a quote is never closed" end
          else
            return nil, "nothing after " .. field .. ":"
          end
        else
          toks[#toks + 1] = { t = "term", field = field, text = rest }
          i = j
        end
      elseif w == "AND" or w == "OR" or w == "NOT" then
        toks[#toks + 1] = { t = w }
        i = j
      else
        toks[#toks + 1] = { t = "term", text = w }
        i = j
      end
    end
  end
  return toks
end

local function parseQuery(toks)
  local pos = 1
  local parseOr
  local function peek() return toks[pos] end
  local function startsAtom(t) return t and (t.t == "term" or t.t == "(" or t.t == "NOT") end
  local function atom()
    local t = peek()
    if not t then return nil, "the search ends too early" end
    if t.t == "(" then
      pos = pos + 1
      local n, err = parseOr()
      if not n then return nil, err end
      if not peek() or peek().t ~= ")" then return nil, "a bracket is never closed" end
      pos = pos + 1
      return n
    elseif t.t == "term" then
      pos = pos + 1
      return { op = "term", field = t.field, text = t.text:lower() }
    end
    return nil, "unexpected " .. t.t
  end
  local function notExpr()
    if peek() and peek().t == "NOT" then
      pos = pos + 1
      local n, err = notExpr()
      if not n then return nil, err end
      return { op = "not", n }
    end
    return atom()
  end
  local function andExpr()
    local l, err = notExpr()
    if not l then return nil, err end
    while true do
      local t = peek()
      if t and t.t == "AND" then pos = pos + 1 elseif not startsAtom(t) then break end
      local r, e2 = notExpr()
      if not r then return nil, e2 end
      l = { op = "and", l, r }
    end
    return l
  end
  parseOr = function()
    local l, err = andExpr()
    if not l then return nil, err end
    while peek() and peek().t == "OR" do
      pos = pos + 1
      local r, e2 = andExpr()
      if not r then return nil, e2 end
      l = { op = "or", l, r }
    end
    return l
  end
  local n, err = parseOr()
  if not n then return nil, err end
  if pos <= #toks then return nil, "unexpected " .. toks[pos].t end
  return n
end

local function has(hay, text) return hay:lower():find(text, 1, true) ~= nil end

local function evalNode(n, h, used)
  if n.op == "and" then return evalNode(n[1], h, used) and evalNode(n[2], h, used) end
  if n.op == "or" then return evalNode(n[1], h, used) or evalNode(n[2], h, used) end
  if n.op == "not" then return not evalNode(n[1], h, used) end
  local f, text = n.field, n.text
  if f == "tag" then
    if h.project and h.project:lower() == text then return true end       -- the project name is a fixed tag
    for _, t in ipairs(h.tags or {}) do if t:lower() == text then return true end end
    return false
  elseif f == "project" then return has(h.project or "", text)
  elseif f == "used" then return (used or {})[h.hash or ""] ~= nil
  elseif f == "source" then return has(h.source or "", text)
  elseif f == "name" then return has(h.name or "", text)
  elseif f == "note" then return has(h.note or "", text)
  end
  return has(h.name or "", text) or has(h.source or "", text) or has(table.concat(h.tags or {}, ","), text) or has(h.note or "", text) or has(h.project or "", text)
end

-- Returns match(header) -> boolean, or nil and the problem (the caller shows it and leaves the list unfiltered).
function M.query(text)
  text = text or ""
  if text:match("^%s*$") then return function() return true end end
  local toks, err = tokenize(text)
  if not toks then return nil, err end
  local tree, perr = parseQuery(toks)
  if not tree then return nil, perr end
  local used = text:find("used:", 1, true) and M.usedHashes() or nil     -- looked up once per search, not per entry
  return function(h) return evalNode(tree, h, used) end
end

return M
