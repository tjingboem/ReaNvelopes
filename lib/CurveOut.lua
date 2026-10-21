--[[----------------------------------------------------------------------------
  CurveOut.lua — writing a CURVE (Curve.lua) out of ReaNvelopes (a family copy of ReaAC's core/reaac_curveout.lua,
  with opts.startBeats: where in the MIDI item the curve starts, in beats from the item start),
  besides notes. Two targets, one shared input:

    commitCC(curve, opts)        MIDI: a CC lane, pitch bend or channel
                                 pressure, into the selected MIDI item (or a
                                 new one at the edit cursor, as reaac_midi.lua
                                 does for notes).
    commitVelocity(curve, opts)  the velocity of the notes of the selected MIDI
                                 item, each note read from the curve at its start.
    commitEnvelope(curve, opts)  a parameter envelope: the envelope lane that
                                 is selected in REAPER (track, FX parameter
                                 or take FX), placed on the time selection
                                 or, without one, from the edit cursor.

  Everything about a module stays in the module; this file only knows how to
  put a curve into REAPER. The value mapping of an envelope (range, scaling
  mode) follows the approach already proven in ReaCurve and ReaComposeM
  (ScaleToEnvelopeMode with PARM_MIN/PARM_MAX), here in a smaller form.

  opts for both: name (string for undo and a new item), thin (v tolerance
  0..1 passed to Curve.thin; 0 or nil = no thinning), lo, hi (the part of the
  target range the curve uses, as fractions 0..1 of the whole range; default
  0 and 1), clear (true = remove what is already in the target range).

  opts for commitCC: kind ("cc" | "bend" | "pressure"), cc (0..127, for
  "cc"), channel (0..15).
  opts for commitEnvelope: automationItem (default true: the points go into a
  new automation item on the lane, which can be moved and copied as one block;
  take envelopes have no automation items and get plain points).
--------------------------------------------------------------------------------]]

local Curve = require("Curve")

-- The selected MIDI item's take and the project QN of its start (copied from ReaAC's reaac_midi.lua).
local function activeTake()
  if reaper.CountSelectedMediaItems(0) > 0 then
    local item = reaper.GetSelectedMediaItem(0, 0)
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      return take, reaper.TimeMap_timeToQN(itemStart), item
    end
  end
  return nil, nil, nil
end

local function selectedOrNewTrack()
  local track = reaper.GetSelectedTrack(0, 0)
  if track then return track end
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  return reaper.GetTrack(0, idx)
end

local function newMidiItem(name, lengthBeats)
  local track = selectedOrNewTrack()
  local cursorQN = reaper.TimeMap_timeToQN(reaper.GetCursorPosition())
  local endQN = cursorQN + math.max(lengthBeats, 1.0)
  local item = reaper.CreateNewMIDIItemInProj(track, cursorQN, endQN, true)
  local take = reaper.GetActiveTake(item)
  reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", name, true)
  return take, cursorQN, item
end

local Midi = { activeTake = activeTake, newMidiItem = newMidiItem }

local M = {}

-- CC curve shapes in REAPER (MIDI_SetCCShape): 0 square, 1 linear.
local CC_SHAPE_SQUARE, CC_SHAPE_LINEAR = 0, 1
-- Envelope point shapes (InsertEnvelopePointEx): 0 linear, 1 square.
local ENV_SHAPE_LINEAR, ENV_SHAPE_SQUARE = 0, 1

local function clamp01(x) return math.max(0.0, math.min(1.0, x)) end

