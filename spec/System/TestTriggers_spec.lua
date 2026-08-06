describe("TestTriggers", function()
	before_each(function()
		newBuild()
	end)

	teardown(function()
		-- newBuild() takes care of resetting everything in setup()
	end)

	it("computes Maximum Energy as the sum of every socketed spell's cost under Cast on Critical", function()
		-- Comet: 1s base cast time + 1s "Total Cast Time" (counted double) = 100*(1 + 2*1) = 300 Energy
		-- Spark: 0.7s base cast time, no Total Cast Time = 100*0.7 = 70 Energy
		-- Maximum Energy is the sum across every socketed spell, not just the one being viewed.
		-- Comet is pasted first so it's the group's default main skill (no extra selection needed).
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nCast on Critical 1/0  1\nSpark 20/0  1")
		build.mainSocketGroup = 1
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.are.equals("Comet", build.calcsTab.mainEnv.player.mainSkill.activeEffect.grantedEffect.name)
		assert.near(370, build.calcsTab.mainOutput.MetaEnergyMax, 0.01)
	end)

	it("derives Cast on Block's trigger rate from the manual block-rate config input", function()
		-- Comet alone: Maximum Energy = 300. Cast on Block generates 25 Energy per block.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nCast on Block 1/0  1")
		build.mainSocketGroup = 1
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		-- No event rate configured yet: Maximum Energy is still shown, but no trigger rate is derived.
		assert.are.equals("Comet", build.calcsTab.mainEnv.player.mainSkill.activeEffect.grantedEffect.name)
		assert.near(300, build.calcsTab.mainOutput.MetaEnergyMax, 0.01)
		assert.is_nil(build.calcsTab.mainOutput.MetaEnergyEventsToTrigger)

		build.configTab.input.metaBlockEventsPerSecond = 5
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		-- ceil(300 / 25) = 12 blocks needed per trigger; 5 blocks/sec -> 5/12 triggers/sec
		assert.are.equals(12, build.calcsTab.mainOutput.MetaEnergyEventsToTrigger)
		assert.near(5 / 12, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
		assert.near(5 / 12, build.calcsTab.mainOutput.Speed, 0.0001)
	end)

	local function equipQuarterstaff()
		build.itemsTab:CreateDisplayItemFromRaw([[
			New Item
			Razor Quarterstaff
		]])
		build.itemsTab:AddDisplayItem()
	end

	it("auto-derives Cast on Critical's events/sec from a self-cast attack skill in the group", function()
		-- A weapon must be equipped for Quarterstaff Strike to have non-zero crit chance.
		equipQuarterstaff()
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nCast on Critical 1/0  1\nQuarterstaff Strike 20/0  1")
		build.mainSocketGroup = 1
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.are.equals("Comet", build.calcsTab.mainEnv.player.mainSkill.activeEffect.grantedEffect.name)
		assert.is_true((build.calcsTab.mainOutput.MetaEnergyEventsPerSecond or 0) > 0)
		assert.is_true((build.calcsTab.mainOutput.MetaEnergyTriggerRate or 0) > 0)
	end)

	it("still lets the manual override win over Cast on Critical's auto-derivation", function()
		equipQuarterstaff()
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nCast on Critical 1/0  1\nQuarterstaff Strike 20/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.metaCoCEventsPerSecond = 2
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.are.equals(2, build.calcsTab.mainOutput.MetaEnergyEventsPerSecond)
	end)

	-- Cast on Elemental Ailment's Freeze/Shock/Ignite don't auto-derive their events/sec yet (see the
	-- comment on findAutoEnergySource in CalcTriggers.lua for why Crit's model doesn't generalize to
	-- them), so all three currently require the manual events/sec override. What Stage 3 does add is the
	-- ailment-type selector picking the right Energy constant, and monster Power scaling applied to it.
	it("derives Cast on Elemental Ailment's Freeze trigger rate from the manual override, scaled by monster Power", function()
		-- Comet alone: Maximum Energy = 300. Freeze generates 10 Energy per instance at 1 monster Power.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nCast on Elemental Ailment 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.enemyIsBoss = "None"
		build.configTab.input.metaCoEAAilmentType = "Freeze"
		build.configTab.input.metaCoEAEventsPerSecond = 15
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		-- ceil(300 / 10) = 30 freezes needed per trigger; 15 freezes/sec -> 0.5 triggers/sec
		assert.are.equals(30, build.calcsTab.mainOutput.MetaEnergyEventsToTrigger)
		assert.near(0.5, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)

	it("scales Cast on Elemental Ailment's Energy-per-event by monster Power for a Boss enemy", function()
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nCast on Elemental Ailment 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.enemyIsBoss = "Boss"
		build.configTab.input.metaCoEAAilmentType = "Freeze"
		build.configTab.input.metaCoEAEventsPerSecond = 15
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		-- Boss = 20 monster Power -> 10*20 = 200 Energy per freeze; ceil(300/200) = 2 needed; 15/2 = 7.5/sec
		assert.are.equals(2, build.calcsTab.mainOutput.MetaEnergyEventsToTrigger)
		assert.near(7.5, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)

	it("still requires the manual override for Cast on Elemental Ailment's Ignite (no auto-derivation)", function()
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nCast on Elemental Ailment 1/0  1\nFrost Darts 20/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.metaCoEAAilmentType = "Ignite"
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		-- No manual override set: Ignite has no auto-derivation, so no trigger rate is produced.
		assert.is_nil(build.calcsTab.mainOutput.MetaEnergyEventsToTrigger)

		build.configTab.input.metaCoEAEventsPerSecond = 3
		build.configTab.input.metaCoEAEnergyPerEvent = 10
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.is_true((build.calcsTab.mainOutput.MetaEnergyEventsToTrigger or 0) > 0)
	end)

	it("derives Curse on Block's trigger rate from the manual block-rate config input", function()
		build.skillsTab:PasteSocketGroup("Despair 20/0  1\nCurse on Block 1/0  1")
		build.mainSocketGroup = 1
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.are.equals("Despair", build.calcsTab.mainEnv.player.mainSkill.activeEffect.grantedEffect.name)
		assert.is_nil(build.calcsTab.mainOutput.MetaEnergyEventsToTrigger)

		build.configTab.input.metaCurseOnBlockEventsPerSecond = 5
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.is_true((build.calcsTab.mainOutput.MetaEnergyEventsToTrigger or 0) > 0)
		assert.is_true((build.calcsTab.mainOutput.MetaEnergyTriggerRate or 0) > 0)
	end)

	it("auto-derives Thundergod's Wrath's events/sec from a self-cast melee attack in the group", function()
		equipQuarterstaff()
		build.skillsTab:PasteSocketGroup("Elemental Weakness 20/0  1\nThundergod's Wrath 1/0  1\nQuarterstaff Strike 20/0  1")
		build.mainSocketGroup = 1
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.are.equals("Elemental Weakness", build.calcsTab.mainEnv.player.mainSkill.activeEffect.grantedEffect.name)
		assert.is_true((build.calcsTab.mainOutput.MetaEnergyEventsPerSecond or 0) > 0)
		assert.is_true((build.calcsTab.mainOutput.MetaEnergyTriggerRate or 0) > 0)
	end)

	it("still lets the manual override win over Thundergod's Wrath's auto-derivation", function()
		equipQuarterstaff()
		build.skillsTab:PasteSocketGroup("Elemental Weakness 20/0  1\nThundergod's Wrath 1/0  1\nQuarterstaff Strike 20/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.metaTGWEventsPerSecond = 2
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.are.equals(2, build.calcsTab.mainOutput.MetaEnergyEventsPerSecond)
	end)

	it("shows Barrier Invocation's fixed Maximum Energy even before its generation rate is set", function()
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nBarrier Invocation 1/0  1")
		build.mainSocketGroup = 1
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		-- Fixed pool (500), not summed from sockets like every other Meta gem.
		assert.are.equals("Comet", build.calcsTab.mainEnv.player.mainSkill.activeEffect.grantedEffect.name)
		assert.near(500, build.calcsTab.mainOutput.MetaEnergyMax, 0.01)
		assert.is_nil(build.calcsTab.mainOutput.MetaEnergyTriggerRate)
	end)

	it("caps Barrier Invocation's discharge rate by Energy generation when generation is the bottleneck", function()
		-- Comet alone costs 300 Energy per discharge. At 1000 ES damage taken/sec (/10 divisor = 100
		-- Energy/sec), the Energy-limited rate (100/300 = 0.333/sec) is below the 0.2s-cooldown cap (5/sec).
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nBarrier Invocation 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.metaBarrierInvocationESDamageTakenPerSecond = 1000
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(100 / 300, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
		assert.near(100 / 300, build.calcsTab.mainOutput.Speed, 0.0001)
	end)

	it("caps Barrier Invocation's discharge rate by its own cooldown when generation is abundant", function()
		-- At 100000 ES damage taken/sec (/10 = 10000 Energy/sec), the Energy-limited rate (10000/300 =
		-- 33.3/sec) exceeds the 0.2s-cooldown cap, so the cooldown (5/sec) is the binding constraint.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nBarrier Invocation 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.metaBarrierInvocationESDamageTakenPerSecond = 100000
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(5, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)

	it("caps Reaper's Invocation's discharge rate by Energy generation when generation is the bottleneck", function()
		-- Comet alone costs 300 Energy per discharge. 30 Energy per monster Power per melee kill (at 1
		-- Power, i.e. a Normal enemy); 2 kills/sec -> 60 Energy/sec, well under the 0.2s-cooldown cap (5/sec).
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nReaper's Invocation 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.enemyIsBoss = "None"
		build.configTab.input.metaReapersInvocationMeleeKillsPerSecond = 2
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(60 / 300, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)

	it("caps Reaper's Invocation's discharge rate by its own cooldown when generation is abundant", function()
		-- 1000 kills/sec -> 30000 Energy/sec; Energy-limited rate (30000/300 = 100/sec) exceeds the
		-- 0.2s-cooldown cap, so the cooldown (5/sec) is the binding constraint.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nReaper's Invocation 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.enemyIsBoss = "None"
		build.configTab.input.metaReapersInvocationMeleeKillsPerSecond = 1000
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(5, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)

	it("shows Spellslinger's fixed Maximum Energy even before its generation rate is set", function()
		-- No other spell in the group is a valid auto-detect source for Spellslinger (any Spell socketed
		-- alongside it also becomes one of its own triggered targets), so with no manual input this stays
		-- unresolved, same as Barrier/Reaper's Invocation with no input.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nSpellslinger 1/0  1")
		build.mainSocketGroup = 1
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.are.equals("Comet", build.calcsTab.mainEnv.player.mainSkill.activeEffect.grantedEffect.name)
		assert.near(500, build.calcsTab.mainOutput.MetaEnergyMax, 0.01)
		assert.is_nil(build.calcsTab.mainOutput.MetaEnergyTriggerRate)
	end)

	it("caps Spellslinger's discharge rate by Energy generation when generation is the bottleneck", function()
		-- Comet alone costs 300 Energy per discharge. At 30 Energy/sec generated, the Energy-limited rate
		-- (30/300 = 0.1/sec) is well below the 0.2s-cooldown cap (5/sec).
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nSpellslinger 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.metaSpellslingerCastsPerSecond = 30
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(30 / 300, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)

	it("caps Spellslinger's discharge rate by its own cooldown when generation is abundant", function()
		-- At 100000 Energy/sec generated, the Energy-limited rate (100000/300 = 333/sec) exceeds the
		-- 0.2s-cooldown cap, so the cooldown (5/sec) is the binding constraint.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nSpellslinger 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.metaSpellslingerCastsPerSecond = 100000
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(5, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)
end)
