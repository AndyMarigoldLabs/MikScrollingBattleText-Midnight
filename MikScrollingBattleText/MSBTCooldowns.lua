-------------------------------------------------------------------------------
-- Title: Mik's Scrolling Battle Text Cooldowns
-- Author: Mikord
-------------------------------------------------------------------------------

-- Create module and set its name.
local module = {}
local moduleName = "Cooldowns"
MikSBT[moduleName] = module


-------------------------------------------------------------------------------
-- Imports.
-------------------------------------------------------------------------------

-- Local references to various modules for faster access.
local MSBTProfiles = MikSBT.Profiles
local MSBTTriggers = MikSBT.Triggers

-- Local references to various functions for faster access.
local string_gsub = string.gsub
local string_find = string.find
local string_format = string.format
local string_match = string.match
local MSBTGetSpellCooldown = MikSBT.MSBTGetSpellCooldown
local EraseTable = MikSBT.EraseTable
local MSBTGetSpellInfo = MikSBT.MSBTGetSpellInfo
local GetSkillName = MikSBT.GetSkillName
local DisplayEvent = MikSBT.Animations.DisplayEvent
local HandleCooldowns = MSBTTriggers.HandleCooldowns
-- Compat shims live in MikSBT.lua so all modules share one set of fallbacks.
local GetItemInfo = MikSBT.GetItemInfo
local GetSpellTexture = MikSBT.GetSpellTexture

-- Midnight 12.x: cooldown values are secret while restricted (combat/encounters);
-- skip processing instead of erroring on secret comparisons/arithmetic.
local ShouldCooldownsBeSecret = C_Secrets and C_Secrets.ShouldCooldownsBeSecret or function() return false end

-------------------------------------------------------------------------------
-- Constants.
-------------------------------------------------------------------------------

-- The minimum and maximum amount of time to delay between checking cooldowns.
local MIN_COOLDOWN_UPDATE_DELAY = 0.1
local MAX_COOLDOWN_UPDATE_DELAY = 1

-- Spell names.
local SPELLID_COLD_SNAP		= 11958
local SPELLID_MIND_FREEZE	= 47528
local SPELLID_PREPARATION	= 14185
local SPELLID_READINESS		= 23989

-- Death knight rune cooldown.
local RUNE_COOLDOWN = 10

-- Parameter locations.
local ITEM_INFO_TEXTURE_POSITION = 10

-------------------------------------------------------------------------------
-- Private variables.
-------------------------------------------------------------------------------

-- Prevent tainting global _.
local _

-- Dynamically created frame for receiving events.
local eventFrame = CreateFrame("Frame")

-- Player's class.
local playerClass

-- Cooldown information.
local activeCooldowns = {player={}, pet={}, item={}}
local delayedCooldowns = {player={}, pet={}, item={}}
local resetAbilities = {}
local runeCooldownAbilities = {}
local lastCooldownIDs = {}
local watchItemIDs = {}

-- Activation times for cooldowns tracked in restricted mode (Midnight 12.x:
-- durations are secret, so completion is detected via isActive transitions).
local restrictedActiveTimes = {}

-- Used for timing between updates.
local updateDelay = MIN_COOLDOWN_UPDATE_DELAY
local lastUpdate = 0

-- Flag for whether item cooldowns are enabled.
local itemCooldownsEnabled = true


-------------------------------------------------------------------------------
-- Utility functions.
-------------------------------------------------------------------------------

-- ****************************************************************************
-- Attempts to return a texture for a given cooldown type and id.
-- ****************************************************************************
local function GetCooldownTexture(cooldownType, cooldownID)
	if (cooldownType == "item") then
		return select(ITEM_INFO_TEXTURE_POSITION, GetItemInfo(cooldownID))
	else
		return GetSpellTexture(cooldownID)
	end
end


-- ****************************************************************************
-- Fires the cooldown completion trigger and notification for a cooldown.
-- ****************************************************************************
local function FireCooldownAlert(cooldownType, cooldownID)
	local infoFunc = (cooldownType == "item") and GetItemInfo or MSBTGetSpellInfo
	local cooldownName = infoFunc(cooldownID) or UNKNOWN
	if (issecretvalue(cooldownName)) then cooldownName = UNKNOWN end
	local texture = GetCooldownTexture(cooldownType, cooldownID)
	HandleCooldowns(cooldownType, cooldownID, cooldownName, texture)

	local eventSettings = MSBTProfiles.currentProfile.events.NOTIFICATION_COOLDOWN
	if (cooldownType == "pet") then
		eventSettings = MSBTProfiles.currentProfile.events.NOTIFICATION_PET_COOLDOWN
	elseif (cooldownType == "item") then
		eventSettings = MSBTProfiles.currentProfile.events.NOTIFICATION_ITEM_COOLDOWN
	end
	if (eventSettings and not eventSettings.disabled) then
		local message = eventSettings.message
		local formattedSkillName = string_format("|cFF%02x%02x%02x%s|r", eventSettings.skillColorR * 255, eventSettings.skillColorG * 255, eventSettings.skillColorB * 255, string_gsub(cooldownName, "%(.+%)%(%)$", ""))
		message = string_gsub(message, "%%e", formattedSkillName)
		DisplayEvent(eventSettings, message, texture)
	end
