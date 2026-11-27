#!/bin/bash
# One-way sync: git repo (source of truth) -> REAPER's live Scripts copy.
# Never run this in reverse -- REAPER's copy is disposable, this one isn't.
# Load ReaNvelopes.lua from the live copy in REAPER's Actions list (once per machine).
# Presets a user saves land in the live copy (OSCPresets, RANDPresets): protected from --delete.
rsync -av --delete \
  --filter='P OSCPresets/***' --filter='P RANDPresets/***' --filter='P DRAWPresets/***' \
  --exclude='.git' \
  --exclude='doc' \
  --exclude='sync_to_reaper.sh' --exclude='toolbar_icons' \
  ~/Claude/ReaNvelopes/ /home/tjingboem/.config/REAPER/Scripts/tjingboem/ReaNvelopes/
mkdir -p ~/.config/REAPER/Data/toolbar_icons && cp ~/Claude/ReaNvelopes/toolbar_icons/*.png ~/.config/REAPER/Data/toolbar_icons/   # toolbar icon (90x30, 3 states)
