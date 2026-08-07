-- Path of Building
--
-- Module: Calc Triggers
-- Performs trigger rate calculations
--

local calcs = ...
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_remove = table.remove
local m_min = math.min
local m_max = math.max
local m_ceil = math.ceil
local m_floor = math.floor
local m_modf = math.modf
local s_format = string.format
local m_huge = math.huge
local bor = OR64 -- bit.bor
local band = AND64 -- bit.band

-- Add trigger-based damage modifiers
local function addTriggerIncMoreMods(activeSkill, sourceSkill)
	for _, value in ipairs(activeSkill.skillModList:Tabulate("INC", sourceSkill.skillCfg, "TriggeredDamage")) do
		activeSkill.skillModList:NewMod("Damage", "INC", value.mod.value, value.mod.source, value.mod.flags, value.mod.keywordFlags, unpack(value.mod))
	end
	for _, value in ipairs(activeSkill.skillModList:Tabulate("MORE", sourceSkill.skillCfg, "TriggeredDamage")) do
		activeSkill.skillModList:NewMod("Damage", "MORE", value.mod.value, value.mod.source, value.mod.flags, value.mod.keywordFlags, unpack(value.mod))
	end
end

local function slotMatch(env, skill)
	local fromItem = (env.player.mainSkill.activeEffect.grantedEffect.fromItem or skill.activeEffect.grantedEffect.fromItem)
	fromItem = fromItem or (env.player.mainSkill.activeEffect.srcInstance and env.player.mainSkill.activeEffect.srcInstance.fromItem) or (skill.activeEffect.srcInstance and skill.activeEffect.srcInstance.fromItem)
	local match1 = fromItem and skill.socketGroup and skill.socketGroup.slot == env.player.mainSkill.socketGroup.slot
	local match2 = (not env.player.mainSkill.activeEffect.grantedEffect.fromItem) and skill.socketGroup == env.player.mainSkill.socketGroup
	return (match1 or match2)
end

function isTriggered(skill)
	return skill.skillData.triggeredByUnique or skill.skillData.triggered or skill.skillTypes[SkillType.InbuiltTrigger] or skill.skillTypes[SkillType.Triggered] or skill.activeEffect.grantedEffect.triggered or (skill.activeEffect.srcInstance and skill.activeEffect.srcInstance.triggered)
end

local function processAddedCastTime(skill, breakdown)
	if skill.skillModList:Flag(skill.skillCfg, "SpellCastTimeAddedToCooldownIfTriggered") then
		local baseCastTime = skill.skillData.castTimeOverride or skill.activeEffect.grantedEffect.castTime or 1
		local inc = skill.skillModList:Sum("INC", skill.skillCfg, "Speed")
		local more = skill.skillModList:More(skill.skillCfg, "Speed")
		local csi = round((1 + inc/100) * more, 2)
		local addsCastTime = baseCastTime / csi
		skill.skillFlags.addsCastTime = true
		if breakdown then
			breakdown.AddedCastTime = {
				s_format("%.2f ^8(base cast time of %s)", baseCastTime, skill.activeEffect.grantedEffect.name),
				s_format("%.2f ^8(increased/reduced)", 1 + inc/100),
				s_format("%.2f ^8(more/less)", more),
				s_format("= %.2f ^8cast time", addsCastTime)
			}
		end
		return addsCastTime, csi
	end
end

local function packageSkillDataForSimulation(skill, env)
	return { uuid = cacheSkillUUID(skill, env), cd = skill.skillData.cooldown, cdOverride = skill.skillModList:Override(skill.skillCfg, "CooldownRecovery"), addsCastTime = processAddedCastTime(skill), icdr = calcLib.mod(skill.skillModList, skill.skillCfg, "CooldownRecovery"), addedCooldown = skill.skillModList:Sum("BASE", skill.skillCfg, "CooldownRecovery")}
end

local function defaultComparer(env, uuid, source, triggerRate)
	local cachedSpeed = GlobalCache.cachedData[env.mode][uuid].HitSpeed or GlobalCache.cachedData[env.mode][uuid].Speed
	return (not source and cachedSpeed) or (cachedSpeed and cachedSpeed > (triggerRate or 0))
end

-- Identify the trigger action skill for trigger conditions, take highest Attack Per Second
local function findTriggerSkill(env, skill, source, triggerRate, comparer)
	local comparer = comparer or defaultComparer

	local uuid = cacheSkillUUID(skill, env)
	if not GlobalCache.cachedData[env.mode][uuid] or env.mode == "CALCULATOR" then
		calcs.buildActiveSkill(env, env.mode, skill, uuid)
	end

	if GlobalCache.cachedData[env.mode][uuid] and comparer(env, uuid, source, triggerRate) and (skill.skillFlags and not skill.skillFlags.disable) and (skill.skillCfg and not skill.skillCfg.skillCond["usedByMirage"]) and not skill.skillTypes[SkillType.OtherThingUsesSkill] then
		return skill, GlobalCache.cachedData[env.mode][uuid].HitSpeed or GlobalCache.cachedData[env.mode][uuid].Speed, uuid
	end
	return source, triggerRate, source and cacheSkillUUID(source, env)
end

