# ReaNvelopes — working notes

Started 21 October 2026 by tjingboem as the home of ReaComposeM's curve-GENERATING part. He intends to delete the
ReaComposeM repo later. All editing of a curve happens in REAPER's own envelope editor (and ReaShapeM where it helps),
so there is no editor here. See `~/Claude/ReaTjingboem/CLAUDE.md` ("How the family fits together") for why.

## What is here

- `ReaNvelopes.lua` — the hub: a window with the tabs RAND, OSC and DRAW.
- `ReaNvelopes_RAND.lua`, `ReaNvelopes_OSC.lua`, `ReaNvelopes_DRAW.lua` — the three generators (from ReaComposeM's
  `ReaCompose_RAND.lua`, `ReaCompose_OSC.lua`, `ReaCompose_DRAW.lua`), each with its OUTPUT section instead of the
  old "SEND SHAPE" to the editor. DRAW (click to add points, drag to move, right-click to delete; linear, smooth or
  step) was first left behind by mistake (Claude counted it as editing) and added the same day at tjingboem's
  question; it has no envelope writer of its own, so its envelope target uses the generic one in `CurveOut`, and
  its step mode goes out as a hold curve (square shapes).
- `lib/RAND`, `lib/OSC`, `lib/DRAW` — the panels, state, presets code and writers (derived from sailok's ReaCurve).
- `lib/CommonFunction` (+ `UI`) — envelope utilities, widgets, theme, logger (also from ReaComposeM/ReaCurve).
- `lib/Curve.lua`, `lib/CurveOut.lua` — family copies of ReaAC's `core/reaac_curve.lua` and `core/reaac_curveout.lua`
  (the curve format and the writers: MIDI CC / pitch bend / pressure, note velocity, envelope). CurveOut here has
  `opts.startBeats` (where in the MIDI item the curve starts), which ReaAC's copy does not have yet.
- `lib/OutputPanel.lua` — the OUTPUT section both tools use. Target: Parameter envelope (the tool's own writer, an
  automation item), MIDI CC / pitch bend / pressure (own Channel slider), Note velocity. Time: the time selection,
  otherwise the selected item; the curve is stretched over it.
- `OSCPresets/`, `RANDPresets/`, `DRAWPresets/` — preset files (looked up next to the hub script; `sync_to_reaper.sh` protects the
  live copy's presets from `--delete`).

## Clean-up (21 October 2026)

tjingboem: no remarks under the write button (the message window covers failures), a rounded write button, and 50 %
more width. Done: the status line under the OUTPUT section of RAND and OSC is gone, and so are the two hint lines the
OUTPUT section showed under the button for the MIDI and note value targets (so a successful write or a loaded preset
gives no green message any more; only failures speak, in the message window); the write button has rounded corners
(frame rounding 8); the hub window is 570 px wide at first (was 380) with a width range of 510 to 900 (was 340 to 600).
The manual's section 3.2 was rewritten ("Messages") to match.

## Range sliders removed (21 October 2026)

The OUTPUT sliders "Range low %" and "Range high %" are gone: they were a second linear scaling applied after the
generator's own Amplitude, Offset and Amp Range, and only for the MIDI targets (not the envelope target). The curve now
fills the whole range of the target (CC 0..127, pitch bend, pressure, velocity and lift 1..127). To use part of a range:
Amplitude, Offset or Amp Range in RAND and OSC, or draw inside the part in DRAW. `CurveOut` still accepts `opts.lo`
and `opts.hi` (default 0 and 1); the panel just does not set them. The manual was changed to match.

## Note values (21 October 2026)

OUTPUT target 3 is "Note value (selected MIDI item)", with a second choice, Value: Velocity, Velocity off (lift),
Duration, Pitch, Channel, Mute. Each note of the selected item reads the curve at its START (lift reads at the END,
the moment of the release); notes outside the length of the curve are left alone; position in time as for the other
targets (the time selection, from the start of the item plus the offset). `CurveOut.commitNoteValue(curve, opts)`:
- velocity: range low and high are the part of 1..127 used.
- lift: the same range, written into the raw events of the take (`MIDI_GetAllEvts` / `MIDI_SetAllEvts`): every note-off
  inside the curve gets the velocity; a note-off stored as note-on with velocity 0 is turned into a real 0x8n message to
  carry it. Offline-tested on a fake event buffer; how REAPER treats a note-off velocity is NOT yet tested in REAPER.
- duration: "factor" (the note's length times 25..200 %, the default: below 100 % shortens, above lengthens), "absolute"
  (1/128 to 4 beats) or "shift" (+/- beats added to the length, default -0.25..+0.25, added after tjingboem asked that
  notes can also get shorter, not only longer); the start stays, the length never goes below one tick.
- pitch: "shift" (-12..+12 semitones, default) or "absolute" (a range); clamped to 0..127. No scale snap yet.
- channel: a channel range 1..16 (rounded); mute: muted where the curve is below the threshold (or at or above it, with
  "mute high intensity instead of low").
Not built, on purpose: position (timing is ReaShapeM's), program change, polyphonic pressure.

## Close All (21 October 2026)

`lib/ReaSnap_Integration.lua` holds pieces 2 (window title with the instance number) and 5 (Close All) of the ReaSnap
Integration Contract, as in ReaComposeM's version; the hub shows `ReaSnap.windowTitle` and closes when
`ReaSnap.shouldClose()` says so (outside the visible gate, so a collapsed window also closes). It only works for an
instance launched through ReaSnap (the launcher puts the project identity in ExtState); one started from the Actions
list is not eligible.

## Full member of ReaSnap (19 November 2026)

tjingboem: "i want ReaNvelopes to be a full member of the ReaSnap system." Pieces 1, 3 and 4 are built:
- Piece 1: `lib/ReaNvelopes_Serial.lua` (a copy of ReaAC's `core/reaac_serial.lua`; no `load()` of strings from outside).
- Piece 3: after a successful WRITE MIDI (CC / pitch bend / pressure) or SET NOTE VALUES, `OutputPanel` writes
  `{ tool = "RAND"|"OSC"|"DRAW", gen = <that generator's preset data>, out = <the OUTPUT section's settings> }` ONTO the MIDI
  item (item P_EXT `ReaNvelopes_ItemSettings`, base64, so a copy of the item carries it; `ReaSnap.writeItemState`). The
  generators give their settings through `getToolState` (6th argument of `OutputPanel.draw`) = `<X>Presets.getData()`, which
  is the preset content.
- The envelope targets write an automation item: the same state goes into the automation item's pool
  (`GetSetAutomationItemInfo_String`, `P_POOL_EXT:ReaNvelopes_ItemSettings`, base64; `ReaSnap.writeAutomationItemState`,
  called after `EnvWriter.finalizeAutomationItem` set `EnvWriter.lastAI`, or with the env and index that
  `CurveOut.commitEnvelope` now returns). ReaSnap's S button falls back to the selected automation item of the selected
  envelope (`ReaSnap_Core.selected_automation_item_state`), and Capture walks the automation items of every track
  (snapshot key `script_ReaNvelopes_AI<track guid>_<envelope>_<index>`). Written 19 November 2026, tested only against
  a mock, then tried in REAPER by tjingboem the same day: S on the written item works, S on the restored item works, S on a
  pooled copy and on an unpooled (unique) copy both work. The snapshot restore left the automation item EMPTY (its points
  did not come back), which ReaSnap now repairs itself: Capture records each automation item (position, length, points,
  tool settings) under `autoitem_<track guid>_<envelope>_<index>`, Restore fills an empty item from that record or
  inserts a missing one (`ReaSnap_Core.lua`, `capture_automation_items` / `restore_automation_items`).
- Send curve writes no item and no automation item, so nothing is remembered for it.
- Piece 4: ReaSnap's launch with settings leaves `pending_ReaNvelopes_settings`; `ReaSnap.pending_state` holds it, the hub
  applies it before the first frame (`<X>Presets.applyData`, `OutputPanel.applyState`) and shows that generator's tab first.
Tested offline (write -> ReaSnap's reader -> apply, for RAND, OSC and DRAW, and the pending hand-over). NOT yet tried in REAPER.

## DRAW smooth (fixed 21 October 2026)

DRAW's Smooth mode (smoothstep between the points, `DRAWState.sampleAt`) was ignored by the OUTPUT section: it was
handed only the control points and wrote straight lines between them. Smooth now hands over 257 samples of the curve
itself (the thinning in the OUTPUT section reduces them again; 25 points for a three-point shape). Linear sends the
control points, Step sends them as a hold curve.

## ReaNvelopes and ReaShapeM — how they divide the work (tjingboem, 21 October 2026)

ReaShapeM is more focused on a SELECTION of notes in the MIDI editor; ReaNvelopes works on the ITEM (a time range of
it). His idea: make raw structures first with ReaNvelopes, and when the composition takes shape, finetune with ReaShapeM.
ReaShapeM already has envelope passes for timing (warp, groove, quantize, humanize, TSB), pitch (octave redistribution,
pitch compression/expansion, interval scaling), velocity, duration, channel and mute, with a red/yellow preview and an
audition; ReaNvelopes' Note value target is the broad-stroke version of part of that. What only ReaNvelopes has: the
generators (RAND, OSC, DRAW) and the parameter envelope and CC targets, and Lift (release velocity), which ReaShapeM
does not do. Consequence: do not build more note-value operations here (no pitch compressor, no microtuning); they
belong in ReaShapeM. A possible link, not looked at: let the generators feed ReaShapeM's envelopes. Possible small
addition here: an option to apply a note value only to the SELECTED notes of the item.

## Manual (21 October 2026)

`doc/ReaNvelopes_Manual.odt`: about 5,400 words, 21 tables, contents list. Written for users (no design reasons, no
internals). It documents the window, the time range rules, the OUTPUT section (all targets and note values), RAND, OSC
and DRAW with every setting, range and default, recipes, a reference chapter, the messages and their remedies. It was
built from a script (plain ODF, not saved by LibreOffice) and NOT rendered: LibreOffice does not start on this
machine, so tjingboem checks the look. To edit it later, unzip it, edit `content.xml`, rezip with `mimetype` stored
first (his usual recipe). The contents list is static until "Update Index" is run in LibreOffice (adds page numbers).
Facts in it come from reading the code of the three tools, not from running them in REAPER.

Found while writing it: RAND's own envelope writer opened no undo block (the old RAND panel wrapped it), so the
OUTPUT button now wraps it (`ReaNvelopes_RAND.lua`); and DRAW's header comment promised "click to add points", but
the code only draws freehand strokes, moves points and deletes them (it was corrected). DRAW has no click-to-add;
that is a possible addition.

## MicroTuning (not moved yet)

ReaComposeM's `lib/MicroTuning.lua` (Scala parser, cents-based quantise to a scale, note plus pitch bend, MPE channel
allocation) is the same module that ReaMaskM carries embedded (same functions; ReaComposeM's has `fromNormPitch` in
addition). Worth salvaging for a Pitch mode with a Scala scale (snap each pitch to a scale degree, with the bend on an
MPE channel). When that is built, copy the ReaComposeM file into `lib/` here; ReaMaskM keeps its own copy.

## Messages

A failed write (no envelope selected, no time selection, no curve, an item selected that has no take FX envelope ...)
is shown in a modal window that the user has to close with OK; the status bar line was too easy to miss
(tjingboem, 21 October 2026). `OutputPanel` runs every write inside `Logger.capture`; the errors collected become
one `Logger.popup(message)`, and the hub (`ReaNvelopes.lua`) opens the window (`BeginPopupModal`, no close box, an
OK button). For the envelope target the window adds "Select the envelope lane first". Note how the tools pick their
target: with a media item selected, `EnvWriter.resolveTarget` wants a take FX envelope of that item; without an
item it wants a time selection and a selected track envelope. That is why an item that is still selected gives
"Selected item has no take FX envelope lane" when a track envelope was meant.

## Left behind on purpose (still in ReaComposeM)

The note editor (`ReaCompose_EDITOR.lua`, `EDITORState`, `EDITORPresets`), `SCOREWrite`
(note generation, audition), `MicroTuning` (needed later for a pitch applier in ReaAC), the ReaSnap integration
(`ReaSnap_Integration`, `ReaComposeM_Serial`).

## State

- 21 October 2026: files moved, editor hooks removed, OUTPUT section built. Tested offline only: the hub runs its
  window loop with a fake ReaImGui (RAND, OSC and DRAW tabs, 4 frames, no error), and `OutputPanel` against a fake REAPER
  (CC placement from the time selection and item start, note velocity inside the range, the tool's own envelope
  writer is called, the generic envelope write over the time selection as an automation item, a step curve, messages
  when there is no range or no curve). NOT yet run in REAPER.
- Install: `sh sync_to_reaper.sh` copies to `Scripts/tjingboem/ReaNvelopes`; load `ReaNvelopes.lua` into the Actions
  list once.

## Ideas, not built

- ReaSnap integration (the registry id depends on where the script was loaded, see `ReaSnap/CLAUDE.md`).
- The envelope target of the OUTPUT section uses each tool's own writer; a generic envelope writer is in `CurveOut`
  (`commitEnvelope`) if the two ever need to be the same.
- Applying a curve to the pitch, length or channel of notes (planned for ReaAC once this is settled).
- Credit and license: sailok is okay with the use of ReaCurve code (a message, not in writing); the LICENSE here is the
  same placeholder as ReaComposeM's. Read the upstream license before this goes to other people.

## Pin, follow and one window (19 November 2026) — BUILT, tested with the real hub in a REAPER of its own, NOT yet seen in the real window

tjingboem: add the pin and the follow to ReaNvelopes, and "1 window is allowed except when pinned".
- Pin: the "tjingboem productions" label in the title bar (added here; a click toggles, blue when pinned), as in ReaMaskM, ReaShapeM and ReaGestM. Pinned, the
  window stops following the selection and a new window opens next to it. (ReaNvelopes writes to whatever is selected or to the chosen lane; the pin does not
  bind a target, it only keeps the window's settings.)
- Follow (`lib/ItemFollow.lua`): a window launched by ReaSnap (project identity known) loads the settings of the selected media item, or else the selected
  automation item of the selected envelope, when the selection changes (`apply_state` in the hub: generator settings, OUTPUT settings, that generator's tab).
  An item without ReaNvelopes settings leaves the window as it is; a window opened from the Actions list never follows.
- One window (`lib/WindowRegistry.lua`): every open window renews a time stamp and its pin state in ExtState (section ReaNvelopes_Windows) from its OWN frame
  loop (at most twice a second, nothing in the background; stamps older than 2 s count as gone). A window started while another UNPINNED one is open does not
  open: it hands over what it was started with (ReaSnap's S settings, or nothing) and ends; the open window loads that and comes to the front. NOTE: ReaSnap's
  CLAUDE.md says "don't reintroduce heartbeat code" (about tracking liveness from ReaSnap's side); this is the window's own stamp, asked for by tjingboem.
  It only works when REAPER's "Terminate or New instance?" dialog is answered "New instance" (tick Remember): the script has to start to be able to hand over.
  ReaSnap: `SINGLE_INSTANCE_SCRIPTS.ReaNvelopes = true`, so a Restore launches it once.
- Tests (in a REAPER with ReaImGui, SWS, js_ReaScriptAPI, RT_EXT=1 in the runner): `tests/selftest_window.lua` (18 checks: registry, stale stamps, what is followed) and
  `tests/hub_smoke.lua` (13 checks with the REAL hub drawing frames: starts, follows an item, a second hub hands over and does not open, a pinned window is left
  alone). Not tested: the click on the label, the focus change, the tab switching on screen.


## Corrections item 22: the selected envelope decides, and a write replaces (19 November 2026) — BUILT, tested in a REAPER of its own, waiting for tjingboem's test

tjingboem (screenshot of "Selected item has no take FX envelope lane"): he HAD selected the envelope lane; and a write into a lane that already had an automation item "adds to the existing one".
- `EnvWriter.resolveTarget` (RAND and OSC): new Case 0 at the top: when the selected envelope is a TRACK envelope (`I_TAKEENVELOPE ~= 1`) it decides, whatever media item is still selected (that was the bug:
  Case 1 looked at the selected item first and refused). Range: the time selection; without one, the selected item's own length; without either: "Set a time selection (the envelope lane is selected)".
  The message for "an item is selected but no lane" now says what to do ("Click the name of an envelope lane (track panel) and set a time selection"). The generic writer (`CurveOut.selectedEnvelope`) never had the problem.
- Replace: `EnvWriter.removeAutomationItemsIn(env, ts_s, ts_e)` deletes every automation item of that envelope that lies COMPLETELY inside the range before the new one is made (called by
  `finalizeAutomationItem`, so RAND, OSC and DRAW's own writers, and by `CurveOut.commitEnvelope`, the generic one). An item that only OVERLAPS the range stays (the new item lies on top of it) — tjingboem has
  not said what he wants there. REAPER has no function to delete an automation item, only the action 42086 "Envelope: Delete automation items", which deletes the SELECTED ones of the whole project, so the
  selection of every other automation item is put aside and restored (the new item itself is selected by REAPER's own InsertAutomationItem, which drops the others' selection: not ours to keep).
  The deletion is part of the write's undo step.
- Test: `tests/selftest_item22.lua` (14 checks, in a REAPER with ReaImGui, SWS, js_ReaScriptAPI): the envelope decides with an item still selected, the item's length as the range, a refusal with neither, replacing the
  item at the same time in both writers, items elsewhere and a partly overlapping one stay, a selected item on another lane keeps its selection.

## Window place (19 November 2026) — BUILT, tested in a REAPER of its own, NOT yet seen on a real screen

Corrections list item 21, fourth tool (ReaMaskM, ReaShapeM, ReaGestM, ReaNvelopes; design in ReaMaskM's CLAUDE.md). `lib/WindowPlace.lua` is the same file as in the other tools; without it the tool works as
before. The hub window can be resized (within 510-900 x 500-1400, `SetNextWindowSizeConstraints`), so position AND size are applied on the first frame (Cond_Once, after the default 570 x 900 FirstUseEver call).
`Place.frame(..., pinned)` runs right before the title-bar label (the pin), `Place.close()` when the window closes (and at exit). Windows that hand over to an open window (one window unless pinned) never get here:
the hub returns before the context exists. Tests: `tests/selftest_place.lua` (copy, 31 checks in plain Lua), `tests/hub_smoke.lua` (the real hub is given the saved position and size, 15 checks);
`tests/selftest_window.lua` (18) and `tests/selftest_item22.lua` (14) still pass.

## Send to ReaCat and the world (23 November 2026) — BUILT, tested offline (14 checks) and with the real hub in a REAPER of its own, NOT yet used by tjingboem, NOT committed
OUTPUT target 4 was "Send to ReaMaskM / ReaShapeM"; it is now **"Send to ReaCat and the world"** (button SEND TO REACAT). `lib/ReaCatSend.lua` fits the curve (`CurveShare.encodeControl` / `encode`)
and stores it in the ReaCat catalogue (`lib/ReaCat.lua`, an identical copy of ReaCat's own; spec in `~/Claude/ReaCat/doc/ReaCat_Spec.md`): source ReaNvelopes, name RAND / OSC / DRAW, the REAPER project name as a fixed tag.
TEMPORARY: it still writes the old one-slot place too, so ReaMaskM / ReaShapeM "Take Curve from ReaNvelopes" keep working until they take curves from ReaCat. The manual (`doc/ReaNvelopes_Manual.odt`) still says "Send to ReaMaskM / ReaShapeM": to update.

## A write also files a copy in ReaCat (23 November 2026) — BUILT, tested offline and in a REAPER of its own (selftest_written 11, hub_smoke 15), NOT used by tjingboem, NOT committed
After a successful write (MIDI CC, note values, both envelope writers) `OutputPanel` calls `ReaCatSend.fileWritten`: the curve is filed in ReaCat (tag `written`) and marked as used by the item or automation item; the item's notes get one `ReaCat: ...` line (the name suffix is a ReaCat setting, off by default). A failure never hides the write; a failed write files nothing.