end


-------------------------------------------------------------------------------
-- Event handlers.
-------------------------------------------------------------------------------

-- ****************************************************************************
-- Called when the player successfully casts a spell.
-- ****************************************************************************
local function OnSpellCast(unitID, spellID)
	-- Midnight 12.x: spell IDs can be secret in restricted content; they can't be tracked then.
	if (issecretvalue(spellID)) then return end

	-- Ignore the cast if the spell name is excluded.
	local spellName = GetSkillName(spellID)
	local cooldownExclusions = MSBTProfiles.currentProfile.cooldownExclusions
	if (cooldownExclusions[spellName] or cooldownExclusions[spellID]) then return end

	-- An ability that resets cooldowns was cast.
	if (resetAbilities[spellID] and unitID == "player") then
		-- Remove active cooldowns that the game is now reporting inactive.
		for spellID, remainingDuration in pairs(activeCooldowns[unitID]) do
			local startTime, duration = MSBTGetSpellCooldown(spellID)
			if (not issecretvalue(duration) and type(remainingDuration) == "number" and duration <= 1.5 and remainingDuration > 1.5) then activeCooldowns[unitID][spellID] = nil end

			-- Force an update.
			updateDelay = MIN_COOLDOWN_UPDATE_DELAY
		end
	end

	-- Set the cooldown spell id to be checked on the next cooldown update event.
	lastCooldownIDs[unitID] = spellID
end


-- ****************************************************************************
-- Called when the player uses an item.
-- ****************************************************************************
local function OnItemUse(itemID)
	-- Ignore if the item name is excluded.
	local itemName = GetItemInfo(itemID)
	local cooldownExclusions = MSBTProfiles.currentProfile.cooldownExclusions
	if (cooldownExclusions[itemName] or cooldownExclusions[itemID]) then return end

	-- Add the item to a lsit to be checked for cooldowns in a a couple of seconds.
	-- There doesn't appear to be a realible event that can be used for items like
	-- there is for spells, so this allows a fairly efficient method of only checking
	-- the cooldowns on used items versus scanning all of the slots in inventory
	-- and bages every update.
	watchItemIDs[itemID] = GetTime()

	-- Force an update.
	updateDelay = MIN_COOLDOWN_UPDATE_DELAY

	-- Check if the event frame is not visible and make it visible so the OnUpdate events start firing.
	-- This is done to keep the number of OnUpdate events down to a minimum for better performance.
	if (not eventFrame:IsVisible()) then eventFrame:Show() end
end


