-- engine_sync.lua — pure-logic helpers only (emitKeyset, planHasChainRemoval).
-- The state machine itself talks to Spring directly (not dependency-injected)
-- so it isn't exercised here; these two methods never touch Spring.

return function(core, t, _fixture, ctx)
	local EngineSync = ctx.requireRuntime("engine_sync.lua")
	local K = core.keyset

	local sync = EngineSync.new({
		model = {},
		keyset = K,
		log = function() end,
	})

	----------------------------------------------------------------
	-- emitKeyset: verbatim boundWith when present, else formatted from ks
	----------------------------------------------------------------
	t.eq(sync:emitKeyset({ boundWith = "Ctrl+sc_e" }), "Ctrl+sc_e", "emitKeyset prefers boundWith verbatim")
	local ks = K.parse("sc_b,sc_b")
	t.eq(sync:emitKeyset({ ks = ks }), "sc_b,sc_b", "emitKeyset formats from ks when boundWith is absent")

	----------------------------------------------------------------
	-- planHasChainRemoval: the engine's `unbind` can never remove a
	-- comma-chain (Bind splits chains via ParseKeyChain; UnBind passes the
	-- whole string straight to CKeySet::Parse, which only understands one
	-- press) — this is what tells execute()/adoptSnapshot() to redirect
	-- through a pristine reload instead of sending a doomed unbind.
	----------------------------------------------------------------
	local noChainPlan = { removals = { { pair = { boundWith = "sc_a" } } } }
	t.ok(not sync:planHasChainRemoval(noChainPlan), "single-press removal is not a chain removal")

	local chainPlan = { removals = { { pair = { boundWith = "sc_e,sc_e" } } } }
	t.ok(sync:planHasChainRemoval(chainPlan), "comma-chain removal detected")

	local mixedPlan = { removals = {
		{ pair = { boundWith = "sc_a" } },
		{ pair = { ks = K.parse("sc_b,sc_b") } }, -- no boundWith: falls back to keyset.toEngine
	} }
	t.ok(sync:planHasChainRemoval(mixedPlan), "chain detected even without boundWith")

	local emptyPlan = { removals = {} }
	t.ok(not sync:planHasChainRemoval(emptyPlan), "no removals: not a chain removal")
end
