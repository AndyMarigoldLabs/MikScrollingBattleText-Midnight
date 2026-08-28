-------------------------------------------------------------------------------
-- Title: Mik's Scrolling Battle Text Parser
-- Author: Mikord
-------------------------------------------------------------------------------

-- Create module and set its name.
local module = {}
local moduleName = "Parser"
MikSBT[moduleName] = module


-------------------------------------------------------------------------------
-- Imports.
-------------------------------------------------------------------------------

-- Local references to various functions for faster access.
local string_find = string.find
local string_gmatch = string.gmatch
local string_gsub = string.gsub
local string_len = string.len
local bit = bit or bit32 -- 12.x compat: fall back to bit32 if the legacy bit library is gone.
local bit_band = bit.band
local bit_bor = bit.bor
local GetTime = GetTime
local UnitClass = UnitClass
local UnitGUID = UnitGUID
local UnitName = UnitName
local Print = MikSBT.Print
local EraseTable = MikSBT.EraseTable
local MSBTGetSpellInfo = MikSBT.MSBTGetSpellInfo


-------------------------------------------------------------------------------
-- Constants.
-------------------------------------------------------------------------------

-- Bit flags.
local AFFILIATION_MINE		= 0x00000001
local AFFILIATION_PARTY		= 0x00000002
local AFFILIATION_RAID		= 0x00000004
local AFFILIATION_OUTSIDER	= 0x00000008
local REACTION_FRIENDLY		= 0x00000010
local REACTION_NEUTRAL		= 0x00000020
local REACTION_HOSTILE		= 0x00000040
local CONTROL_HUMAN			= 0x00000100
local CONTROL_SERVER		= 0x00000200
local UNITTYPE_PLAYER		= 0x00000400
local UNITTYPE_NPC			= 0x00000800
local UNITTYPE_PET			= 0x00001000
local UNITTYPE_GUARDIAN		= 0x00002000
local UNITTYPE_OBJECT		= 0x00004000
local TARGET_TARGET			= 0x00010000
local TARGET_FOCUS			= 0x00020000
local OBJECT_NONE			= 0x80000000

-- Value when there is no GUID.
local GUID_NONE				= "0x0000000000000000"

-- Aura types.
local AURA_TYPE_BUFF = "BUFF"
local AURA_TYPE_DEBUFF = "DEBUFF"

-- Update timings.
local UNIT_MAP_UPDATE_DELAY = 0.2
local PET_UPDATE_DELAY = 1
local CLASS_HOLD_TIME = 300

-- Cast correlation for the Midnight 12.x UNIT_COMBAT feed.
local CAST_CORRELATION_WINDOW = 1.2
local MAX_RECENT_CASTS = 10

-- Long-duration ground effects (seconds) whose ticks outlive the correlation window.
local PERSISTENT_SPELLS = {
	[73920]  = 12, -- Shaman: Healing Rain / Acid Rain
	[265046] = 12, -- Shaman: Earthen Wall Totem
	[190356] = 8,  -- Mage: Blizzard
	[2120]   = 8,  -- Mage: Flamestrike
	[26573]  = 10, -- Paladin: Consecration
	[145205] = 10, -- Druid: Efflorescence
	[43265]  = 10, -- DK: Death and Decay
	[5740]   = 8,  -- Warlock: Rain of Fire
}

