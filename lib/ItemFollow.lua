-- ============================================================
--   ItemFollow.lua
--   What a ReaNvelopes window follows (19 November 2026): the selected media item, or else the selected automation item of the selected
--   envelope. read_current() returns a key that tells the two apart (it changes when the selection changes, also to an item without
--   ReaNvelopes settings) and the encoded settings when that item has some, as ReaNvelopes wrote them (ReaSnap_Integration:
--   P_EXT / P_POOL_EXT "ReaNvelopes_ItemSettings", "b64:" + base64).
-- ============================================================
local Serial = require("ReaNvelopes_Serial")
local M = {}
local KEY = "ReaNvelopes_ItemSettings"

local function decode(v)
  if type(v) == "string" and v:sub(1, 4) == "b64:" then return Serial.b64_decode(v:sub(5)) end
  return nil
end

function M.read_current()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if item then
    local _, guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
    local _, v = reaper.GetSetMediaItemInfo_String(item, "P_EXT:" .. KEY, "", false)
    return "item:" .. guid, decode(v)
  end
  local env = reaper.GetSelectedTrackEnvelope(0)
  if env then
    for i = 0, reaper.CountAutomationItems(env) - 1 do
      if reaper.GetSetAutomationItemInfo(env, i, "D_UISEL", 0, false) > 0 then
        local pool = reaper.GetSetAutomationItemInfo(env, i, "D_POOL_ID", 0, false)
        local pos = reaper.GetSetAutomationItemInfo(env, i, "D_POSITION", 0, false)
        local ok, v = reaper.GetSetAutomationItemInfo_String(env, i, "P_POOL_EXT:" .. KEY, "", false)
        return string.format("ai:%d:%.4f", pool, pos), ok and decode(v) or nil
      end
    end
  end
  return nil, nil
end

return M
