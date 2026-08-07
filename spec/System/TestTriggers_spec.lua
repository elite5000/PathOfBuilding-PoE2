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

	it("caps Cast on Block's trigger rate by the displayed spell's own cooldown (Eye of Winter, 10s)", function()
		-- Eye of Winter is a real Spell+Triggerable skill with its own 10s cooldown (unrelated to the Meta
		-- Energy mechanic). Even with an enormous manual block rate pushing the Energy-limited rate far
		-- above 1/10s, the spell itself cannot fire faster than once per 10 seconds.
		build.skillsTab:PasteSocketGroup("Eye of Winter 20/0  1\nCast on Block 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.metaBlockEventsPerSecond = 1000
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.are.equals("Eye of Winter", build.calcsTab.mainEnv.player.mainSkill.activeEffect.grantedEffect.name)
		assert.near(10, build.calcsTab.mainEnv.player.mainSkill.skillData.cooldown, 0.01)
		-- calcSkillCooldown rounds up to the nearest 33ms server tick: 10s -> 304 ticks -> 10.032s.
		assert.near(1 / 10.032, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
		assert.near(1 / 10.032, build.calcsTab.mainOutput.Speed, 0.0001)
	end)

	it("reduces the displayed spell's own cooldown cap via Temporalis's flat Cooldown Recovery mod", function()
		-- Same Eye of Winter setup as above, but with Temporalis's "Skills have -2 seconds to Cooldown"
		-- (CooldownRecoveryFromTemporalis): 10s - 2s = 8s, then rounded up to the nearest 33ms server tick
		-- (243 ticks -> 8.019s). The old manual cooldown reconstruction in mainSkillCooldownRate never read
		-- this mod (or tick-rounded) at all, so it would have silently stayed at 1/10 - this confirms
		-- mainSkillCooldownRate now goes through the shared calcSkillCooldown helper.
		build.skillsTab:PasteSocketGroup("Eye of Winter 20/0  1\nCast on Block 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.metaBlockEventsPerSecond = 1000
		build.configTab.input.customMods = "Skills have -2 seconds to Cooldown"
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(1 / 8.019, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)

	it("does not cap Cast on Block's trigger rate when the displayed spell has no cooldown of its own", function()
		-- Same setup as above but with Comet (no native cooldown) instead of Eye of Winter: the fix must
		-- stay a no-op when there's nothing to cap by.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nCast on Block 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.metaBlockEventsPerSecond = 5
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		-- ceil(300 / 25) = 12 blocks needed per trigger; 5 blocks/sec -> 5/12 triggers/sec (unchanged from
		-- the existing "derives Cast on Block's trigger rate..." test above).
		assert.near(5 / 12, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)

	it("caps Reaper's Invocation's trigger rate by the displayed spell's own cooldown (Eye of Winter, 10s)", function()
		build.skillsTab:PasteSocketGroup("Eye of Winter 20/0  1\nReaper's Invocation 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.enemyIsBoss = "None"
		build.configTab.input.metaReapersInvocationMeleeKillsPerSecond = 1000
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.are.equals("Eye of Winter", build.calcsTab.mainEnv.player.mainSkill.activeEffect.grantedEffect.name)
		-- Even though 1000 kills/sec would otherwise make Reaper's Invocation's own 0.2s cooldown the
		-- binding constraint (per the existing "caps...by its own cooldown" test), Eye of Winter's much
		-- slower 10s cooldown (tick-rounded to 10.032s) is now the tightest constraint of the three.
		assert.near(1 / 10.032, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
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

	it("gives every payload spell in a multi-spell Cast on Critical bundle the same trigger rate", function()
		-- Comet and Spark are both socketed alongside Cast on Critical, sharing one 370-Energy pool
		-- (300 + 70, per the "Maximum Energy" test above) filled by Quarterstaff Strike's crits. Since both
		-- payloads trigger together off the same pool, whichever one is currently viewed as the main skill
		-- should report the identical bundle trigger rate - not its own individual cast rate.
		equipQuarterstaff()

		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nCast on Critical 1/0  1\nSpark 20/0  1\nQuarterstaff Strike 20/0  1")
		build.mainSocketGroup = 1
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.are.equals("Comet", build.calcsTab.mainEnv.player.mainSkill.activeEffect.grantedEffect.name)
		local cometRate = build.calcsTab.mainOutput.MetaEnergyTriggerRate
		assert.is_true((cometRate or 0) > 0)

		-- A second, separately-pasted group with Spark listed first makes Spark the default main skill,
		-- sidestepping the known displaySkillList/mainActiveSkill indexing mismatch when Meta gems are
		-- present in a group (see TestSkills_spec.lua's selectActiveSkillById workaround for the same issue).
		build.skillsTab:PasteSocketGroup("Spark 20/0  1\nCast on Critical 1/0  1\nComet 20/0  1\nQuarterstaff Strike 20/0  1")
		build.mainSocketGroup = 2
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.are.equals("Spark", build.calcsTab.mainEnv.player.mainSkill.activeEffect.grantedEffect.name)
		local sparkRate = build.calcsTab.mainOutput.MetaEnergyTriggerRate
		assert.near(cometRate, sparkRate, 0.0001)
	end)

	it("counts every payload spell in a multi-spell Cast on Critical bundle toward Full DPS", function()
		-- Full DPS iterates every active skill in the group, temporarily reassigning mainSkill to each one
		-- in turn (Calcs.lua's "fullEnv.player.mainSkill = activeSkill" before each calcs.perform pass) -
		-- an integration path the single-mainSkill tests above never exercise. Comet and Spark should both
		-- show up as separate, non-zero contributors, each computed off the shared bundle trigger rate.
		equipQuarterstaff()
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nCast on Critical 1/0  1\nSpark 20/0  1\nQuarterstaff Strike 20/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.buildFlag = true
		runCallback("OnFrame")

		local calcsModule = LoadModule("Modules/Calcs")
		local fullDPS = calcsModule.calcFullDPS(build, "CALCULATOR", {}, {})

		local cometDPS, sparkDPS
		for _, skill in ipairs(fullDPS.skills) do
			if skill.name == "Comet" then cometDPS = skill.dps end
			if skill.name == "Spark" then sparkDPS = skill.dps end
		end

		assert.is_true((cometDPS or 0) > 0)
		assert.is_true((sparkDPS or 0) > 0)
		assert.is_true(fullDPS.combinedDPS >= cometDPS + sparkDPS - 0.01)
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
		-- 33.3/sec) exceeds the 0.2s-cooldown cap, so the cooldown is the binding constraint - tick-rounded
		-- to the nearest 33ms server tick (7 ticks -> 0.231s, ~4.329/sec), not exactly 0.2s/5/sec.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nBarrier Invocation 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.metaBarrierInvocationESDamageTakenPerSecond = 100000
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(1 / 0.231, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
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
		-- 0.2s-cooldown cap, so the cooldown is the binding constraint - tick-rounded to 0.231s (~4.329/sec).
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nReaper's Invocation 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.enemyIsBoss = "None"
		build.configTab.input.metaReapersInvocationMeleeKillsPerSecond = 1000
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(1 / 0.231, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)

	it("chains multiple discharges per activation when Energy banks up faster than the cooldown drains it", function()
		-- Spark costs only 70 Energy per discharge (vs Comet's 300 in the tests above). At 1000 kills/sec
		-- (30000 Energy/sec) and a 0.2s cooldown (tick-rounded to 0.231s, ~4.329/sec), up to 30000*0.231 =
		-- 6930 Energy could bank between activations, capped at the fixed 500 Maximum Energy pool.
		-- floor(500/70) = 7 discharges fit in that cap, so one activation chains 7 discharges:
		-- (1/0.231)*7 = ~30.303/sec - not just ~4.329/sec, which is what a one-discharge-per-activation
		-- model (the old formula) would have reported.
		build.skillsTab:PasteSocketGroup("Spark 20/0  1\nReaper's Invocation 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.enemyIsBoss = "None"
		build.configTab.input.metaReapersInvocationMeleeKillsPerSecond = 1000
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(7 / 0.231, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)

	it("reduces Invocation's own activation cooldown via Temporalis's flat Cooldown Recovery mod", function()
		-- Comet + Reaper's Invocation (0.2s cooldown), 1000 kills/sec (generation and Energy-limited rate
		-- both comfortably non-binding, floor(500/300)=1 discharge per activation). Temporalis's "Skills
		-- have -2 seconds to Cooldown" pushes 0.2s - 2s deep negative, clamped to the 0.1s minimum, then
		-- tick-rounded up to the nearest 33ms server tick (4 ticks -> 0.132s, ~7.576/sec) - not the
		-- 1/0.2 = 5/sec the old manual reconstruction (which never read CooldownRecoveryFromTemporalis or
		-- tick-rounded at all) would have silently reported.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nReaper's Invocation 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.enemyIsBoss = "None"
		build.configTab.input.metaReapersInvocationMeleeKillsPerSecond = 1000
		build.configTab.input.customMods = "Skills have -2 seconds to Cooldown"
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(1 / 0.132, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)

	it("applies alt-quality Reaper's Invocation's Triggered Damage bonus to the payload's DPS", function()
		-- Reaper's Invocation's altQualityStats grants "triggered_skill_damage_+%" at 1 per quality point,
		-- mapped to TriggeredDamage (SkillStatMap.lua). That mod is declared on Reaper's Invocation itself
		-- (metaSkill), not the hidden per-payload support - it needs addMetaTriggerIncMoreMods's read-from-
		-- metaSkill/write-to-mainSkill split, not the generic addTriggerIncMoreMods, to reach Comet's Damage.
		-- Alt-quality is a build-wide toggle (env.useAltGemQualityStats), driven by an allocated tree node
		-- (here "Advanced Thaumaturgy", id 14429, confirmed real via TestSkills_spec.lua's own use of this
		-- same node) rather than a per-gem flag or parseable text mod - 20 quality -> 20% increased
		-- Triggered Damage.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nReaper's Invocation 1/20  1")
		build.mainSocketGroup = 1
		build.configTab.input.enemyIsBoss = "None"
		build.configTab.input.metaReapersInvocationMeleeKillsPerSecond = 2
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()
		assert.is_not_nil(build.calcsTab.mainOutput.MetaEnergyTriggerRate)
		local baseDPS = build.calcsTab.mainOutput.TotalDPS

		-- Directly allocating the node (bypassing the interactive-UI-only path-hover mechanism AllocNode
		-- normally requires) - calc code just reads spec.allocNodes as a plain table.
		local advancedThaumaturgy = build.spec.nodes[14429]
		advancedThaumaturgy.alloc = true
		build.spec.allocNodes[14429] = advancedThaumaturgy
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		-- Not an exact 1.20x (Comet's real damage calc has more than one INC/MORE contributor interacting),
		-- but within a fraction of a percent - enough to confirm the mod is actually applying.
		assert.near(baseDPS * 1.20, build.calcsTab.mainOutput.TotalDPS, baseDPS * 0.005)
	end)

	it("scales Invocation's fixed Maximum Energy by an explicit increased-Maximum-Energy modifier", function()
		-- "Invocated skills have X% increased Maximum Energy" scales the fixed 500 pool itself, distinct
		-- from "Meta Skills gain X% increased Energy" (generation rate) - found via ultrareview to have
		-- previously been silently mismapped onto the wrong stat (MetaEnergyGeneration instead of a
		-- dedicated Maximum Energy stat).
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nReaper's Invocation 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.customMods = "Invocated skills have 30% increased Maximum Energy"
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(650, build.calcsTab.mainOutput.MetaEnergyMax, 0.01)
	end)

	it("applies Energy Capacitor's fixed Maximum Energy increase via its own skill stat, not just text mods", function()
		-- Energy Capacitor is a real support gem (requireSkillTypes = SkillType.Invocation) granting a fixed
		-- "skill_maximum_energy_+%" = 80 stat directly, mapped through SkillStatMap.lua rather than parsed
		-- from item text - a separate code path from the "Invocated skills have X% increased Maximum Energy"
		-- text mod tested above, but landing on the same MetaEnergyMaxIncrease stat: 500 * 1.8 = 900.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nReaper's Invocation 1/0  1\nEnergy Capacitor 1/0  1")
		build.mainSocketGroup = 1
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(900, build.calcsTab.mainOutput.MetaEnergyMax, 0.01)
	end)

	it("applies Energy Retention's fixed refund chance via its own skill stat, not just text mods", function()
		-- Energy Retention is a real support gem (requireSkillTypes = SkillType.GeneratesEnergy) granting a
		-- fixed "trigger_skills_refund_half_energy_spent_chance_%" = 35 stat directly, mapped through
		-- SkillStatMap.lua rather than parsed from item text, landing on the same MetaEnergyRefundChance
		-- stat as the "X% chance for Trigger skills to refund half of Energy Spent" text mod. Single-spell
		-- bundle, so this reduces to the same 2-branch model already verified: eventsToTrigger =
		-- 0.35*ceil(150/25) + 0.65*ceil(300/25) = 0.35*6 + 0.65*12 = 9.9.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nCast on Block 1/0  1\nEnergy Retention 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.metaBlockEventsPerSecond = 5
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(9.9, build.calcsTab.mainOutput.MetaEnergyEventsToTrigger, 0.0001)
		assert.near(5 / 9.9, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)

	it("reduces Invocation's effective discharge cost via Energy refund/discount chance mods", function()
		-- Both mods reduce to the same expected-value multiplier on the cost of one discharge:
		-- (1 - chance/200). 20% refund -> 0.9, 40% discount -> 0.8, combined (independent) -> 0.72.
		-- At 2 kills/sec (60 Energy/sec generated, 300 Energy/discharge), generationLimitedRate is the sole
		-- binding constraint both before and after (dischargesPerActivation rounds to 0 either way, so
		-- burstRate stays non-binding) - so the trigger rate should scale by exactly 1/0.72.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nReaper's Invocation 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.enemyIsBoss = "None"
		build.configTab.input.metaReapersInvocationMeleeKillsPerSecond = 2
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()
		local baseRate = build.calcsTab.mainOutput.MetaEnergyTriggerRate

		build.configTab.input.customMods = "20% chance for Trigger skills to refund half of Energy Spent\nInvocated Spells have 40% chance to consume half as much Energy"
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(baseRate / 0.72, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)

	it("reduces the auto-fire Meta gems' effective Energy-to-trigger via the refund chance mod", function()
		-- Comet (300 Energy) + Cast on Block, 25 Energy/block, 5 blocks/sec: base eventsToTrigger =
		-- ceil(300/25) = 12, triggerRate = 5/12. A 20% refund chance requires averaging the two already-
		-- rounded outcomes (not rounding the average): 20% chance -> ceil(150/25) = 6 events; 80% chance ->
		-- ceil(300/25) = 12 events. eventsToTrigger = 0.2*6 + 0.8*12 = 10.8 -> triggerRate = 5/10.8.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nCast on Block 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.metaBlockEventsPerSecond = 5
		build.configTab.input.customMods = "20% chance for Trigger skills to refund half of Energy Spent"
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(10.8, build.calcsTab.mainOutput.MetaEnergyEventsToTrigger, 0.0001)
		assert.near(5 / 10.8, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)

	it("rolls the refund chance independently for each socketed spell in a multi-spell bundle, not once for the whole pool", function()
		-- Two Comets (300 Energy each, 600 total) + Cast on Block, with a manual 40-Energy-per-block
		-- override (metaBlockEnergyPerEvent) chosen so the division doesn't come out clean, and a 50%
		-- refund chance. A single pooled roll on the combined 600 would give branches {600: 50%, 300: 50%}
		-- -> 0.5*ceil(600/40) + 0.5*ceil(300/40) = 0.5*15 + 0.5*8 = 11.5. Rolling independently per spell
		-- gives four equally-likely combinations collapsing to {600: 25%, 450: 50%, 300: 25%} ->
		-- 0.25*15 + 0.5*ceil(450/40) + 0.25*8 = 0.25*15 + 0.5*12 + 0.25*8 = 11.75 - a different, larger
		-- (more accurate) number of events needed, since ceil doesn't commute with how the total is
		-- decomposed into independent per-spell rolls.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nComet 20/0  1\nCast on Block 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.metaBlockEventsPerSecond = 5
		build.configTab.input.metaBlockEnergyPerEvent = 40
		build.configTab.input.customMods = "50% chance for Trigger skills to refund half of Energy Spent"
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(600, build.calcsTab.mainOutput.MetaEnergyMax, 0.01)
		assert.near(11.75, build.calcsTab.mainOutput.MetaEnergyEventsToTrigger, 0.0001)
	end)

	it("averages discrete per-discharge outcomes for Invocation's chained-burst count, rather than flooring the expected cost", function()
		-- Comet (300 Energy) + Reaper's Invocation, 1000 kills/sec (30000 Energy/sec, same as the "chains
		-- multiple discharges" test above), 0.2s cooldown (tick-rounded to 0.231s) -> energyPerActivation
		-- (30000*0.231 = 6930, capped at 500) still caps at the 500 Maximum Energy pool either way. With a
		-- 40% chance to consume half as much Energy (discount only, no refund): naively,
		-- floor(500 / (300*0.8)) = floor(500/240) = 2 discharges - but that ignores that an early discharge
		-- without the discount consumes the full 300, which can block a would-be-affordable later discharge.
		-- The exact expected count (hand-verified via the same quarters-DP the implementation uses:
		-- quarterCost=75, maxQuarters=6, pFull=0.6, pHalf=0.4, pBoth=0) is 1.704, not 2 - unaffected by the
		-- cooldown tick-rounding, since energyPerActivation is still capped at energyMax=500 either way.
		-- burstRate = cooldownRate(1/0.231) * 1.704 = ~7.377, which binds below generationLimitedRate
		-- (30000/240=125) and Comet's own (nonexistent) cooldown cap.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nReaper's Invocation 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.enemyIsBoss = "None"
		build.configTab.input.metaReapersInvocationMeleeKillsPerSecond = 1000
		build.configTab.input.customMods = "Invocated Spells have 40% chance to consume half as much Energy"
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(1.704 / 0.231, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)

	it("reports Invocation as untriggered when the socketed payload costs more than the Maximum Energy pool can ever hold", function()
		-- Two Comets (300 Energy each = 600 total) socketed with Reaper's Invocation exceed its fixed 500
		-- Maximum Energy - the reservoir can never hold enough Energy for even one discharge. Without the
		-- oversized-payload guard, generationLimitedRate (a pure continuous ratio unaware of the pool cap)
		-- would still report a large positive rate here; the fix should report it as untriggered instead.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nComet 20/0  1\nReaper's Invocation 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.enemyIsBoss = "None"
		build.configTab.input.metaReapersInvocationMeleeKillsPerSecond = 1000
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.is_nil(build.calcsTab.mainOutput.MetaEnergyTriggerRate)
	end)

	it("still reports the oversized payload as untriggered when only a refund chance is present, not a discount", function()
		-- Same oversized two-Comet bundle (600 nominal cost vs. 500 Maximum Energy), but with ONLY a 20%
		-- refund chance (no discount). A refund only returns Energy after the full cost has already been
		-- paid, so it can never lower what's needed to attempt a discharge - the full 600 must still be
		-- banked, which the 500 pool can never hold. A model that merges refund and discount into one
		-- "cheapest achievable cost" (as an earlier version of this guard did) would incorrectly treat this
		-- as affordable via the refund alone; the fix must still reject it.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nComet 20/0  1\nReaper's Invocation 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.enemyIsBoss = "None"
		build.configTab.input.metaReapersInvocationMeleeKillsPerSecond = 1000
		build.configTab.input.customMods = "20% chance for Trigger skills to refund half of Energy Spent"
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.is_nil(build.calcsTab.mainOutput.MetaEnergyTriggerRate)
	end)

	it("still reports a trigger rate for an oversized payload when refund/discount luck can make a discharge affordable", function()
		-- Same oversized two-Comet bundle (600 nominal cost vs. 500 Maximum Energy), but with both a 20%
		-- refund chance and a 40% discount chance present: the cheapest achievable outcome (both landing)
		-- costs only 0.25 * 600 = 150 Energy, well under the 500 pool - so a discharge is still possible,
		-- just less likely than the nominal cost would suggest. The guard must not reject this case.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nComet 20/0  1\nReaper's Invocation 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.enemyIsBoss = "None"
		build.configTab.input.metaReapersInvocationMeleeKillsPerSecond = 1000
		build.configTab.input.customMods = "20% chance for Trigger skills to refund half of Energy Spent\nInvocated Spells have 40% chance to consume half as much Energy"
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.is_not_nil(build.calcsTab.mainOutput.MetaEnergyTriggerRate)
		assert.is_true(build.calcsTab.mainOutput.MetaEnergyTriggerRate > 0)
	end)

	it("caps the trigger rate by a fractional (sub-1) expected discharge count, not just the continuous rate", function()
		-- Same oversized two-Comet bundle (600 Energy) + Reaper's Invocation, but with only a 40% discount
		-- chance (no refund): the only affordable outcome needs a 300-Energy gross cost (2 of 3 quarters
		-- banked, quarterCost=150), so dischargesPerActivation = 0.4 exactly (hand-verified via the same DP
		-- the implementation uses: q=1 affords nothing, q=2 gives 0.4*(1+ED[0])=0.4, q=3 gives
		-- 0.4*(1+ED[1]=0)=0.4). burstRate = cooldownRate(1/0.231) * 0.4 - a real, every-cycle probabilistic
		-- cap that must bind below the far larger generationLimitedRate (30000/480 = 62.5), not be skipped
		-- because 0.4 < 1.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nComet 20/0  1\nReaper's Invocation 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.enemyIsBoss = "None"
		build.configTab.input.metaReapersInvocationMeleeKillsPerSecond = 1000
		build.configTab.input.customMods = "Invocated Spells have 40% chance to consume half as much Energy"
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(0.4 / 0.231, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
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

	it("does not re-scale Spellslinger's manual Energy-generated/sec override by increased-Energy mods", function()
		-- The metaSpellslingerCastsPerSecond field is documented (ConfigOptions.lua) as a final Energy/sec
		-- value, not a casts/sec rate - "Meta Skills gain 20% increased Energy" must not multiply it again
		-- (30 * 1.2 = 36, which would report 36/300 = 0.12 instead of the correct 30/300 = 0.1).
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nSpellslinger 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.metaSpellslingerCastsPerSecond = 30
		build.configTab.input.customMods = "Meta Skills gain 20% increased Energy"
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(30 / 300, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)

	it("caps Spellslinger's discharge rate by its own cooldown when generation is abundant", function()
		-- At 100000 Energy/sec generated, the Energy-limited rate (100000/300 = 333/sec) exceeds the
		-- 0.2s-cooldown cap, so the cooldown is the binding constraint - tick-rounded to 0.231s (~4.329/sec).
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nSpellslinger 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.metaSpellslingerCastsPerSecond = 100000
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(1 / 0.231, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)

	it("shows Elemental Invocation's fixed Maximum Energy even before its generation rate is set", function()
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nElemental Invocation 1/0  1")
		build.mainSocketGroup = 1
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.are.equals("Comet", build.calcsTab.mainEnv.player.mainSkill.activeEffect.grantedEffect.name)
		assert.near(500, build.calcsTab.mainOutput.MetaEnergyMax, 0.01)
		assert.is_nil(build.calcsTab.mainOutput.MetaEnergyTriggerRate)
	end)

	it("caps Elemental Invocation's discharge rate by Energy generation when generation is the bottleneck (Freeze)", function()
		-- Comet alone costs 300 Energy per discharge. Freeze's constant is 10 Energy per monster Power per
		-- event (1 Power for a Normal enemy); 2 freezes/sec -> 20 Energy/sec, well under the 0.2s-cooldown
		-- cap (5/sec). Freeze is the selector's default, so it's left unset here.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nElemental Invocation 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.enemyIsBoss = "None"
		build.configTab.input.metaElementalInvocationEventsPerSecond = 2
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(20 / 300, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)

	it("caps Elemental Invocation's discharge rate by its own cooldown when generation is abundant", function()
		-- 1000 freezes/sec -> 10000 Energy/sec; Energy-limited rate (10000/300 = 33.3/sec) exceeds the
		-- 0.2s-cooldown cap, so the cooldown is the binding constraint - tick-rounded to 0.231s (~4.329/sec).
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nElemental Invocation 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.enemyIsBoss = "None"
		build.configTab.input.metaElementalInvocationEventsPerSecond = 1000
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(1 / 0.231, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)

	it("uses Shock's Energy constant instead of Freeze's when the ailment selector is switched", function()
		-- Shock/Ignite's constant is 1 Energy per monster Power per event (10x smaller than Freeze's), so
		-- 30 events/sec -> 30 Energy/sec here, versus 300 Energy/sec if this were still reading Freeze's
		-- constant. Energy-limited rate: 30/300 = 0.1/sec, matching Reaper's/Spellslinger's 30-Energy/sec cases.
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\nElemental Invocation 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.input.enemyIsBoss = "None"
		build.configTab.input.metaElementalInvocationAilmentType = "Shock"
		build.configTab.input.metaElementalInvocationEventsPerSecond = 30
		build.configTab:BuildModList()
		runCallback("OnFrame")
		build.calcsTab:BuildOutput()

		assert.near(30 / 300, build.calcsTab.mainOutput.MetaEnergyTriggerRate, 0.0001)
	end)
end)
