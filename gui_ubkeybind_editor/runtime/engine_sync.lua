-- ubKeybind Editor — engine synchronization state machine.
--
-- Owns every Spring.GetKeyBindings/SendCommands interaction and keeps three
-- truths aligned: the pristine preset BASE (core model), the override plan,
-- and the live engine state.
--
--   PRISTINE_RELOAD → WAITING_ENGINE → APPLYING/VERIFYING → SYNCED
--                          ↑  (resync triggers)  |            | watchdog
--                          +------ fail x2 → DEGRADED ←-------+
--
-- Why the pristine reload at startup: if this widget was disabled and
-- re-enabled mid-game, the live state still contains our old override binds;
-- snapshotting that as "base" would bake our own edits into reset-to-default.
-- One extra keyreload is cheap — BAR already keyreloads during startup.
--
-- Why the settle window: Spring.SendCommands is processed deferred, so a
-- snapshot taken right after `keyreload` can see the OLD table. We accept a
-- snapshot only after a minimum number of Update ticks AND two consecutive
-- identical fingerprints.
--
-- Resync triggers:
--   1. wrap of WG['bar_hotkeys'].reloadBindings — catches preset/layout
--      switches from gui_options, in order, with cause. Re-installed every
--      update in case cmd_bar_hotkeys is toggled and recreates its WG table.
--   2. the SYNCED watchdog (default 5 s) — catches manual /keyreload, other
--      widgets rebinding, anything else. Foreign drift is ABSORBED (never
--      fought); only our own vanished binds are re-applied, once.
--   3. explicit UI "Resync".
--
-- Shutdown issues NO engine commands: on /luaui reload or exit,
-- cmd_bar_hotkeys keyreloads anyway; on plain widget-disable the user's
-- chosen binds staying live is the least surprising behavior.

local STATE = {
	IDLE = "IDLE",
	PRISTINE_RELOAD = "PRISTINE_RELOAD",
	WAITING_ENGINE = "WAITING_ENGINE",
	VERIFYING = "VERIFYING",
	SYNCED = "SYNCED",
	DEGRADED = "DEGRADED",
}

---@class EngineSync
---@field model table
---@field consumers table
---@field onSynced fun(self: EngineSync)
---@field onStateChanged fun(state: string, detail?: string)
---@field log fun(msg: string)
---@field settleTicks integer
---@field watchdogPeriod number
---@field massDriftThreshold integer
---@field state string
---@field ticks integer
---@field lastFingerprint string|nil
---@field pendingPlan table|nil
---@field verifyRetries integer
---@field verifyWaited boolean
---@field watchdogTimer number
---@field reapplyFailures integer
---@field degradedReason string|nil
---@field wrapper function|nil
---@field original function|nil
local EngineSync = {}
EngineSync.__index = EngineSync
EngineSync.STATE = STATE

local DEFAULT_PRESET = "luaui/configs/hotkeys/grid_keys.txt"

---@param deps table {
---  model      core model instance (required)
---  consumers  Consumers module (required)
---  onSynced   fn(self) called whenever we (re)enter SYNCED — refresh the UI
---  onStateChanged fn(state, detail) for the status line
---  log        fn(msg)
---  settleTicks, watchdogPeriod, massDriftThreshold  tuning
--- }
function EngineSync.new(deps)
	local self = setmetatable({}, EngineSync)
	self.model = deps.model
	self.keyset = deps.keyset
	self.consumers = deps.consumers
	self.onSynced = deps.onSynced or function() end
	self.onStateChanged = deps.onStateChanged or function() end
	self.log = deps.log or function() end

	self.settleTicks = deps.settleTicks or 3
	self.watchdogPeriod = deps.watchdogPeriod or 5
	self.massDriftThreshold = deps.massDriftThreshold or 10

	self.state = STATE.IDLE
	self.ticks = 0
	self.lastFingerprint = nil
	self.pendingPlan = nil
	self.verifyRetries = 0
	self.verifyWaited = false
	self.watchdogTimer = 0
	self.reapplyFailures = 0
	self.degradedReason = nil

	self.wrapper = nil
	self.original = nil
	return self
