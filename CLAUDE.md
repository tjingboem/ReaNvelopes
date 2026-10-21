# ReaNvelopes — working notes

Started 21 October 2026 by tjingboem as the home of ReaComposeM's curve-GENERATING part. He intends to delete the
ReaComposeM repo later. All editing of a curve happens in REAPER's own envelope editor (and ReaShapeM where it helps),
so there is no editor here. See `~/Downloads/ReaTjingboem/CLAUDE.md` ("How the family fits together") for why.

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

## DRAW smooth (fixed 21 October 2026)

DRAW's Smooth mode (smoothstep between the points, `DRAWState.sampleAt`) was ignored by the OUTPUT section: it was
handed only the control points and wrote straight lines between them. Smooth now hands over 257 samples of the curve
itself (the thinning in the OUTPUT section reduces them again; 25 points for a three-point shape). Linear sends the
control points, Step sends them as a hold curve.

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
