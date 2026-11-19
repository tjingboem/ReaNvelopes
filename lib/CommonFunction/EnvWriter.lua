-- ============================================================
--   CommonFunction/EnvWriter.lua
--   Shared envelope-writing utilities used by RAND, LFO, MORPH.
--
--   Exports:
--     getEffectiveRange()                      → ts_s, ts_e, time_offset, has_item
--     resolveTarget()                          → env, ts_s, ts_e, time_offset
--     insertPoints(env, pts, ts_s, ts_len, target_idx)
--     removeAutomationItemsIn(env, ts_s, ts_e)  → number of automation items deleted (they lie completely inside the range)
--     finalizeAutomationItem(env, ts_s, ts_e)  → ai_idx
--     commitAutomationItem(env, pts, ts_s, ts_e) → ai_idx
-- ============================================================

local M = {}

local Logger     = require("Logger")
local EnvUtils   = require("EnvelopeUtils")
local EnvConvert = require("EnvConvert")

local toEnvValue = EnvConvert.toEnvValue

-- ── Effective range ──────────────────────────────────────────
-- Priority:
--   1. Item selected → time_offset = item_s
--      a. Time selection overlapping item → clamped ts
--      b. No valid ts → full item bounds
--   2. No item → time selection only (time_offset = 0)
--
-- Returns: ts_s, ts_e, time_offset, has_item
-- Returns nil when no item and no valid time selection.
function M.getEffectiveRange()
  if reaper.CountSelectedMediaItems(0) > 0 then
    local item   = reaper.GetSelectedMediaItem(0, 0)
    local item_s = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_e = item_s + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

    local ts_s, ts_e = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
    local has_ts     = (ts_e - ts_s) >= 0.01

    if has_ts and ts_s < item_e and ts_e > item_s then
      local range_s = math.max(ts_s, item_s)
      local range_e = math.min(ts_e, item_e)
      if range_e - range_s >= 0.01 then
        return range_s, range_e, item_s, true
      end
    end

    if item_e - item_s >= 0.01 then
      return item_s, item_e, item_s, true
    end
    return nil
  end

  local ts_s, ts_e = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  if ts_e - ts_s < 0.01 then return nil end
  return ts_s, ts_e, 0, false
end