-- ****************************************************************************
-- Called when a spell cooldown is started.
-- ****************************************************************************
local function OnUpdateCooldown(cooldownType, cooldownFunc)
	if (not delayedCooldowns[cooldownType] or not activeCooldowns[cooldownType]) then return end

	-- Midnight 12.x: in restricted content start/duration are secret, but isActive is not,
	-- so fall back to a state machine that needs no secret math. Items lack isActive and stay paused.
	local isRestricted = ShouldCooldownsBeSecret()
	if (isRestricted and cooldownType == "item") then return end

	-- Start delayed cooldowns once they have been used.
	for cooldownID in pairs(delayedCooldowns[cooldownType]) do
		if (isRestricted) then
			-- Activate anything the UI considers on cooldown; the duration is unknown in this mode.
			local _, _, _, _, isActive = cooldownFunc(cooldownID)
			if (isActive == true) then
				activeCooldowns[cooldownType][cooldownID] = "restricted"
				restrictedActiveTimes[cooldownID] = GetTime()
				delayedCooldowns[cooldownType][cooldownID] = nil

				-- Check if the event frame is not visible and make it visible so the OnUpdate events start firing.
				if (not eventFrame:IsVisible()) then eventFrame:Show() end
			end
		else
			-- Check if the cooldown is enabled yet.
			local _, duration, enabled = cooldownFunc(cooldownID)
			if (enabled == 1 or enabled == true) then
				-- Add the cooldown to the active cooldowns list if the cooldown is longer than the cooldown threshold or it's required to show.
				local cooldownName = GetSkillName(cooldownID)
				local ignoreCooldownThreshold = MSBTProfiles.currentProfile.ignoreCooldownThreshold
				if (duration >= MSBTProfiles.currentProfile.cooldownThreshold or ignoreCooldownThreshold[cooldownName] or ignoreCooldownThreshold[cooldownID]) then
					activeCooldowns[cooldownType][cooldownID] = duration

					-- Force an update.
					updateDelay = MIN_COOLDOWN_UPDATE_DELAY

					-- Check if the event frame is not visible and make it visible so the OnUpdate events start firing.
					-- This is done to keep the number of OnUpdate events down to a minimum for better performance.
					if (not eventFrame:IsVisible()) then eventFrame:Show() end
				end

				-- Remove the cooldown from the delayed cooldowns list.
				delayedCooldowns[cooldownType][cooldownID] = nil
			end
		end
	end

	-- Add the last successful spell to the active cooldowns if necessary.
	local cooldownID = lastCooldownIDs[cooldownType]
	if (cooldownID) then
		if (isRestricted) then
			-- Same restricted-mode handling as the delayed cooldowns above.
			local _, _, _, _, isActive = cooldownFunc(cooldownID)
			if (isActive == true) then
				activeCooldowns[cooldownType][cooldownID] = "restricted"
				restrictedActiveTimes[cooldownID] = GetTime()
				delayedCooldowns[cooldownType][cooldownID] = nil

				-- Check if the event frame is not visible and make it visible so the OnUpdate events start firing.
				if (not eventFrame:IsVisible()) then eventFrame:Show() end
			end
		else
			-- Make sure the spell cooldown is enabled.
			local _, duration, enabled = cooldownFunc(cooldownID)
			if (enabled == 1 or enabled == true) then
				-- XXX This is a hack to compensate for Blizzard's API reporting incorrect cooldown information for death knights.
				-- XXX Ignore cooldowns that are the same duration as a rune cooldown except for the abilities that truly have the same cooldown.
				if (playerClass == "DEATHKNIGHT" and duration == RUNE_COOLDOWN and cooldownType == "player" and not runeCooldownAbilities[cooldownID]) then duration = -1 end

				-- Add the cooldown to the active cooldowns list if the cooldown is longer than the cooldown threshold or it's required to show.
				local cooldownName = GetSkillName(cooldownID)
				local ignoreCooldownThreshold = MSBTProfiles.currentProfile.ignoreCooldownThreshold
				if (duration >= MSBTProfiles.currentProfile.cooldownThreshold or ignoreCooldownThreshold[cooldownName] or ignoreCooldownThreshold[cooldownID]) then
					activeCooldowns[cooldownType][cooldownID] = duration

					-- Force an update.
					updateDelay = MIN_COOLDOWN_UPDATE_DELAY

					-- Check if the event frame is not visible and make it visible so the OnUpdate events start firing.
					-- This is done to keep the number of OnUpdate events down to a minimum for better performance.
					if (not eventFrame:IsVisible()) then eventFrame:Show() end
				end

			-- Cooldown is NOT enabled so add it to the delayed cooldowns list.
			else
				delayedCooldowns[cooldownType][cooldownID] = true
			end
		end

		lastCooldownIDs[cooldownType] = nil
	end -- cooldownID?
end