-- Synthesized recipient flags for killing blows (based on the victim's GUID prefix).
local FLAGS_KILL_PLAYER	= bit_bor(REACTION_HOSTILE, CONTROL_HUMAN, UNITTYPE_PLAYER)
local FLAGS_KILL_NPC	= bit_bor(REACTION_HOSTILE, CONTROL_SERVER, UNITTYPE_NPC)

-- Commonly used flag combinations.
local FLAGS_ME			= bit_bor(AFFILIATION_MINE, REACTION_FRIENDLY, CONTROL_HUMAN, UNITTYPE_PLAYER)


-------------------------------------------------------------------------------
-- Private variables.
-------------------------------------------------------------------------------

-- Prevent tainting global _.
local _

-- Dynamically created frames for receiving events and tooltip info.
local eventFrame

-- Name and GUID of the player.
local playerName
local playerGUID

-- Used for timing between updates.
local lastUnitMapUpdate = 0
local lastPetMapUpdate = 0

-- Whether or not values that need to be updated after a delay are stale.
local isUnitMapStale
local isPetMapStale

-- GUIDs of current group members and their pets (used to age the class map).
local rosterGUIDs = {}
local rosterPetGUIDs = {}

-- Information about global strings for CHAT_MSG_X events.
local searchMap
local searchCaptureFuncs
local rareWords = {}
local searchPatterns = {}
local captureOrders = {}

-- Captured and parsed event data.
local captureTable = {}
local parserEvent = {}

-- List of functions to call when an event occurs.
local handlers = {}

-- Recent player/pet casts for UNIT_COMBAT spell correlation (Midnight 12.x feed).
local recentCasts = {}

-- Currently active ground effects (spellID -> {name, expires}).
local activeGroundEffects = {}

-- UNIT_COMBAT actions that map to miss events.
local missActions = {
	MISS = true, DODGE = true, PARRY = true, BLOCK = true, RESIST = true,
	ABSORB = true, EVADE = true, IMMUNE = true, DEFLECT = true, REFLECT = true,
}

-- COMBAT_TEXT_UPDATE power tokens mapped to power types.
local ctuPowerTypes = {
	MANA = Enum.PowerType.Mana, RAGE = Enum.PowerType.Rage, FOCUS = Enum.PowerType.Focus,
	ENERGY = Enum.PowerType.Energy, RUNIC_POWER = Enum.PowerType.RunicPower,
	DEMONIC_FURY = Enum.PowerType.DemonicFury, HOLY_POWER = Enum.PowerType.HolyPower,
	SOUL_SHARDS = Enum.PowerType.SoulShards, CHI = Enum.PowerType.Chi,
	COMBO_POINTS = Enum.PowerType.ComboPoints, ARCANE_CHARGES = Enum.PowerType.ArcaneCharges,
	ALTERNATE_POWER = Enum.PowerType.Alternate,
}

-- Holds information about guid to class mappings for known units.
local classMapCleanupTime = 0
local classMap = {}
local classTimes = {}
local arenaUnits = {}


-------------------------------------------------------------------------------
-- Utility functions.
-------------------------------------------------------------------------------

-- ****************************************************************************
-- Registers a function to be called when an event occurs.
-- ****************************************************************************
local function RegisterHandler(handler)
	handlers[handler] = true
end

-- ****************************************************************************
-- Unregisters a previously registered function.
-- ****************************************************************************
local function UnregisterHandler(handler)
	handlers[handler] = nil
end


-- ****************************************************************************
-- Tests if any of the bits in the passed testFlags are set in the unit flags.
-- ****************************************************************************
local function TestFlagsAny(unitFlags, testFlags)
	if (bit_band(unitFlags, testFlags) > 0) then return true end
end


-- ****************************************************************************
-- Tests if all of the passed testFlags are set in the unit flags.
-- ****************************************************************************
local function TestFlagsAll(unitFlags, testFlags)
	if (bit_band(unitFlags, testFlags) == testFlags) then return true end
end


-- ****************************************************************************
-- Sends the parser event to the registered handlers.
-- ****************************************************************************
local function SendParserEvent()
	-- Add percentage calculation for outgoing damage events
	if parserEvent.eventType == "damage" and parserEvent.sourceUnit == "player" and parserEvent.amount and not issecretvalue(parserEvent.amount) then
		if UnitExists("target") then
			local targetMaxHealth = UnitHealthMax("target")
			-- Midnight 12.x: enemy health may be a secret value; comparisons on it error.
			if targetMaxHealth and not issecretvalue(targetMaxHealth) and targetMaxHealth > 0 then
				local percentage = (parserEvent.amount / targetMaxHealth) * 100
				if percentage >= 0.1 then -- Only show if >= 0.1%
					local roundedPercentage = math.floor(percentage * 10) / 10
					-- Store the percentage in the parser event for MSBT to use
					parserEvent.damagePercentage = roundedPercentage
				end
			end
		end
	end
	
	for handler in pairs(handlers) do
		local success, ret = pcall(handler, parserEvent)
		if not success then
			geterrorhandler()(ret)
		end
	end
end


-- ****************************************************************************
-- Compares two global strings so the most specific one comes first. This
-- prevents incorrectly capturing information for certain events.
-- ****************************************************************************
local function GlobalStringCompareFunc(globalStringNameOne, globalStringNameTwo)
	-- Get the global string for the passed names.
	local globalStringOne = _G[globalStringNameOne]
	local globalStringTwo = _G[globalStringNameTwo]

	local gsOneStripped = string_gsub(globalStringOne, "%%%d?%$?[sd]", "")
	local gsTwoStripped = string_gsub(globalStringTwo, "%%%d?%$?[sd]", "")

	-- Check if the stripped global strings are the same length.
	if (string_len(gsOneStripped) == string_len(gsTwoStripped)) then
		-- Count the number of captures in each string.
		local numCapturesOne = 0
		for _ in string_gmatch(globalStringOne, "%%%d?%$?[sd]") do
			numCapturesOne = numCapturesOne + 1
		end

		local numCapturesTwo = 0
		for _ in string_gmatch(globalStringTwo, "%%%d?%$?[sd]") do
			numCapturesTwo = numCapturesTwo + 1
		end

		-- Return the global string with the least captures.
		return numCapturesOne < numCapturesTwo

	else
		-- Return the longest global string.
		return string_len(gsOneStripped) > string_len(gsTwoStripped)
	end
end


-- ****************************************************************************
-- Converts the passed global string into a lua search pattern with a capture
-- order table and stores the results so any requests to convert the same
-- global string will just return the cached one.
-- ****************************************************************************
local function ConvertGlobalString(globalStringName)
	-- Don't do anything if the passed global string does not exist.
	local globalString = _G[globalStringName]
	if (globalString == nil) then return end

	-- Return the cached conversion if it has already been converted.
	if (searchPatterns[globalStringName]) then
		return searchPatterns[globalStringName], captureOrders[globalStringName]
	end

	-- Hold the capture order.
	local captureOrder
	local numCaptures = 0

	-- Escape lua magic chars.
	local searchPattern = string.gsub(globalString, "([%^%(%)%.%[%]%*%+%-%?])", "%%%1")

	-- Loop through each capture and setup the capture order.
	for captureIndex in string_gmatch(searchPattern, "%%(%d)%$[sd]") do
		if (not captureOrder) then captureOrder = {} end
		numCaptures = numCaptures + 1
		captureOrder[tonumber(captureIndex)] = numCaptures
	end

	-- Convert %1$s / %s to (.+) and %1$d / %d to (%d+).
	searchPattern = string.gsub(searchPattern, "%%%d?%$?s", "(.+)")
	searchPattern = string.gsub(searchPattern, "%%%d?%$?d", "(%%d+)")

	-- Escape any remaining $ chars.
	searchPattern = string.gsub(searchPattern, "%$", "%%$")

	-- Cache the converted pattern and capture order.
	searchPatterns[globalStringName] = searchPattern
	captureOrders[globalStringName] = captureOrder

	-- Return the converted global string.
	return searchPattern, captureOrder
end


-- ****************************************************************************
-- Fills in the capture table with the captured data if a match is found.
-- ****************************************************************************
local function CaptureData(matchStart, matchEnd, c1, c2, c3, c4, c5, c6, c7, c8, c9)
	-- Check if a match was found.
	if (matchStart) then
		captureTable[1] = c1
		captureTable[2] = c2
		captureTable[3] = c3
		captureTable[4] = c4
		captureTable[5] = c5
		captureTable[6] = c6
		captureTable[7] = c7
		captureTable[8] = c8
		captureTable[9] = c9

		-- Return the last position of the match.
		return matchEnd
	end

	-- Don't return anything since no match was found.
	return nil
end


-- ****************************************************************************
-- Reorders the capture table according to the passed capture order.
-- ****************************************************************************
local function ReorderCaptures(capOrder)
	local t, o = captureTable, capOrder

	t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8], t[9] =
	t[o[1] or 1], t[o[2] or 2], t[o[3] or 3], t[o[4] or 4], t[o[5] or 5],
	t[o[6] or 6], t[o[7] or 7], t[o[8] or 8], t[o[9] or 9]