-- ── Target resolution ────────────────────────────────────────
-- Returns: env, ts_s, ts_e, time_offset
-- time_offset = item D_POSITION for take envelopes, 0 for track envelopes.
-- Points must be written at (t - time_offset) for take envelopes.
function M.resolveTarget()
  -- ── Case 0: a selected TRACK envelope decides (19 Nov 2026, corrections list item 22) ──────
  -- tjingboem selected an envelope lane and still got "Selected item has no take FX envelope lane": a media item that was still selected (the
  -- one of an earlier test) took priority over the lane. The envelope that is selected decides: when it is a track envelope, a selected
  -- item no longer matters. The time range is the time selection; without one, the selected item's own length is the range.
  do
    local sel = reaper.GetSelectedEnvelope(0)
    if sel and reaper.GetEnvelopeInfo_Value(sel, "I_TAKEENVELOPE") ~= 1 then
      if not EnvUtils.isVisible(sel) then
        local _, en = reaper.GetEnvelopeName(sel)
        Logger.error("⚠  Envelope '" .. en .. "' is not visible") ; return nil
      end
      local ts_s, ts_e = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
      if ts_e - ts_s < 0.01 and reaper.CountSelectedMediaItems(0) > 0 then
        local item = reaper.GetSelectedMediaItem(0, 0)
        ts_s = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        ts_e = ts_s + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      end
      if ts_e - ts_s < 0.01 then
        Logger.error("⚠  Set a time selection (the envelope lane is selected)") ; return nil
      end
      return sel, ts_s, ts_e, 0
    end
  end

  -- ── Case 1: selected media item ──────────────────────────────
  if reaper.CountSelectedMediaItems(0) > 0 then
    local item = reaper.GetSelectedMediaItem(0, 0)
    local take = reaper.GetActiveTake(item)
    if not take then
      Logger.error("⚠  Selected item has no active take") ; return nil
    end

    local n_take_env = reaper.CountTakeEnvelopes(take)
    if n_take_env == 0 then
      -- (an item is selected, but no envelope lane: the usual case is a track envelope that was not clicked)
      Logger.error("⚠  Click the name of an envelope lane (track panel) and set a time selection") ; return nil
    end
    local has_visible = false
    for e = 0, n_take_env - 1 do
      if EnvUtils.isVisible(reaper.GetTakeEnvelope(take, e)) then
        has_visible = true ; break
      end
    end
    if not has_visible then
      Logger.error("⚠  Selected item has no visible take FX envelope lane") ; return nil
    end

    local sel_env = reaper.GetSelectedEnvelope(0)
    if not sel_env then
      Logger.error("⚠  Click a take FX envelope lane on the item") ; return nil
    end
    local is_take_env = false
    for e = 0, n_take_env - 1 do
      if reaper.GetTakeEnvelope(take, e) == sel_env then
        is_take_env = true ; break
      end
    end
    if not is_take_env then
      Logger.error("⚠  Selected envelope is not a take FX envelope of this item") ; return nil
    end
    if not EnvUtils.isVisible(sel_env) then
      local _, en = reaper.GetEnvelopeName(sel_env)
      Logger.error("⚠  Take FX envelope '" .. en .. "' is not visible") ; return nil
    end

    local ts_s, ts_e, time_offset = M.getEffectiveRange()
    if not ts_s then
      Logger.error("⚠  Selected item is too short") ; return nil
    end
    return sel_env, ts_s, ts_e, time_offset
  end

  -- ── Case 2: time selection + selected track envelope ─────────
  local sel_env = reaper.GetSelectedEnvelope(0)
  if not sel_env then
    Logger.error("⚠  Select a media item + take FX lane, or set a time selection + envelope lane") ; return nil
  end
  if not EnvUtils.isVisible(sel_env) then
    local _, en = reaper.GetEnvelopeName(sel_env)
    Logger.error("⚠  Envelope '" .. en .. "' is not visible") ; return nil
  end
  local ts_s, ts_e = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  if ts_e - ts_s < 0.01 then
    Logger.error("⚠  Select an envelope lane and set a time selection") ; return nil
  end
  return sel_env, ts_s, ts_e, 0
end

-- ── Point insertion ──────────────────────────────────────────
-- Converts a [{tn, v, shape, tension}] list to native envelope
-- values and inserts them. target_idx defaults to -1 (base env).
function M.insertPoints(env, pts, ts_s, ts_len, target_idx)
  target_idx = target_idx or -1
  local conv         = EnvUtils.detectConverter(env)
  local lo, hi, mode = EnvUtils.resolveRange(env)
  for _, p in ipairs(pts) do
    reaper.InsertEnvelopePointEx(env, target_idx,
      ts_s + p.tn * ts_len,
      toEnvValue(p.v, conv, lo, hi, mode),
      p.shape, p.tension, false, true)
  end
end