-- ****************************************************************************
-- Called when the OnUpdate event occurs.
-- ****************************************************************************
local function OnUpdate(frame, elapsed)
	-- Increment the amount of time passed since the last update.
	lastUpdate = lastUpdate + elapsed

	-- Check if it's time for an update.
	if (lastUpdate >= updateDelay) then
		-- Reset the update delay to the max value.
		updateDelay = MAX_COOLDOWN_UPDATE_DELAY

		-- Loop through the item ids being watched for cooldowns.
		local currentTime = GetTime()
		for cooldownID, usedTime in pairs(watchItemIDs) do
			if (currentTime >= (usedTime + 1)) then
				lastCooldownIDs["item"] = cooldownID
				OnUpdateCooldown("item", C_Container.GetItemCooldown)
				watchItemIDs[cooldownID] = nil
				break
			end
		end

		-- Midnight 12.x: in restricted content, durations are secret — switch to isActive transitions.
		local isRestricted = ShouldCooldownsBeSecret()

		-- Loop through all of the active cooldowns.
		local currentTime = GetTime()
		for cooldownType, cooldowns in pairs(activeCooldowns) do
			local cooldownFunc = (cooldownType == "item") and C_Container.GetItemCooldown or MSBTGetSpellCooldown
			for cooldownID, remainingDuration in pairs(cooldowns) do
				if (isRestricted) then
					-- Items have no isActive; they resume normal tracking once unrestricted.
					if (cooldownType ~= "item") then
						-- Convert to the restricted sentinel on mode switch.
						if (remainingDuration ~= "restricted") then
							remainingDuration = "restricted"
							cooldowns[cooldownID] = remainingDuration
							restrictedActiveTimes[cooldownID] = currentTime
						end

						-- Cooldown completed once the UI no longer considers it active.
						local _, _, _, _, isActive = cooldownFunc(cooldownID)
						if (isActive ~= true) then
							-- Apply the cooldown threshold to the observed duration (legal: our own timestamps).
							local activatedAt = restrictedActiveTimes[cooldownID] or currentTime
							restrictedActiveTimes[cooldownID] = nil
							cooldowns[cooldownID] = nil
							if (currentTime - activatedAt + 1 >= MSBTProfiles.currentProfile.cooldownThreshold) then
								FireCooldownAlert(cooldownType, cooldownID)
							end
						end
					end
				else
					-- Ensure the cooldown is still valid.
					local startTime, duration, enabled = cooldownFunc(cooldownID)
					if (startTime ~= nil) then
						-- Calculate the remaining cooldown.
						local cooldownRemaining = startTime + duration - currentTime

						-- XXX This is to compensate for Blizzard's API reporting incorrect cooldown information for pets that have been dismissed.
						-- XXX Use an internal timer for pet skills.
						-- XXX This will have to be updated if any skills are added that dynamically adjust pet cooldowns.
						if (cooldownType == "pet" and type(remainingDuration) == "number") then cooldownRemaining = remainingDuration - lastUpdate end

						-- Cooldown completed.
						if (cooldownRemaining <= 0) then
							FireCooldownAlert(cooldownType, cooldownID)

							-- Remove the cooldown from active cooldowns.
							cooldowns[cooldownID] = nil
							restrictedActiveTimes[cooldownID] = nil

						-- Cooldown NOT completed.
						else
							cooldowns[cooldownID] = cooldownRemaining
							if (cooldownRemaining < updateDelay) then updateDelay = cooldownRemaining end
						end

					-- Cooldown is no longer valid.
					else
						cooldowns[cooldownID] = nil
						restrictedActiveTimes[cooldownID] = nil
					end
				end
			end -- cooldowns
		end -- units

		-- Ensure the update delay isn't less than the min value.
		if (updateDelay < MIN_COOLDOWN_UPDATE_DELAY) then updateDelay = MIN_COOLDOWN_UPDATE_DELAY end

		-- Hide the event frame if there are no active cooldowns so the OnUpdate events stop firing.
		-- This is done to keep the number of OnUpdate events down to a minimum for better performance.
		local allInactive = true
		for cooldownType, cooldowns in pairs(activeCooldowns) do
			if (next(cooldowns)) then allInactive = false end
		end
		if (allInactive and not next(watchItemIDs)) then eventFrame:Hide() end

		-- Reset the time since last update.
		lastUpdate = 0
	end
end


-- ****************************************************************************
-- Successful spell casts.
-- ****************************************************************************
function eventFrame:UNIT_SPELLCAST_SUCCEEDED(unitID, lineID, skillID)
	if (unitID == "player") then OnSpellCast("player", skillID) end
end


-- ****************************************************************************
-- Called when spell cooldowns begin.
-- ****************************************************************************
function eventFrame:SPELL_UPDATE_COOLDOWN()
	OnUpdateCooldown("player", MSBTGetSpellCooldown)
end


-- ****************************************************************************
-- Called when pet cooldowns begin.
-- ****************************************************************************
function eventFrame:PET_BAR_UPDATE_COOLDOWN()
	OnUpdateCooldown("pet", MSBTGetSpellCooldown)
end


