describe("TestAilments", function()
	before_each(function()
		newBuild()
	end)

	teardown(function()
		-- newBuild() takes care of resetting everything in setup()
	end)

	--TODO: Bleed not supported currently
	--it("bleed is buffed by bleed chance", function()
	--end)

	it("does not double count chaos damage taken for chaos poison", function()
		build.skillsTab:PasteSocketGroup("Chaos Bolt 1/0  1\nPoison I 1/0  1\n")
		runCallback("OnFrame")

		local baseEffMult = build.calcsTab.mainOutput.PoisonEffMult
		assert.True(baseEffMult and baseEffMult > 0)

		build.configTab.input.customMods = "Nearby enemies take 10% increased Chaos Damage"
		build.configTab:BuildModList()
		runCallback("OnFrame")

		assert.are.equals(1.1, build.calcsTab.mainOutput.PoisonEffMult)
	end)

	it("scales Freeze buildup with an increased Freeze Buildup modifier", function()
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\n")
		runCallback("OnFrame")

		local baseBuildup = build.calcsTab.mainOutput.FreezeBuildupAvg
		assert.True(baseBuildup and baseBuildup > 0)

		build.configTab.input.customMods = "50% increased Freeze Buildup"
		build.configTab:BuildModList()
		runCallback("OnFrame")

		assert.near(baseBuildup * 1.5, build.calcsTab.mainOutput.FreezeBuildupAvg, 0.01)
	end)

	it("scales Shock chance on hit by an increased-chance-to-Shock modifier", function()
		build.skillsTab:PasteSocketGroup("Ball Lightning 20/0  1\n")
		runCallback("OnFrame")

		local baseChance = build.calcsTab.mainOutput.ShockChanceOnHit
		assert.True(baseChance and baseChance > 0)

		build.configTab.input.customMods = "50% increased chance to Shock"
		build.configTab:BuildModList()
		runCallback("OnFrame")

		assert.near(baseChance * 1.5, build.calcsTab.mainOutput.ShockChanceOnHit, 0.0001)
	end)

	it("scales Shock's effect magnitude with an increased Magnitude of Shock modifier", function()
		build.skillsTab:PasteSocketGroup("Ball Lightning 20/0  1\n")
		build.configTab.input.customMods = "100% chance to Shock"
		build.configTab:BuildModList()
		runCallback("OnFrame")

		local baseEffect = build.calcsTab.mainOutput.ShockEffectMod
		assert.True(baseEffect and baseEffect > 0)

		build.configTab.input.customMods = "100% chance to Shock\n50% increased Magnitude of Shock"
		build.configTab:BuildModList()
		runCallback("OnFrame")

		assert.near(baseEffect * 1.5, build.calcsTab.mainOutput.ShockEffectMod, 0.01)
	end)

	it("increases Ignite chance on hit by an explicit chance-to-Ignite modifier", function()
		build.skillsTab:PasteSocketGroup("Fireball 20/0  1\n")
		runCallback("OnFrame")

		local baseChance = build.calcsTab.mainOutput.IgniteChanceOnHit or 0

		build.configTab.input.customMods = "20% chance to Ignite"
		build.configTab:BuildModList()
		runCallback("OnFrame")

		assert.near(baseChance + 20, build.calcsTab.mainOutput.IgniteChanceOnHit, 0.01)
	end)

	it("scales Ignite DPS with an increased Magnitude of Ignite modifier", function()
		build.skillsTab:PasteSocketGroup("Fireball 20/0  1\n")
		build.configTab.input.customMods = "100% chance to Ignite"
		build.configTab:BuildModList()
		runCallback("OnFrame")

		local baseDPS = build.calcsTab.mainOutput.IgniteDPS
		assert.True(baseDPS and baseDPS > 0)

		build.configTab.input.customMods = "100% chance to Ignite\n50% increased Magnitude of Ignite"
		build.configTab:BuildModList()
		runCallback("OnFrame")

		assert.near(baseDPS * 1.5, build.calcsTab.mainOutput.IgniteDPS, 0.01)
	end)

	-- Patch 0.5.0 consolidated Freeze Buildup, Shock Chance and Flammability (Ignite) Magnitude into a
	-- single "Elemental Ailment Application" stat, which previously parsed to an empty modifier list.
	it("scales Freeze buildup with an increased Elemental Ailment Application modifier", function()
		build.skillsTab:PasteSocketGroup("Comet 20/0  1\n")
		runCallback("OnFrame")

		local baseBuildup = build.calcsTab.mainOutput.FreezeBuildupAvg
		assert.True(baseBuildup and baseBuildup > 0)

		build.configTab.input.customMods = "40% increased Elemental Ailment Application"
		build.configTab:BuildModList()
		runCallback("OnFrame")

		assert.near(baseBuildup * 1.4, build.calcsTab.mainOutput.FreezeBuildupAvg, 0.01)
	end)

	it("scales Shock chance on hit with an increased Elemental Ailment Application modifier", function()
		build.skillsTab:PasteSocketGroup("Ball Lightning 20/0  1\n")
		runCallback("OnFrame")

		local baseChance = build.calcsTab.mainOutput.ShockChanceOnHit
		assert.True(baseChance and baseChance > 0)

		build.configTab.input.customMods = "40% increased Elemental Ailment Application"
		build.configTab:BuildModList()
		runCallback("OnFrame")

		assert.near(baseChance * 1.4, build.calcsTab.mainOutput.ShockChanceOnHit, 0.0001)
	end)

	it("scales Ignite chance on hit with an increased Elemental Ailment Application modifier", function()
		build.skillsTab:PasteSocketGroup("Fireball 20/0  1\n")
		runCallback("OnFrame")

		local baseChance = build.calcsTab.mainOutput.IgniteChanceOnHit
		assert.True(baseChance and baseChance > 0)

		build.configTab.input.customMods = "40% increased Elemental Ailment Application"
		build.configTab:BuildModList()
		runCallback("OnFrame")

		assert.near(baseChance * 1.4, build.calcsTab.mainOutput.IgniteChanceOnHit, 0.0001)
	end)

	it("parses Elemental Ailment Application with a conditional suffix (Wyvern's Breath's wording) instead of dropping it", function()
		build.skillsTab:PasteSocketGroup("Ball Lightning 20/0  1\n")
		runCallback("OnFrame")

		local baseChance = build.calcsTab.mainOutput.ShockChanceOnHit
		assert.True(baseChance and baseChance > 0)

		build.configTab.input.customMods = "40% increased Elemental Ailment Application if you have Shapeshifted to an Animal form Recently"
		build.configTab.input.conditionShapeshiftToAnimal = true
		build.configTab:BuildModList()
		runCallback("OnFrame")

		assert.near(baseChance * 1.4, build.calcsTab.mainOutput.ShockChanceOnHit, 0.0001)
	end)
end)