-- Calculate the impact other skills and source rate to trigger cooldown alignment have on the trigger rate
-- for more details regarding the implementation see comments of #4599 and #5428
function calcMultiSpellRotationImpact(env, skillRotation, sourceRate, triggerCD, chance, actor)
	local rotationIndex = 1
	local next_trigger = 0
	local triggerIncrement = 1 / sourceRate
	local SIM_TIME = triggerIncrement * 1000 -- Simulate 1000 attacks
	local chance = chance or 100
	local skillCount = #skillRotation
	local actor = actor or env.player

	for _, skill in ipairs(skillRotation) do
		skill.cd = m_max(skill.cdOverride or ( ((skill.cd or 0) + (skill.addedCooldown or 0)) / (skill.icdr or 1)), ( (triggerCD or 0) + (skill.addsCastTime or 0) ) / (skill.icdr or 1))
		skill.next_trig = 0
		skill.count = 0
	end

	while next_trigger < SIM_TIME do
		local currentIndex = rotationIndex
		repeat
			if skillRotation[currentIndex].next_trig <= next_trigger then -- Skill at current index off cooldown, Trigger it.
				skillRotation[currentIndex].count = skillRotation[currentIndex].count + 1
				-- Cooldown starts at the beginning of current tick and ends at the next tick after cooldown expiration
				skillRotation[currentIndex].next_trig = ceil_b(floor_b(next_trigger, data.misc.ServerTickTime) + skillRotation[currentIndex].cd, data.misc.ServerTickTime)
				break
			end
			currentIndex = (currentIndex % skillCount) + 1 -- Current skill on cooldown, try the next one.
		until(currentIndex == rotationIndex) -- All skills checked, trigger wasted
		rotationIndex = (rotationIndex % skillCount) + 1 -- Move on to the next skill in rotation
		next_trigger = next_trigger + triggerIncrement
	end

	local trigRateTable = { simTime = SIM_TIME, rates = {}, }
	local mainRate = 0
	for _, sd in ipairs(skillRotation) do
		-- Account for trigger chance. Adds the expected value of a geometric distribution where p = chance multiplied by triggerIncrement
		-- This allows for O(1) estimation of trigger chance impact on trigger rate as number of triggers approaches infinity
		-- Credit to Logik and Quickstick. More info in prs linked here: https://github.com/PathOfBuildingCommunity/PathOfBuilding/pull/7244 and on discord.
		t_insert(trigRateTable.rates, { name = sd.uuid, rate = 1 / (SIM_TIME / sd.count + (triggerIncrement / chance * 100) - triggerIncrement) })
		if cacheSkillUUID(actor.mainSkill, env) == sd.uuid then
			mainRate = trigRateTable.rates[#trigRateTable.rates].rate
		end
	end

	return mainRate, trigRateTable
end

local function helmetFocusHandler(env)
	if not env.player.mainSkill.skillFlags.minion and not env.player.mainSkill.skillFlags.disable and env.player.mainSkill.triggeredBy then
		local triggerName = "Focus"
		env.player.mainSkill.skillData.triggered = true
		local output = env.player.output
		local breakdown = env.player.breakdown
		local triggerCD = env.player.mainSkill.triggeredBy.grantedEffect.levels[env.player.mainSkill.triggeredBy.level].cooldown
		local triggeredCD = env.player.mainSkill.skillData.cooldown

		local icdrFocus = calcLib.mod(env.player.mainSkill.skillModList, env.player.mainSkill.skillCfg, "FocusCooldownRecovery")
		local icdrSkill = calcLib.mod(env.player.mainSkill.skillModList, env.player.mainSkill.skillCfg, "CooldownRecovery")

		-- Skills trigger only on activation
		-- Next possible activation will be duration + cooldown
		-- cooldown is in milliseconds
		local skillFocus = env.data.skills["Focus"]
		local focusDuration = (skillFocus.constantStats[1][2] / 1000)
		local focusCD = (skillFocus.levels[1].cooldown / icdrFocus)
		local focusTotalCD = focusDuration + focusCD

		-- skill cooldown should still apply to focus triggers
		local modActionCooldown = m_max( triggeredCD or 0, (triggerCD or 0) / icdrSkill )
		local rateCapAdjusted = m_ceil(modActionCooldown * data.misc.ServerTickRate) / data.misc.ServerTickRate
		local triggerRate = m_huge
		if rateCapAdjusted ~= 0 then
			triggerRate = 1 / rateCapAdjusted
		end

		output.TriggerRateCap = triggerRate
		output.SkillTriggerRate = 1 / focusTotalCD

		if breakdown then
			if triggeredCD then
				breakdown.TriggerRateCap = {
					s_format("%.2f ^8(base cooldown of triggered skill)", triggeredCD),
					s_format("/ %.2f ^8(increased/reduced cooldown recovery)", icdrSkill),
					s_format("= %.4f ^8(final cooldown of triggered skill)", triggeredCD / icdrSkill),
					"",
					s_format("%.2f ^8(base cooldown of trigger)", triggerCD),
					s_format("/ %.2f ^8(increased/reduced cooldown recovery)", icdrSkill),
					s_format("= %.4f ^8(final cooldown of trigger)", triggerCD / icdrSkill),
					"",
					s_format("%.3f ^8(biggest of trigger cooldown and triggered skill cooldown)", modActionCooldown),
					"",
					(env.player.mainSkill.skillData.ignoresTickRate and "") or s_format("%.3f ^8(adjusted for server tick rate)", rateCapAdjusted),
					"",
					"Trigger rate:",
					s_format("1 / %.3f", rateCapAdjusted),
					s_format("= %.2f ^8per second", triggerRate),
				}
			else
				breakdown.TriggerRateCap = {
					"Triggered skill has no base cooldown",
					"",
					s_format("%.2f ^8(base cooldown of trigger)", triggerCD),
					s_format("/ %.2f ^8(increased/reduced cooldown recovery)", icdrSkill),
					s_format("= %.4f ^8(final cooldown of trigger)", triggerCD / icdrSkill),
					"",
					(env.player.mainSkill.skillData.ignoresTickRate and "") or s_format("%.3f ^8(adjusted for server tick rate)", rateCapAdjusted),
					"",
					"Trigger rate:",
					s_format("1 / %.3f", rateCapAdjusted),
					s_format("= %.3f ^8per second", triggerRate),
				}
			end
			breakdown.SkillTriggerRate = {
				s_format("%.2f ^8(focus base cooldown)", skillFocus.levels[1].cooldown),
				s_format("/ %.2f ^8(increased/reduced cooldown recovery)", icdrFocus),
				s_format("+ %.2f ^8(skills are only triggered on activation thus we add focus duration)", focusDuration),
				s_format("= %.2f ^8(effective skill cooldown for trigger purposes)", focusTotalCD),
				"",
				s_format("%.3f casts per second ^8(Assuming player uses focus exactly when its cooldown of %.2fs expires)", 1 / focusTotalCD, focusTotalCD)
			}
		end

		-- Account for Trigger-related INC/MORE modifiers
		addTriggerIncMoreMods(env.player.mainSkill, env.player.mainSkill)
		env.player.mainSkill.infoMessage = "Assuming perfect focus Re-Use"
		env.player.mainSkill.infoTrigger = triggerName
		env.player.mainSkill.skillData.triggerRate = output.SkillTriggerRate
		env.player.mainSkill.skillFlags.globalTrigger = true
	end
end

local function CWCHandler(env)
	if not env.player.mainSkill.skillFlags.minion and not env.player.mainSkill.skillFlags.disable then
		local triggeredSkills = {}
		local trigRate = 0
		local source = nil
		local triggerName = "Cast While Channeling"
		local output = env.player.output
		local breakdown = env.player.breakdown
		for _, skill in ipairs(env.player.activeSkillList) do
			local match1 = env.player.mainSkill.activeEffect.grantedEffect.fromItem and skill.socketGroup and skill.socketGroup.slot == env.player.mainSkill.socketGroup.slot
			local match2 = (not env.player.mainSkill.activeEffect.grantedEffect.fromItem) and skill.socketGroup == env.player.mainSkill.socketGroup
			if env.player.mainSkill.triggeredBy.gemData and calcLib.canGrantedEffectSupportActiveSkill(env.player.mainSkill.triggeredBy.gemData.grantedEffect, skill) and skill ~= env.player.mainSkill and (match1 or match2) and not isTriggered(skill) then
				source, trigRate = findTriggerSkill(env, skill, source, trigRate)
			end
			if skill.skillData.triggeredWhileChannelling and (match1 or match2) then
				t_insert(triggeredSkills, packageSkillDataForSimulation(skill, env))
			end
		end
		if not source or #triggeredSkills < 1 then
			env.player.mainSkill.skillData.triggered = nil
			env.player.mainSkill.infoMessage2 = "DPS reported assuming Self-Cast"
			env.player.mainSkill.infoMessage = s_format("No %s Triggering Skill Found", triggerName)
			env.player.mainSkill.infoTrigger = ""
		else
			local triggeredName = env.player.mainSkill.activeEffect.grantedEffect.name or "Triggered"

			output.addsCastTime = processAddedCastTime(env.player.mainSkill, breakdown)

			local icdr = calcLib.mod(env.player.mainSkill.skillModList, env.player.mainSkill.skillCfg, "CooldownRecovery") or 1
			local adjTriggerInterval = m_ceil(source.skillData.triggerTime * data.misc.ServerTickRate) / data.misc.ServerTickRate
			local triggerRateOfTrigger = 1/adjTriggerInterval
			local triggeredCD = env.player.mainSkill.skillData.cooldown
			local cooldownOverride = env.player.mainSkill.skillModList:Override(env.player.mainSkill.skillCfg, "CooldownRecovery")

			if cooldownOverride then
				env.player.mainSkill.skillFlags.hasOverride = true
			end

			local triggeredTotalCooldown = cooldownOverride or m_max(triggeredCD or 0, output.addsCastTime or 0) / icdr
			local triggeredCDAdjusted = m_ceil(triggeredTotalCooldown * data.misc.ServerTickRate) / data.misc.ServerTickRate
			local effCDTriggeredSkill = m_ceil(triggeredCDAdjusted * triggerRateOfTrigger) / triggerRateOfTrigger

			local simBreakdown = nil
			output.TriggerRateCap = m_min(1 / effCDTriggeredSkill, triggerRateOfTrigger)
			output.SkillTriggerRate, simBreakdown = calcMultiSpellRotationImpact(env, triggeredSkills, triggerRateOfTrigger, 0)

			if breakdown then
				if triggeredCD or cooldownOverride then
					breakdown.TriggerRateCap = {
						s_format("Cast While Channeling triggers %s every %.2fs while channeling %s ", triggeredName, source.skillData.triggerTime, source.activeEffect.grantedEffect.name),
						s_format("%.3f ^8(adjusted for server tick rate)", adjTriggerInterval),
						"",
						s_format("%.2f ^8(base cooldown of triggered skill)", triggeredCD),
						s_format("/ %.2f ^8(increased/reduced cooldown recovery)", icdr),
						s_format("= %.4f ^8(final cooldown of triggered skill)", triggeredCD / icdr),
						"",
					}
					if cooldownOverride ~= nil then
						breakdown.TriggerRateCap[4] = s_format("%.2f ^8(hard override of cooldown of %s)", cooldownOverride, triggeredName)
						t_remove(breakdown.TriggerRateCap, 5)
						t_remove(breakdown.TriggerRateCap, 5)
					end
				else
					breakdown.TriggerRateCap = {
						s_format("Cast While Channeling triggers %s every %.2fs while channeling %s ", triggeredName, source.skillData.triggerTime, source.activeEffect.grantedEffect.name),
						s_format("%.3f ^8(adjusted for server tick rate)", adjTriggerInterval),
						"",
						triggeredName .. " has no base cooldown or cooldown override",
						"",
					}
				end

				local function extraIncreaseNeeded(affectedCD)
					if not cooldownOverride then
						local nextBreakpoint = effCDTriggeredSkill - adjTriggerInterval
						local timeOverBreakpoint = triggeredTotalCooldown - nextBreakpoint
						local alreadyReducedTime = triggeredTotalCooldown * icdr - triggeredTotalCooldown
						if timeOverBreakpoint < affectedCD then
							local divNeeded = affectedCD / (affectedCD - timeOverBreakpoint - alreadyReducedTime)
							local incTotal = m_ceil(( divNeeded - 1 ) * 100)
							return incTotal - (icdr - 1) * 100
						end
					end
				end

				if output.addsCastTime then
					t_insert(breakdown.TriggerRateCap, "Cast While Channeling had no base cooldown")
					t_insert(breakdown.TriggerRateCap, s_format("+ %.2f ^8(%s adds cast time as cooldown to trigger)", output.addsCastTime, triggeredName))
					t_insert(breakdown.TriggerRateCap, s_format("/ %.2f ^8(increased/reduced cooldown recovery)", icdr))
					t_insert(breakdown.TriggerRateCap, s_format("= %.4f ^8(final cooldown of triggered skill)", output.addsCastTime / icdr))
					t_insert(breakdown.TriggerRateCap, "")
					t_insert(breakdown.TriggerRateCap, s_format("%.3f ^8(adjusted for server tick rate)", triggeredCDAdjusted))
					t_insert(breakdown.TriggerRateCap, "")

					local extraCSINeeded = extraIncreaseNeeded(output.addsCastTime)
					local extraICDRNeeded = extraIncreaseNeeded(triggeredTotalCooldown*icdr)
					if extraICDRNeeded then
						t_insert(breakdown.TriggerRateCap, s_format("^8(extra ICDR of %d%% would reach next breakpoint)", extraICDRNeeded))
					end
					if extraCSINeeded then
						t_insert(breakdown.TriggerRateCap, s_format("^8(extra Cast Rate Increase of %d%% would reach next breakpoint)", extraCSINeeded))
						t_insert(breakdown.TriggerRateCap,"")
					end
				else
					local extraICDRNeeded = extraIncreaseNeeded(triggeredTotalCooldown*icdr)
					if extraICDRNeeded then
						t_insert(breakdown.TriggerRateCap, s_format("^8(extra ICDR of %d%% would reach next breakpoint)", extraICDRNeeded))
						t_insert(breakdown.TriggerRateCap,"")
					end
				end

				t_insert(breakdown.TriggerRateCap, "Trigger rate:")
				t_insert(breakdown.TriggerRateCap, s_format("1 / %.3f ^8(trigger rate adjusted for triggering interval)", 1 / output.TriggerRateCap))
				t_insert(breakdown.TriggerRateCap, s_format("= %.2f ^8 %s casts per second", output.TriggerRateCap, triggeredName))

				if #triggeredSkills > 1 then
					breakdown.SkillTriggerRate = {
						s_format("%.2f ^8(%s triggers per second)", triggerRateOfTrigger, triggerName),
						s_format("/ %.2f ^8(Estimated impact of linked spells)", (triggerRateOfTrigger / output.SkillTriggerRate) or 1),
						s_format("= %.2f ^8%s casts per second", output.SkillTriggerRate, triggeredName),
					}

					if simBreakdown.extraSimInfo then
						t_insert(breakdown.SkillTriggerRate, "")
						t_insert(breakdown.SkillTriggerRate, simBreakdown.extraSimInfo)
					end
					breakdown.SimData = {
						rowList = { },
						colList = {
							{ label = "Rate", key = "rate" },
							{ label = "Skill Name", key = "skillName" },
							{ label = "Slot Name", key = "slotName" },
							{ label = "Gem Index", key = "gemIndex" },
						},
					}
					for _, rateData in ipairs(simBreakdown.rates) do
						local t = { }
						for str in string.gmatch(rateData.name, "([^_]+)") do
							t_insert(t, str)
						end

						local row = {
							rate = round(rateData.rate,2),
							skillName = t[1],
							slotName = t[2],
							gemIndex = t[3],
						}
						t_insert(breakdown.SimData.rowList, row)
					end
				end
			end

			-- Account for Trigger-related INC/MORE modifiers
			addTriggerIncMoreMods(env.player.mainSkill, env.player.mainSkill)
			env.player.output.ChannelTimeToTrigger = source.skillData.triggerTime
			env.player.mainSkill.skillData.triggered = true
			env.player.mainSkill.skillFlags.globalTrigger = true
			env.player.mainSkill.skillData.triggerRate = output.SkillTriggerRate
			env.player.mainSkill.skillData.triggerSourceUUID = cacheSkillUUID(source, env)
			env.player.mainSkill.infoMessage = triggerName .."'s Trigger: ".. source.activeEffect.grantedEffect.name
			env.player.infoTrigger = env.player.mainSkill.infoTrigger or triggerName
		end
	end
end

-- Auto-derive events/sec (Cast on Critical only, currently) from a self-cast, non-triggered Attack/Damage
-- skill in the same socket group, using its cached hit rate and hit/crit chance. This is the closest
-- analogue to the legacy PoE1 "cast on critical strike" self-cast source lookup (see the
-- ["cast on critical strike"] / "mjolner" entries below); PoB has no confirmed rule yet for which skill's
-- hits count towards a Meta gem's Energy, so this is a reasonable default pending in-game validation.
-- Written as a self-contained scan (not calcs.findTriggerSkill/defaultComparer) because those read
-- skill.skillFlags directly, which - like actor.mainSkill.skillFlags before it - isn't populated under
-- the current stat-set skill architecture; see metaEnergyTriggerHandler below for the working equivalent.
--
-- Freeze/Shock auto-derivation was attempted and pulled back: this engine doesn't give either of them a
-- clean per-hit chance the way Crit has. Shock's chance is gated behind ailment-eligibility checks keyed
-- on the skill's own damage-type tags (CalcOffence.lua's canDoAilment) that never resolved true in
-- testing even for a natively Lightning-tagged attack with a real weapon; Freeze isn't a per-hit chance
-- at all in this engine - it's a buildup/threshold mechanic (see CalcOffence.lua's
-- "Freeze"/"Electrocute"/"HeavyStun"/"Pin" poise-buildup loop, the same model Heavy Stun uses). Both need
-- dedicated follow-up work, not a naive "reuse the Crit shape" attempt, so for now Freeze/Shock/Ignite all
-- require the manual Stage 1 override, same as Ignite always did.
-- requireMelee restricts candidates to SkillType.Melee, for Meta gems that only generate Energy from
-- melee hits specifically (Thundergod's Wrath, Fire Spell on Melee Hit). requireSpell restricts to
-- SkillType.Spell (and drops the Attack/Damage requirement, since "cast Spells" doesn't require a hit),
-- for Spellslinger, which generates Energy from casting rather than hitting.
local function findAutoEnergySource(env, actor, mainSkill, requireMelee, requireSpell)
	local bestSkill, bestUuid, bestRate
	for _, skill in ipairs(actor.activeSkillList) do
		if skill ~= mainSkill and skill.socketGroup == mainSkill.socketGroup
			and (requireSpell and skill.skillTypes[SkillType.Spell] or (not requireSpell and (skill.skillTypes[SkillType.Attack] or skill.skillTypes[SkillType.Damage])))
			and (not requireMelee or skill.skillTypes[SkillType.Melee])
			and not skill.skillModList:Flag(skill.skillCfg, "TriggeredByMetaEnergy") then
			local uuid = cacheSkillUUID(skill, env)
			if not GlobalCache.cachedData[env.mode][uuid] then
				calcs.buildActiveSkill(env, env.mode, skill, uuid)
			end
			local cached = GlobalCache.cachedData[env.mode][uuid]
			local rate = cached and (cached.HitSpeed or cached.Speed)
			if rate and (not bestRate or rate > bestRate) then
				bestSkill, bestUuid, bestRate = skill, uuid, rate
			end
		end
	end
	return bestSkill, bestUuid
end

-- Cast on Elemental Ailment covers three sub-events sharing one Energy pool; metaCoEAAilmentType (a
-- ConfigOptions selector) picks which one a given build is generating Energy from, and which of these
-- three constants applies. None of the three currently auto-derive (see findAutoEnergySource above for
-- why) - all require the manual Stage 1 events/sec override.
local autoDetectAilmentInfo = {
	Freeze = { energyStat = "MetaEnergyPerEventFreeze" },
	Shock = { energyStat = "MetaEnergyPerEventShock" },
	Ignite = { energyStat = "MetaEnergyPerEventIgnite" },
}

-- Shared by metaEnergyTriggerHandler (Cast on Elemental Ailment) and metaInvocationTriggerHandler
-- (Elemental Invocation) - both gems expose the same Freeze/Shock/Ignite selector and constant shape.
local function resolveAilmentEnergyStat(env, config)
	if not config.ailmentTypeVar then return nil, nil end
	local ailmentType = env.build.configTab.input[config.ailmentTypeVar] or "Freeze"
	return ailmentType, autoDetectAilmentInfo[ailmentType]
end

-- Both metaEnergyTriggerHandler and metaInvocationTriggerHandler report a rate for whichever socketed
-- spell is currently selected as mainSkill. If that specific spell has its own inherent cooldown
-- (independent of the Meta/Invocation Energy mechanic - e.g. a spell with a native activation cooldown),
-- it can't fire faster than that even when the group's Energy-based discharge-attempt rate would allow it.
local function mainSkillCooldownRate(mainSkill)
	local cooldown = mainSkill.skillData.cooldown
	if not cooldown or cooldown <= 0 then
		return m_huge
	end
	local icdr = calcLib.mod(mainSkill.skillModList, mainSkill.skillCfg, "CooldownRecovery")
	local addedCooldown = mainSkill.skillModList:Sum("BASE", mainSkill.skillCfg, "CooldownRecovery")
	local adjustedCooldown = (cooldown + addedCooldown) / icdr
	return adjustedCooldown > 0 and (1 / adjustedCooldown) or m_huge
end

-- Shared handler for PoE2 Meta gems (Cast on Critical, Cast on Elemental Ailment, Cast on Dodge,
-- Cast on Minion Death, Cast on Melee Kill, Cast on Melee Stun, Cast on Block, Cast on Charm Use).
-- All of these share the Energy mechanic: every spell socketed alongside the Meta gem adds to a
-- shared maximum-Energy pool, qualifying events add Energy, and every socketed spell triggers
-- together once the pool is filled. See docs/New Feature - Meta Skills/ for the underlying research.
--
-- The qualifying-event rate is a manual per-build input (config.eventsVar) by default; some gems
-- (config.autoDetectCrit / config.autoDetectHit, see findAutoEnergySource below) instead auto-derive it
-- from a self-cast source skill's combat outputs, falling back to the manual input if no source is found
-- or the input is explicitly set (a manual value always takes precedence over auto-derivation).
local function metaEnergyTriggerHandler(env, config)
	local actor = config.actor
	local output = actor.output
	local breakdown = actor.breakdown
	local mainSkill = actor.mainSkill
	-- Per-instance skill flags live on the active skill's stat set, not directly on the skill object.
	local skillFlags = env.mode == "CALCS" and mainSkill.activeEffect.statSetCalcs.skillFlags or mainSkill.activeEffect.statSet.skillFlags

	-- Find the Meta gem itself (e.g. "Cast on Critical") socketed in the same group; it carries the
	-- Energy-generation stats (energy_generated_+%, the per-event centienergy constant(s)).
	local metaSkill
	for _, skill in ipairs(actor.activeSkillList) do
		if skill.socketGroup == mainSkill.socketGroup and skill.skillModList:Flag(skill.skillCfg, "MetaEnergySumSocketedSkills") then
			metaSkill = skill
			break
		end
	end

	if not metaSkill then
		mainSkill.skillData.triggered = nil
		mainSkill.infoMessage2 = "DPS reported assuming Self-Cast"
		mainSkill.infoMessage = s_format("%s not found in socket group", config.triggerName or "Meta gem")
		mainSkill.infoTrigger = ""
		return
	end

	-- Maximum Energy is the sum of every socketed spell's cost: 100 * base cast/attack time,
	-- plus flat "Total Cast/Attack Time" additions counted at double value (general Energy rule).
	local energyMax = 0
	local costBreakdown = breakdown and {}
	for _, skill in ipairs(actor.activeSkillList) do
		if skill.socketGroup == mainSkill.socketGroup and skill.skillModList:Flag(skill.skillCfg, "TriggeredByMetaEnergy") then
			local costRateMs = skill.skillModList:Sum("BASE", skill.skillCfg, "MetaEnergyCostRateMs")
			if costRateMs and costRateMs > 0 then
				local baseTime = (skill.skillData.castTimeOverride or skill.activeEffect.grantedEffect.castTime or 0) + skill.skillModList:Sum("BASE", skill.skillCfg, "Speed")
				local totalTime = skill.skillModList:Sum("BASE", skill.skillCfg, "TotalCastTime") + skill.skillModList:Sum("BASE", skill.skillCfg, "TotalAttackTime")
				local cost = ((baseTime * 1000) + (totalTime * 1000 * 2)) / costRateMs
				energyMax = energyMax + cost
				if costBreakdown then
					t_insert(costBreakdown, s_format("%.1f ^8Energy (%s: %.2fs base%s)", cost, skill.activeEffect.grantedEffect.name, baseTime, totalTime > 0 and s_format(" + 2x%.2fs Total Cast Time", totalTime) or ""))
				end
			end
		end
	end

	-- Maximum Energy is always exposed, even before the manual rate inputs below are filled in.
	output.MetaEnergyMax = energyMax
	skillFlags.metaEnergyTriggered = true
	if breakdown then
		breakdown.MetaEnergyMax = costBreakdown
		t_insert(breakdown.MetaEnergyMax, s_format("= %.1f ^8Total Maximum Energy", energyMax))
	end

	-- Which per-event Energy stat applies: static per gem, except Cast on Elemental Ailment which reads
	-- its Freeze/Shock/Ignite selector to pick one of the three constants sharing this gem.
	local ailmentType, ailmentInfo = resolveAilmentEnergyStat(env, config)
	local energyPerEventStat = (ailmentInfo and ailmentInfo.energyStat) or config.energyPerEventStat

	-- Qualifying events/sec: manual override if set, otherwise auto-derived from a self-cast source
	-- skill's hit rate (Cast on Critical additionally multiplies by crit chance; Thundergod's Wrath /
	-- Fire Spell on Melee Hit key off plain melee hits, so they don't).
	local eventsPerSecond = env.build.configTab.input[config.eventsVar] or 0
	if eventsPerSecond <= 0 and config.autoDetectCrit then
		local source, uuid = findAutoEnergySource(env, actor, mainSkill)
		if source and uuid then
			local cached = GlobalCache.cachedData[env.mode][uuid]
			local rate = cached.HitSpeed or cached.Speed or 0
			local hitChance = (cached.HitChance or 100) / 100
			local critChance = (cached.CritChance or 0) / 100
			eventsPerSecond = rate * hitChance * critChance
			if breakdown and eventsPerSecond > 0 then
				breakdown.MetaEnergyEventsPerSecond = {
					s_format("%.2f ^8(%s hit rate)", rate, source.activeEffect.grantedEffect.name),
					s_format("x %.2f%% ^8(hit chance)", cached.HitChance or 100),
					s_format("x %.2f%% ^8(critical strike chance)", cached.CritChance or 0),
					s_format("= %.2f ^8(critical hits per second)", eventsPerSecond),
				}
			end
		end
	elseif eventsPerSecond <= 0 and config.autoDetectHit then
		local source, uuid = findAutoEnergySource(env, actor, mainSkill, true)
		if source and uuid then
			local cached = GlobalCache.cachedData[env.mode][uuid]
			local rate = cached.HitSpeed or cached.Speed or 0
			local hitChance = (cached.HitChance or 100) / 100
			eventsPerSecond = rate * hitChance
			if breakdown and eventsPerSecond > 0 then
				breakdown.MetaEnergyEventsPerSecond = {
					s_format("%.2f ^8(%s hit rate)", rate, source.activeEffect.grantedEffect.name),
					s_format("x %.2f%% ^8(hit chance)", cached.HitChance or 100),
					s_format("= %.2f ^8(melee hits per second)", eventsPerSecond),
				}
			end
		end
	end

	-- Energy per qualifying event: manual override if set, otherwise the gem's own constant,
	-- scaled by monster Power (for the events that are "per monster Power" - Crit, Elemental Ailment,
	-- Melee Kill, Melee Stun) and by "Meta Skills gain X% increased/more Energy" mods on the Meta gem.
	local energyPerEventOverride = env.build.configTab.input[config.energyPerEventVar]
	local energyPerEventBase = (energyPerEventOverride and energyPerEventOverride > 0) and energyPerEventOverride
		or (energyPerEventStat and metaSkill.skillModList:Sum("BASE", metaSkill.skillCfg, energyPerEventStat)) or 0
	if config.powerScaled then
		local enemyPower = metaSkill.skillModList:Sum("BASE", metaSkill.skillCfg, "Multiplier:EnemyPower")
		energyPerEventBase = energyPerEventBase * ((enemyPower and enemyPower > 0) and enemyPower or 1)
	end
	local generationMult = calcLib.mod(metaSkill.skillModList, metaSkill.skillCfg, "MetaEnergyGeneration")
	local energyPerEvent = energyPerEventBase * generationMult

	if eventsPerSecond <= 0 or energyMax <= 0 or energyPerEvent <= 0 then
		mainSkill.skillData.triggered = nil
		mainSkill.infoMessage2 = "DPS reported assuming Self-Cast"
		mainSkill.infoMessage = s_format("Set %s's qualifying events/Energy-per-event in the Configuration tab", config.triggerName or "Meta gem")
		mainSkill.infoTrigger = ""
		return
	end

	-- "X% chance for Trigger skills to refund half of Energy Spent": each trigger either refunds half the
	-- pool (rounding down to fewer events needed next cycle) or doesn't - two discrete, already-rounded
	-- outcomes. The long-run average events-per-trigger is the chance-weighted average of those two rounded
	-- outcomes (E[ceil(cost)]), not ceil of the averaged cost (ceil(E[cost])) - those aren't the same number,
	-- since rounding doesn't commute with averaging.
	local refundChance = m_min(100, metaSkill.skillModList:Sum("BASE", metaSkill.skillCfg, "MetaEnergyRefundChance"))
	local refundProb = refundChance / 100
	local eventsToTriggerFull = m_ceil(energyMax / energyPerEvent)
	local eventsToTriggerRefund = m_ceil(energyMax * 0.5 / energyPerEvent)
	local eventsToTrigger = refundProb * eventsToTriggerRefund + (1 - refundProb) * eventsToTriggerFull
	local energyLimitedRate = eventsPerSecond / eventsToTrigger
	local cooldownCap = mainSkillCooldownRate(mainSkill)
	local triggerRate = m_min(energyLimitedRate, cooldownCap)

	mainSkill.skillData.triggered = true
	mainSkill.skillData.triggerRate = triggerRate
	mainSkill.infoMessage = config.triggerName
	mainSkill.infoTrigger = config.triggerName
	output.MetaEnergyPerEvent = energyPerEvent
	output.MetaEnergyEventsToTrigger = eventsToTrigger
	output.MetaEnergyEventsPerSecond = eventsPerSecond
	output.MetaEnergyTriggerRate = triggerRate

	if breakdown then
		if refundProb > 0 then
			breakdown.MetaEnergyEventsToTrigger = {
				s_format("%.1f%% chance: %.1f / %.2f = %.2f, rounded up to %d ^8(events needed if refund triggers)", refundChance, energyMax * 0.5, energyPerEvent, energyMax * 0.5 / energyPerEvent, eventsToTriggerRefund),
				s_format("%.1f%% chance: %.1f / %.2f = %.2f, rounded up to %d ^8(events needed if it doesn't)", 100 - refundChance, energyMax, energyPerEvent, energyMax / energyPerEvent, eventsToTriggerFull),
				s_format("= %.2f ^8(chance-weighted average events needed per trigger)", eventsToTrigger),
			}
		else
			breakdown.MetaEnergyEventsToTrigger = {
				s_format("%.1f ^8(Maximum Energy)", energyMax),
				s_format("/ %.2f ^8(Energy per qualifying event)", energyPerEvent),
				s_format("= %.2f, rounded up to %d ^8(qualifying events needed per trigger)", energyMax / energyPerEvent, eventsToTriggerFull),
			}
		end
		breakdown.EffectiveSourceRate = {
			s_format("%.2f ^8(qualifying events per second%s)", eventsPerSecond, breakdown.MetaEnergyEventsPerSecond and ", auto-derived (see above)" or ", from Configuration tab"),
			s_format("/ %.2f ^8(qualifying events needed per trigger)", eventsToTrigger),
			s_format("= %.2f ^8(Energy-limited trigger rate)", energyLimitedRate),
		}
		if cooldownCap < energyLimitedRate then
			t_insert(breakdown.EffectiveSourceRate, s_format("min(%.2f, %.2f) ^8(Energy-limited, capped by %s's own cooldown)", energyLimitedRate, cooldownCap, mainSkill.activeEffect.grantedEffect.name))
			t_insert(breakdown.EffectiveSourceRate, s_format("= %.2f ^8(%s trigger rate)", triggerRate, config.triggerName or "Meta gem"))
		end
	end
end

-- Invocation Meta skills (Barrier Invocation, proof of concept for Stage 6 - see the Stage 6 plan notes)
-- don't auto-fire at maximum Energy; the player manually activates a real cooldown-gated skill, which
-- discharges banked Energy to trigger socketed spells, possibly multiple times per activation if enough
-- Energy is banked. Reported as a steady-state average rate (matching every other rate PoB reports),
-- bounded by whichever is more restrictive: how fast the Invocation can be activated (its own cooldown),
-- or how fast Energy regenerates relative to one full discharge's cost:
--   triggerRate = min(1 / cooldown, generationRatePerSecond / totalSocketedSpellCost)
-- This intentionally elides burst/reservoir-depletion behavior (how many discharges can chain back-to-back
-- before Energy runs dry) - a documented approximation, same as Stage 1's manual-rate model was.
local function metaInvocationTriggerHandler(env, config)
	local actor = config.actor
	local output = actor.output
	local breakdown = actor.breakdown
	local mainSkill = actor.mainSkill
	local skillFlags = env.mode == "CALCS" and mainSkill.activeEffect.statSetCalcs.skillFlags or mainSkill.activeEffect.statSet.skillFlags

	-- Find the Invocation skill itself, carrying the fixed Maximum Energy and generation stats.
	local metaSkill
	for _, skill in ipairs(actor.activeSkillList) do
		if skill.socketGroup == mainSkill.socketGroup and skill.skillModList:Sum("BASE", skill.skillCfg, "MetaEnergyMax") > 0 then
			metaSkill = skill
			break
		end
	end

	if not metaSkill then
		mainSkill.skillData.triggered = nil
		mainSkill.infoMessage2 = "DPS reported assuming Self-Cast"
		mainSkill.infoMessage = s_format("%s not found in socket group", config.triggerName or "Invocation")
		mainSkill.infoTrigger = ""
		return
	end

	-- Cost of one full discharge: same per-socketed-spell cost formula as the auto-fire Meta gems, just
	-- summed here for "what one discharge consumes" rather than "what fills the (separately fixed) pool".
	local totalSocketedSpellCost = 0
	local costBreakdown = breakdown and {}
	for _, skill in ipairs(actor.activeSkillList) do
		if skill.socketGroup == mainSkill.socketGroup and skill.skillModList:Flag(skill.skillCfg, "TriggeredByMetaEnergy") then
			local costRateMs = skill.skillModList:Sum("BASE", skill.skillCfg, "MetaEnergyCostRateMs")
			if costRateMs and costRateMs > 0 then
				local baseTime = (skill.skillData.castTimeOverride or skill.activeEffect.grantedEffect.castTime or 0) + skill.skillModList:Sum("BASE", skill.skillCfg, "Speed")
				local totalTime = skill.skillModList:Sum("BASE", skill.skillCfg, "TotalCastTime") + skill.skillModList:Sum("BASE", skill.skillCfg, "TotalAttackTime")
				local cost = ((baseTime * 1000) + (totalTime * 1000 * 2)) / costRateMs
				totalSocketedSpellCost = totalSocketedSpellCost + cost
				if costBreakdown then
					t_insert(costBreakdown, s_format("%.1f ^8Energy (%s: %.2fs base%s)", cost, skill.activeEffect.grantedEffect.name, baseTime, totalTime > 0 and s_format(" + 2x%.2fs Total Cast Time", totalTime) or ""))
				end
			end
		end
	end

	-- "Invocated skills have X% increased Maximum Energy" scales the fixed pool itself (MetaEnergyMaxIncrease),
	-- distinct from "Meta Skills gain X% increased Energy" (MetaEnergyGeneration), which scales generation
	-- rate. The mod is tagged Condition:InvocationSkill (matching "Invocated Spells deal/have..." mods
	-- elsewhere), which nothing in the calc engine sets automatically for SkillType.Invocation skills - use
	-- a config-scoped copy so it reads true here without mutating the Invocation's real skillCfg/mod list.
	-- "Invocated Spells have..." mods (as opposed to "Invocated skills have...") are additionally tagged
	-- keywordFlags=Spell by the "invocated spells have" prefix (ModParser.lua), since those mods are meant to
	-- apply within a Spell's own calculation context - add that bit here too so Sum()'s MatchKeywordFlags
	-- check doesn't reject them when read via the Invocation skill's own (non-Spell-tagged) cfg.
	local invocationCfg = copyTable(metaSkill.skillCfg, true)
	invocationCfg.skillCond = setmetatable({ InvocationSkill = true }, { __index = metaSkill.skillCfg.skillCond })
	invocationCfg.keywordFlags = bor(metaSkill.skillCfg.keywordFlags, KeywordFlag.Spell)
	local energyMaxBase = metaSkill.skillModList:Sum("BASE", metaSkill.skillCfg, "MetaEnergyMax")
	local energyMaxMult = calcLib.mod(metaSkill.skillModList, invocationCfg, "MetaEnergyMaxIncrease")
	local energyMax = energyMaxBase * energyMaxMult
	output.MetaEnergyMax = energyMax
	skillFlags.metaEnergyTriggered = true
	if breakdown then
		breakdown.MetaEnergyMax = costBreakdown
		if energyMaxMult ~= 1 then
			t_insert(breakdown.MetaEnergyMax, s_format("%.1f ^8(fixed Maximum Energy)", energyMaxBase))
			t_insert(breakdown.MetaEnergyMax, s_format("x %.2f ^8(increased/more Maximum Energy)", energyMaxMult))
			t_insert(breakdown.MetaEnergyMax, s_format("= %.1f ^8Energy cost of one discharge", totalSocketedSpellCost))
		else
			t_insert(breakdown.MetaEnergyMax, s_format("= %.1f ^8Energy cost of one discharge (fixed Maximum Energy: %.1f)", totalSocketedSpellCost, energyMax))
		end
	end

	-- "X% chance for Trigger skills to refund half of Energy Spent" (generic, from either Meta or Invocation
	-- sources) and "Invocated Spells have X% chance to consume half as much Energy" (Invocation-only, reads
	-- the same Condition:InvocationSkill-scoped invocationCfg as MetaEnergyMaxIncrease above) both reduce to
	-- the same expected-value multiplier on the cost of one discharge; independent, so their multipliers
	-- combine multiplicatively. energyMax (the pool cap) is unaffected - refund/discount affects spending,
	-- not how much can be banked.
	local refundChance = m_min(100, metaSkill.skillModList:Sum("BASE", metaSkill.skillCfg, "MetaEnergyRefundChance"))
	local discountChance = m_min(100, metaSkill.skillModList:Sum("BASE", invocationCfg, "MetaEnergyDischargeCostReduceChance"))
	local refundDiscountMult = (1 - refundChance / 200) * (1 - discountChance / 200)
	local effectiveDischargeCost = totalSocketedSpellCost * refundDiscountMult
	if breakdown and refundDiscountMult ~= 1 then
		breakdown.MetaEnergyDischargeCost = {
			s_format("%.1f ^8(Energy cost of one discharge)", totalSocketedSpellCost),
			s_format("x %.3f ^8(chance-weighted Energy refund/discount)", refundDiscountMult),
			s_format("= %.2f ^8(effective Energy cost per discharge)", effectiveDischargeCost),
		}
	end

	-- Generation rate: manual input (config.generationRateVar), converted to Energy/sec one of three ways
	-- depending on the gem, then scaled by "Meta Skills gain X% increased/more Energy" mods on the
	-- Invocation itself. config.generationDivisorStat: input is a continuous quantity (e.g. Barrier
	-- Invocation's "ES damage taken/sec"), divided by the gem's own divisor constant.
	-- config.generationEnergyPerEventStat: input is an event rate (e.g. Reaper's Invocation's "melee
	-- kills/sec"), multiplied by the gem's own per-event constant (optionally scaled by monster Power,
	-- same as the auto-fire Meta gems' powerScaled handling).
	-- config.generationPerCastTimeStat (Spellslinger): Energy per cast depends on the caster's own base
	-- cast time, so this auto-detects a self-cast Spell in the group the same way Cast on Critical does
	-- (findAutoEnergySource), and uses its cast rate (or the manual override, if set) x its own base cast
	-- time x the gem's per-cast-time-second constant. A source skill is always needed for its base cast
	-- time, even when the rate itself is manually overridden.
	local generationInput = env.build.configTab.input[config.generationRateVar] or 0
	local generationMult = calcLib.mod(metaSkill.skillModList, metaSkill.skillCfg, "MetaEnergyGeneration")
	local generationRatePerSecond = 0
	if config.generationDivisorStat then
		local divisor = metaSkill.skillModList:Sum("BASE", metaSkill.skillCfg, config.generationDivisorStat)
		generationRatePerSecond = (divisor and divisor > 0) and (generationInput / divisor) * generationMult or 0
	elseif config.generationEnergyPerEventStat then
		local perEvent = metaSkill.skillModList:Sum("BASE", metaSkill.skillCfg, config.generationEnergyPerEventStat) or 0
		if config.generationPowerScaled then
			local enemyPower = metaSkill.skillModList:Sum("BASE", metaSkill.skillCfg, "Multiplier:EnemyPower")
			perEvent = perEvent * ((enemyPower and enemyPower > 0) and enemyPower or 1)
		end
		generationRatePerSecond = generationInput * perEvent * generationMult
	elseif config.generationPerCastTimeStat then
		-- Auto-detection needs a self-cast, non-triggered Spell in the same group - but Spellslinger's own
		-- hidden support attaches to every compatible Triggerable spell in that same group, so a genuine
		-- "self-cast, untriggered Spell" companion essentially never exists there in practice. Attempted
		-- as best-effort for the rare case a valid source does exist; otherwise config.generationRateVar
		-- (the manual override) is read directly as the final Energy/sec, since there's no source to
		-- supply a base cast time to decompose it against.
		local perCastTimeSecond = metaSkill.skillModList:Sum("BASE", metaSkill.skillCfg, config.generationPerCastTimeStat) or 0
		local source, uuid = findAutoEnergySource(env, actor, mainSkill, false, true)
		if source and uuid then
			local cached = GlobalCache.cachedData[env.mode][uuid]
			local sourceBaseCastTime = source.activeEffect.grantedEffect.castTime or 0
			local castRate = (cached and (cached.HitSpeed or cached.Speed)) or 0
			generationRatePerSecond = castRate * sourceBaseCastTime * perCastTimeSecond * 100 * generationMult
			if breakdown and generationRatePerSecond > 0 then
				breakdown.MetaEnergyEventsPerSecond = {
					s_format("%.2f ^8(%s cast rate)", castRate, source.activeEffect.grantedEffect.name),
					s_format("x %.2fs ^8(%s base cast time)", sourceBaseCastTime, source.activeEffect.grantedEffect.name),
					s_format("x %.2f ^8(Energy generated per second of base cast time)", perCastTimeSecond * 100),
					s_format("= %.2f ^8(Energy generated per second)", generationRatePerSecond),
				}
			end
		elseif generationInput > 0 then
			generationRatePerSecond = generationInput * generationMult
		end
	elseif config.ailmentTypeVar then
		-- Elemental Invocation: same Freeze/Shock/Ignite selector and per-event constants as Cast on
		-- Elemental Ailment (Stage 3), just feeding this handler's discharge model instead.
		local ailmentType, ailmentInfo = resolveAilmentEnergyStat(env, config)
		local perEvent = (ailmentInfo and metaSkill.skillModList:Sum("BASE", metaSkill.skillCfg, ailmentInfo.energyStat)) or 0
		local enemyPower = metaSkill.skillModList:Sum("BASE", metaSkill.skillCfg, "Multiplier:EnemyPower")
		perEvent = perEvent * ((enemyPower and enemyPower > 0) and enemyPower or 1)
		generationRatePerSecond = generationInput * perEvent * generationMult
	end

	-- The Invocation's own activation cooldown, independent of any config input.
	local baseCooldown = (metaSkill.activeEffect.grantedEffect.levels[metaSkill.activeEffect.level] or {}).cooldown or metaSkill.skillData.cooldown or 0
	local cooldownRecoveryMod = calcLib.mod(metaSkill.skillModList, metaSkill.skillCfg, "CooldownRecovery")
	local cooldown = (baseCooldown > 0 and cooldownRecoveryMod > 0) and (baseCooldown / cooldownRecoveryMod) or 0
	local cooldownRate = cooldown > 0 and (1 / cooldown) or m_huge

	if generationRatePerSecond <= 0 or totalSocketedSpellCost <= 0 then
		mainSkill.skillData.triggered = nil
		mainSkill.infoMessage2 = "DPS reported assuming Self-Cast"
		mainSkill.infoMessage = s_format("Set %s's Energy generation rate in the Configuration tab", config.triggerName or "Invocation")
		mainSkill.infoTrigger = ""
		return
	end

	local generationLimitedRate = generationRatePerSecond / effectiveDischargeCost

	-- A single Invocation activation can chain multiple discharges at once if Energy has banked up faster
	-- than the cooldown drains it ("triggers spells... a number of times based on the amount of energy
	-- used") - not just one discharge per activation. Energy banked between activations is capped at the
	-- fixed Maximum Energy pool (energyMax); generation beyond that between two activations is wasted, same
	-- "excess is discarded" rule the auto-fire gems already use.
	--
	-- With refund/discount chances present, each discharge within the chain independently rolls its own
	-- cost (cost * X * Y, X/Y in {1, 0.5} for discount/refund respectively) - floor(reservoir / E[cost])
	-- is biased (a bad roll on an early discharge can block a later one that would otherwise have fit), so
	-- this is computed exactly via a DP over the reservoir discretized into quarters of the full cost (all
	-- three possible per-discharge costs - full/half/quarter - are exact multiples of that quarter, so the
	-- discretization loses no precision: any remainder below one quarter can never be spent by any outcome).
	local pRefund, pDischargeDiscount = refundChance / 100, discountChance / 100
	local pBoth = pRefund * pDischargeDiscount
	local pHalf = pRefund + pDischargeDiscount - 2 * pBoth
	local pFull = 1 - pHalf - pBoth
	local quarterCost = totalSocketedSpellCost * 0.25

	local burstRate = m_huge
	local dischargesPerActivation = 0
	if cooldown > 0 then
		local energyPerActivation = m_min(generationRatePerSecond * cooldown, energyMax)
		local maxQuarters = m_floor(energyPerActivation / quarterCost)
		local expectedDischarges = { [0] = 0 }
		for q = 1, maxQuarters do
			local e = 0
			if q >= 4 then e = e + pFull * (1 + expectedDischarges[q - 4]) end
			if q >= 2 then e = e + pHalf * (1 + expectedDischarges[q - 2]) end
			if q >= 1 then e = e + pBoth * (1 + expectedDischarges[q - 1]) end
			expectedDischarges[q] = e
		end
		dischargesPerActivation = expectedDischarges[maxQuarters] or 0
		if dischargesPerActivation >= 1 then
			burstRate = cooldownRate * dischargesPerActivation
		end
	end

	local spellCooldownCap = mainSkillCooldownRate(mainSkill)
	local triggerRate = m_min(generationLimitedRate, burstRate, spellCooldownCap)

	mainSkill.skillData.triggered = true
	mainSkill.skillData.triggerRate = triggerRate
	mainSkill.infoMessage = config.triggerName
	mainSkill.infoTrigger = config.triggerName
	output.MetaEnergyPerEvent = totalSocketedSpellCost
	output.MetaEnergyEventsPerSecond = generationRatePerSecond
	output.MetaEnergyTriggerRate = triggerRate

	if breakdown then
		breakdown.MetaEnergyEventsToTrigger = {
			s_format("%.2f ^8(Energy generated per second)", generationRatePerSecond),
			s_format("/ %.2f ^8(effective Energy cost of one discharge)", effectiveDischargeCost),
			s_format("= %.3f ^8(Energy-limited discharge rate)", generationLimitedRate),
		}
		breakdown.EffectiveSourceRate = {
			s_format("%.3fs ^8(Invocation cooldown, after cooldown recovery)", cooldown),
			s_format("= %.3f ^8(activation rate)", cooldownRate),
		}
		if dischargesPerActivation >= 1 then
			t_insert(breakdown.EffectiveSourceRate, s_format("x %.2f ^8(expected discharges chained per activation, chance-weighted from banked Energy)", dischargesPerActivation))
			t_insert(breakdown.EffectiveSourceRate, s_format("= %.3f ^8(cooldown-limited discharge rate)", burstRate))
		end
		t_insert(breakdown.EffectiveSourceRate, "")
		t_insert(breakdown.EffectiveSourceRate, s_format("min(%.3f, %.3f) ^8(cooldown-limited, Energy-limited)", burstRate, generationLimitedRate))
		local minusCooldownCap = m_min(generationLimitedRate, burstRate)
		if spellCooldownCap < minusCooldownCap then
			t_insert(breakdown.EffectiveSourceRate, s_format("= %.3f", minusCooldownCap))
			t_insert(breakdown.EffectiveSourceRate, "")
			t_insert(breakdown.EffectiveSourceRate, s_format("min(%.3f, %.3f) ^8(prior result, capped by %s's own cooldown)", minusCooldownCap, spellCooldownCap, mainSkill.activeEffect.grantedEffect.name))
		end
		t_insert(breakdown.EffectiveSourceRate, s_format("= %.3f ^8(%s trigger rate)", triggerRate, config.triggerName or "Invocation"))
	end
end

local function defaultTriggerHandler(env, config)
	local actor = config.actor
	local output = config.actor.output
	local breakdown = config.actor.breakdown
	local source = config.source
	local triggeredSkills = config.triggeredSkills or {}
	local trigRate = config.trigRate
	local uuid

	-- Find trigger skill and triggered skills
	if config.triggeredSkillCond or config.triggerSkillCond then
		for _, skill in ipairs(env.player.activeSkillList) do
			if config.triggerSkillCond and config.triggerSkillCond(env, skill) and (not isTriggered(skill) or actor.mainSkill.skillFlags.globalTrigger or config.allowTriggered) and skill ~= actor.mainSkill then
				source, trigRate, uuid = findTriggerSkill(env, skill, source, trigRate, config.comparer)
			end
			if config.triggeredSkillCond and config.triggeredSkillCond(env,skill) then
				t_insert(triggeredSkills, packageSkillDataForSimulation(skill, env))
			end
		end
	end
	if #triggeredSkills > 0 or not config.triggeredSkillCond then
		if not source and not (actor.mainSkill.skillFlags.globalTrigger and config.triggeredSkillCond) then
			actor.mainSkill.skillData.triggered = nil
			actor.mainSkill.infoMessage2 = "DPS reported assuming Self-Cast"
			actor.mainSkill.infoMessage = s_format("No %s Triggering Skill Found", config.triggerName)
			actor.mainSkill.infoTrigger = ""
		else
			actor.mainSkill.skillData.triggered = true

			-- Account for Arcanist Brand using activation frequency
			if breakdown and actor.mainSkill.skillData.triggeredByBrand then
				breakdown.EffectiveSourceRate = {
					s_format("%.2f ^8(base activation cooldown of %s)", actor.mainSkill.triggeredBy.mainSkill.skillData.repeatFrequency, config.triggerName),
					s_format("* %.2f ^8(more activation frequency)", actor.mainSkill.triggeredBy.activationFreqMore),
					s_format("* %.2f ^8(increased activation frequency)", actor.mainSkill.triggeredBy.activationFreqInc),
					s_format("= %.2f ^8(activation rate of %s)", trigRate, actor.mainSkill.triggeredBy.mainSkill.activeEffect.grantedEffect.name)
				}
			elseif breakdown then
				breakdown.EffectiveSourceRate = {}
				if trigRate and source then
					if config.assumingEveryHitKills then
						t_insert(breakdown.EffectiveSourceRate, "Assuming every attack kills")
					end
					t_insert(breakdown.EffectiveSourceRate, s_format("%.2f ^8(%s %s)", trigRate, config.sourceName or source.activeEffect.grantedEffect.name, config.useCastRate and "cast rate" or "attack rate"))
				end
			end

			-- Dual wield triggers
			if trigRate and source and env.player.weaponData1.type and env.player.weaponData2.type and not source.skillData.combinesHitsWhenDualWielding and (source.skillTypes[SkillType.Melee] or source.skillTypes[SkillType.Attack]) and actor.mainSkill.triggeredBy and actor.mainSkill.triggeredBy.grantedEffect.support and actor.mainSkill.triggeredBy.grantedEffect.fromItem then
				trigRate = trigRate / 2
				if breakdown then
					t_insert(breakdown.EffectiveSourceRate, 2, s_format("/ 2 ^8(due to dual wielding)"))
				end
			end

			actor.mainSkill.skillData.ignoresTickRate = actor.mainSkill.skillData.ignoresTickRate or (actor.mainSkill.skillData.storedUses and actor.mainSkill.skillData.storedUses > 1)

			--Account for source unleash
			if source and GlobalCache.cachedData[env.mode][uuid] and source.skillModList:Flag(nil, "HasSeals") and source.skillModList:Flag(nil, "DamageSeal") then
				local unleashDpsMult = GlobalCache.cachedData[env.mode][uuid].ActiveSkill.skillData.dpsMultiplier or 1
				trigRate = trigRate * unleashDpsMult
				actor.mainSkill.skillFlags.HasSeals = true
				actor.mainSkill.skillData.ignoresTickRate = true
				if breakdown then
					t_insert(breakdown.EffectiveSourceRate, s_format("x %.2f ^8(multiplier from Unleash)", unleashDpsMult))
				end
			end

			--Account for skills that can hit multiple times per use
			if source and GlobalCache.cachedData[env.mode][uuid] and source.skillPartName and source.skillPartName:match("(.*)All(.*)Projectiles(.*)") and source.skillFlags.projectile then
				local multiHitDpsMult = GlobalCache.cachedData[env.mode][uuid].Env.player.output.ProjectileCount or 1
				trigRate = trigRate * multiHitDpsMult
				if breakdown then
					t_insert(breakdown.EffectiveSourceRate, s_format("x %.2f ^8(%d projectiles hit)", multiHitDpsMult, multiHitDpsMult))
				end
			end

			--Special handling for Kitava's Thirst
			-- Repeated hits do not consume mana and do not trigger Kitava's thirst
			if actor.mainSkill.skillData.triggeredByManaSpent then
				local repeats = 1 + source.skillModList:Sum("BASE", nil, "RepeatCount")
				trigRate = trigRate / repeats
				if breakdown and repeats > 1 then
					t_insert(breakdown.EffectiveSourceRate, s_format("/%d ^8(repeated attacks/casts do not count as they don't use mana)", repeats))
				end
			end

			-- Battlemage's Cry uptime
			if actor.mainSkill.skillData.triggeredByBattleMageCry and GlobalCache.cachedData[env.mode][uuid] and source and source.skillTypes[SkillType.Melee] then
				local battleMageExertsCount = GlobalCache.cachedData[env.mode][uuid].Env.player.output.BattleCryExertsCount
				local battleMageDuration = ceil_b(GlobalCache.cachedData[env.mode][uuid].Env.player.output.BattleMageCryDuration, data.misc.ServerTickTime)
				local battleMageCastTime = GlobalCache.cachedData[env.mode][uuid].Env.player.output.BattleMageCryCastTime
				local battleMageCooldown = ceil_b(GlobalCache.cachedData[env.mode][uuid].Env.player.output.BattleMageCryCooldown, data.misc.ServerTickTime)

				-- Cap the number of hits that happen during the duration
				local battleMageHits = m_max(m_min(trigRate * battleMageDuration, battleMageExertsCount), 0)

				if breakdown then
					t_insert(breakdown.EffectiveSourceRate, s_format("^8(min(%.2f * %.2f, %d) = %.2f average number of exerted attacks capped by exerted count)", trigRate, battleMageDuration, battleMageExertsCount, battleMageHits))
					t_insert(breakdown.EffectiveSourceRate, s_format("= %.2f / (%.2f + %.2f) ^8(the calculated number of exerted attacks happens every cooldown + duration)", battleMageHits, battleMageCastTime, battleMageCooldown))
				end

				-- The hits happen every battlemage cooldown + duration
				trigRate = battleMageHits / (battleMageCastTime + battleMageCooldown)
			end

			-- Infernal Cry uptime
			if actor.mainSkill.activeEffect.grantedEffect.name == "Combust" and GlobalCache.cachedData[env.mode][uuid] and source and source.skillTypes[SkillType.Melee] then
				local infernalCryExertsCount = GlobalCache.cachedData[env.mode][uuid].Env.player.output.InfernalEmpoweredCount
				local infernalCryDuration = ceil_b(GlobalCache.cachedData[env.mode][uuid].Env.player.output.InfernalCryDuration, data.misc.ServerTickTime)
				local infernalCryCastTime = GlobalCache.cachedData[env.mode][uuid].Env.player.output.InfernalCryCastTime
				local infernalCryCooldown = ceil_b(GlobalCache.cachedData[env.mode][uuid].Env.player.output.InfernalCryCooldown, data.misc.ServerTickTime)

				-- Cap the number of hits that happen during the duration
				local infernalCryHits = m_max(m_min(trigRate * infernalCryDuration, infernalCryExertsCount), 0)

				if breakdown then
					t_insert(breakdown.EffectiveSourceRate, s_format("^8(min(%.2f * %.2f, %d) = %.2f average number of exerted attacks capped by exerted count)", trigRate, infernalCryDuration, infernalCryExertsCount, infernalCryHits))
					t_insert(breakdown.EffectiveSourceRate, s_format("= %.2f / (%.2f + %.2f) ^8(the calculated number of exerted attacks happens every cooldown + duration)", infernalCryHits, infernalCryCastTime, infernalCryCooldown))
				end

				-- The hits happen every Infernal Cry cooldown + duration
				trigRate = infernalCryHits / (infernalCryCastTime + infernalCryCooldown)
			end

			-- Handling for mana spending rate for Manaforged Arrows Support
			if actor.mainSkill.skillData.triggeredByManaforged and trigRate > 0 then
				local triggeredUUID = cacheSkillUUID(actor.mainSkill, env)
				if not GlobalCache.cachedData[env.mode][triggeredUUID] then
					calcs.buildActiveSkill(env, env.mode, actor.mainSkill, triggeredUUID, {[triggeredUUID] = true})
				end
				local triggeredManaCost = GlobalCache.cachedData[env.mode][triggeredUUID].Env.player.output.ManaCostRaw or 0
				if triggeredManaCost > 0 then
					local manaSpentThreshold = triggeredManaCost * actor.mainSkill.skillData.ManaForgedArrowsPercentThreshold
					local sourceManaCost = GlobalCache.cachedData[env.mode][uuid].Env.player.output.ManaCostRaw or 0
					if sourceManaCost > 0 then
						if breakdown then
							breakdown.EffectiveSourceRate = {
								s_format("%.4f ^8(Mana cost of trigger source)", sourceManaCost),
								s_format(""),
								s_format("%.4f ^8(Mana Cost of triggered)", triggeredManaCost),
								s_format("%.2f ^8(Manaforged threshold multiplier)", actor.mainSkill.skillData.ManaForgedArrowsPercentThreshold),
								s_format("= %.4f ^8(Manaforged trigger threshold)", manaSpentThreshold),
								s_format(""),
								s_format("%.4f ^8(Manaforged trigger threshold)", manaSpentThreshold),
								s_format("/ %.4f ^8(Mana cost of trigger source)", sourceManaCost),
								s_format("= %.2f ^8(Skill usages required)", manaSpentThreshold / sourceManaCost),
								s_format(""),
								breakdown.EffectiveSourceRate[1],
								s_format("/ ceil(%.2f) ^8(%d Skill usages required)", manaSpentThreshold / sourceManaCost, m_ceil(manaSpentThreshold / sourceManaCost)),
							}
						end
						trigRate = trigRate / m_ceil(manaSpentThreshold / sourceManaCost)
					else
						if breakdown then
							t_insert(breakdown.EffectiveSourceRate, s_format("Source skill has no mana cost", output.EffectiveSourceRate))
						end
						trigRate = 0
					end
				end
			end

			local icdr = calcLib.mod(actor.mainSkill.skillModList, actor.mainSkill.skillCfg, "CooldownRecovery") or 1
			local addedCooldown = actor.mainSkill.skillModList:Sum("BASE", actor.mainSkill.skillCfg, "CooldownRecovery")
			addedCooldown = addedCooldown ~= 0 and addedCooldown or nil
			local cooldownOverride = actor.mainSkill.skillModList:Override(actor.mainSkill.skillCfg, "CooldownRecovery")
			local triggerCD = actor.mainSkill.triggeredBy and env.player.mainSkill.triggeredBy.grantedEffect.levels[env.player.mainSkill.triggeredBy.level].cooldown
			triggerCD = triggerCD or source.triggeredBy and source.triggeredBy.grantedEffect.levels[source.triggeredBy.level].cooldown
			local triggeredCD = actor.mainSkill.skillData.cooldown

			if actor.mainSkill.skillData.triggeredByBrand then
				triggerCD = actor.mainSkill.triggeredBy.mainSkill.skillData.repeatFrequency / actor.mainSkill.triggeredBy.activationFreqMore / actor.mainSkill.triggeredBy.activationFreqInc
				triggerCD = triggerCD * icdr -- cancels out division by icdr lower, brand activation rate is not affected by icdr
			end

			local triggeredName = (actor.mainSkill.activeEffect.grantedEffect and actor ~= env.minion and actor.mainSkill.activeEffect.grantedEffect.name) or "Triggered skill"
			local csi
			output.addsCastTime, csi = processAddedCastTime(env.player.mainSkill, breakdown)

			local triggeredCDAdjusted = ( (triggeredCD or 0) + (addedCooldown or 0) ) / icdr
			local triggerCDAdjusted = ( (triggerCD or 0) + (output.addsCastTime or 0) ) / icdr
			local triggeredCDTickRounded = actor.mainSkill.skillData and actor.mainSkill.skillData.ignoresTickRate and triggeredCDAdjusted or m_ceil(triggeredCDAdjusted * data.misc.ServerTickRate) / data.misc.ServerTickRate
			local triggerCDTickRounded = actor.mainSkill.triggeredBy and actor.mainSkill.triggeredBy.ignoresTickRate and triggerCDAdjusted or m_ceil(triggerCDAdjusted * data.misc.ServerTickRate) / data.misc.ServerTickRate
			local actionCooldown = cooldownOverride or m_max((triggerCD or 0) + (output.addsCastTime or 0), (triggeredCD or 0) + (addedCooldown or 0))
			local actionCooldownAdjusted = cooldownOverride or m_max(triggerCDAdjusted, triggeredCDAdjusted)
			local actionCooldownTickRounded = cooldownOverride and (m_ceil(cooldownOverride * data.misc.ServerTickRate) / data.misc.ServerTickRate) or m_max(triggerCDTickRounded, triggeredCDTickRounded)

			output.TriggerRateCap = source == actor.mainSkill and actor.mainSkill.skillData.triggerRateCapOverride or m_huge
			if actionCooldownTickRounded ~= 0 then
				output.TriggerRateCap = 1 / actionCooldownTickRounded
			end
			if config.triggerName == "Doom Blast" and env.build.configTab.input["doomBlastSource"] == "expiration" then
				local expirationRate = 1 / GlobalCache.cachedData[env.mode][uuid].Env.player.output.Duration
				if breakdown and breakdown.EffectiveSourceRate then
						breakdown.EffectiveSourceRate[1] = s_format("1 / %.2f ^8(source curse duration)", GlobalCache.cachedData[env.mode][uuid].Env.player.output.Duration)
				end
				if expirationRate > trigRate then
					env.player.modDB:NewMod("UsesCurseOverlaps", "FLAG", true, "Config")
					if breakdown and breakdown.EffectiveSourceRate then
						t_insert(breakdown.EffectiveSourceRate, 2, s_format("max(%.2f, %.2f) ^8(If a curse expires instantly curse expiration is equivalent to curse replacement)", expirationRate, trigRate))
						t_insert(breakdown.EffectiveSourceRate, 2, s_format("%.2f ^8(%s cast rate)", trigRate, source.activeEffect.grantedEffect.name))
					end
				else
					trigRate = expirationRate
				end
			elseif config.triggerName == "Doom Blast" and env.build.configTab.input["doomBlastSource"] == "hexblast" then
				local hexBlast, rate
				for _, skill in ipairs(env.player.activeSkillList) do
					if skill.activeEffect.grantedEffect.name == "Hexblast" and not isTriggered(skill) and skill ~= actor.mainSkill then
						hexBlast, rate, uuid = findTriggerSkill(env, skill, hexBlast, rate)
					end
				end
				if hexBlast then
					if breakdown then
						breakdown.EffectiveSourceRate[1] = s_format("1 / (%.2f + %.2f) ^8(sum of triggered curse and hexblast cast time)", 1/trigRate, 1/rate)
					end
					trigRate = 1/ (1/trigRate + 1/rate)
				end
			end

			if breakdown and not breakdown.TriggerRateCap then
				breakdown.TriggerRateCap = {}

				if cooldownOverride then
					t_insert(breakdown.TriggerRateCap, s_format("%.2f ^8(hard override of cooldown of %s)", cooldownOverride, triggeredName))
				elseif triggeredCDAdjusted == 0 then
					t_insert(breakdown.TriggerRateCap, triggeredName .. " has no base cooldown or cooldown override")
				else -- triggeredCDAdjusted ~= 0 triggered skill has some kind of cooldown
					if triggeredCD then
						t_insert(breakdown.TriggerRateCap, s_format("%.2f ^8(base cooldown of triggered skill)", triggeredCD))
					else
						t_insert(breakdown.TriggerRateCap, triggeredName .. " has no base cooldown or cooldown override")
					end
					if addedCooldown then
						t_insert(breakdown.TriggerRateCap, s_format("+ %.2f ^8(flat added cooldown)", addedCooldown))
					end
					t_insert(breakdown.TriggerRateCap, s_format("/ %.2f ^8(increased/reduced cooldown recovery)", icdr))
					t_insert(breakdown.TriggerRateCap, s_format("= %.4f ^8(final cooldown of triggered skill)", triggeredCDAdjusted))
				end

				t_insert(breakdown.TriggerRateCap, "")

				if actor ~= env.minion then -- Minion triggers have internal triggers
					if triggerCDAdjusted == 0 then
						t_insert(breakdown.TriggerRateCap, s_format("Trigger rate based on %s cooldown", triggeredName))
					else -- triggerCDAdjusted ~= 0 trigger has some kind of cooldown
						if triggerCD then
							t_insert(breakdown.TriggerRateCap, s_format("%.2f ^8(base cooldown of %s)", triggerCD, config.triggerName))
						else
							t_insert(breakdown.TriggerRateCap, config.triggerName .. " has no base cooldown")
						end
						if output.addsCastTime then
							t_insert(breakdown.TriggerRateCap, s_format("+ %.2f ^8(this skill adds cast time to cooldown when triggered)", output.addsCastTime))
						end
						t_insert(breakdown.TriggerRateCap, s_format("/ %.2f ^8(increased/reduced cooldown recovery)", icdr))
						t_insert(breakdown.TriggerRateCap, s_format("= %.4f ^8(final cooldown of trigger)", triggerCDAdjusted))
					end
				end

				t_insert(breakdown.TriggerRateCap, "")

				if triggeredCDAdjusted ~= 0 and triggerCDAdjusted ~= 0 then
					t_insert(breakdown.TriggerRateCap, s_format("%.3f ^8(biggest of trigger cooldown and triggered skill cooldown)", actionCooldownAdjusted))
				end

				local displayCooldownRounding = (actor.mainSkill.skillData and not actor.mainSkill.skillData.ignoresTickRate and triggeredCDAdjusted ~= 0) or (actor.mainSkill.triggeredBy and not actor.mainSkill.triggeredBy.ignoresTickRate and triggerCDAdjusted ~= 0)
				if displayCooldownRounding then
					t_insert(breakdown.TriggerRateCap, s_format("%.3f ^8(adjusted for server tick rate)", actionCooldownTickRounded))
				end

				local function extraIncreaseNeeded(affectedCD)
					if not cooldownOverride then
						local nextBreakpoint = actionCooldownTickRounded - data.misc.ServerTickTime
						local timeOverBreakpoint = actionCooldownAdjusted - nextBreakpoint
						local alreadyReducedTime = actionCooldown - actionCooldownAdjusted
						if timeOverBreakpoint < affectedCD then
							local divNeeded = affectedCD / (affectedCD - timeOverBreakpoint - alreadyReducedTime)
							local incTotal = m_ceil(( divNeeded - 1 ) * 100)
							return incTotal - (icdr - 1) * 100
						end
					end
				end

				local extraICDRNeeded = extraIncreaseNeeded(actionCooldown)
				if extraICDRNeeded then
					t_insert(breakdown.TriggerRateCap, s_format("^8(extra ICDR of %d%% would reach next breakpoint)", extraICDRNeeded))
				end

				local extraCSIncNeeded = output.addsCastTime and extraIncreaseNeeded(output.addsCastTime)
				if extraCSIncNeeded then
					t_insert(breakdown.TriggerRateCap, s_format("^8(extra ICS  of %d%% would reach next breakpoint)", extraCSIncNeeded))
				end

				t_insert(breakdown.TriggerRateCap, "")

				if not (triggeredCD or triggerCD or cooldownOverride) then
					t_insert(breakdown.TriggerRateCap, "Assuming cast on every kill/attack/hit")
				else
					t_insert(breakdown.TriggerRateCap, "Trigger rate:")
					t_insert(breakdown.TriggerRateCap, s_format("1 / %.3f", actionCooldownTickRounded))
					t_insert(breakdown.TriggerRateCap, s_format("= %.2f ^8per second", output.TriggerRateCap))
				end
			end

			if env.player.mainSkill.activeEffect.grantedEffect.name == "Doom Blast" and env.build.configTab.input["doomBlastSource"] == "vixen" then
				if not env.player.itemList["Gloves"] or env.player.itemList["Gloves"].title ~= "Vixen's Entrapment" then
					output.VixenModeNoVixenGlovesWarn = true
				end

				env.player.modDB:NewMod("UsesCurseOverlaps", "FLAG", true, "Config")
				local vixens = env.data.skills["SupportUniqueCastCurseOnCurse"]
				local vixensCD = vixens and vixens.levels[1].cooldown / icdr
				output.EffectiveSourceRate = calcMultiSpellRotationImpact(env, {{ uuid = cacheSkillUUID(env.player.mainSkill, env), icdr = icdr}}, trigRate, vixensCD)
				output.VixensTooMuchCastSpeedWarn = vixensCD > (1 / trigRate)
				if breakdown then
					t_insert(breakdown.EffectiveSourceRate, s_format("%.2f / %.2f = %.2f ^8(Vixen's trigger cooldown)", vixensCD * icdr, icdr, vixensCD))
					t_insert(breakdown.EffectiveSourceRate, s_format("%.2f ^8(Simulated trigger rate of a curse socketed in Vixen's given ^7%.2f ^8CD and ^7%.2f ^8source rate)", output.EffectiveSourceRate, vixensCD, trigRate))
				end
			elseif trigRate ~= nil and not actor.mainSkill.skillFlags.globalTrigger and not config.ignoreSourceRate then
				output.EffectiveSourceRate = trigRate
			else
				output.EffectiveSourceRate = output.TriggerRateCap
				actor.mainSkill.skillFlags.globalTrigger = true
			end

			if breakdown and not actor.mainSkill.skillData.sourceRateIsFinal then
				t_insert(breakdown.EffectiveSourceRate, s_format("= %.2f ^8(Effective source rate)", output.EffectiveSourceRate))
			end

			local skillName = (source and source.activeEffect.grantedEffect.name) or (actor.mainSkill.triggeredBy and actor.mainSkill.triggeredBy.grantedEffect.name) or actor.mainSkill.activeEffect.grantedEffect.name

			if output.EffectiveSourceRate ~= 0 then
				local triggerChance = 100
				local triggerChanceBreakdown = {}

				--Accuracy and crit chance
				if source and (source.skillTypes[SkillType.Melee] or source.skillTypes[SkillType.Attack]) and GlobalCache.cachedData[env.mode][uuid] and not config.triggerOnUse then

					local sourceHitChance = GlobalCache.cachedData[env.mode][uuid].HitChance or 0
					if sourceHitChance ~= 100 then
						-- Some skills hit with both weapons at the same time. Each weapon rolls accuracy and crit independently
						if source and env.player.weaponData1.type and env.player.weaponData2.type and source.skillData.combinesHitsWhenDualWielding then
							local mainHandHit = GlobalCache.cachedData[env.mode][uuid].Env.player.output.MainHand.HitChance
							local offHandHit = GlobalCache.cachedData[env.mode][uuid].Env.player.output.OffHand.HitChance
							local bothHit = mainHandHit * offHandHit / 100
							local mainHandMiss = (100 - mainHandHit)
							local offHandMiss = (100 - offHandHit)
							local effectiveHitChance = bothHit + mainHandHit * offHandMiss / 100 + mainHandMiss * offHandHit / 100
							triggerChance = triggerChance * effectiveHitChance / 100
							if breakdown then
								t_insert(triggerChanceBreakdown, s_format("x %.2f%% ^8(%s effective hit chance for skills that hit with both weapons)", effectiveHitChance, source.activeEffect.grantedEffect.name))
							end
						else
							triggerChance = triggerChance * (sourceHitChance or 0) / 100
							if breakdown then
								t_insert(triggerChanceBreakdown, s_format("x %.2f%% ^8(%s hit chance)", sourceHitChance, source.activeEffect.grantedEffect.name))
							end
						end
					end
					if actor.mainSkill.skillData.triggerOnCrit then
						local onCritChance = actor.mainSkill.skillData.chanceToTriggerOnCrit or (GlobalCache.cachedData[env.mode][uuid] and GlobalCache.cachedData[env.mode][uuid].Env.player.mainSkill.skillData.chanceToTriggerOnCrit)
						config.triggerChance = config.triggerChance or actor.mainSkill.skillData.chanceToTriggerOnCrit or onCritChance

						local sourceCritChance = GlobalCache.cachedData[env.mode][uuid].CritChance or 0
						if sourceCritChance ~= 100 then
							-- Some skills hit with both weapons at the same time. Each weapon rolls accuracy and crit independently
							if source and env.player.weaponData1.type and env.player.weaponData2.type and source.skillData.combinesHitsWhenDualWielding then
								local mainHandCrit = GlobalCache.cachedData[env.mode][uuid].Env.player.output.MainHand.CritChance
								local offHandCrit = GlobalCache.cachedData[env.mode][uuid].Env.player.output.OffHand.CritChance
								local bothHit = mainHandCrit * offHandCrit / 100
								local mainHandMiss = (100 - mainHandCrit)
								local offHandMiss = (100 - offHandCrit)
								local effectiveCritChance = bothHit + mainHandCrit * offHandMiss / 100 + mainHandMiss * offHandCrit / 100
								triggerChance = triggerChance * effectiveCritChance / 100
								if breakdown then
									t_insert(triggerChanceBreakdown, s_format("x %.2f%% ^8(%s effective crit chance for skills that hit with both weapons)", effectiveCritChance, source.activeEffect.grantedEffect.name))
								end
							else
								triggerChance = triggerChance * (sourceCritChance or 0) / 100
								if breakdown then
									t_insert(triggerChanceBreakdown, s_format("x %.2f%% ^8(%s crit chance)", sourceCritChance, source.activeEffect.grantedEffect.name))
								end
							end
						end
					end
				end

				--Trigger chance
				if config.triggerChance and config.triggerChance ~= 100 then
					triggerChance = triggerChance * config.triggerChance / 100
					if breakdown then
						t_insert(triggerChanceBreakdown, s_format("x %.2f%% ^8(chance to trigger)", config.triggerChance))
					end
				end

				-- If the current triggered skill ignores tick rate and is the only triggered skill by this trigger use charge based calcs
				if actor.mainSkill.skillData.ignoresTickRate and ( not config.triggeredSkillCond or (triggeredSkills and #triggeredSkills == 1 and triggeredSkills[1] == packageSkillDataForSimulation(actor.mainSkill, env)) ) then
					local overlaps = config.stagesAreOverlaps and env.player.mainSkill.skillPart == config.stagesAreOverlaps and env.player.mainSkill.activeEffect.srcInstance.skillStageCount or config.overlaps
					output.SkillTriggerRate = m_min(output.TriggerRateCap, output.EffectiveSourceRate * (overlaps or 1))
					if breakdown then
						if overlaps then
							breakdown.SkillTriggerRate = {
								s_format("min(%.2f, %.2f *  %d) ^8(%d overlaps)", output.TriggerRateCap, output.EffectiveSourceRate, overlaps, overlaps)
							}
						else
							breakdown.SkillTriggerRate = {
								s_format("min(%.2f, %.2f)", output.TriggerRateCap, output.EffectiveSourceRate)
							}
						end
					end
				elseif actor.mainSkill.skillFlags.globalTrigger and not config.triggeredSkillCond then -- Trigger does not use source rate breakpoints for one reason or another
					output.SkillTriggerRate = output.EffectiveSourceRate
				else -- Triggers like Cast on Crit go through simulation to calculate the trigger rate of each skill in the trigger group
					output.SkillTriggerRate, simBreakdown = calcMultiSpellRotationImpact(env, config.triggeredSkillCond and triggeredSkills or {packageSkillDataForSimulation(actor.mainSkill, env)}, output.EffectiveSourceRate, (not actor.mainSkill.skillData.triggeredByBrand and ( triggerCD or triggeredCD ) or 0), triggerChance, actor)
					local triggerBotsEffective = actor.modDB:Flag(nil, "HaveTriggerBots") and actor.mainSkill.skillTypes[SkillType.Spell]
					if triggerBotsEffective then
						output.SkillTriggerRate = 2 * output.SkillTriggerRate
					end

					-- stagesAreOverlaps is the skill part which makes the stages behave as overlaps
					local hits_per_cast = config.stagesAreOverlaps and env.player.mainSkill.skillPart == config.stagesAreOverlaps and env.player.mainSkill.activeEffect.srcInstance.skillStageCount or 1
					output.SkillTriggerRate = hits_per_cast * output.SkillTriggerRate
					if breakdown then
						breakdown.SkillTriggerRate = {
							s_format("%.2f ^8(%s)", output.EffectiveSourceRate, (actor.mainSkill.skillData.triggeredByBrand and s_format("%s activations per second", source.activeEffect.grantedEffect.name)) or (not trigRate and s_format("%s triggers per second", skillName)) or "Effective source rate"),
							s_format("/ %.2f ^8(Estimated impact of skill rotation, cooldown alignment and trigger chance)", m_max(output.EffectiveSourceRate / output.SkillTriggerRate, 1)),
							s_format("= %.2f ^8per second", output.SkillTriggerRate),
						}
						if triggerChance ~= 100 then
							t_insert(breakdown.SkillTriggerRate, 1, "")
							t_insert(breakdown.SkillTriggerRate, 1, s_format("= %.2f%% ^8(Effective chance to trigger)", triggerChance))
							for _, line in ipairs(triggerChanceBreakdown) do
								t_insert(breakdown.SkillTriggerRate, 1, line)
							end
							t_insert(breakdown.SkillTriggerRate, 1, "100% ^8(Base chance)")
						end
						if triggerBotsEffective then
							t_insert(breakdown.SkillTriggerRate, 3, "x 2 ^8(Trigger bots effectively cause the skill to trigger twice)")
						end
						if hits_per_cast > 1 then
							t_insert(breakdown.SkillTriggerRate, 3, s_format("x %.2f ^8(hits per triggered skill cast)", hits_per_cast))
						end
						if simBreakdown.extraSimInfo then
							t_insert(breakdown.SkillTriggerRate, "")
							t_insert(breakdown.SkillTriggerRate, simBreakdown.extraSimInfo)
						end
						breakdown.SimData = {
							rowList = { },
							colList = {
								{ label = "Rate", key = "rate" },
								{ label = "Skill Name", key = "skillName" },
								{ label = "Slot Name", key = "slotName" },
								{ label = "Gem Index", key = "gemIndex" },
							},
						}
						for _, rateData in ipairs(simBreakdown.rates) do
							local t = { }
							for str in string.gmatch(rateData.name, "([^_]+)") do
								t_insert(t, str)
							end

							local row = {
								rate = round(rateData.rate, 2),
								skillName = t[1],
								slotName = t[2],
								gemIndex = t[3],
							}
							t_insert(breakdown.SimData.rowList, row)
						end
						t_insert(breakdown.SimData, s_format("Simulation duration: %.2f ^8(In game source skill usage duration in seconds)", simBreakdown.simTime, simBreakdown.simTime))
					end
				end
			else
				if breakdown then
					breakdown.SkillTriggerRate = {
						s_format("The trigger needs to be triggered for any skill to be triggered."),
					}
				end
				output.SkillTriggerRate = 0
			end
			actor.mainSkill.skillData.triggerRate = output.SkillTriggerRate

			-- Account for Trigger-related INC/MORE modifiers
			output.Speed = actor.mainSkill.skillData.triggerRate
			addTriggerIncMoreMods(actor.mainSkill, source or actor.mainSkill)
			if source and source ~= actor.mainSkill then
				actor.mainSkill.skillData.triggerSourceUUID = cacheSkillUUID(source, env)
				actor.mainSkill.infoMessage = (config.customTriggerName or ((config.triggerName ~= source.activeEffect.grantedEffect.name and config.triggerName or triggeredName) .. ( actor == env.minion and "'s attack Trigger: " or "'s Trigger: "))) .. source.activeEffect.grantedEffect.name
			else
				actor.mainSkill.infoMessage = actor.mainSkill.triggeredBy and actor.mainSkill.triggeredBy.grantedEffect.name or config.triggerName .. " Trigger"
			end

			actor.mainSkill.infoTrigger = config.triggerName
		end
	end
end

local configTable = {
	["law of the wilds"] = function()
		return {
			triggerSkillCond = function(env, skill)
				return not skill.skillTypes[SkillType.SummonsTotem] and (skill.skillTypes[SkillType.Melee] or skill.skillTypes[SkillType.Attack]) and band(skill.skillCfg.flags, ModFlag.Claw) > 0
			end
		}
	end,
	["the rippling thoughts"] = function(env)
		if env.player.mainSkill.activeEffect.grantedEffect.name == "Storm Cascade" then
			return {
				triggerSkillCond = function(env, skill)
					return (skill.skillTypes[SkillType.Melee] or skill.skillTypes[SkillType.Attack])
				end
			}
		end
	end,
	["the surging thoughts"] = function(env)
		if env.player.mainSkill.activeEffect.grantedEffect.name == "Storm Cascade" then
			return {
				triggerSkillCond = function(env, skill)
					return (skill.skillTypes[SkillType.Melee] or skill.skillTypes[SkillType.Attack])
				end
			}
		end
	end,
	["the hidden blade"] = function(env)
        env.player.mainSkill.skillFlags.globalTrigger = true
		env.player.mainSkill.skillData.triggerRateCapOverride = 2
		if env.player.modDB:Flag(nil, "Condition:Phasing") then
			if env.player.breakdown then
				env.player.breakdown.TriggerRateCap = {
					s_format("%.2f ^8(Unseen Strike from The Hidden Blade has no cooldown but is still triggered)", env.player.mainSkill.skillData.triggerRateCapOverride),
					s_format("= %.2f", env.player.mainSkill.skillData.triggerRateCapOverride),
				}
			end
			return {source = env.player.mainSkill}
		end
		env.player.mainSkill.skillFlags.disable = true
		env.player.mainSkill.disableReason = "This skill is requires you to be phasing"
	end,
	["replica eternity shroud"] = function(env)
        env.player.mainSkill.skillFlags.globalTrigger = true
		return {source = env.player.mainSkill}
	end,
	["shroud of the lightless"] = function(env)
        env.player.mainSkill.skillFlags.globalTrigger = true
		return {source = env.player.mainSkill}
	end,
	["limbsplit"] = function()
		return {triggerName = "Gore Shockwave", triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Melee] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["the cauteriser"] = function()
		return {triggerName = "Gore Shockwave", triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Melee] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["duskblight"] = function()
		return {triggerName = "Stalking Pustule", triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["lioneye's paws"] = function(env)
		-- Due to the way the triggerExtraSkill function in mod parser works this trigger does not use the custom trigger skill (RainOfArrowsOnAttackingWithBow)
		-- the normal version is used here instead. The stats are the same but the normal version does not have cooldown.
		env.player.mainSkill.skillData.cooldown = 1
		return {triggerOnUse = true, triggerSkillCond = function(env, skill) return skill.skillTypes[SkillType.Attack] and band(skill.skillCfg.flags, ModFlag.Bow) > 0 end}
	end,
	["replica lioneye's paws"] = function(env)
		-- Due to the way the triggerExtraSkill function in mod parser works this trigger does not use the custom trigger skill (RainOfArrowsOnAttackingWithBow)
		-- the normal version is used here instead. The stats are the same but the normal version does not have cooldown.
		env.player.mainSkill.skillData.cooldown = 1
		return {triggerOnUse = true, triggerSkillCond = function(env, skill) return skill.skillTypes[SkillType.Attack] and band(skill.skillCfg.flags, ModFlag.Bow) > 0 end}
	end,
	["moonbender's wing"] = function(env)
		--Similar situation to "Replica Lioneye's Paws"
		env.player.mainSkill.skillData.cooldown = 1
		return {triggerName = "Lightning Warp", triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Melee] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["ngamahu's flame"] = function()
		return {triggerName = "Molten Burst", triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Melee] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["cameria's avarice"] = function()
		return {triggerName = "Icicle Burst", triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["uul-netol's embrace"] = function()
		return {triggerName = "Bone Nova", triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["rigwald's crest"] = function(env)
		env.player.mainSkill.skillData.sourceRateIsFinal = true
		return {assumingEveryHitKills = true, triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["jorrhast's blacksteel"] = function(env)
		env.player.mainSkill.skillData.sourceRateIsFinal = true
		return {assumingEveryHitKills = true, triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["ashcaller"] = function(env)
		env.player.mainSkill.skillData.sourceRateIsFinal = true
		return {assumingEveryHitKills = true, triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["arakaali's fang"] = function()
		return {assumingEveryHitKills = true, triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["sporeguard"] = function()
		return {assumingEveryHitKills = true, triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["mark of the elder"] = function()
		return {assumingEveryHitKills = true, triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["mark of the shaper"] = function()
		return {assumingEveryHitKills = true, triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["poet's pen"] = function()
		return {triggerOnUse = true,
				triggerSkillCond = function(env, skill)
					return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) and band(skill.skillCfg.flags, ModFlag.Wand) > 0
				end,
				triggeredSkillCond = function(env, skill)
					return skill.skillData.triggeredByUnique and env.player.mainSkill.socketGroup.slot == skill.socketGroup.slot and skill.skillTypes[SkillType.Spell]
				end}
	end,
	["maloney's mechanism"] = function(env)
		local _, _, uniqueTriggerName = env.player.itemList[env.player.mainSkill.slotName].modSource:find(".*:.*:(.*),.*")
		local isReplica = uniqueTriggerName:match("Replica.")
		return {triggerOnUse = true, triggerName = uniqueTriggerName, useCastRate = isReplica,
				triggerSkillCond = function(env, skill)
					local attack = skill.skillTypes[SkillType.Attack] and (band(skill.skillCfg.flags, ModFlag.Bow) > 0) and not isReplica
					local spell = skill.skillTypes[SkillType.Spell] and isReplica
					return (attack or spell)
				end,
				triggeredSkillCond = function(env, skill)
					return skill.skillData.triggeredByUnique and env.player.mainSkill.socketGroup.slot == skill.socketGroup.slot and skill.skillTypes[SkillType.RangedAttack]
				end}
	end,
	["asenath's chant"] = function()
		return {triggerOnUse = true,
				triggerSkillCond = function(env, skill)
					return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) and band(skill.skillCfg.flags, ModFlag.Bow) > 0
				end,
				triggeredSkillCond = function(env, skill)
					return skill.skillData.triggeredByUnique and env.player.mainSkill.socketGroup.slot == skill.socketGroup.slot and skill.skillTypes[SkillType.Spell]
				end}
	end,
	["vixen's entrapment"] = function()
		return {useCastRate = true,
				triggerSkillCond = function(env, skill)
					return skill.skillTypes[SkillType.Hex]
				end}
	end,
	["flames of judgement"] = function(env)
		env.player.mainSkill.skillData.sourceRateIsFinal = true
		return {triggerName = env.player.mainSkill.activeEffect.grantedEffect.name,
				triggerSkillCond = function(env, skill) return skill.activeEffect.grantedEffect.name == "Queen's Demand" end,
				triggeredSkillCond = function(env, skill) return skill.skillData.triggeredByUnique and env.player.mainSkill.socketGroup.slot == skill.socketGroup.slot end}
	end,
	["storm of judgement"] = function(env)
		env.player.mainSkill.skillData.sourceRateIsFinal = true
		return {triggerName = env.player.mainSkill.activeEffect.grantedEffect.name,
				triggerSkillCond = function(env, skill) return skill.activeEffect.grantedEffect.name == "Queen's Demand" end,
				triggeredSkillCond = function(env, skill) return skill.skillData.triggeredByUnique and env.player.mainSkill.socketGroup.slot == skill.socketGroup.slot end}
	end,
	["trigger craft"] = function(env)
		if env.player.mainSkill.skillData.triggeredByCraft then
			local trigRate, source, uuid, useCastRate, triggeredSkills
			triggeredSkills = {}
			for _, skill in ipairs(env.player.activeSkillList) do
				if (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack] or skill.skillTypes[SkillType.Spell]) and not skill.skillFlags.aura and skill ~= env.player.mainSkill and not skill.skillData.triggeredByCraft and not skill.activeEffect.grantedEffect.fromItem and not isTriggered(skill) then
					source, trigRate, uuid = findTriggerSkill(env, skill, source, trigRate)
					if skill.skillFlags and (skill.skillFlags.totem or skill.skillFlags.golem or skill.skillFlags.banner or skill.skillFlags.ballista) and skill.activeEffect.grantedEffect.castTime then
						if skill.activeEffect.grantedEffect.levels ~= nil then
							trigRate = 1 / (skill.activeEffect.grantedEffect.castTime + (skill.activeEffect.grantedEffect.levels[skill.activeEffect.level].cooldown or 0))
						else
							trigRate = 1 / skill.activeEffect.grantedEffect.castTime
						end
						useCastRate = true
					end
				end
				if skill.skillData.triggeredByCraft and env.player.mainSkill.socketGroup.slot == skill.socketGroup.slot then
					t_insert(triggeredSkills, packageSkillDataForSimulation(skill, env))
				end
			end
			return {trigRate = trigRate, source = source, uuid = uuid, useCastRate = useCastRate, triggeredSkills = triggeredSkills}
		end
	end,
	["kitava's thirst"] = function(env)
		local requiredManaCost = env.player.modDB:Sum("BASE", nil, "KitavaRequiredManaCost")
		return {triggerChance = env.player.modDB:Sum("BASE", nil, "KitavaTriggerChance"),
				triggerName = "Kitava's Thirst",
				comparer = function(env, uuid, source, triggerRate)
					local cachedSpeed = GlobalCache.cachedData[env.mode][uuid].HitSpeed or GlobalCache.cachedData[env.mode][uuid].Speed
					local cachedManaCost = GlobalCache.cachedData[env.mode][uuid].ManaCost
					return ( (not source and cachedSpeed) or (cachedSpeed and cachedSpeed > (triggerRate or 0)) ) and ( (cachedManaCost or 0) > requiredManaCost )
				end,
				triggerSkillCond = function(env, skill)
					return true
					-- Filtering done by skill() in SkillStatMap, comparer and default excludes
				end}
	end,
	["mjolner"] = function()
		return {triggerSkillCond = function(env, skill)
					return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) and band(skill.skillCfg.flags, bor(ModFlag.Mace, ModFlag.Weapon1H)) > 0 and not slotMatch(env, skill)
				end,
				triggeredSkillCond = function(env, skill)
					return skill.skillData.triggeredByMjolner and slotMatch(env, skill)
				end}
	end,
	["cospri's malice"] = function()
		return {triggerSkillCond = function(env, skill)
					return skill.skillTypes[SkillType.Melee] and band(skill.skillCfg.flags, bor(ModFlag.Sword, ModFlag.Weapon1H)) > 0
				end,
				triggeredSkillCond = function(env, skill) return skill.skillData.triggeredByCospris and env.player.mainSkill.socketGroup.slot == skill.socketGroup.slot end}
	end,
	["cast on critical strike"] = function()
		return {triggerSkillCond = function(env, skill) return skill.skillTypes[SkillType.Attack] and slotMatch(env, skill) end,
				triggeredSkillCond = function(env, skill) return skill.skillData.triggeredByCoc and slotMatch(env, skill) end}
	end,
	["cast on melee kill"] = function(env)
		if env.player.modDB:Flag(nil, "Condition:KilledRecently") then
			return {assumingEveryHitKills = true,
					triggerSkillCond = function(env, skill)
						return skill.skillTypes[SkillType.Attack] and skill.skillTypes[SkillType.Melee] and slotMatch(env, skill)
					end,
					triggeredSkillCond = function(env, skill) return skill.skillData.triggeredByMeleeKill and slotMatch(env, skill) end}
		else
			env.player.mainSkill.infoMessage2 = "DPS reported assuming Self-Cast"
			env.player.mainSkill.infoMessage = "Cast on Melee Kill requires recent kills"
		end
	end,
	["nova"] = function(env)
		if env.minion and env.minion.mainSkill then
			return {triggerName = "Summon Holy Relic",
				   actor = env.minion,
				   triggeredSkills = {{ uuid = cacheSkillUUID(env.minion.mainSkill, env), cd = env.minion.mainSkill.skillData.cooldown}},
				   triggerSkillCond = function(env, skill) return skill.skillTypes[SkillType.Attack] end}
		end
	end,
	["cast when damage taken"] = function(env)
		if env.player.mainSkill.skillData.triggeredByDamageTaken then
			local thresholdMod = calcLib.mod(env.player.mainSkill.skillModList, nil, "CWDTThreshold")
			env.player.output.CWDTThreshold = env.player.mainSkill.skillData.triggeredByDamageTaken * thresholdMod
			if env.player.breakdown and env.player.output.CWDTThreshold ~= env.player.mainSkill.skillData.triggeredByDamageTaken then
				env.player.breakdown.CWDTThreshold = {
					s_format("%.2f ^8(base threshold)", env.player.mainSkill.skillData.triggeredByDamageTaken),
					s_format("x %.2f ^8(threshold modifier)", thresholdMod),
					s_format("= %.2f", env.player.output.CWDTThreshold),
				}
			end
			env.player.mainSkill.skillFlags.globalTrigger = true
			return  {source = env.player.mainSkill}
		end
	end,
	["cast when stunned"] = function(env)
        env.player.mainSkill.skillFlags.globalTrigger = true
		return {triggerChance =  env.player.mainSkill.skillData.chanceToTriggerOnStun,
				source = env.player.mainSkill}
	end,
	["automation"] = function(env)
		if env.player.mainSkill.activeEffect.grantedEffect.name == "Automation" then
			-- This calculated the trigger rate of the Automation gem it self
			env.player.mainSkill.skillFlags.globalTrigger = true
			return {source = env.player.mainSkill}
		end
		env.player.mainSkill.skillData.sourceRateIsFinal = true

		-- Trigger rate of the triggered skill is capped by the cooldown of Automation
		-- which will likely be different from the cooldown of the triggered skill
		-- and is affected by different cooldown modifiers
		env.player.mainSkill.skillData.ignoresTickRate = true

		-- This basically does min(trigger rate of steelskin assuming no trigger cooldown, trigger rate of Automation)
		return {triggerOnUse = true,
				useCastRate = true,
				triggerSkillCond = function(env, skill)
					return skill.activeEffect.grantedEffect.name == "Automation"
				end}
	end,
	["spellslinger"] = function(env)
		if env.player.mainSkill.activeEffect.grantedEffect.name == "Spellslinger" then
			return {triggerName = "Spellslinger",
				triggerOnUse = true,
				triggerSkillCond = function(env, skill)
					local isWandAttack = (not skill.weaponTypes or (skill.weaponTypes and skill.weaponTypes["Wand"])) and skill.skillTypes[SkillType.Attack]
					return isWandAttack and not skill.skillData.triggeredBySpellSlinger
				end}
		end
		env.player.mainSkill.skillData.sourceRateIsFinal = true
		return {triggerOnUse = true,
				useCastRate = true,
				triggerSkillCond = function(env, skill)
					return skill.activeEffect.grantedEffect.name == "Spellslinger"
				end}
	end,
	["call to arms"] = function(env)
		if env.player.mainSkill.activeEffect.grantedEffect.name == "Call to Arms" then
			env.player.mainSkill.skillFlags.globalTrigger = true
			return {source = env.player.mainSkill}
		end
		env.player.mainSkill.skillData.sourceRateIsFinal = true
		env.player.mainSkill.skillData.ignoresTickRate = true
		return {triggerOnUse = true,
				useCastRate = true,
				triggerSkillCond = function(env, skill)
					return skill.activeEffect.grantedEffect.name == "Call to Arms"
				end}
	end,
	["autoexertion"] = function(env)
		if env.player.mainSkill.activeEffect.grantedEffect.name == "Autoexertion" then
			env.player.mainSkill.skillFlags.globalTrigger = true
			return {source = env.player.mainSkill}
		end
		env.player.mainSkill.skillData.sourceRateIsFinal = true
		env.player.mainSkill.skillData.ignoresTickRate = true
		return {triggerOnUse = true,
				useCastRate = true,
				triggerSkillCond = function(env, skill)
					return skill.activeEffect.grantedEffect.name == "Autoexertion"
				end}
	end,
	["mark on hit"] = function()
		return {triggerSkillCond = function(env, skill) return skill.skillTypes[SkillType.Attack] end}
	end,
	["hextouch"] = function(env)
		env.player.mainSkill.skillData.sourceRateIsFinal = true
		return {triggerSkillCond = function(env, skill)
					return skill.skillTypes[SkillType.Attack] and slotMatch(env, skill)
				end}
	end,
	["oskarm"] = function(env)
		env.player.mainSkill.skillData.sourceRateIsFinal = true
		return {triggerSkillCond = function(env, skill)
					return skill.skillTypes[SkillType.Attack]
				end}
	end,
	["tempest shield"] = function(env)
        env.player.mainSkill.skillFlags.globalTrigger = true
		return {source = env.player.mainSkill}
	end,
	["shattershard"] = function(env)
        env.player.mainSkill.skillFlags.globalTrigger = true
		local uuid = cacheSkillUUID(env.player.mainSkill, env)
		if not GlobalCache.cachedData[env.mode][uuid] or env.mode == "CALCULATOR" then
			calcs.buildActiveSkill(env, env.mode, env.player.mainSkill, uuid, {[uuid] = true})
		end
		env.player.mainSkill.skillData.triggerRateCapOverride = 1 / GlobalCache.cachedData[env.mode][uuid].Env.player.output.Duration
		if env.player.breakdown then
			env.player.breakdown.SkillTriggerRate = {
				s_format("Shattershard uses duration as pseudo cooldown"),
				s_format("1 / %.2f ^8(Shattershard duration)", GlobalCache.cachedData[env.mode][uuid].Env.player.output.Duration),
				s_format("= %.2f ^8per second", env.player.mainSkill.skillData.triggerRateCapOverride),
			}
		end
		return {source = env.player.mainSkill}
	end,
	["battlemage's cry"] = function(env)
		if env.player.mainSkill.activeEffect.grantedEffect.name ~= "Battlemage's Cry" then
			return {triggerSkillCond = function(env, skill)	return skill.skillTypes[SkillType.Melee] end,
					comparer = function(env, uuid, source, triggerRate)
						-- Skills with no uptime ratio are not exerted by battlemage so should not be considered.
						local uptimeRatio = GlobalCache.cachedData[env.mode][uuid].Env.player.output.BattlemageUpTimeRatio
						return defaultComparer(env, uuid, source, triggerRate) and uptimeRatio
					end,
					triggeredSkillCond = function(env, skill) return skill.skillData.triggeredByBattleMageCry and slotMatch(env, skill) end}
		end
	end,
	["arcanist brand"] = function(env)
		if env.player.mainSkill.activeEffect.grantedEffect.name ~= "Arcanist Brand" then
			env.player.mainSkill.skillData.sourceRateIsFinal = true
			for _, skill in ipairs(env.player.activeSkillList) do
				if skill.activeEffect.grantedEffect.name == "Arcanist Brand" then
					env.player.mainSkill.triggeredBy.mainSkill = skill
					break
				end
			end

			local activationFreqInc = (100 + env.player.mainSkill.triggeredBy.mainSkill.skillModList:Sum("INC", env.player.mainSkill.skillCfg, "Speed", "BrandActivationFrequency")) / 100
			local activationFreqMore = env.player.mainSkill.triggeredBy.mainSkill.skillModList:More(env.player.mainSkill.skillCfg, "BrandActivationFrequency")
			env.player.mainSkill.triggeredBy.activationFreqInc = activationFreqInc
			env.player.mainSkill.triggeredBy.activationFreqMore = activationFreqMore
			env.player.mainSkill.triggeredBy.ignoresTickRate = true
			return {trigRate = env.player.mainSkill.triggeredBy.mainSkill.skillData.repeatFrequency * activationFreqInc * activationFreqMore,
					source = env.player.mainSkill.triggeredBy.mainSkill,
					triggeredSkillCond = function(env, skill) return skill.skillData.triggeredByBrand and slotMatch(env, skill) end}
		end
	end,
	["cast on death"] = function(env)
        env.player.mainSkill.skillFlags.globalTrigger = true
		env.player.mainSkill.skillData.triggered = true
		env.player.mainSkill.infoMessage = env.player.mainSkill.activeEffect.grantedEffect.name .. " Triggered on Death"
	end,
	["combust"] = function(env)
		return {triggerSkillCond = function(env, skill)	return skill.skillTypes[SkillType.Melee] end,
				comparer = function(env, uuid, source, triggerRate)
					-- Skills with no uptime ratio are not exerted by infernal cry so should not be considered.
					local uptimeRatio = GlobalCache.cachedData[env.mode][uuid].Env.player.output.InfernalUpTimeRatio
					return defaultComparer(env, uuid, source, triggerRate) and uptimeRatio
				end,}
	end,
	["prismatic burst"] = function(env)
		return {triggerSkillCond = function(env, skill)	return skill.skillTypes[SkillType.Attack] and slotMatch(env, skill) end}
	end,
	["shockwave"] = function(env)
		return {triggerSkillCond = function(env, skill)	return skill.skillTypes[SkillType.Melee] and slotMatch(env, skill) end}
	end,
	["manaforged arrows"] = function(env)
		return {triggerOnUse = true,
				triggerName = "Manaforged Arrows",
				triggerSkillCond = function(env, skill)	return skill.skillTypes[SkillType.Attack] and band(skill.skillCfg.flags, ModFlag.Bow) > 0 end}
	end,
	["doom blast"] = function(env)
		if env.build.configTab.input["doomBlastSource"] == "replacement" then
			env.player.modDB:NewMod("UsesCurseOverlaps", "FLAG", true, "Config")
		end
		env.player.mainSkill.skillData.ignoresTickRate = true
		return {useCastRate = true,
				overlaps = #env.player.modDB:Tabulate("BASE", nil, "Multiplier:CurseOverlaps") > 0 and m_max(env.player.modDB:Sum("BASE", nil, "Multiplier:CurseOverlaps"), 1),
				customTriggerName = "Doom Blast triggering Hex: ",
				triggerSkillCond = function(env, skill) return skill.skillTypes[SkillType.Hex] and slotMatch(env, skill) end}
	end,
	["cast while channelling"] = function()
		return {customHandler = CWCHandler}
	end,
	["focus"] = function()
		return {customHandler = helmetFocusHandler}
	end,
	["supportmetacastoncritplayer"] = function()
		return {customHandler = metaEnergyTriggerHandler, triggerName = "Cast on Critical",
				eventsVar = "metaCoCEventsPerSecond", energyPerEventVar = "metaCoCEnergyPerEvent", energyPerEventStat = "MetaEnergyPerEvent",
				autoDetectCrit = true, powerScaled = true}
	end,
	["supportmetacastonelementalailmentplayer"] = function()
		-- Freeze/Shock/Ignite each add Energy at a different rate; metaCoEAAilmentType picks which one.
		-- Freeze/Shock auto-derive from a self-cast source's chance-per-hit; Ignite always needs the
		-- manual Energy-per-event override (see autoDetectAilmentInfo).
		return {customHandler = metaEnergyTriggerHandler, triggerName = "Cast on Elemental Ailment",
				eventsVar = "metaCoEAEventsPerSecond", energyPerEventVar = "metaCoEAEnergyPerEvent",
				ailmentTypeVar = "metaCoEAAilmentType", powerScaled = true}
	end,
	["supportmetacastondodgeplayer"] = function()
		return {customHandler = metaEnergyTriggerHandler, triggerName = "Cast on Dodge",
				eventsVar = "metaDodgeEventsPerSecond", energyPerEventVar = "metaDodgeEnergyPerEvent", energyPerEventStat = "MetaEnergyPerEvent"}
	end,
	["supportmetacastonminiondeathplayer"] = function()
		-- Constant is expressed as a divisor (1 Energy per X% minion relative defensiveness), not a
		-- centienergy value, so Stage 1 requires a manual Energy-per-event override.
		return {customHandler = metaEnergyTriggerHandler, triggerName = "Cast on Minion Death",
				eventsVar = "metaMinionDeathEventsPerSecond", energyPerEventVar = "metaMinionDeathEnergyPerEvent"}
	end,
	["supportmetacastonmeleekillplayer"] = function()
		return {customHandler = metaEnergyTriggerHandler, triggerName = "Cast on Melee Kill",
				eventsVar = "metaMeleeKillEventsPerSecond", energyPerEventVar = "metaMeleeKillEnergyPerEvent", energyPerEventStat = "MetaEnergyPerEvent",
				powerScaled = true}
	end,
	["supportmetacastonmeleestunplayer"] = function()
		-- Defaults to the (lower) Stun value; Heavy Stun can be modelled via the manual override.
		return {customHandler = metaEnergyTriggerHandler, triggerName = "Cast on Melee Stun",
				eventsVar = "metaMeleeStunEventsPerSecond", energyPerEventVar = "metaMeleeStunEnergyPerEvent", energyPerEventStat = "MetaEnergyPerEvent",
				powerScaled = true}
	end,
	["supportmetacastonblockplayer"] = function()
		return {customHandler = metaEnergyTriggerHandler, triggerName = "Cast on Block",
				eventsVar = "metaBlockEventsPerSecond", energyPerEventVar = "metaBlockEnergyPerEvent", energyPerEventStat = "MetaEnergyPerEvent"}
	end,
	["supportmetacastoncharmuseplayer"] = function()
		return {customHandler = metaEnergyTriggerHandler, triggerName = "Cast on Charm Use",
				eventsVar = "metaCharmUseEventsPerSecond", energyPerEventVar = "metaCharmUseEnergyPerEvent", energyPerEventStat = "MetaEnergyPerEvent"}
	end,
	-- Stage 5: not "Cast on X" gems by name, but identical Meta/Energy architecture (unique item or
	-- passive-tree granted instead of a standalone gem).
	["supportmetacastcurseonblockplayer"] = function()
		return {customHandler = metaEnergyTriggerHandler, triggerName = "Curse on Block",
				eventsVar = "metaCurseOnBlockEventsPerSecond", energyPerEventVar = "metaCurseOnBlockEnergyPerEvent", energyPerEventStat = "MetaEnergyPerEvent"}
	end,
	["supportmetacastlightningspellonhitplayer"] = function()
		return {customHandler = metaEnergyTriggerHandler, triggerName = "Thundergod's Wrath",
				eventsVar = "metaTGWEventsPerSecond", energyPerEventVar = "metaTGWEnergyPerEvent", energyPerEventStat = "MetaEnergyPerEvent",
				powerScaled = true, autoDetectHit = true}
	end,
	["supportmetacastfirespellonhitplayer"] = function()
		return {customHandler = metaEnergyTriggerHandler, triggerName = "Fire Spell on Melee Hit",
				eventsVar = "metaFSOMHEventsPerSecond", energyPerEventVar = "metaFSOMHEnergyPerEvent", energyPerEventStat = "MetaEnergyPerEvent",
				powerScaled = true, autoDetectHit = true}
	end,
	-- Stage 6 proof of concept: Invocation Meta skills discharge manually instead of auto-firing at
	-- maximum Energy, so they use metaInvocationTriggerHandler, not metaEnergyTriggerHandler.
	["supportbarrierinvocationplayer"] = function()
		return {customHandler = metaInvocationTriggerHandler, triggerName = "Barrier Invocation",
				generationRateVar = "metaBarrierInvocationESDamageTakenPerSecond", generationDivisorStat = "MetaEnergyPerESDamageTakenDivisor"}
	end,
	["supportreapersinvocationplayer"] = function()
		return {customHandler = metaInvocationTriggerHandler, triggerName = "Reaper's Invocation",
				generationRateVar = "metaReapersInvocationMeleeKillsPerSecond",
				generationEnergyPerEventStat = "MetaEnergyPerEvent", generationPowerScaled = true}
	end,
	["supportspellslingerplayer"] = function()
		return {customHandler = metaInvocationTriggerHandler, triggerName = "Spellslinger",
				generationRateVar = "metaSpellslingerCastsPerSecond", generationPerCastTimeStat = "MetaEnergyPerCastTimeSecond"}
	end,
	["supportelementalinvocationplayer"] = function()
		return {customHandler = metaInvocationTriggerHandler, triggerName = "Elemental Invocation",
				generationRateVar = "metaElementalInvocationEventsPerSecond",
				ailmentTypeVar = "metaElementalInvocationAilmentType"}
	end,
	["snipe"] = function(env)
		local snipeStages = m_min(env.player.modDB:Sum("BASE", nil, "Multiplier:SnipeStage"), env.player.modDB:Sum("BASE", nil, "Multiplier:SnipeStagesMax"))
		local snipeHitMulti = env.player.mainSkill.skillModList:Sum("BASE", env.player.mainSkill.skillCfg, "snipeHitMulti")
		local snipeAilmentMulti = env.player.mainSkill.skillModList:Sum("BASE", env.player.mainSkill.skillCfg, "snipeAilmentMulti")
		local triggeredSkills = {}

		for _, skill in ipairs(env.player.activeSkillList) do
			if skill.skillData.triggeredBySnipe and skill.socketGroup and skill.socketGroup.slot == env.player.mainSkill.socketGroup.slot then
				t_insert(triggeredSkills, skill)
			end
		end

		if env.player.mainSkill.activeEffect.grantedEffect.name == "Snipe" then
			if (env.limitedSkills and env.limitedSkills[cacheSkillUUID(env.player.mainSkill, env)]) then
				-- Snipe is being used by some other skill. In this case snipe does not get more damage mods
				snipeStages = 0
			else
				-- max(1, snipeStages) makes it behave consistently with other channeled ranged skills (scourge arrow)
				env.player.mainSkill.skillData.hitTimeMultiplier = m_max(1, snipeStages) - 0.5 --First stage takes 0.5x time to channel compared to subsequent stages
			end
			if #triggeredSkills < 1 then
				-- Snipe is being used as a standalone skill
				if snipeStages then
					env.player.mainSkill.skillModList:NewMod("Multiplier:SnipeStages", "BASE", snipeStages, "Snipe")
					env.player.mainSkill.skillModList:NewMod("Damage", "MORE", snipeHitMulti, "Snipe", ModFlag.Hit, 0, { type = "Multiplier", var = "SnipeStages" })
					env.player.mainSkill.skillModList:NewMod("Damage", "MORE", snipeAilmentMulti, "Snipe", ModFlag.Ailment, 0, { type = "Multiplier", var = "SnipeStages" })
				end
			else
				-- Snipe is being used as a trigger source, it triggers other skills but does no damage it self
				env.player.mainSkill.skillModList:NewMod("DealNoLightning", "FLAG", true, { type = "SkillName", skillName = "Snipe", includeTransfigured = true })
				env.player.mainSkill.skillModList:NewMod("DealNoCold", "FLAG", true, { type = "SkillName", skillName = "Snipe", includeTransfigured = true })
				env.player.mainSkill.skillModList:NewMod("DealNoFire", "FLAG", true, { type = "SkillName", skillName = "Snipe", includeTransfigured = true })
				env.player.mainSkill.skillModList:NewMod("DealNoChaos", "FLAG", true, { type = "SkillName", skillName = "Snipe", includeTransfigured = true })
				env.player.mainSkill.skillModList:NewMod("DealNoPhysical", "FLAG", true, { type = "SkillName", skillName = "Snipe", includeTransfigured = true })
			end
		else
			local currentSkillSnipeIndex
			for index, skill in ipairs(triggeredSkills) do
				if skill == env.player.mainSkill then
					currentSkillSnipeIndex = index
					break
				end
			end

			-- Does snipe have enough stages to trigger this skill?
			if currentSkillSnipeIndex and currentSkillSnipeIndex <= snipeStages then
				local source
				local trigRate
				env.player.mainSkill.skillModList:NewMod("Multiplier:SnipeStages", "BASE", snipeStages, "Snipe")
				env.player.mainSkill.skillModList:NewMod("Damage", "MORE", snipeAilmentMulti, "Snipe", ModFlag.Ailment, 0, { type = "Multiplier", var = "SnipeStages" })
				env.player.mainSkill.skillModList:NewMod("Damage", "MORE", snipeHitMulti, "Snipe", ModFlag.Hit, 0, { type = "Multiplier", var = "SnipeStages" })
				for _, skill in ipairs(env.player.activeSkillList) do
					if skill.activeEffect.grantedEffect.name == "Snipe" and skill.socketGroup and skill.socketGroup.slot == env.player.mainSkill.socketGroup.slot then
						skill.skillData.hitTimeMultiplier = snipeStages - 0.5
						local uuid = cacheSkillUUID(skill, env)
						if not GlobalCache.cachedData[env.mode][uuid] or env.mode == "CALCULATOR" then
							calcs.buildActiveSkill(env, env.mode, skill, uuid)
						end
						local cachedSpeed = GlobalCache.cachedData[env.mode][uuid].Env.player.output.HitSpeed
						if (skill.skillFlags and not skill.skillFlags.disable) and (skill.skillCfg and not skill.skillCfg.skillCond["usedByMirage"]) and not skill.skillTypes[SkillType.OtherThingUsesSkill] and ((not source and cachedSpeed) or (cachedSpeed and cachedSpeed > (trigRate or 0))) then
							trigRate = cachedSpeed
							env.player.output.ChannelTimeToTrigger = GlobalCache.cachedData[env.mode][uuid].Env.player.output.HitTime
							source = skill
						end
					end
				end

				return {trigRate = trigRate, source = source}
			else
				env.player.mainSkill.skillData.triggered = nil
				env.player.mainSkill.infoMessage2 = "DPS reported assuming Self-Cast"
				env.player.mainSkill.infoMessage = "Not enough Snipe stages to trigger this skill"
				env.player.mainSkill.infoTrigger = ""
			end
		end
	end,
	["avenging flame"]  = function(env)
		return {triggerSkillCond = function(env, skill) return skill.skillFlags.totem and slotMatch(env, skill) end,
				comparer = function(env, uuid, source, currentTotemLife)
					local totemLife = GlobalCache.cachedData[env.mode][uuid].Env.player.output.TotemLife
					return (not source and totemLife) or (totemLife and totemLife > (currentTotemLife or 0))
				end,
				ignoreSourceRate = true}
	end,
	["intuitive link"] = function(env)
		if env.player.mainSkill.activeEffect.grantedEffect.name ~= "Intuitive Link" then
			for _, skill in ipairs(env.player.activeSkillList) do
				if skill.activeEffect.grantedEffect.name == "Intuitive Link" then
					env.player.mainSkill.triggeredBy.mainSkill = skill
					break
				end
			end
			return {triggeredSkillCond = function(env, skill) return skill.skillTypes[SkillType.Spell] and slotMatch(env, skill) and skill ~= env.player.mainSkill.triggeredBy.mainSkill end,
					trigRate = env.modDB:Sum("BASE", nil, "IntuitiveLinkSourceRate"),
					source = env.player.mainSkill.triggeredBy.mainSkill,
					sourceName = "Custom source",
					useCastRate = true}
		end
	end,
	["supporttriggerelementalspellonblock"] = function(env) -- Svalinn Girded Tower Shield
		env.player.mainSkill.skillFlags.globalTrigger = true
		return {source = env.player.mainSkill,
				triggeredSkillCond = function(env, skill)
					return slotMatch(env, skill) and skill.triggeredBy and calcLib.canGrantedEffectSupportActiveSkill(skill.triggeredBy.grantedEffect, skill)
				end}
	end,
	["supporttriggerfirespellonhit"] = function(env)
		return {triggerSkillCond = function(env, skill)
					-- Skill is triggered only when the weapon with the enchant on it hits
					return skill.skillTypes[SkillType.Melee]
				end,
				triggeredSkillCond = function(env, skill)
					return skill.skillData.triggeredBySettlersEnchantTrigger and slotMatch(env, skill)
				end}
	end,
}

-- Find unique item trigger name
local function getUniqueItemTriggerName(skill)
	if skill.skillData.triggerSource then
		return skill.skillData.triggerSource
	elseif skill.supportList and #skill.supportList >= 1 then
		for _, gemInstance in ipairs(skill.supportList) do
			if gemInstance.grantedEffect and gemInstance.grantedEffect.fromItem and not gemInstance.grantedEffect.support then
				return gemInstance.grantedEffect.name
			end
		end
	end

	if skill.socketGroup and skill.socketGroup.source then
		local _, _, uniqueTriggerName = skill.socketGroup.source:find(".*:.*:(.*),.*")
		return uniqueTriggerName
	end
end

local metaEnergySupportNames = {
	["supportmetacastoncritplayer"] = true,
	["supportmetacastonelementalailmentplayer"] = true,
	["supportmetacastondodgeplayer"] = true,
	["supportmetacastonminiondeathplayer"] = true,
	["supportmetacastonmeleekillplayer"] = true,
	["supportmetacastonmeleestunplayer"] = true,
	["supportmetacastonblockplayer"] = true,
	["supportmetacastoncharmuseplayer"] = true,
	["supportmetacastcurseonblockplayer"] = true,
	["supportmetacastlightningspellonhitplayer"] = true,
	["supportmetacastfirespellonhitplayer"] = true,
	["supportbarrierinvocationplayer"] = true,
	["supportreapersinvocationplayer"] = true,
	["supportspellslingerplayer"] = true,
	["supportelementalinvocationplayer"] = true,
}

-- calcs.triggers(env, env.player) is currently disabled globally in CalcPerform.lua ("TURNING OFF
-- CALC TRIGGERS AND MIRAGES FOR TIME BEING", since the stat-set skill data migration) because most
-- legacy PoE1-style trigger handlers haven't been re-verified against the new format. This lets
-- CalcPerform.lua narrowly re-enable calcs.triggers just for Meta gem (Cast on X) skills, without
-- resurrecting every other (still-unverified) trigger type for the player.
function calcs.isMetaEnergyTriggerSkill(actor)
	local skill = actor and actor.mainSkill
	local triggerName = skill and skill.triggeredBy and skill.triggeredBy.grantedEffect.name
	return triggerName ~= nil and metaEnergySupportNames[triggerName:lower()] or false
end

function calcs.triggers(env, actor)
	local skillFlags
	if env.mode == "CALCS" then
		skillFlags = actor.mainSkill.activeEffect.statSetCalcs.skillFlags
	else
		skillFlags = actor.mainSkill.activeEffect.statSet.skillFlags
	end
	if actor and not skillFlags.disable and not (env.limitedSkills and env.limitedSkills[cacheSkillUUID(actor.mainSkill, env)]) then
		local skillName = actor.mainSkill.activeEffect.grantedEffect.name
		local triggerName = actor.mainSkill.triggeredBy and actor.mainSkill.triggeredBy.grantedEffect.name
		local uniqueName = isTriggered(actor.mainSkill) and getUniqueItemTriggerName(actor.mainSkill)
		local skillNameLower = skillName and skillName:lower()
		local triggerNameLower = triggerName and triggerName:lower()
		local awakenedTriggerNameLower = triggerNameLower and triggerNameLower:gsub("^awakened ", "")
		local uniqueNameLower = uniqueName and uniqueName:lower()
		local config = skillNameLower and configTable[skillNameLower] and configTable[skillNameLower](env)
        config = config or triggerNameLower and configTable[triggerNameLower] and configTable[triggerNameLower](env)
        config = config or awakenedTriggerNameLower and configTable[awakenedTriggerNameLower] and configTable[awakenedTriggerNameLower](env)
        config = config or uniqueNameLower and configTable[uniqueNameLower] and configTable[uniqueNameLower](env)
		if config then
		    config.actor = config.actor or actor
			config.triggerName = config.triggerName or triggerName or skillName or uniqueName
			config.triggerChance = config.triggerChance or (actor.mainSkill.activeEffect.srcInstance and actor.mainSkill.activeEffect.srcInstance.triggerChance)
			local triggerHandler = config.customHandler or defaultTriggerHandler
		    triggerHandler(env, config)
		else
			actor.mainSkill.skillData.triggered = nil
        end
	end
end