-- The curve to write: thinned, with the value range applied (lo..hi
-- fractions of the target's whole range). Returns a new list of {t, v}.
local function preparedPoints(curve, opts)
  local c = Curve.thin(curve, opts.thin or 0)
  local lo = clamp01(opts.lo or 0.0)
  local hi = clamp01(opts.hi or 1.0)
  local out = {}
  for i, p in ipairs(c.points) do
    out[i] = { t = p.t, v = lo + p.v * (hi - lo) }
  end
  return out, c
end

-- ── MIDI CC / pitch bend / channel pressure ─────────────────────────────────

local function ccEventFor(kind, cc, v)
  if kind == "bend" then
    local val = math.floor(clamp01(v) * 16383 + 0.5)
    return 0xE0, val & 0x7F, (val >> 7) & 0x7F
  elseif kind == "pressure" then
    local val = math.floor(clamp01(v) * 127 + 0.5)
    return 0xD0, val, 0
  end
  local val = math.floor(clamp01(v) * 127 + 0.5)
  return 0xB0, cc, val
end

function M.commitCC(curve, opts)
  opts = opts or {}
  if not curve or #curve.points == 0 then return false, "nothing to write: the curve is empty" end
  local kind    = opts.kind or "cc"
  local cc      = math.max(0, math.min(127, math.floor(opts.cc or 1)))
  local channel = math.max(0, math.min(15, math.floor(opts.channel or 0)))

  local pts, used = preparedPoints(curve, opts)
  local shape = used.hold and CC_SHAPE_SQUARE or CC_SHAPE_LINEAR

  local take, baseQN, item = Midi.activeTake()
  if not take then
    take, baseQN, item = Midi.newMidiItem(opts.name or "ReaNvelopes", curve.lengthBeats)
  end
  baseQN = baseQN + (opts.startBeats or 0)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  reaper.MIDI_DisableSort(take)

  local firstPPQ = reaper.MIDI_GetPPQPosFromProjQN(take, baseQN + pts[1].t)
  local lastPPQ  = reaper.MIDI_GetPPQPosFromProjQN(take, baseQN + pts[#pts].t)

  -- Remove what is already there of this kind, channel and number in the range.
  if opts.clear ~= false then
    local chanmsgWant = ccEventFor(kind, cc, 0)
    local _, _, ccCount = reaper.MIDI_CountEvts(take)
    for i = ccCount - 1, 0, -1 do
      local ok, _, _, ppq, chanmsg, chan, msg2 = reaper.MIDI_GetCC(take, i)
      if ok and chanmsg == chanmsgWant and chan == channel
         and (kind ~= "cc" or msg2 == cc) and ppq >= firstPPQ - 0.5 and ppq <= lastPPQ + 0.5 then
        reaper.MIDI_DeleteCC(take, i)
      end
    end
  end

  -- Insert. Two points never share a tick (REAPER would keep both).
  local written, lastPPQwritten = {}, nil
  for _, p in ipairs(pts) do
    local ppq = math.floor(reaper.MIDI_GetPPQPosFromProjQN(take, baseQN + p.t) + 0.5)
    if ppq ~= lastPPQwritten then
      local chanmsg, msg2, msg3 = ccEventFor(kind, cc, p.v)
      reaper.MIDI_InsertCC(take, false, false, ppq, chanmsg, channel, msg2, msg3)
      written[#written + 1] = { ppq = ppq, chanmsg = chanmsg, msg2 = (kind == "cc") and msg2 or nil }
      lastPPQwritten = ppq
    end
  end
  reaper.MIDI_Sort(take)

  -- Set the curve shape of the events just written (found again by position).
  if reaper.MIDI_SetCCShape then
    local want = {}
    for _, w in ipairs(written) do want[w.ppq .. ":" .. w.chanmsg .. ":" .. (w.msg2 or "")] = true end
    local _, _, ccCount = reaper.MIDI_CountEvts(take)
    for i = 0, ccCount - 1 do
      local ok, _, _, ppq, chanmsg, chan, msg2 = reaper.MIDI_GetCC(take, i)
      if ok and chan == channel then
        local key = math.floor(ppq + 0.5) .. ":" .. chanmsg .. ":" .. ((kind == "cc") and msg2 or "")
        if want[key] then reaper.MIDI_SetCCShape(take, i, shape, 0, true) end
      end
    end
    reaper.MIDI_Sort(take)
  end

  reaper.PreventUIRefresh(-1)
  if item then reaper.UpdateItemInProject(item) end
  reaper.Undo_EndBlock((opts.name or "ReaNvelopes") .. ": curve to MIDI CC", -1)
  return true, nil, item, #written
end

-- ── Note values ─────────────────────────────────────────────────────────────

-- Sets one value of the notes of the selected MIDI item from the curve. The curve starts at the start of the item (plus
-- opts.startBeats); a note takes the value of the curve at its START, except "lift", which reads at the END of the
-- note (the moment of the release). Notes outside the length of the curve are left alone.
--
-- opts.value and what goes with it:
--   "velocity"  lo, hi        the part of 1..127 the curve uses, as fractions 0..1
--   "lift"      lo, hi        the same, for the note-off velocity (the release velocity)
--   "duration"  durMode       "factor": the note keeps its start and its length is multiplied by durLo..durHi
--                             (ratios, e.g. 0.25..2: below 1 shortens, above 1 lengthens); "absolute": the length
--                             is durLo..durHi beats; "shift": durLo..durHi beats are added to the length (negative
--                             values shorten, positive lengthen, e.g. -0.25..+0.25)
--   "pitch"     pitchMode     "shift": the pitch moves by pitchLo..pitchHi semitones; "absolute": the pitch is
--                             pitchLo..pitchHi
--   "channel"   chLo, chHi    the channel is chLo..chHi (0..15), rounded
--   "mute"      threshold     0..1: the note is muted where the curve is below it (unmuted where it is at or above);
--               invert        true: muted where the curve is at or above it
-- Returns ok, err, item, count.

local function noteBeat(take, baseQN, opts, ppq)
  return reaper.MIDI_GetProjQNFromPPQPos(take, ppq) - baseQN - (opts.startBeats or 0)
end

-- Lift: the velocity of the note-off events. REAPER keeps it in the note-off message (0x8n, key, velocity), so the
-- take's raw events are read, every note-off inside the curve gets its value, and they are written back. A note-off
-- that is stored as a note-on with velocity 0 is turned into a real note-off to carry the value.
local function commitLift(curve, opts, take, baseQN, item)
  local lo = clamp01(opts.lo or 0.0)
  local hi = clamp01(opts.hi or 1.0)
  local ok, buf = reaper.MIDI_GetAllEvts(take, "")
  if not ok or not buf then return false, "could not read the MIDI events of the item" end
  local pos, abs, count = 1, 0, 0
  local out = {}
  while pos <= #buf do
    local offset, flags, msg, nxt = string.unpack("<i4Bs4", buf, pos)
    abs = abs + offset
    local status = msg:byte(1) or 0
    local isOff = (#msg == 3) and ((status & 0xF0) == 0x80 or ((status & 0xF0) == 0x90 and msg:byte(3) == 0))
    if isOff then
      local beat = noteBeat(take, baseQN, opts, abs)
      if beat >= -1e-6 and beat <= curve.lengthBeats + 1e-6 then
        local v = lo + Curve.eval(curve, math.max(0, beat)) * (hi - lo)
        local vel = math.max(1, math.min(127, math.floor(v * 127 + 0.5)))
        msg = string.char(0x80 | (status & 0x0F), msg:byte(2), vel)
        count = count + 1
      end
    end
    out[#out + 1] = string.pack("<i4Bs4", offset, flags, msg)
    pos = nxt
  end
  if count == 0 then return false, "no note-off inside the curve (does the item have notes in the range?)" end
  if not reaper.MIDI_SetAllEvts(take, table.concat(out)) then return false, "REAPER refused the changed MIDI events" end
  return true, nil, item, count
end

local LABEL = {
  velocity = "note velocity", lift = "note-off velocity (lift)", duration = "note duration",
  pitch = "note pitch", channel = "note channel", mute = "note mute",
}

function M.commitNoteValue(curve, opts)
  opts = opts or {}
  local what = opts.value or "velocity"
  if not LABEL[what] then return false, "unknown note value: " .. tostring(what) end
  if not curve or #curve.points == 0 then return false, "nothing to write: the curve is empty" end
  local take, baseQN, item = Midi.activeTake()
  if not take then
    return false, "select the MIDI item whose notes should be changed first"
  end
  local _, noteCount = reaper.MIDI_CountEvts(take)
  if not noteCount or noteCount == 0 then return false, "the selected MIDI item has no notes" end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local ok, err, count = true, nil, 0

  if what == "lift" then
    local o, e, _, c = commitLift(curve, opts, take, baseQN, item)
    ok, err, count = o, e, c or 0
  else
    local lo = clamp01(opts.lo or 0.0)
    local hi = clamp01(opts.hi or 1.0)
    for i = 0, noteCount - 1 do
      local got, _, muted, sPPQ, ePPQ, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
      if got then
        local beat = noteBeat(take, baseQN, opts, sPPQ)
        if beat >= -1e-6 and beat <= curve.lengthBeats + 1e-6 then
          local c = Curve.eval(curve, math.max(0, beat))
          if what == "velocity" then
            local v = lo + c * (hi - lo)
            reaper.MIDI_SetNote(take, i, nil, nil, nil, nil, nil, nil, math.max(1, math.min(127, math.floor(v * 127 + 0.5))), true)
          elseif what == "duration" then
            local sQN = reaper.MIDI_GetProjQNFromPPQPos(take, sPPQ)
            local eQN = reaper.MIDI_GetProjQNFromPPQPos(take, ePPQ)
            local dLo, dHi = opts.durLo or 0.25, opts.durHi or 2.0
            local f = dLo + c * (dHi - dLo)
            local oldLen = eQN - sQN
            local newLen = (opts.durMode == "absolute") and f or (opts.durMode == "shift") and (oldLen + f) or oldLen * f
            newLen = math.max(newLen, 1 / 960)   -- never zero
            reaper.MIDI_SetNote(take, i, nil, nil, nil, reaper.MIDI_GetPPQPosFromProjQN(take, sQN + newLen), nil, nil, nil, true)
          elseif what == "pitch" then
            local pLo, pHi = opts.pitchLo or -12, opts.pitchHi or 12
            local v = pLo + c * (pHi - pLo)
            local np = (opts.pitchMode == "absolute") and math.floor(v + 0.5) or (pitch + math.floor(v + 0.5))
            reaper.MIDI_SetNote(take, i, nil, nil, nil, nil, nil, math.max(0, math.min(127, np)), nil, true)
          elseif what == "channel" then
            local cLo, cHi = opts.chLo or 0, opts.chHi or 15
            local ch = math.floor(cLo + c * (cHi - cLo) + 0.5)
            reaper.MIDI_SetNote(take, i, nil, nil, nil, nil, math.max(0, math.min(15, ch)), nil, nil, true)
          elseif what == "mute" then
            local below = c < (opts.threshold or 0.5)
            reaper.MIDI_SetNote(take, i, nil, (opts.invert and not below) or (not opts.invert and below), nil, nil, nil, nil, nil, true)
          end
          count = count + 1
        end
      end
    end
    reaper.MIDI_Sort(take)
  end

  reaper.PreventUIRefresh(-1)
  if item then reaper.UpdateItemInProject(item) end
  reaper.Undo_EndBlock((opts.name or "ReaNvelopes") .. ": curve to " .. LABEL[what], -1)
  if not ok then return false, err end
  return true, nil, item, count
end

-- Kept for callers of the first version: the velocity of the notes.
function M.commitVelocity(curve, opts)
  local o = {}
  for k, v in pairs(opts or {}) do o[k] = v end
  o.value = "velocity"
  return M.commitNoteValue(curve, o)
end

-- ── Parameter envelope ──────────────────────────────────────────────────────

-- Name and mapping facts of the selected envelope lane, or nil and a message.
function M.selectedEnvelope()
  local env = reaper.GetSelectedEnvelope(0)
  if not env then
    return nil, "select an envelope lane in REAPER first (click its name in the track control panel)"
  end
  local _, name = reaper.GetEnvelopeName(env)
  return env, nil, name or ""
end

-- Where the envelope's own time zero is, and whether it is a take envelope:
-- (0, false) for a track envelope, (item position, true) for a take envelope
-- of the selected item. Automation items exist on track envelopes only.
local function timeOffsetOf(env)
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if take then
      for e = 0, reaper.CountTakeEnvelopes(take) - 1 do
        if reaper.GetTakeEnvelope(take, e) == env then
          return reaper.GetMediaItemInfo_Value(item, "D_POSITION"), true
        end
      end
    end
  end
  return 0.0, false
end

-- (lo, hi, mode) of an envelope: PARM_MIN/PARM_MAX, then MINVAL/MAXVAL of its
-- state chunk, then 0..1. mode is REAPER's scaling mode (1 = fader).
local function envelopeRange(env)
  local mode = reaper.GetEnvelopeScalingMode(env)
  if mode == 1 then return 0.0, 1.0, mode end
  local pmin = reaper.GetEnvelopeInfo_Value(env, "PARM_MIN")
  local pmax = reaper.GetEnvelopeInfo_Value(env, "PARM_MAX")
  if pmin and pmax and (pmax - pmin) > 1e-9 then return pmin, pmax, mode end
  local ok, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
  if ok and chunk then
    local mn = tonumber(chunk:match("\nMINVAL ([%-%.%d]+)"))
    local mx = tonumber(chunk:match("\nMAXVAL ([%-%.%d]+)"))
    if mn and mx and (mx - mn) > 1e-9 then return mn, mx, mode end
  end
  return 0.0, 1.0, mode
end

local function toEnvelopeValue(v, lo, hi, mode)
  if mode == 1 then return reaper.ScaleToEnvelopeMode(mode, v) end
  return reaper.ScaleToEnvelopeMode(mode, lo + v * (hi - lo))
end

function M.commitEnvelope(curve, opts)
  opts = opts or {}
  if not curve or #curve.points == 0 then return false, "nothing to write: the curve is empty" end
  local env, err, envName = M.selectedEnvelope()
  if not env then return false, err end

  local pts, used = preparedPoints(curve, opts)
  local shape = used.hold and ENV_SHAPE_SQUARE or ENV_SHAPE_LINEAR

  -- Time: the time selection if there is one (the curve is stretched over it),
  -- otherwise from the edit cursor for the length of the curve in beats.
  local tsS, tsE = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  if opts.rangeStart and opts.rangeEnd and (opts.rangeEnd - opts.rangeStart) >= 0.01 then   -- the caller's own range
    tsS, tsE = opts.rangeStart, opts.rangeEnd
  end
  local startTime, lenTime
  if (tsE - tsS) >= 0.01 then
    startTime, lenTime = tsS, tsE - tsS
  else
    startTime = reaper.GetCursorPosition()
    local qn0 = reaper.TimeMap_timeToQN(startTime)
    lenTime = reaper.TimeMap_QNToTime(qn0 + curve.lengthBeats) - startTime
  end
  local offset, isTake = timeOffsetOf(env)
  local useAI = (opts.automationItem ~= false) and not isTake
  local lenBeats = math.max(curve.lengthBeats, 1e-9)
  local lo, hi, mode = envelopeRange(env)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  -- An automation item collects the points that lie in its range, so what is already there is cleared first
  -- in that case whatever "clear" says.
  if opts.clear ~= false or useAI then
    reaper.DeleteEnvelopePointRangeEx(env, -1, startTime - offset - 0.0001, startTime - offset + lenTime + 0.0001)
  end
  for _, p in ipairs(pts) do
    local t = startTime - offset + (p.t / lenBeats) * lenTime
    reaper.InsertEnvelopePointEx(env, -1, t, toEnvelopeValue(p.v, lo, hi, mode), shape, 0, false, true)
  end
  reaper.Envelope_SortPointsEx(env, -1)
  local aiIdx = nil
  if useAI then
    -- Same order as ReaCurve: create the item (it takes the points of the range), then remove any base points left.
    aiIdx = reaper.InsertAutomationItem(env, -1, startTime, lenTime)
    reaper.DeleteEnvelopePointRangeEx(env, -1, startTime - 0.0001, startTime + lenTime + 0.0001)
    reaper.Envelope_SortPointsEx(env, -1)
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock((opts.name or "ReaNvelopes") .. ": curve to envelope", -1)
  return true, nil, envName, #pts, (useAI and aiIdx ~= nil and aiIdx >= 0)
end

return M
