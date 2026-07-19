-- ubKeybind Editor — modal key-capture session.
--
-- Drives one "press keys for this action" interaction. Pure-ish: all engine
-- reads are injected (GetKeySymbol/GetScanSymbol/meta state), so the state
-- machine is unit-testable by feeding synthetic presses.
--
-- Flow:
--   begin{unitId, slot, actionLabel}  → active, waiting for input
--   keyPress(...)                     → build/extend the pending keyset,
--                                       (re)arm the chain window
--   update(dt)                        → chain window expiry auto-commits
--   accept()                          → commit the pending combo now
--   unbind()                          → commit "no binding" for this slot
--   cancel()                          → abort (Esc)
--
-- Rules (from the plan):
--   * A non-modifier press records a combo (event mods + injected meta) and
--     arms a chain window; another non-modifier press within the window
--     extends the chain (double-tap etc.). Window expiry commits.
--   * A modifier pressed alone does not complete; if released with no other
--     key pressed in between, it commits as a bare-modifier binding
--     (BAR binds e.g. Any+shift). Any real key in between cancels that.
--   * Esc cancels and is therefore not capturable (Esc-bound actions are
--     catalog-locked).
--   * Repeats are consumed and ignored.
--
-- Validation/conflict feedback and the actual apply live in the widget; this
-- module only produces a canonical keyset string (or nil for unbind) via
-- onCommit, and notifies onChange whenever the pending display should update.

local Capture = {}
Capture.__index = Capture

---@param deps table {
---  keyset        core.keyset (required)
---  getKeySymbol  fn(keyCode) -> string
---  getScanSymbol fn(scanCode) -> string
---  getMeta       fn() -> boolean   (Spring.GetModKeyState 3rd return)
---  chainTimeout  number seconds (default 0.7)
---  onChange      fn(self)          pending changed / session started
---  onCommit      fn(unitId, slot, keysetString|nil)
---  onCancel      fn(unitId, slot)
--- }
function Capture.new(deps)
	local self = setmetatable({}, Capture)
	self.keyset = deps.keyset
	self.getKeySymbol = deps.getKeySymbol or function() return nil end
	self.getScanSymbol = deps.getScanSymbol or function() return nil end
	self.getMeta = deps.getMeta or function() return false end
	self.chainTimeout = deps.chainTimeout or 0.7
	self.onChange = deps.onChange or function() end
	self.onCommit = deps.onCommit or function() end
	self.onCancel = deps.onCancel or function() end

	self.active = false
	self:_reset()
	return self
end

function Capture:_reset()
	self.unitId = nil
	self.slot = nil
	self.actionLabel = ""
	self.pending = nil -- keyset object, or nil
	self.timer = 0
	self.sawNonMod = false
	self.modKeyDown = nil -- bare-modifier name currently held alone
	self.message = nil -- optional feedback shown in the overlay
end

function Capture:begin(session)
	self.active = true
	self:_reset()
	self.unitId = session.unitId
	self.slot = session.slot
	self.actionLabel = session.actionLabel or ""
	self.onChange(self)
end

function Capture:isActive()
	return self.active
end

---Overlay text for the pending combo.
function Capture:pendingDisplay(scToChar)
	if self.pending then
		return self.keyset.display(self.pending, scToChar)
	end
	if self.modKeyDown then
		return self.modKeyDown:sub(1, 1):upper() .. self.modKeyDown:sub(2)
	end
	return "..."
end

---Canonical string for the pending combo (for live conflict probing), or nil.
function Capture:pendingCanonical()
	if self.pending then
		return self.keyset.canonical(self.pending)
	end
	return nil
end

function Capture:setMessage(msg)
	self.message = msg
	self.onChange(self)
end

---Handle a key press. Returns true (always consumed while active).
function Capture:keyPress(keyCode, mods, isRepeat, scanCode)
	if not self.active then
		return false
	end
	if isRepeat then
		return true
	end

	local keySym = self.getKeySymbol(keyCode)
	local modName = self.keyset.modifierKeyName(keySym)

	if modName then
		-- Modifier alone (so far). Remember it for a possible bare-modifier
		-- bind on release; do not build a combo yet.
		if not self.sawNonMod then
			self.modKeyDown = modName
			self.onChange(self)
		end
		return true
	end

	-- A real key: cancels any pending bare-modifier intent.
	self.modKeyDown = nil
	self.sawNonMod = true

	local press = {
		keySymbol = keySym,
		scanSymbol = self.getScanSymbol(scanCode),
		alt = mods and mods.alt or false,
		ctrl = mods and mods.ctrl or false,
		shift = mods and mods.shift or false,
		meta = self.getMeta() or false,
	}
	local single, err = self.keyset.fromCapture(press)
	if not single then
		self:setMessage(err or "unrecognized key")
		return true
	end

	self.message = nil
	if self.pending then
		self.pending = self.keyset.appendPress(self.pending, single)
	else
		self.pending = single
	end
	self.timer = self.chainTimeout
	self.onChange(self)
	return true
end

---Handle a key release. Returns true while active.
function Capture:keyRelease(keyCode, mods, scanCode)
	if not self.active then
		return false
	end
	if self.pending or self.sawNonMod then
		return true
	end
	-- Modifier released with nothing else pressed: commit the bare modifier.
	local keySym = self.getKeySymbol(keyCode)
	local modName = self.keyset.modifierKeyName(keySym)
	if modName and self.modKeyDown == modName then
		local single = self.keyset.fromCapture({ keySymbol = keySym })
		if single then
			self.pending = single
			self:_commitPending()
		end
	end
	return true
end

function Capture:update(dt)
	if not self.active or not self.pending then
		return
	end
	if self.timer > 0 then
		self.timer = self.timer - dt
		if self.timer <= 0 then
			self:_commitPending()
		end
	end
end

function Capture:_commitPending()
	if not self.pending then
		return
	end
	local canonical = self.keyset.canonical(self.pending)
	local unitId, slot = self.unitId, self.slot
	self.active = false
	self:_reset()
	self.onCommit(unitId, slot, canonical)
end

---Accept the pending combo immediately (overlay button).
function Capture:accept()
	if self.active and self.pending then
		self:_commitPending()
	end
end

---Clear this slot (overlay button).
function Capture:unbind()
	if not self.active then
		return
	end
	local unitId, slot = self.unitId, self.slot
	self.active = false
	self:_reset()
	self.onCommit(unitId, slot, nil)
end

function Capture:cancel()
	if not self.active then
		return
	end
	local unitId, slot = self.unitId, self.slot
	self.active = false
	self:_reset()
	self.onCancel(unitId, slot)
end

return Capture
