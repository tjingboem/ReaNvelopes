#!/bin/bash
# One-way sync: git repo (source of truth) -> REAPER's live Scripts copy.
# Never run this in reverse -- REAPER's copy is disposable, this one isn't.
# Load ReaNvelopes.lua from the live copy in REAPER's Actions list (once per machine).
# Presets a user saves land in the live copy (OSCPresets, RANDPresets): protected from --delete.
rsync -av --delete \
  --filter='P OSCPresets/***' --filter='P RANDPresets/***' --filter='P DRAWPresets/***' \
  --exclude='.git' \
  --exclude='doc' \
  --exclude='sync_to_reaper.sh' \
  ~/Downloads/ReaNvelopes/ /home/tjingboem/.config/REAPER/Scripts/tjingboem/ReaNvelopes/