-- ****************************************************************************
-- Updates the registered events depending on active options.
-- ****************************************************************************
local function UpdateRegisteredEvents()
	-- Toggle the registered events for player cooldowns depending on enabled notifications and triggers.
	local doEnable = false
	if (not MSBTProfiles.currentProfile.events.NOTIFICATION_COOLDOWN.disabled or MSBTTriggers.categorizedTriggers["SKILL_COOLDOWN"]) then doEnable = true end
	local registerFunc = doEnable and "RegisterEvent" or "UnregisterEvent"
	eventFrame[registerFunc](eventFrame, "UNIT_SPELLCAST_SUCCEEDED")
	eventFrame[registerFunc](eventFrame, "SPELL_UPDATE_COOLDOWN")

	-- Toggle the registered events for pet cooldowns depending on enabled notifications and triggers.
	local doEnable = false
	if (not MSBTProfiles.currentProfile.events.NOTIFICATION_PET_COOLDOWN.disabled or MSBTTriggers.categorizedTriggers["PET_COOLDOWN"]) then doEnable = true end
	local registerFunc = doEnable and "RegisterEvent" or "UnregisterEvent"
	eventFrame[registerFunc](eventFrame, "PET_BAR_UPDATE_COOLDOWN")

	-- Toggle the flag for tracking item cooldowns depending on enabled notifications and triggers.
	local doEnable = false
	if (not MSBTProfiles.currentProfile.events.NOTIFICATION_ITEM_COOLDOWN.disabled or MSBTTriggers.categorizedTriggers["ITEM_COOLDOWN"]) then doEnable = true end
	itemCooldownsEnabled = doEnable
end


-- ****************************************************************************
-- Enables the module.
-- ****************************************************************************
local function Enable()
	UpdateRegisteredEvents()
end


-- ****************************************************************************
-- Disables the module.
-- ****************************************************************************
local function Disable()
	-- Stop receiving updates.
	eventFrame:Hide()
	eventFrame:UnregisterAllEvents()

	-- Clear the cooldown tracking tables.
	for cooldownType, cooldowns in pairs(activeCooldowns) do EraseTable(cooldowns) end
	for cooldownType, cooldowns in pairs(delayedCooldowns) do EraseTable(cooldowns) end
	EraseTable(watchItemIDs)
end


-------------------------------------------------------------------------------
-- Item usage hooks.
-------------------------------------------------------------------------------

-- ****************************************************************************
-- Called when an action button is used.
-- ****************************************************************************
local function UseActionHook(slot)
	if (not itemCooldownsEnabled) then return end

	-- Get item id for the action if the action was using and item.
	local actionType, itemID = GetActionInfo(slot)
	if (actionType == "item") then OnItemUse(itemID) end
end


-- ****************************************************************************
-- Called when an inventory item is used.
-- ****************************************************************************
local function UseInventoryItemHook(slot)
	if (not itemCooldownsEnabled) then return end

	-- Get item id for the used inventory item.
	local itemID = GetInventoryItemID("player", slot);
	if (itemID) then OnItemUse(itemID) end
end


-- ****************************************************************************
-- Called when a container item is used.
-- ****************************************************************************
local function UseContainerItemHook(bag, slot)
	if (not itemCooldownsEnabled) then return end

	-- Get item id for the used bag and slot.
	local itemID = C_Container.GetContainerItemID(bag, slot)
	if (itemID) then OnItemUse(itemID) end
end


-- ****************************************************************************
-- Called when an item is used by name.
-- ****************************************************************************
local function UseItemByNameHook(itemName)
	if (not itemCooldownsEnabled) then return end

	-- Get item link for the name and extract item id from item link.
	if (not itemName) then return end
	local _, itemLink = GetItemInfo(itemName)
	local itemID
	if (itemLink) then itemID = string_match(itemLink, "item:(%d+)") end
	if (itemID) then OnItemUse(itemID) end
end


-------------------------------------------------------------------------------
-- Initialization.
-------------------------------------------------------------------------------

-- Setup event frame.
eventFrame:Hide()
eventFrame:SetScript("OnEvent", function (self, event, ...)
	if (self[event]) then
		self[event](self, ...)
	end
end)
eventFrame:SetScript("OnUpdate", OnUpdate)

-- Get the player's class.
_, playerClass = UnitClass("player")

-- Setup hooks.
hooksecurefunc("UseAction", UseActionHook)
hooksecurefunc("UseInventoryItem", UseInventoryItemHook)
hooksecurefunc(C_Container, "UseContainerItem", UseContainerItemHook)
-- UseItemByName moved to the C_Item namespace; the old global is gone.
if (C_Item and C_Item.UseItemByName) then
	hooksecurefunc(C_Item, "UseItemByName", UseItemByNameHook)
end

-- Specify the abilities that reset cooldowns.
resetAbilities[SPELLID_COLD_SNAP] = true
resetAbilities[SPELLID_PREPARATION] = true
resetAbilities[SPELLID_READINESS] = true

-- Set the death knight abilities that are the same as the rune cooldown.
runeCooldownAbilities[SPELLID_MIND_FREEZE] = true




-------------------------------------------------------------------------------
-- Module interface.
-------------------------------------------------------------------------------

-- Protected Functions.
module.Enable					= Enable
module.Disable					= Disable
module.UpdateRegisteredEvents	= UpdateRegisteredEvents
