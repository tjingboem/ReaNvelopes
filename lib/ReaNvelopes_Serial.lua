--[[
ReaNvelopes_Serial.lua

ReaNvelopes' own self-contained serializer -- a copy of ReaAC's core/reaac_serial.lua (itself a copy of the proven
ReaSculpt_Serial.lua template), kept as its own file rather than required from another repo. This is piece 1 of the ReaSnap Integration Contract
("Own serializer... never depending on an external file") -- ReaNvelopes must
work identically with ReaSnap's whole folder deleted, so this file has
to be a genuine copy, not a reference.

decode() is a hand-written recursive descent parser, not
load("return " .. str) -- load() executes whatever string it's handed,
which is fine for a file ReaAC wrote itself but a liability the moment
the same function reads a blob out of a .rpp someone else sent.

No REAPER API calls anywhere in this file. Runs under plain Lua 5.4,
which is what makes it testable outside REAPER at all (see the shared
core's own offline-test discipline, CLAUDE.md).
--]]

local M = {}

-- ===================== ENCODE =====================

local function is_array(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  for i = 1, n do
    if t[i] == nil then return false, n end
  end
  return true, n
end

local function encode_string(s)
  -- %q gives a Lua-safe quoted literal (escapes quotes, backslashes,
  -- newlines, embedded zeros). We parse its escapes ourselves in decode,
  -- so we control the whole grammar on both ends.
  return string.format("%q", s)
end

local function encode_number(n)
  if n ~= n then return "0/0" end -- NaN guard, shouldn't occur in practice
  if n == math.huge then return "1/0" end
  if n == -math.huge then return "-1/0" end
  -- %.17g round-trips any double exactly (17 significant digits is
  -- provably sufficient for IEEE 754 double -> string -> double).
  return string.format("%.17g", n)
end

local encode_value -- forward decl

local function encode_table(t, seen)
  seen = seen or {}
  if seen[t] then
    error("ReaSculpt_Serial.encode: cannot serialize a table with a cycle")
  end
  seen[t] = true

  local arr, n = is_array(t)
  local parts = {}

  if arr then
    for i = 1, n do
      parts[#parts + 1] = encode_value(t[i], seen)
    end
  else
    -- Deterministic key order: sort string keys, numeric keys after.
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
      local ta, tb = type(a), type(b)
      if ta ~= tb then return ta < tb end
      return tostring(a) < tostring(b)
    end)
    for _, k in ipairs(keys) do
      local v = t[k]
      local key_str
      if type(k) == "string" and k:match("^[%a_][%w_]*$") then
        key_str = k
      else
        key_str = "[" .. encode_value(k, seen) .. "]"
      end
      parts[#parts + 1] = key_str .. "=" .. encode_value(v, seen)
    end
  end

  seen[t] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end

encode_value = function(v, seen)
  local t = type(v)
  if t == "nil" then
    return "nil"
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "number" then
    return encode_number(v)
  elseif t == "string" then
    return encode_string(v)
  elseif t == "table" then
    return encode_table(v, seen)
  else
    error("ReaSculpt_Serial.encode: unsupported type " .. t)
  end
end

function M.encode(value)
  return encode_value(value, {})
end

-- ===================== DECODE =====================
-- Recursive descent parser over the grammar encode() produces.
-- No load(), no loadstring(), no compiled Lua chunks of any kind.

local Parser = {}
Parser.__index = Parser

local function new_parser(str)
  return setmetatable({ s = str, pos = 1, len = #str }, Parser)
end

function Parser:peek()
  return self.s:sub(self.pos, self.pos)
end

function Parser:skip_ws()
  while self.pos <= self.len do
    local c = self:peek()
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      self.pos = self.pos + 1
    else
      break
    end
  end
end

function Parser:error(msg)
  error(string.format("ReaSculpt_Serial.decode: %s at position %d (near %q)",
    msg, self.pos, self.s:sub(math.max(1, self.pos - 10), self.pos + 10)))
end

function Parser:expect(ch)
  if self:peek() ~= ch then
    self:error("expected '" .. ch .. "'")
  end
  self.pos = self.pos + 1
end

function Parser:parse_string()
  self:expect('"')
  local out = {}
  while true do
    if self.pos > self.len then self:error("unterminated string") end
    local c = self.s:sub(self.pos, self.pos)
    if c == '"' then
      self.pos = self.pos + 1
      break
    elseif c == "\\" then
      local nxt = self.s:sub(self.pos + 1, self.pos + 1)
      if nxt == "n" then out[#out + 1] = "\n"; self.pos = self.pos + 2
      elseif nxt == "t" then out[#out + 1] = "\t"; self.pos = self.pos + 2
      elseif nxt == "r" then out[#out + 1] = "\r"; self.pos = self.pos + 2
      elseif nxt == '"' then out[#out + 1] = '"'; self.pos = self.pos + 2
      elseif nxt == "\\" then out[#out + 1] = "\\"; self.pos = self.pos + 2
      elseif nxt == "\n" then out[#out + 1] = "\n"; self.pos = self.pos + 2
      elseif nxt:match("%d") then
        -- \ddd decimal byte escape, as produced by %q
        local digits = self.s:sub(self.pos + 1, self.pos + 3):match("^(%d%d?%d?)")
        out[#out + 1] = string.char(tonumber(digits))
        self.pos = self.pos + 1 + #digits
      else
        self:error("unknown escape \\" .. nxt)
      end
    else
      out[#out + 1] = c
      self.pos = self.pos + 1
    end
  end
  return table.concat(out)
end

function Parser:parse_number()
  local start = self.pos
  -- handles the 1/0, -1/0 inf sentinels and ordinary numeric literals
  local rest = self.s:sub(self.pos)
  local inf = rest:match("^%-?1/0")
  if inf then
    self.pos = self.pos + #inf
    return inf == "1/0" and math.huge or -math.huge
  end
  local nan = rest:match("^0/0")
  if nan then
    self.pos = self.pos + #nan
    return 0 / 0
  end
  local num = rest:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*")
  if not num or num == "" then self:error("expected number") end
  self.pos = self.pos + #num
  local n = tonumber(num)
  if not n then self:error("malformed number literal " .. num) end
  return n
end

function Parser:parse_identifier()
  local rest = self.s:sub(self.pos)
  local id = rest:match("^[%a_][%w_]*")
  if not id then self:error("expected identifier") end
  self.pos = self.pos + #id
  return id
end

local parse_value -- forward decl

function Parser:parse_table()
  self:expect("{")
  local t = {}
  local arr_idx = 1
  self:skip_ws()
  if self:peek() == "}" then
    self.pos = self.pos + 1
    return t
  end
  while true do
    self:skip_ws()
    local c = self:peek()
    local key
    if c == "[" then
      self.pos = self.pos + 1
      self:skip_ws()
      key = parse_value(self)
      self:skip_ws()
      self:expect("]")
      self:skip_ws()
      self:expect("=")
      self:skip_ws()
      t[key] = parse_value(self)
    elseif c:match("[%a_]") then
      -- could be `identifier=value` or a bareword we mis-scan as ident
      -- but our grammar never emits bare identifiers as values, so any
      -- identifier at a value position is a key.
      local save = self.pos
      local id = self:parse_identifier()
      self:skip_ws()
      if self:peek() == "=" then
        self.pos = self.pos + 1
        self:skip_ws()
        t[id] = parse_value(self)
      else
        -- not actually a key (shouldn't happen given our grammar) --
        -- rewind and treat as a positional value for safety
        self.pos = save
        t[arr_idx] = parse_value(self)
        arr_idx = arr_idx + 1
      end
    else
      t[arr_idx] = parse_value(self)
      arr_idx = arr_idx + 1
    end
    self:skip_ws()
    local sep = self:peek()
    if sep == "," then
      self.pos = self.pos + 1
      self:skip_ws()
      if self:peek() == "}" then
        -- trailing comma, as ReaMaskM's old serializer always emits
        self.pos = self.pos + 1
        break
      end
    elseif sep == "}" then
      self.pos = self.pos + 1
      break
    else
      self:error("expected ',' or '}'")
    end
  end
  return t
end

parse_value = function(p)
  p:skip_ws()
  local c = p:peek()
  if c == "{" then
    return p:parse_table()
  elseif c == '"' then
    return p:parse_string()
  elseif c == "-" or c:match("%d") then
    return p:parse_number()
  elseif c == "t" and p.s:sub(p.pos, p.pos + 3) == "true" then
    p.pos = p.pos + 4
    return true
  elseif c == "f" and p.s:sub(p.pos, p.pos + 4) == "false" then
    p.pos = p.pos + 5
    return false
  elseif c == "n" and p.s:sub(p.pos, p.pos + 2) == "nil" then
    p.pos = p.pos + 3
    return nil
  else
    p:error("unexpected character '" .. c .. "'")
  end
end

function M.decode(str)
  local p = new_parser(str)
  local v = parse_value(p)
  p:skip_ws()
  if p.pos <= p.len then
    p:error("trailing data after top-level value")
  end
  return v
end

-- ===== Item state: settings that travel with the item =====
-- The settings of an item are kept ON the item (item P_EXT, key "<tool>_ItemSettings"), not in a project table keyed
-- by the item GUID: REAPER gives a copy of an item a new GUID but copies the item's P_EXT, so a copy carries the
-- settings of its original. Stored as base64 ("b64:" + text) so line breaks and quotes in the encoded settings cannot
-- upset REAPER's item chunk. Same format and key as in ReaSnap, which reads it (ReaSnap_Core.lua, ReaSnapItemState).
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function M.b64_encode(encoded)
  local out = {}
  for i = 1, #encoded, 3 do
    local a, b, c = encoded:byte(i, i + 2)
    local n = (a << 16) | ((b or 0) << 8) | (c or 0)
    local c1, c2, c3, c4 = (n >> 18) & 63, (n >> 12) & 63, (n >> 6) & 63, n & 63
    out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
      .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
  end
  return table.concat(out)
end

function M.write_item_state(item, tool, encoded)
  return reaper.GetSetMediaItemInfo_String(item, "P_EXT:" .. tool .. "_ItemSettings", "b64:" .. M.b64_encode(encoded), true)
end


return M
