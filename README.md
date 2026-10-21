# ReaNvelopes

Envelope generators for REAPER. Make a curve, then send it where it is needed:

- a **parameter envelope** (as an automation item on the selected lane),
- a **MIDI CC, pitch bend or channel pressure** lane in a MIDI item,
- the **velocity of the notes** of a MIDI item.

Two generators: **RAND** (random shapes) and **OSC** (a polygon LFO). Everything is edited afterwards in REAPER itself.

Needs ReaImGui, the SWS extension and js_ReaScriptAPI (all via ReaPack). Load `ReaNvelopes.lua` into the Actions list.

Parts of the code are derived from sailok's ReaCurve, used with his permission.
