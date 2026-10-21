-- ============================================================
--   Logger.lua
--   Centralized message bus.
--   Decouples message production (services) from display (UI).
--   Usage:
--     Logger.ok("✔ Done")       → green status
--     Logger.error("⚠ Failed")  → red blinking status
--     local msg, is_ok = Logger.get()
-- ============================================================

local M = {}

local _msg   = "Ready"
local _is_ok = true
local _popup = nil      -- a message the hub shows in a window the user has to close with OK
M.capture = nil         -- while a table: every error is also collected in it (see OutputPanel's write actions)

-- Set a success / informational message.
function M.ok(msg)
  _msg   = msg or ""
  _is_ok = true
end

-- Set an error message (UI will display it in red with blink).
function M.error(msg)
  _msg   = msg or ""
  _is_ok = false
  if M.capture then M.capture[#M.capture + 1] = _msg end
end

-- Ask the hub to show `msg` in a window the user has to close with OK.
function M.popup(msg)
  _popup = msg
end

-- The pending popup message (nil if none). The hub reads it once, then calls clearPopup().
function M.peekPopup() return _popup end
function M.clearPopup() _popup = nil end

-- Returns (message_string, is_ok_boolean).
function M.get()
  return _msg, _is_ok
end

return M