end


-- ****************************************************************************
-- Parses the CHAT_MSG_X search style events.
-- ****************************************************************************
local function ParseSearchMessage(event, combatMessage)
	-- Leave if there is no map of global strings to search for the event.
	if (not searchMap[event]) then return end

	-- Chat messages are secret in instances (Midnight 12.x); they can't be pattern matched then.
	if (not combatMessage or issecretvalue(combatMessage)) then return end

	-- Loop through all of the global strings to search for the event.
	for _, globalStringName in pairs(searchMap[event]) do
		-- Make sure the capture func for the global string exists.
		local captureFunc = searchCaptureFuncs[globalStringName]
		if (captureFunc) then
			-- First, check if there is a rare word for the global string and it is in the combat
			-- message since a plain text search is faster than doing a full regular expression search.
			if (not rareWords[globalStringName] or string_find(combatMessage, rareWords[globalStringName], 1, true)) then
				-- Get capture data.
				local matchEnd = CaptureData(string_find(combatMessage, searchPatterns[globalStringName]))


				-- Check if a match was found.
				if (matchEnd) then
					-- Check if there is a capture order for the global string and reorder the data accordingly.
					if (captureOrders[globalStringName]) then ReorderCaptures(captureOrders[globalStringName]) end

					-- Erase the parser event table..
					for key in pairs(parserEvent) do parserEvent[key] = nil end

					-- Populate fields that exist for all events.
					parserEvent.sourceGUID = GUID_NONE
					parserEvent.sourceFlags = OBJECT_NONE
					parserEvent.recipientGUID = playerGUID
					parserEvent.recipientName = playerName
					parserEvent.recipientFlags = FLAGS_ME
					parserEvent.recipientUnit = "player"

					-- Map the captured arguments into the parser event table.
					captureFunc(parserEvent, captureTable)

					-- Send the event.
					SendParserEvent()
					return
				end -- Match found.
			end -- Fast plain search.
		end -- Capture func is valid.
	end -- Loop through global strings to search.
end


-- ****************************************************************************
-- Midnight 12.x data feeds.
-- The combat log was removed in 12.0. These translators rebuild the normalized
-- parserEvent table from the sanctioned feeds: UNIT_COMBAT (amounts),
-- UNIT_SPELLCAST_SUCCEEDED (spell correlation), COMBAT_TEXT_UPDATE (typed
-- player events) and PARTY_KILL (killing blows). Values arriving from the game
-- may be secret in restricted content: never compare, measure, index by, or do
-- arithmetic on them — only store, pass, concatenate, or string.format them.
-- ****************************************************************************