end

----------------------------------------------------------------------
-- Engine access (pcall-wrapped; the only Spring calls in the widget's
-- data path)
----------------------------------------------------------------------

local function readBindings()
	local ok, result = pcall(Spring.GetKeyBindings)
	if ok and type(result) == "table" then
		return result
	end
	return {}
end

local function sendCommands(commands)
	if #commands > 0 then
		Spring.SendCommands(commands)
	end
end

local function currentPresetKey()
	return Spring.GetConfigString("KeybindingFile", DEFAULT_PRESET)
end

-- djb2 over sorted pair strings: cheap stable fingerprint of the bind table.
local function fingerprint(rawBinds)
	local strs = {}
	for i, rb in ipairs(rawBinds) do
		strs[i] = (rb.boundWith or "") .. "|" .. (rb.command or "") .. " " .. (rb.extra or "")
	end
	table.sort(strs)
	local hash = 5381
	for _, s in ipairs(strs) do
		for j = 1, #s do
			hash = (hash * 33 + s:byte(j)) % 4294967296
		end
	end
	return hash .. ":" .. #strs
end

----------------------------------------------------------------------
-- bar_hotkeys wrap
----------------------------------------------------------------------

function EngineSync:installWrap()
	local bh = WG["bar_hotkeys"]
	if not bh or type(bh.reloadBindings) ~= "function" then
		return
	end
	if bh.reloadBindings == self.wrapper then
		return
	end
	-- Either first install or cmd_bar_hotkeys was recreated: wrap the
	-- current function.
	self.original = bh.reloadBindings
	local sync = self
	self.wrapper = function(...)
		local ret = sync.original(...)
		sync:requestResync("bar_hotkeys reload")
		return ret
	end
	bh.reloadBindings = self.wrapper
end

function EngineSync:removeWrap()
	local bh = WG["bar_hotkeys"]
	if bh and bh.reloadBindings == self.wrapper and self.original then
		bh.reloadBindings = self.original
	end
	self.wrapper = nil
	self.original = nil
end

----------------------------------------------------------------------
-- State transitions
----------------------------------------------------------------------

function EngineSync:setState(state, detail)
	if self.state ~= state then
		self.state = state
		self.onStateChanged(state, detail)
	end
end

function EngineSync:initialize()
	self:installWrap()
	self:requestPristineResync("startup")
end

---True when it is safe to accept an edit (settled; not mid-apply/reload).
function EngineSync:canEdit()
	return self.state == STATE.SYNCED or self.state == STATE.DEGRADED
end

---Full cycle: reload the preset pristine, then settle, snapshot, re-apply.
function EngineSync:requestPristineResync(reason)
	self.log("pristine resync (" .. reason .. ")")
	self:setState(STATE.PRISTINE_RELOAD, reason)
end

---Settle and re-adopt whatever lands (used when something else already
---triggered the reload, e.g. the bar_hotkeys wrap).
function EngineSync:requestResync(reason)
	self.log("resync (" .. reason .. ")")
	self.pendingPlan = nil
	self.ticks = 0
	self.lastFingerprint = nil
	self:setState(STATE.WAITING_ENGINE, reason)
end

---The engine-side keyset text for a pair: verbatim boundWith when we read it
---live, otherwise formatted from the parsed keyset (additions from a plan
---never carry boundWith). Never the raw keyset table — that's what compile.lua's
---emitKeyset does for command building; this mirrors it for anything that
---logs a pair instead of sending it.
function EngineSync:emitKeyset(pair)
	if pair.boundWith then
		return pair.boundWith
	end
	if self.keyset and pair.ks then
		return self.keyset.toEngine(pair.ks)
	end
	return "?"
end

---True if any of a plan's removals is a comma-chain keyset ("sc_b,sc_b").
---Confirmed against the engine source (RecoilEngine rts/Game/UI/KeyBindings.cpp):
---`Bind` splits its keyset argument on commas via ParseKeyChain before parsing
---each press, but `UnBind` passes the WHOLE string straight to CKeySet::Parse
---in one call — which only ever understands a single press, so it always
---fails ("Bad keysym: sc_b,sc_b") for ANY chain, regardless of which keys are
---involved. This is not fixable by choosing a different key or string form
---(see the reverted F9 investigation) — `unbind` of a chain is simply
---unsupported by the engine. `bind` of a chain works fine.
function EngineSync:planHasChainRemoval(plan)
	for _, r in ipairs(plan.removals) do
		if self:emitKeyset(r.pair):find(",", 1, true) then
			return true
		end
	end
	return false