-- ── Replace what is there (19 Nov 2026, corrections list item 22) ─────
-- A write into a lane that already has an automation item over the same time used to make a second item on top of it, "added to the existing
-- one". tjingboem: it should replace the existing one, or make a fresh item in the time selection. Now every automation item of this envelope that lies
-- COMPLETELY inside [ts_s, ts_e] is deleted before the new one is made; one that only overlaps the range stays (the new item lies on top of it).
-- REAPER has no function to delete an automation item, only the action "Envelope: Delete automation items" (42086), which deletes the SELECTED
-- ones of the whole project: so the selection of every other automation item is put aside and restored afterwards.
-- Returns the number of items deleted.
function M.removeAutomationItemsIn(env, ts_s, ts_e)
  local tol = 0.001
  local doomed = {}
  for i = 0, reaper.CountAutomationItems(env) - 1 do
    local pos = reaper.GetSetAutomationItemInfo(env, i, "D_POSITION", 0, false)
    local len = reaper.GetSetAutomationItemInfo(env, i, "D_LENGTH", 0, false)
    if pos >= ts_s - tol and pos + len <= ts_e + tol then doomed[i] = true end
  end
  if next(doomed) == nil then return 0 end

  -- every automation item of the project: where it is, whether it was selected
  local all = {}
  local function collect(e)
    for i = 0, reaper.CountAutomationItems(e) - 1 do
      all[#all + 1] = { env = e, idx = i, sel = reaper.GetSetAutomationItemInfo(e, i, "D_UISEL", 0, false) > 0,
                        pos = reaper.GetSetAutomationItemInfo(e, i, "D_POSITION", 0, false),
                        len = reaper.GetSetAutomationItemInfo(e, i, "D_LENGTH", 0, false),
                        pool = reaper.GetSetAutomationItemInfo(e, i, "D_POOL_ID", 0, false) }
    end
  end
  local master = reaper.GetMasterTrack(0)
  for t = -1, reaper.CountTracks(0) - 1 do
    local tr = (t < 0) and master or reaper.GetTrack(0, t)
    for e = 0, reaper.CountTrackEnvelopes(tr) - 1 do collect(reaper.GetTrackEnvelope(tr, e)) end
  end
  local n_before = reaper.CountAutomationItems(env)
  for _, a in ipairs(all) do
    local want = (a.env == env and doomed[a.idx]) and 1 or 0
    reaper.GetSetAutomationItemInfo(a.env, a.idx, "D_UISEL", want, true)
  end
  reaper.Main_OnCommand(42086, 0)                              -- Envelope: Delete automation items
  -- put the selection back (the items of this envelope have new indexes: find them again by position, length and pool)
  for _, a in ipairs(all) do
    if a.sel and not (a.env == env and doomed[a.idx]) then
      for i = 0, reaper.CountAutomationItems(a.env) - 1 do
        local pos = reaper.GetSetAutomationItemInfo(a.env, i, "D_POSITION", 0, false)
        local len = reaper.GetSetAutomationItemInfo(a.env, i, "D_LENGTH", 0, false)
        local pool = reaper.GetSetAutomationItemInfo(a.env, i, "D_POOL_ID", 0, false)
        if math.abs(pos - a.pos) < 1e-6 and math.abs(len - a.len) < 1e-6 and pool == a.pool then
          reaper.GetSetAutomationItemInfo(a.env, i, "D_UISEL", 1, true)
          break
        end
      end
    end
  end
  return n_before - reaper.CountAutomationItems(env)
end

-- ── Automation item finalize ─────────────────────────────────
-- Call AFTER all points have been written to the base envelope.
-- Creates the automation item (absorbs base points), then deletes
-- any residual base-envelope points in the range.
-- Returns ai_idx (≥0 on success, <0 on failure).
function M.finalizeAutomationItem(env, ts_s, ts_e)
  reaper.Envelope_SortPointsEx(env, -1)
  M.removeAutomationItemsIn(env, ts_s, ts_e)          -- replace what is there (see above)
  local ai_idx = reaper.InsertAutomationItem(env, -1, ts_s, ts_e - ts_s)
  reaper.DeleteEnvelopePointRangeEx(env, -1, ts_s - 0.0001, ts_e + 0.0001)
  reaper.Envelope_SortPointsEx(env, -1)
  -- ReaSnap: which automation item was just made, so the tool that asked for it can put its settings on it.
  M.lastAI = (ai_idx and ai_idx >= 0) and { env = env, idx = ai_idx } or nil
  return ai_idx
end

-- ── Automation item commit ───────────────────────────────────
-- Convenience: insertPoints then finalizeAutomationItem.
-- Use when you have a pre-built pts list (RAND, MORPH).
-- For generators that write points themselves (LFO), call
-- finalizeAutomationItem directly after the write loop.
function M.commitAutomationItem(env, pts, ts_s, ts_e)
  M.insertPoints(env, pts, ts_s, ts_e - ts_s)
  return M.finalizeAutomationItem(env, ts_s, ts_e)
end

return M