-- ****************************************************************************
-- Tracks recent player/pet spell casts so UNIT_COMBAT amounts can be
-- correlated back to the spell that caused them.
-- ****************************************************************************
local function TrackSpellCast(unitID, castGUID, spellID)
	-- Only the player's and pet's casts are correlated.
	if (unitID ~= "player" and unitID ~= "pet") then return end

	-- Spell IDs can be secret in restricted content; nothing can be done with them then.
	if (not spellID or issecretvalue(spellID)) then return end

	local spellName, _, spellIcon = MSBTGetSpellInfo(spellID)
	if (not spellName) then return end

	-- Casts that can't produce combat events (mounts, shapeshifts, summons) would only
	-- misattribute later ticks; clear the buffer instead of recording them.
	-- (English name matching only — worst case elsewhere is a useless buffer entry.)
	local lowerName = string.lower(spellName)
	if (string_find(lowerName, "mount") or string_find(lowerName, "form") or string_find(lowerName, "travel") or string_find(lowerName, "flight") or string_find(lowerName, "summon") or spellID == 150544) then
		EraseTable(recentCasts)
		return
	end

	-- Track long-duration ground effects separately; their ticks outlive the window.
	if (PERSISTENT_SPELLS[spellID]) then
		activeGroundEffects[spellID] = {name = spellName, expires = GetTime() + PERSISTENT_SPELLS[spellID]}
	end

	recentCasts[#recentCasts+1] = {time = GetTime(), spellID = spellID, spellName = spellName, spellIcon = spellIcon}
	if (#recentCasts > MAX_RECENT_CASTS) then table.remove(recentCasts, 1) end
end


-- ****************************************************************************
-- Returns the spell data for the most recent cast within the correlation window.
-- ****************************************************************************
local function CorrelateCast()
	local now = GetTime()
	for i = #recentCasts, 1, -1 do
		local cast = recentCasts[i]
		if (now - cast.time > CAST_CORRELATION_WINDOW) then break end
		return cast.spellID, cast.spellName, cast.spellIcon
	end

	-- Ground effects (Consecration, Healing Rain, ...) tick long after the cast.
	for spellID, effect in pairs(activeGroundEffects) do
		if (now <= effect.expires) then return spellID, effect.name end
		activeGroundEffects[spellID] = nil
	end
end


-- ****************************************************************************
-- Returns the name of a unit unless it's a secret value (restricted content).
-- ****************************************************************************
local function SafeUnitName(unitID)
	local name = UnitName(unitID)
	if (name and not issecretvalue(name)) then return name end
end


-- ****************************************************************************
-- Checks one aura index on a unit; pcalled by FindPlayerAuraName since aura
-- data access can error when auras are secret (Midnight 12.x).
-- ****************************************************************************
local function CheckAuraIndex(unitID, index, filter)
	local aura = C_UnitAuras.GetAuraDataByIndex(unitID, index, filter)
	if (not aura) then return "end" end

	-- isFromPlayerOrPlayerPet is explicitly non-secret (12.0.5+).
	if (aura.isFromPlayerOrPlayerPet == true) then
		local name = aura.name
		if (name and not issecretvalue(name)) then return "found", name end
	end
	return "skip"
end


-- ****************************************************************************
-- Returns the name of the first player-sourced aura of the given filter on the
-- unit, or nil when aura data is secret/unavailable. Used to name periodic
-- ticks, which carry no spell reference on the Midnight 12.x feeds. Heuristic:
-- the first player-sourced aura may not be the one actually ticking.
-- ****************************************************************************
local function FindPlayerAuraName(unitID, filter)
	if (not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex) then return end
	for i = 1, 40 do
		local ok, state, name = pcall(CheckAuraIndex, unitID, i, filter)
		if (not ok or state == "end") then break end
		if (state == "found") then return name end
	end
end


-- ****************************************************************************
-- Parses UNIT_COMBAT events (damage, misses). UNIT_COMBAT reports what happened
-- to a unit (the victim), not who caused it: wounds on units other than the
-- player/pet are attributed to the player, which is approximate when others
-- attack the same unit. Heals on the player come through COMBAT_TEXT_UPDATE.
-- ****************************************************************************
local function ParseUnitCombat(unitTarget, action, flagText, amount, schoolMask)
	-- The action identifies the event family; nothing can be done if it's secret.
	if (not action or issecretvalue(action)) then return end

	-- Only wounds and miss-family actions map onto MSBT events.
	local isWound = (action == "WOUND")
	if (not isWound and not missActions[action]) then return end

	-- Amounts can be secret in restricted content; never compare or do math on them here.
	if (amount ~= nil and not issecretvalue(amount) and isWound and amount == 0) then return end

	-- Figure out the direction from the affected unit.
	local sourceUnit, recipientUnit, recipientFlags
	if (unitTarget == "player") then
		recipientUnit = "player"
		recipientFlags = FLAGS_ME
	elseif (unitTarget == "pet") then
		recipientUnit = "pet"
		recipientFlags = OBJECT_NONE
	else
		-- Wounds/misses on another unit are treated as outgoing.
		sourceUnit = "player"
		recipientFlags = OBJECT_NONE
	end

	-- Erase the parser event table.
	for k in pairs(parserEvent) do parserEvent[k] = nil end

	-- Populate fields that exist for all events. The attacker is unknown on this feed.
	parserEvent.sourceUnit = sourceUnit
	parserEvent.sourceGUID = GUID_NONE
	parserEvent.sourceFlags = OBJECT_NONE
	parserEvent.recipientUnit = recipientUnit
	parserEvent.recipientFlags = recipientFlags

	-- The affected unit's identity can be secret in restricted content.
	local recipientName = SafeUnitName(unitTarget)
	parserEvent.recipientName = recipientName or UNKNOWN

	-- Map the unit's class for name coloring when it's knowable.
	if (recipientName and unitTarget ~= "player" and unitTarget ~= "pet") then
		local guid = UnitGUID(unitTarget)
		if (guid and not issecretvalue(guid) and not classMap[guid]) then
			local _, class = UnitClass(unitTarget)
			if (class and not issecretvalue(class)) then classMap[guid] = class end
		end
	end

	-- Crit / glancing / crushing flags. flagText can be compound (e.g. critical
	-- blocks), so match by substring like prior art does.
	if (flagText and not issecretvalue(flagText)) then
		if (string_find(flagText, "CRITICAL")) then parserEvent.isCrit = true end
		if (string_find(flagText, "GLANCING")) then parserEvent.isGlancing = true end
		if (string_find(flagText, "CRUSHING")) then parserEvent.isCrushing = true end
	end

	-- Damage school for coloring (same numeric domain as the old combat log school mask).
	if (schoolMask and not issecretvalue(schoolMask)) then parserEvent.damageType = schoolMask end

	if (not isWound) then
		parserEvent.eventType = "miss"
		parserEvent.missType = action
	else
		parserEvent.eventType = "damage"
		parserEvent.amount = amount

		-- Correlate outgoing damage to the spell that caused it, if there is one.
		if (sourceUnit) then
			local spellID, spellName = CorrelateCast()
			if (not spellName) then
				-- Periodic ticks carry no cast reference; name them from the victim's auras.
				spellName = FindPlayerAuraName(unitTarget, "HARMFUL")
				if (spellName) then parserEvent.isDoT = true end
			end
			if (spellID) then parserEvent.skillID = spellID end
			if (spellName) then parserEvent.skillName = spellName end
		end
	end

	-- Send the event.
	SendParserEvent()
end


-- ****************************************************************************
-- Parses COMBAT_TEXT_UPDATE events for the watched unit (the player). This is
-- the same feed Blizzard's own floating combat text uses in Midnight. Damage
-- and miss events are intentionally not handled here (UNIT_COMBAT covers them).
-- ****************************************************************************
local function ParseCombatTextUpdate(messageType)
	if (not messageType or issecretvalue(messageType)) then return end

	local data, arg3, arg4 = C_CombatText.GetCurrentEventInfo()

	-- Aura gains and fades on the player.
	if (messageType == "SPELL_AURA_START" or messageType == "SPELL_AURA_START_HARMFUL" or
		messageType == "SPELL_AURA_END" or messageType == "SPELL_AURA_END_HARMFUL") then
		-- Aura names can be secret in combat; nothing useful can be done with them then.
		if (not data or issecretvalue(data)) then return end

		for k in pairs(parserEvent) do parserEvent[k] = nil end
		parserEvent.eventType = "aura"
		parserEvent.skillName = data
		parserEvent.auraType = (messageType == "SPELL_AURA_START_HARMFUL" or messageType == "SPELL_AURA_END_HARMFUL") and AURA_TYPE_DEBUFF or AURA_TYPE_BUFF
		if (messageType == "SPELL_AURA_END" or messageType == "SPELL_AURA_END_HARMFUL") then parserEvent.isFade = true end
		parserEvent.sourceFlags = OBJECT_NONE
		parserEvent.recipientUnit = "player"
		parserEvent.recipientGUID = playerGUID
		parserEvent.recipientName = playerName
		parserEvent.recipientFlags = FLAGS_ME
		SendParserEvent()

	-- Heals on the player: data is the healer's name, arg3 the amount, arg4 the absorbed amount.
	elseif (messageType == "HEAL" or messageType == "HEAL_CRIT" or messageType == "HEAL_ABSORB" or messageType == "HEAL_CRIT_ABSORB" or
			messageType == "PERIODIC_HEAL" or messageType == "PERIODIC_HEAL_CRIT" or
			messageType == "PERIODIC_HEAL_ABSORB" or messageType == "PERIODIC_HEAL_CRIT_ABSORB") then
		for k in pairs(parserEvent) do parserEvent[k] = nil end
		parserEvent.eventType = "heal"
		if (arg3 and not issecretvalue(arg3)) then arg3 = tonumber(arg3) or arg3 end
		parserEvent.amount = arg3
		if (string_find(messageType, "PERIODIC", 1, true)) then
			parserEvent.isHoT = true
			-- Periodic heals carry no spell reference; name them from the player's auras.
			local auraName = FindPlayerAuraName("player", "HELPFUL")
			if (auraName) then parserEvent.skillName = auraName end
		end
		if (string_find(messageType, "_CRIT", 1, true)) then parserEvent.isCrit = true end
		if (arg4 and not issecretvalue(arg4)) then parserEvent.absorbAmount = tonumber(arg4) end
		if (data and not issecretvalue(data)) then parserEvent.sourceName = data end
		parserEvent.sourceFlags = OBJECT_NONE
		parserEvent.recipientUnit = "player"
		parserEvent.recipientGUID = playerGUID
		parserEvent.recipientName = playerName
		parserEvent.recipientFlags = FLAGS_ME
		SendParserEvent()

	-- Power gains on the player: data is the amount, arg3 the power token.
	elseif (messageType == "ENERGIZE" or messageType == "PERIODIC_ENERGIZE") then
		local powerType = (arg3 and not issecretvalue(arg3)) and ctuPowerTypes[arg3]
		if (not powerType) then return end
		if (not issecretvalue(data)) then data = tonumber(data) or data end

		for k in pairs(parserEvent) do parserEvent[k] = nil end
		parserEvent.eventType = "power"
		parserEvent.isGain = true
		parserEvent.amount = data
		parserEvent.powerType = powerType
		parserEvent.sourceFlags = OBJECT_NONE
		parserEvent.recipientUnit = "player"
		parserEvent.recipientGUID = playerGUID
		parserEvent.recipientName = playerName
		parserEvent.recipientFlags = FLAGS_ME
		SendParserEvent()

	-- The player's cast was interrupted: data is the interrupted spell's name.
	elseif (messageType == "INTERRUPT") then
		for k in pairs(parserEvent) do parserEvent[k] = nil end
		parserEvent.eventType = "interrupt"
		if (data and not issecretvalue(data)) then parserEvent.extraSkillName = data end
		parserEvent.sourceFlags = OBJECT_NONE
		parserEvent.recipientUnit = "player"
		parserEvent.recipientGUID = playerGUID
		parserEvent.recipientName = playerName
		parserEvent.recipientFlags = FLAGS_ME
		SendParserEvent()

	-- Extra attacks granted: data is the spell name, arg3 the number of attacks.
	elseif (messageType == "EXTRA_ATTACKS") then
		for k in pairs(parserEvent) do parserEvent[k] = nil end
		parserEvent.eventType = "extraattacks"
		if (data and not issecretvalue(data)) then parserEvent.skillName = data end
		if (arg3 and not issecretvalue(arg3)) then parserEvent.amount = tonumber(arg3) end
		parserEvent.sourceUnit = "player"
		parserEvent.sourceGUID = playerGUID
		parserEvent.sourceName = playerName
		parserEvent.sourceFlags = FLAGS_ME
		SendParserEvent()

	-- Low health/mana warnings for the player (Blizzard's thresholds; these carry no
	-- values, so they still fire when vitals are secret). Skipped when the player's
	-- values aren't secret — the UNIT_HEALTH/UNIT_POWER_UPDATE triggers cover that.
	elseif (messageType == "HEALTH_LOW" or messageType == "MANA_LOW") then
		local isLowHealth = (messageType == "HEALTH_LOW")
		local value = isLowHealth and UnitHealth("player") or UnitPower("player", Enum.PowerType.Mana)
		if (not issecretvalue(value)) then return end

		for k in pairs(parserEvent) do parserEvent[k] = nil end
		parserEvent.eventType = isLowHealth and "lowhealth" or "lowmana"
		parserEvent.sourceFlags = OBJECT_NONE
		parserEvent.recipientUnit = "player"
		parserEvent.recipientGUID = playerGUID
		parserEvent.recipientName = playerName
		parserEvent.recipientFlags = FLAGS_ME
		SendParserEvent()
	end
end


-- ****************************************************************************
-- Parses PARTY_KILL events into killing blow notifications.
-- ****************************************************************************
local function ParsePartyKill(attackerGUID, targetGUID)
	-- GUIDs are secret in restricted content; the attacker can't be verified then.
	if (not attackerGUID or not targetGUID or issecretvalue(attackerGUID) or issecretvalue(targetGUID)) then return end

	-- Only the player's own kills produce killing blows.
	if (attackerGUID ~= playerGUID) then return end

	-- Classify the victim as a player or NPC from its GUID prefix.
	local recipientFlags = string_find(targetGUID, "^Player%-") and FLAGS_KILL_PLAYER or FLAGS_KILL_NPC

	-- Resolve the victim's name when possible.
	local recipientName = UnitNameFromGUID and UnitNameFromGUID(targetGUID)
	if (recipientName and issecretvalue(recipientName)) then recipientName = nil end

	for k in pairs(parserEvent) do parserEvent[k] = nil end
	parserEvent.eventType = "kill"
	parserEvent.sourceUnit = "player"
	parserEvent.sourceGUID = playerGUID
	parserEvent.sourceName = playerName
	parserEvent.sourceFlags = FLAGS_ME
	parserEvent.recipientGUID = targetGUID
	parserEvent.recipientName = recipientName or UNKNOWN
	parserEvent.recipientFlags = recipientFlags
	SendParserEvent()
end


-------------------------------------------------------------------------------
-- Startup utility functions.
-------------------------------------------------------------------------------

-- ****************************************************************************
-- Creates a map of global strings to search for CHAT_MSG_X events.
-- ****************************************************************************
local function CreateSearchMap()
	searchMap = {
		-- Honor Gains.
		CHAT_MSG_COMBAT_HONOR_GAIN = {"COMBATLOG_HONORGAIN", "COMBATLOG_HONORAWARD"},

		-- Reputation Gains/Losses.
		CHAT_MSG_COMBAT_FACTION_CHANGE = {"FACTION_STANDING_INCREASED", "FACTION_STANDING_DECREASED"},

		-- Skill Gains.
		CHAT_MSG_SKILL = {"SKILL_RANK_UP"},

		-- Experience Gains.
		CHAT_MSG_COMBAT_XP_GAIN = {"COMBATLOG_XPGAIN_FIRSTPERSON", "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED"},

		-- Looted Items.
		CHAT_MSG_LOOT = {
			"LOOT_ITEM_CREATED_SELF_MULTIPLE", "LOOT_ITEM_CREATED_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE",
			"LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_SELF"
		},

		-- Money.
		CHAT_MSG_MONEY = {"YOU_LOOT_MONEY", "LOOT_MONEY_SPLIT"},

		-- Currency.
		CHAT_MSG_CURRENCY = { "CURRENCY_GAINED", "CURRENCY_GAINED_MULTIPLE", "CURRENCY_GAINED_MULTIPLE_BONUS" },
	}


	-- Loop through each of the events.
	for event, map in pairs(searchMap) do
		-- Remove invalid global strings.
		for i = #map, 1, -1 do
			if (not _G[map[i]]) then table.remove(map, i) end
		end

		-- Sort the global strings from most to least specific.
		table.sort(map, GlobalStringCompareFunc)
	end
end


-- ****************************************************************************
-- Creates a map of capture functions for supported global strings.
-- ****************************************************************************
local function CreateSearchCaptureFuncs()
	searchCaptureFuncs = {
		-- Honor events.
		COMBATLOG_HONORAWARD = function (p, c) p.eventType, p.amount = "honor", c[1] end,
		COMBATLOG_HONORGAIN = function (p, c) p.eventType, p.sourceName, p.sourceRank, p.amount = "honor", c[1], c[2], c[3] end,

		-- Experience events.
		COMBATLOG_XPGAIN_FIRSTPERSON = function (p, c) p.eventType, p.sourceName, p.amount = "experience", c[1], c[2] end,
		COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED = function (p, c) p.eventType, p.amount = "experience", c[1] end,

		-- Reputation events.
		FACTION_STANDING_DECREASED = function (p, c) p.eventType, p.isLoss, p.factionName, p.amount = "reputation", true, c[1], c[2] end,
		FACTION_STANDING_INCREASED = function (p, c) p.eventType, p.factionName, p.amount = "reputation", c[1], c[2] end,

		-- Proficiency events.
		SKILL_RANK_UP = function (p, c) p.eventType, p.skillName, p.amount = "proficiency", c[1], c[2] end,

		-- Loot events.
		LOOT_ITEM_SELF = function (p, c) p.eventType, p.itemLink, p.amount = "loot", c[1], c[2] end,
		LOOT_ITEM_CREATED_SELF = function (p, c) p.eventType, p.isCreate, p.itemLink, p.amount = "loot", true, c[1], c[2] end,
		LOOT_MONEY_SPLIT = function (p, c) p.eventType, p.isMoney, p.moneyString = "loot", true, c[1] end,
		CURRENCY_GAINED = function (p, c) p.eventType, p.isCurrency, p.itemLink, p.amount = "loot", true, c[1], c[2] end,
	}

	searchCaptureFuncs["LOOT_ITEM_SELF_MULTIPLE"] = searchCaptureFuncs["LOOT_ITEM_SELF"]
	searchCaptureFuncs["LOOT_ITEM_CREATED_SELF_MULTIPLE"] = searchCaptureFuncs["LOOT_ITEM_CREATED_SELF"]
	searchCaptureFuncs["LOOT_ITEM_PUSHED_SELF"] = searchCaptureFuncs["LOOT_ITEM_CREATED_SELF"]
	searchCaptureFuncs["LOOT_ITEM_PUSHED_SELF_MULTIPLE"] = searchCaptureFuncs["LOOT_ITEM_CREATED_SELF"]
	searchCaptureFuncs["YOU_LOOT_MONEY"] = searchCaptureFuncs["LOOT_MONEY_SPLIT"]
	searchCaptureFuncs["CURRENCY_GAINED_MULTIPLE"] = searchCaptureFuncs["CURRENCY_GAINED"]
	searchCaptureFuncs["CURRENCY_GAINED_MULTIPLE_BONUS"] = searchCaptureFuncs["CURRENCY_GAINED"]

	-- Print an error message for each global string that isn't found and remove it from the map.
	for globalStringName in pairs(searchCaptureFuncs) do
		if (not _G[globalStringName]) then
			Print("Unable to find global string: " .. globalStringName, 1, 0, 0)
			searchCaptureFuncs[globalStringName] = nil
		end
	end
end


-- ****************************************************************************
-- Finds the rarest word for each global string.
-- ****************************************************************************
local function FindRareWords()
	-- Hold the number of times each word appears in all the global strings.
	local wordCounts = {}

	-- Loop through all of the supported global strings.
	for globalStringName in pairs(searchCaptureFuncs) do
		-- Strip out all of the formatting codes.
		local strippedGS = string.gsub(_G[globalStringName], "%%%d?%$?[sd]", "")

		-- Count how many times each word appears in the global string.
		for word in string_gmatch(strippedGS, "%w+") do
			wordCounts[word] = (wordCounts[word] or 0) + 1
		end
	end


	-- Loop through all of the supported global strings.
	for globalStringName in pairs(searchCaptureFuncs) do
		local leastSeen, rarestWord

		-- Strip out all of the formatting codes.
		local strippedGS = string.gsub(_G[globalStringName], "%%%d?%$?[sd]", "")

		-- Find the rarest word in the global string.
		for word in string_gmatch(strippedGS, "%w+") do
			if (not leastSeen or wordCounts[word] < leastSeen) then
				leastSeen = wordCounts[word]
				rarestWord = word
			end
		end

		-- Set the rarest word.
		rareWords[globalStringName] = rarestWord
	end
end


-- ****************************************************************************
-- Validates rare words to make sure there are no oddities caused by various
-- languages.
-- ****************************************************************************
local function ValidateRareWords()
	-- Loop through all of the global strings there is a rare word entry for.
	for globalStringName, rareWord in pairs(rareWords) do
		-- Remove the entry if the rare word isn't found in the associated global string.
		if (not string_find(_G[globalStringName], rareWord, 1, true)) then
			rareWords[globalStringName] = nil
		end
	end
end


-- ****************************************************************************
-- Converts all of the supported global strings.
-- ****************************************************************************
local function ConvertGlobalStrings()
	-- Loop through all of the supported global strings.
	for globalStringName in pairs(searchCaptureFuncs) do
		-- Get the global string converted to a lua search pattern and prepend an anchor to
		-- speed up searching.
		searchPatterns[globalStringName] = "^" .. ConvertGlobalString(globalStringName)
	end
end




-------------------------------------------------------------------------------
-- Event handlers.
-------------------------------------------------------------------------------

-- ****************************************************************************
-- Called when there is information that needs to be obtained after a delay.
-- ****************************************************************************
local function OnUpdateDelayedInfo(this, elapsed)
	-- Check if the unit map needs to be updated after a delay.
	if (isUnitMapStale) then
		-- Increment the amount of time passed since the last update.
		lastUnitMapUpdate = lastUnitMapUpdate + elapsed

		-- Check if it's time for an update.
		if (lastUnitMapUpdate >= UNIT_MAP_UPDATE_DELAY) then
			-- Update the player GUID if it isn't known yet and verify it's now known.
			if (not playerGUID) then playerGUID = UnitGUID("player") end
			if (playerGUID) then
				-- Mark all old group GUIDs for cleanup from the class map.
				local now = GetTime()
				for guid in pairs(rosterGUIDs) do
					rosterGUIDs[guid] = nil
					classTimes[guid] = now + CLASS_HOLD_TIME
				end

				-- Loop through all of the group members and add their class to the class map.
				local unitPrefix = IsInRaid() and "raid" or "party"
				local numGroupMembers = GetNumGroupMembers()
				for i = 1, numGroupMembers do
					local unitID = unitPrefix .. i
					-- XXX: This call is returning nil for party members in certain circumstances - need to debug further.
					local guid = UnitGUID(unitID)
					if (guid) then
						rosterGUIDs[guid] = true
						if (not classMap[guid]) then _, classMap[guid] = UnitClass(unitID) end
						classTimes[guid] = nil
					end
				end -- Loop through group members

				-- Add the player and player's class to the class map.
				rosterGUIDs[playerGUID] = true
				if (not classMap[playerGUID]) then _, classMap[playerGUID] = UnitClass("player") end
				classTimes[playerGUID] = nil

				-- Clear the unit map stale flag.
				isUnitMapStale = false
			end

			-- Reset the time since last update.
			lastUnitMapUpdate = 0
		end
	end -- Unit map is stale.

	-- Check if the pet map needs to be updated after a delay.
	if (isPetMapStale) then
		-- Increment the amount of time passed since the last update.
		lastPetMapUpdate = lastPetMapUpdate + elapsed

		-- Check if it's time for an update.
		if (lastPetMapUpdate >= PET_UPDATE_DELAY) then
			-- Verify the player's pet is not in an unknown state if there is one.
			local petName = UnitName("pet")
			if (not petName or petName ~= UNKNOWN) then
				-- Mark all old group pet GUIDs for cleanup from the class map.
				local now = GetTime()
				for guid in pairs(rosterPetGUIDs) do
					rosterPetGUIDs[guid] = nil
					classTimes[guid] = now + CLASS_HOLD_TIME
				end

					-- Loop through all of the group members and add their pets and pet's class to the class map.
				local unitPrefix = IsInRaid() and "raidpet" or "partypet"
				local numGroupMembers = GetNumGroupMembers()
				for i = 1, numGroupMembers do
					local unitID = unitPrefix .. i
					if (UnitExists(unitID)) then
						-- XXX: This call is returning nil for party members in certain circumstances - need to debug further.
						local guid = UnitGUID(unitID)
						if (guid ~= nil) then
							rosterPetGUIDs[guid] = true
							if (not classMap[guid]) then _, classMap[guid] = UnitClass(unitID) end
							classTimes[guid] = nil
						end
					end
				end -- Loop through group members

				-- Add the player's pet and its class if there is one. Treat vehicles as the player instead of a pet.
				if (petName) then
					local unitID = "pet"
					local guid = UnitGUID(unitID)
					if (guid == UnitGUID("vehicle")) then unitID = "player" end
					rosterPetGUIDs[guid] = true
					if (not classMap[guid]) then _, classMap[guid] = UnitClass(unitID) end
					classTimes[guid] = nil
				end

				-- Clear the pet map stale flag.
				isPetMapStale = false
			end -- Pet in known state.

			-- Reset the time since last update.
			lastPetMapUpdate = 0
		end
	end -- Pet map is stale.

	-- Stop receiving updates if no more data needs to be updated.
	if (not isUnitMapStale and not isPetMapStale) then this:Hide() end
end


-- ****************************************************************************
-- Called when the events the parser registered for occur.
-- ****************************************************************************
local function OnEvent(this, event, arg1, arg2, ...)
	-- Damage and miss events (Midnight 12.x feed).
	if (event == "UNIT_COMBAT") then
		ParseUnitCombat(arg1, arg2, ...)

	-- Recent cast tracking for spell correlation.
	elseif (event == "UNIT_SPELLCAST_SUCCEEDED") then
		TrackSpellCast(arg1, arg2, ...)

	-- Killing blows.
	elseif (event == "PARTY_KILL") then
		ParsePartyKill(arg1, arg2)

	-- Player-centric typed combat text feed (auras, heals, power gains, interrupts).
	elseif (event == "COMBAT_TEXT_UPDATE") then
		ParseCombatTextUpdate(arg1)

	-- Mouseover changes.
	elseif (event == "UPDATE_MOUSEOVER_UNIT") then
		-- Map the GUID for the moused over unit to a class.
		-- Midnight 12.x: unit identity can be secret in restricted content.
		local mouseoverGUID = UnitGUID("mouseover")
		if (not mouseoverGUID or issecretvalue(mouseoverGUID)) then return end

		-- Ignore the GUID if its class is already known and there is no cleanup time for it.
		if (classMap[mouseoverGUID] and not classTimes[mouseoverGUID]) then return end

		-- Update the cleanup time for the GUID and map it to a class if it's not already known.
		classTimes[mouseoverGUID] = GetTime() + CLASS_HOLD_TIME
		if (not classMap[mouseoverGUID]) then
			local _, class = UnitClass("mouseover")
			if (class and not issecretvalue(class)) then classMap[mouseoverGUID] = class end
		end

	-- Target changes.
	elseif (event == "PLAYER_TARGET_CHANGED") then
		-- Map the GUID for the target unit to a class.
		-- Midnight 12.x: unit identity can be secret in restricted content.
		local targetGUID = UnitGUID("target")
		if (not targetGUID or issecretvalue(targetGUID)) then return end

		-- Ignore the GUID if its class is already known and there is no cleanup time for it.
		if (classMap[targetGUID] and not classTimes[targetGUID]) then return end

		-- Update the cleanup time for the GUID and map it to a class if it's not already known.
		local now = GetTime()
		classTimes[targetGUID] = now + CLASS_HOLD_TIME
		if (not classMap[targetGUID]) then
			local _, class = UnitClass("target")
			if (class and not issecretvalue(class)) then classMap[targetGUID] = class end
		end

		-- Loop through all of the recent guid to class mappings and remove the old ones if enough time has passed.
		if (now >= classMapCleanupTime) then
			for guid, cleanupTime in pairs(classTimes) do
				if (now >= cleanupTime) then classMap[guid] = nil classTimes[guid] = nil end
			end

			classMapCleanupTime = now + CLASS_HOLD_TIME
		end -- Time to clean up class map.

	-- Party/Raid changes.
	elseif (event == "GROUP_ROSTER_UPDATE") then
		-- Set the unit map stale flag and schedule the unit map to be updated after a short delay.
		isUnitMapStale = true
		eventFrame:Show()

	-- Pet changes.
	elseif (event == "UNIT_PET") then
		isPetMapStale = true
		eventFrame:Show()

	-- Arena opponent changes.
	elseif (event == "ARENA_OPPONENT_UPDATE") then
		-- Map the unit id and GUID for an arena unit to a class when it's seen.
		-- Midnight 12.x: arena unit identity is secret during matches.
		if (arg2 == "seen") then
			local arenaGUID = UnitGUID(arg1)
			if (not arenaGUID or issecretvalue(arenaGUID)) then return end
			local _, class = UnitClass(arg1)
			if (not class or issecretvalue(class)) then return end
			arenaUnits[arg1] = arenaGUID
			classMap[arenaGUID] = class

		-- Remove the mappings for an arena unit when it's cleared.
		elseif (arg2 == "cleared") then
			local arenaGUID = arenaUnits[arg1]
			if (not arenaGUID) then return end
			arenaUnits[arg1] = nil
			classMap[arenaGUID] = nil
		end

	-- Chat message combat events.
	else
		ParseSearchMessage(event, arg1)
	end
end


-- ****************************************************************************
-- Enables parsing.
-- ****************************************************************************
local function Enable()
	-- Register for the Midnight 12.x combat data feeds (the combat log was removed).
	eventFrame:RegisterEvent("UNIT_COMBAT")
	eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
	eventFrame:RegisterEvent("PARTY_KILL")
	if (C_CombatText) then
		eventFrame:RegisterEvent("COMBAT_TEXT_UPDATE")
		C_CombatText.SetActiveUnit("player")
	end

	-- Register CHAT_MSG_X search style events.
	for event in pairs(searchMap) do
		eventFrame:RegisterEvent(event)
	end

	-- Register additional events for unit and class map processing.
	eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
	eventFrame:RegisterEvent("UNIT_PET")
	if WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
		eventFrame:RegisterEvent("ARENA_OPPONENT_UPDATE")
	end
	eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
	eventFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")

	-- Update the unit map and current pet information.
	isUnitMapStale = true
	isPetMapStale = true

	-- Start receiving updates.
	eventFrame:Show()
end


-- ****************************************************************************
-- Disables the parsing.
-- ****************************************************************************
local function Disable()
	-- Stop receiving updates.
	eventFrame:Hide()
	eventFrame:UnregisterAllEvents()

	-- Erase the recent casts used for spell correlation.
	EraseTable(recentCasts)
end


-------------------------------------------------------------------------------
-- Initialization.
-------------------------------------------------------------------------------

-- Create a frame to receive events.
eventFrame = CreateFrame("Frame")
eventFrame:Hide()
eventFrame:SetScript("OnEvent", OnEvent)
eventFrame:SetScript("OnUpdate", OnUpdateDelayedInfo)

-- Get the name, GUID, and class of the player.
playerName = UnitName("player")
playerGUID = UnitGUID("player")

-- Create various maps.
CreateSearchMap()
CreateSearchCaptureFuncs()

-- Find the rarest word for each supported global string.
FindRareWords()
ValidateRareWords()

-- Convert the supported global strings into lua search patterns.
ConvertGlobalStrings()




-------------------------------------------------------------------------------
-- Module interface.
-------------------------------------------------------------------------------

-- Protected Constants.
module.AFFILIATION_MINE		= AFFILIATION_MINE
module.AFFILIATION_PARTY	= AFFILIATION_PARTY
module.AFFILIATION_RAID		= AFFILIATION_RAID
module.AFFILIATION_OUTSIDER	= AFFILIATION_OUTSIDER
module.REACTION_FRIENDLY	= REACTION_FRIENDLY
module.REACTION_NEUTRAL		= REACTION_NEUTRAL
module.REACTION_HOSTILE		= REACTION_HOSTILE
module.CONTROL_HUMAN		= CONTROL_HUMAN
module.CONTROL_SERVER		= CONTROL_SERVER
module.UNITTYPE_PLAYER		= UNITTYPE_PLAYER
module.UNITTYPE_NPC			= UNITTYPE_NPC
module.UNITTYPE_PET			= UNITTYPE_PET
module.UNITTYPE_GUARDIAN	= UNITTYPE_GUARDIAN
module.UNITTYPE_OBJECT		= UNITTYPE_OBJECT
module.TARGET_TARGET		= TARGET_TARGET
module.TARGET_FOCUS			= TARGET_FOCUS
module.OBJECT_NONE			= OBJECT_NONE

-- Protected Variables.
module.classMap = classMap

-- Protected Functions.
module.RegisterHandler				= RegisterHandler
module.UnregisterHandler			= UnregisterHandler
module.TestFlagsAny					= TestFlagsAny
module.TestFlagsAll					= TestFlagsAll
module.Enable						= Enable
module.Disable						= Disable