end

---Log the exact pairs a failed verify found off (missing = expected but not
---live, stale = expected gone but still live) — otherwise a rejected batch
---is a single opaque line with nothing to act on.
function EngineSync:logVerifyMismatch(details, verdict)
	if not details then
		return
	end
	for _, m in ipairs(details.missing or {}) do
		self.log("verify (" .. verdict .. "): expected but not live — " .. m.unitId .. ": "
			.. self:emitKeyset(m.pair) .. " " .. tostring(m.pair.action))
	end
	for _, s in ipairs(details.stale or {}) do
		self.log("verify (" .. verdict .. "): should be gone but still live — " .. s.unitId .. ": "
			.. self:emitKeyset(s.pair) .. " " .. tostring(s.pair.action))
	end
end

---Execute an edit plan (from the UI). Only valid when settled.
---Returns ok, err.
function EngineSync:execute(plan)
	if self.state ~= STATE.SYNCED and self.state ~= STATE.DEGRADED then
		return false, "engine sync busy (" .. self.state .. ")"
	end
	if #plan.commands == 0 then
		-- Nothing to change in the engine, but the store may have changed
		-- (e.g. override cleared by re-entering base keysets).
		self.model.commitPlan(plan)
		self.onSynced(self)
		return true
	end
	if self:planHasChainRemoval(plan) then
		-- unbind can never remove a chain (see planHasChainRemoval). The
		-- store is already updated by the caller (setBinding/resetUnit/
		-- resetAll all mutate it before calling execute), so a pristine
		-- reload — which discards every runtime bind and reloads purely
		-- from the preset file — naturally clears the stuck chain, then the
		-- normal resync re-applies every override fresh via `bind` (which
		-- DOES support chains). No unbind of a chain is ever needed this way.
		self:requestPristineResync("plan requires removing a chain bind")
		return true
	end
	self.pendingPlan = plan
	self.verifyRetries = 0
	self.verifyWaited = false
	sendCommands(plan.commands)
	self:setState(STATE.VERIFYING)
	return true
end

----------------------------------------------------------------------
-- Update loop
----------------------------------------------------------------------

function EngineSync:update(dt)
	self:installWrap()

	if self.state == STATE.PRISTINE_RELOAD then
		-- Use the original (unwrapped) reload so we do not double-trigger,
		-- falling back to a bare keyreload of the configured preset.
		if self.original then
			pcall(self.original)
		else
			sendCommands({ "keyreload " .. currentPresetKey() })
		end
		self:requestResync("pristine reload issued")
		return
	end

	if self.state == STATE.WAITING_ENGINE then
		self.ticks = self.ticks + 1
		if self.ticks >= self.settleTicks then
			local raw = readBindings()
			local fp = fingerprint(raw)
			if fp == self.lastFingerprint then
				self:adoptSnapshot(raw)
			else
				self.lastFingerprint = fp
			end
		end
		return
	end

	if self.state == STATE.VERIFYING then
		if not self.pendingPlan then
			-- Cancelled mid-flight (resync trigger); nothing to verify.
			self:requestResync("verify cancelled")
			return
		end
		-- Give SendCommands one tick to land before re-reading.
		if not self.verifyWaited then
			self.verifyWaited = true
			return
		end
		local ok, details = self.model.verifyPlan(readBindings(), self.pendingPlan)
		if ok then
			self.model.commitPlan(self.pendingPlan)
			self.pendingPlan = nil
			self.consumers.notify()
			self:setState(STATE.SYNCED)
			self.watchdogTimer = 0
			self.reapplyFailures = 0
			self.onSynced(self)
		elseif self.verifyRetries < 1 then
			self.verifyRetries = self.verifyRetries + 1
			self.verifyWaited = false
			self:logVerifyMismatch(details, "retrying")
			sendCommands(self.pendingPlan.commands)
		else
			-- Commit intent anyway so the model reflects what we asked for;
			-- the watchdog will keep reporting the gap.
			self:logVerifyMismatch(details, "giving up")
			self.log("engine rejected part of the bind batch")
			self.degradedReason = "engine rejected some bindings"
			self.model.commitPlan(self.pendingPlan)
			self.pendingPlan = nil
			self.consumers.notify()
			self:setState(STATE.DEGRADED, self.degradedReason)
			self.onSynced(self)
		end
		return
	end

	if self.state == STATE.SYNCED or self.state == STATE.DEGRADED then
		self.watchdogTimer = self.watchdogTimer + dt
		if self.watchdogTimer >= self.watchdogPeriod then
			self.watchdogTimer = 0
			self:watchdog()
		end
		return
	end
end

function EngineSync:adoptSnapshot(raw)
	self.model.setPreset(currentPresetKey())
	local plan, warnings = self.model.refreshFromSnapshot(raw)
	for _, w in ipairs(warnings) do
		self.log("import: " .. w)
	end

	if self:planHasChainRemoval(plan) then
		-- A fresh reload still needs to remove a chain: unlike the execute()
		-- case (a leftover runtime override), this means the chain IS the
		-- unit's preset-file-defined base — no reload will ever clear it, so
		-- retrying would just loop. Drop the conflicting override(s) instead
		-- so those units fall back to living with their base chain, same
		-- self-heal shape as the corrupted-override handling.
		local conflicted = {}
		for _, r in ipairs(plan.removals) do
			if self:emitKeyset(r.pair):find(",", 1, true) then
				conflicted[r.unitId] = true
			end
		end
		for unitId in pairs(conflicted) do
			self.log("reverting override for '" .. unitId
				.. "': its preset default is a multi-press chain, which the engine's unbind command can never remove")
			plan = self.model.resetUnit(unitId)
		end
	end

	if #plan.commands == 0 then
		self.model.commitPlan(plan)
		self:setState(STATE.SYNCED)
		self.watchdogTimer = 0
		self.reapplyFailures = 0
		self.onSynced(self)
	else
		self.log("applying " .. #plan.commands .. " override commands")
		self.pendingPlan = plan
		self.verifyRetries = 0
		self.verifyWaited = false
		sendCommands(plan.commands)
		self:setState(STATE.VERIFYING)
	end
end

function EngineSync:watchdog()
	local raw = readBindings()
	local ok, diff = self.model.diffLive(raw)
	if ok then
		self.reapplyFailures = 0
		return
	end

	-- A pile of expected binds vanishing at once means the whole table was
	-- reloaded under us (manual /keyreload): re-adopt from scratch.
	if #diff.foreignRemoved + #diff.oursMissing >= self.massDriftThreshold then
		self:requestResync("watchdog: bind table reloaded externally")
		return
	end

	if #diff.oursMissing > 0 then
		-- Re-assert our own binds once per detection; never loop-fight
		-- whatever removed them.
		self.reapplyFailures = self.reapplyFailures + 1
		if self.reapplyFailures <= 2 then
			local cmds = {}
			for _, pr in ipairs(diff.oursMissing) do
				cmds[#cmds + 1] = "bind " .. self:emitKeyset(pr) .. " " .. pr.action
			end
			self.log("watchdog: re-asserting " .. #cmds .. " of our binds")
			sendCommands(cmds)
		else
			self.degradedReason = "another widget keeps unbinding our keys"
			self:setState(STATE.DEGRADED, self.degradedReason)
		end
	end

	if #diff.foreignAdded > 0 or #diff.foreignRemoved > 0 then
		self.log("watchdog: absorbing foreign bind changes (+"
			.. #diff.foreignAdded .. "/-" .. #diff.foreignRemoved .. ")")
		self.model.absorb(diff)
		self.onSynced(self) -- conflict badges may change
	end
end

function EngineSync:shutdown()
	self:removeWrap()
	self:setState(STATE.IDLE)
end

return EngineSync
