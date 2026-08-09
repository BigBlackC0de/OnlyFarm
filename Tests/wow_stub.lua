--[[---------------------------------------------------------------------------
	OnlyFarm — Tests/wow_stub.lua

	Environnement WoW minimal pour Lua 5.1 standard.

	But : exécuter la logique pure (collection, verrous, éligibilité) hors du
	jeu. Ça n'attrape évidemment pas les erreurs d'API réelles — seul le client
	le peut — mais ça attrape tout ce qui compte le plus souvent : nil arithmetic,
	comparaison de types, clés de table qui divergent, logique de reset inversée.

	Les fixtures sont pilotables : voir `stub.mounts`, `stub.savedInstances`, etc.
-----------------------------------------------------------------------------]]

local stub = {}

--------------------------------------------------------------------------------
-- Horloge contrôlée
--------------------------------------------------------------------------------

stub.now = 1700000000       -- horodatage fixe et reproductible
stub.gameTime = 1000.0      -- GetTime(), monotone depuis le lancement

function stub.Advance(seconds)
	stub.now = stub.now + seconds
	stub.gameTime = stub.gameTime + seconds
end

--- Avance seulement l'horloge des frames : utile pour laisser tourner un
--  anti-rebond sans déplacer la date du serveur.
function stub.AdvanceFrames(seconds)
	stub.gameTime = stub.gameTime + seconds
end

_G.time = function() return stub.now end
_G.GetTime = function() return stub.gameTime end

-- debugprofilestop AVANCE à chaque appel, d'une milliseconde.
--
-- Ce n'est pas une coquetterie : les coroutines à budget de frame tournent
-- dans un « repeat … until debugprofilestop() >= deadline ». Avec une horloge
-- figée sur gameTime, la condition n'est jamais atteinte et le test part en
-- boucle infinie au lieu d'échouer. Une horloge qui avance donne quelques
-- itérations par frame simulée, exactement comme en jeu.
stub.profileClock = 0
_G.debugprofilestop = function()
	stub.profileClock = stub.profileClock + 1
	return stub.profileClock
end

--------------------------------------------------------------------------------
-- Timers différés
--------------------------------------------------------------------------------

stub.timers = {}

_G.C_Timer = {
	After = function(delay, callback)
		table.insert(stub.timers, { at = stub.gameTime + delay, callback = callback })
	end,
}

--- Exécute les timers dont l'échéance est atteinte. `Advance` d'abord si besoin.
function stub.FlushTimers(maxRounds)
	maxRounds = maxRounds or 10
	for _ = 1, maxRounds do
		local due, remaining = {}, {}
		for _, timer in ipairs(stub.timers) do
			if timer.at <= stub.gameTime then
				table.insert(due, timer)
			else
				table.insert(remaining, timer)
			end
		end
		stub.timers = remaining
		if #due == 0 then return end
		for _, timer in ipairs(due) do timer.callback() end
	end
end

function stub.ClearTimers()
	stub.timers = {}
end

--------------------------------------------------------------------------------
-- Frames
--------------------------------------------------------------------------------

local frameProto = {}
frameProto.__index = frameProto

local KNOWN_EVENTS = {
	ADDON_LOADED = true, PLAYER_LOGIN = true, PLAYER_ENTERING_WORLD = true,
	NEW_MOUNT_ADDED = true, COMPANION_LEARNED = true,
	UPDATE_INSTANCE_INFO = true, BOSS_KILL = true, ENCOUNTER_END = true,
	PLAYER_REGEN_ENABLED = true, SPELLS_CHANGED = true, TOYS_UPDATED = true,
}
stub.KNOWN_EVENTS = KNOWN_EVENTS

function frameProto:RegisterEvent(event)
	if not KNOWN_EVENTS[event] then
		error("Unknown event: " .. tostring(event), 2)
	end
	self.events[event] = true
end

function frameProto:UnregisterEvent(event) self.events[event] = nil end
function frameProto:SetScript(name, handler) self.scripts[name] = handler end
function frameProto:GetScript(name) return self.scripts[name] end
function frameProto:Show() self.shown = true end
function frameProto:Hide() self.shown = false end
function frameProto:IsShown() return self.shown == true end

--- Fait tourner les scripts OnUpdate, ce qui fait avancer les coroutines
--  pilotées par frame (cartographie, futur solveur de route).
function stub.RunFrames(count)
	for _ = 1, (count or 1) do
		-- Copie : un pilote peut retirer son OnUpdate en cours de route, et une
		-- frame peut en créer une autre.
		local snapshot = {}
		for index, frame in ipairs(stub.frames) do snapshot[index] = frame end
		for _, frame in ipairs(snapshot) do
			local onUpdate = frame.scripts.OnUpdate
			if onUpdate then onUpdate(frame, 0.016) end
		end
	end
end

--- Envoie un événement à toutes les frames abonnées.
function stub.Fire(event, ...)
	for _, frame in ipairs(stub.frames) do
		if frame.events[event] and frame.scripts.OnEvent then
			frame.scripts.OnEvent(frame, event, ...)
		end
	end
end

stub.frames = {}

_G.CreateFrame = function(frameType, name)
	local frame = setmetatable({
		frameType = frameType,
		name = name,
		events = {},
		scripts = {},
		shown = false,
	}, frameProto)
	table.insert(stub.frames, frame)
	return frame
end

--------------------------------------------------------------------------------
-- Chat et erreurs
--------------------------------------------------------------------------------

stub.messages = {}
stub.errors = {}

_G.DEFAULT_CHAT_FRAME = {
	AddMessage = function(_, text) table.insert(stub.messages, text) end,
}

_G.geterrorhandler = function()
	return function(err)
		table.insert(stub.errors, err)
	end
end

--------------------------------------------------------------------------------
-- Joueur
--------------------------------------------------------------------------------

stub.player = {
	name = "Krayne",
	realm = "Hyjal",
	class = "DRUID",
	classLocalized = "Druide",
	faction = "Alliance",
	level = 80,
}

_G.UnitName = function(unit) return unit == "player" and stub.player.name or nil end
_G.UnitClass = function() return stub.player.classLocalized, stub.player.class end
_G.UnitFactionGroup = function() return stub.player.faction end
_G.UnitLevel = function() return stub.player.level end
_G.GetNormalizedRealmName = function() return stub.player.realm end
_G.GetRealmName = function() return stub.player.realm end
_G.GetLocale = function() return stub.locale or "enUS" end
_G.GetBuildInfo = function() return "12.0.7", "68974", "2026-08-03", 120007 end

_G.C_AddOns = {
	GetAddOnMetadata = function(_, field)
		if field == "Version" then return "0.1.0-test" end
		return nil
	end,
	LoadAddOn = function() return true end,
}

--------------------------------------------------------------------------------
-- Journal des montures
--
-- Fixture : liste d'entrées { mountID, name, sourceType, isCollected,
-- shouldHideOnChar, faction, source }.
--------------------------------------------------------------------------------

stub.mounts = {}

_G.C_MountJournal = {
	GetMountIDs = function()
		local ids = {}
		for _, mount in ipairs(stub.mounts) do
			table.insert(ids, mount.mountID)
		end
		return ids
	end,

	GetMountInfoByID = function(mountID)
		for _, mount in ipairs(stub.mounts) do
			if mount.mountID == mountID then
				return mount.name, mount.spellID or 0, mount.icon or 0,
					false, true, mount.sourceType or 1, false,
					mount.isFactionSpecific or false, mount.faction,
					mount.shouldHideOnChar or false,
					mount.isCollected or false, mountID, false
			end
		end
		return nil
	end,

	-- 1 creatureDisplayInfoID  2 description  3 source  4 isSelfMount
	-- 5 mountTypeID  6 uiModelSceneID  7 animID  8 spellVisualKitID
	-- 9 disablePlayerMountPreview
	GetMountInfoExtraByID = function(mountID)
		for _, mount in ipairs(stub.mounts) do
			if mount.mountID == mountID then
				return nil, mount.description or "", mount.source or "", false,
					mount.mountTypeID or 230, 0, 0, 0, false
			end
		end
		return nil
	end,

	GetMountFromItem = function(itemID)
		for _, mount in ipairs(stub.mounts) do
			if mount.itemID == itemID then return mount.mountID end
		end
		return nil
	end,

	GetNumMounts = function() return #stub.mounts end,
}

-- Libellés de catégorie de source, tels que les expose le client.
--
-- La liste est COMPLÈTE exprès. Cinq de ces catégories (promotion, JCC,
-- boutique, découverte, comptoir) partagent le même `kind` interne, parce
-- qu'aucune ne porte de verrou — et c'est précisément là que l'affichage s'est
-- déjà trompé en les fusionnant. Sans leurs libellés ici, le test ne vérifiait
-- que la moitié du problème : les seaux se séparaient, mais tous sous
-- l'étiquette « Autres ».
_G.BATTLE_PET_SOURCE_1 = "Drop"
_G.BATTLE_PET_SOURCE_2 = "Quest"
_G.BATTLE_PET_SOURCE_3 = "Vendor"
_G.BATTLE_PET_SOURCE_4 = "Profession"
_G.BATTLE_PET_SOURCE_5 = "Pet Battle"
_G.BATTLE_PET_SOURCE_6 = "Achievement"
_G.BATTLE_PET_SOURCE_7 = "World Event"
_G.BATTLE_PET_SOURCE_8 = "Promotion"
_G.BATTLE_PET_SOURCE_9 = "Trading Card Game"
_G.BATTLE_PET_SOURCE_10 = "In-Game Store"
_G.BATTLE_PET_SOURCE_11 = "Discovery"
_G.BATTLE_PET_SOURCE_12 = "Trading Post"

--------------------------------------------------------------------------------
-- Journal des rencontres — paliers et instances
--
-- Fixture : stub.tiers = { { name = "Wrath",
--                            instances = { { id = 187, name = "Ulduar", isRaid = true } } } }
--------------------------------------------------------------------------------

stub.tiers = {}
stub.selectedTier = 1

_G.EJ_GetNumTiers = function() return #stub.tiers end
_G.EJ_SelectTier = function(tier) stub.selectedTier = tier end
_G.EJ_GetTierInfo = function(tier)
	local entry = stub.tiers[tier]
	return entry and entry.name or nil
end

_G.EJ_GetInstanceByIndex = function(index, isRaid)
	local tier = stub.tiers[stub.selectedTier]
	if not tier then return nil end
	local matching = {}
	for _, instance in ipairs(tier.instances or {}) do
		if (instance.isRaid and true or false) == (isRaid and true or false) then
			matching[#matching + 1] = instance
		end
	end
	local instance = matching[index]
	if not instance then return nil end
	return instance.id, instance.name
end

--------------------------------------------------------------------------------
-- Recherche de groupe : la seconde source d'extension
--
-- Fixture : stub.lfgDungeons[dungeonID] = { name, subtypeID, expansionLevel }
--------------------------------------------------------------------------------

stub.lfgDungeons = {}

_G.GetLFGDungeonInfo = function(dungeonID)
	local entry = stub.lfgDungeons[dungeonID]
	if not entry then return nil end
	-- name, typeID, subtypeID, minLevel, maxLevel, recLevel, minRecLevel,
	-- maxRecLevel, expansionLevel, …
	return entry.name, entry.typeID or 1, entry.subtypeID or 1,
		0, 0, 0, 0, 0, entry.expansionLevel or 0
end

-- Libellés d'extension du client, tels que les expose _G["EXPANSION_NAME"..n].
_G.EXPANSION_NAME0 = "Classic"
_G.EXPANSION_NAME1 = "The Burning Crusade"
_G.EXPANSION_NAME2 = "Wrath of the Lich King"
_G.EXPANSION_NAME3 = "Cataclysm"
_G.EXPANSION_NAME6 = "Legion"

_G.EJ_SelectInstance = function(id) stub.selectedInstance = id end
_G.EJ_SelectEncounter = function(id) stub.selectedEncounter = id end
_G.EJ_GetEncounterInfoByIndex = function() return nil end

--------------------------------------------------------------------------------
-- Verrous d'instance
--
-- Fixture : liste de tables décrivant chaque verrou sauvegardé.
--------------------------------------------------------------------------------

stub.savedInstances = {}

_G.RequestRaidInfo = function()
	-- Asynchrone en jeu ; ici on répond au tour suivant, comme le serveur.
	table.insert(stub.timers, {
		at = stub.gameTime,
		callback = function() stub.Fire("UPDATE_INSTANCE_INFO") end,
	})
end

_G.GetNumSavedInstances = function() return #stub.savedInstances end

_G.GetSavedInstanceInfo = function(index)
	local lock = stub.savedInstances[index]
	if not lock then return nil end
	return lock.name, lock.lockoutID or 0, lock.reset or 0, lock.difficultyID or 14,
		lock.locked ~= false, lock.extended or false, 0, lock.isRaid ~= false,
		lock.maxPlayers or 25, lock.difficultyName or "Normal",
		lock.numEncounters or 0, lock.encounterProgress or 0, false, lock.instanceID
end

_G.GetSavedInstanceEncounterInfo = function(instanceIndex, encounterIndex)
	local lock = stub.savedInstances[instanceIndex]
	if not lock or not lock.bosses then return nil end
	local boss = lock.bosses[encounterIndex]
	if not boss then return nil end
	return boss.name, 0, boss.isKilled or false, false
end

_G.GetNumSavedWorldBosses = function() return 0 end

--------------------------------------------------------------------------------
-- Instance courante
--------------------------------------------------------------------------------

stub.currentInstance = nil   -- { name, instanceType, difficultyID, instanceID }

_G.IsInInstance = function()
	if not stub.currentInstance then return false, "none" end
	return true, stub.currentInstance.instanceType or "party"
end

_G.GetInstanceInfo = function()
	local inst = stub.currentInstance
	if not inst then
		return "Azeroth", "none", 0, "", 0, 0, false, 0, 0, nil, false
	end
	return inst.name, inst.instanceType or "party", inst.difficultyID or 1, "Normal",
		5, 0, false, inst.instanceID, 5, nil, false
end

--------------------------------------------------------------------------------
-- Cartes et coordonnées monde
--
-- Fixture : `stub.maps[uiMapID] = { continentID, originX, originY, spanX, spanY }`.
-- La projection carte -> monde est affine et volontairement triviale : ce qui
-- se teste ici, c'est que le routeur refuse de comparer deux continents, pas
-- la géométrie d'Azeroth.
--------------------------------------------------------------------------------

stub.maps = {}
stub.playerMap = nil        -- { uiMapID, x, y }

_G.C_Map = {
	GetBestMapForUnit = function() return stub.playerMap and stub.playerMap.uiMapID or nil end,

	GetPlayerMapPosition = function()
		if not stub.playerMap then return nil end
		return { x = stub.playerMap.x, y = stub.playerMap.y }
	end,

	GetWorldPosFromMapPos = function(uiMapID, position)
		local map = stub.maps[uiMapID]
		if not map then return nil end
		return map.continentID, {
			x = map.originX + position.x * map.spanX,
			y = map.originY + position.y * map.spanY,
		}
	end,

	GetMapChildrenInfo = function()
		local list = {}
		for uiMapID in pairs(stub.maps) do
			table.insert(list, { mapID = uiMapID })
		end
		table.sort(list, function(a, b) return a.mapID < b.mapID end)
		return list
	end,

	GetMapInfo = function(uiMapID)
		local map = stub.maps[uiMapID]
		if not map then return nil end
		return { mapID = uiMapID, name = map.name or ("Carte " .. tostring(uiMapID)) }
	end,

	CanSetUserWaypointOnMap = function(uiMapID) return stub.maps[uiMapID] ~= nil end,
	SetUserWaypoint = function(point) stub.waypoint = point end,
	ClearUserWaypoint = function() stub.waypoint = nil end,
}

_G.UiMapPoint = {
	CreateFromCoordinates = function(uiMapID, x, y)
		return { uiMapID = uiMapID, position = { x = x, y = y } }
	end,
}

_G.C_SuperTrack = {
	SetSuperTrackedUserWaypoint = function(on) stub.superTracked = on and true or false end,
}

--------------------------------------------------------------------------------
-- Grimoire, jouets, cooldowns
--------------------------------------------------------------------------------

stub.spells = {}      -- { { spellID, name, castTime, passive } }
stub.toys = {}        -- { { itemID, name } }
stub.cooldowns = {}   -- [spellID] = { startTime, duration }

_G.Enum = { SpellBookSpellBank = { Player = 0 } }

_G.C_SpellBook = {
	GetNumSpellBookSkillLines = function() return 1 end,

	GetSpellBookSkillLineInfo = function()
		return { name = "Général", itemIndexOffset = 0, numSpellBookItems = #stub.spells }
	end,

	GetSpellBookItemInfo = function(index)
		local spell = stub.spells[index]
		if not spell then return nil end
		return {
			spellID = spell.spellID,
			name = spell.name,
			isPassive = spell.passive or false,
		}
	end,

	IsSpellKnown = function(spellID)
		for _, spell in ipairs(stub.spells) do
			if spell.spellID == spellID then return true end
		end
		return false
	end,
}

_G.C_Spell = {
	GetSpellInfo = function(spellID)
		for _, spell in ipairs(stub.spells) do
			if spell.spellID == spellID then
				return { name = spell.name, castTime = spell.castTime or 0, spellID = spellID }
			end
		end
		return nil
	end,

	GetSpellCooldown = function(spellID)
		local cd = stub.cooldowns[spellID]
		if not cd then return { startTime = 0, duration = 0, isEnabled = true } end
		-- `secret = true` simule les valeurs secrètes de la 12.0 : le champ
		-- existe mais n'est pas un nombre, donc inutilisable en arithmétique.
		if cd.secret then
			return { startTime = "secret", duration = "secret", isEnabled = true }
		end
		return { startTime = cd.startTime, duration = cd.duration, isEnabled = true }
	end,
}

_G.C_ToyBox = {
	GetNumToys = function() return #stub.toys end,
	GetToyFromIndex = function(index)
		local toy = stub.toys[index]
		return toy and toy.itemID or nil
	end,
	GetToyInfo = function(itemID)
		for _, toy in ipairs(stub.toys) do
			if toy.itemID == itemID then return itemID, toy.name end
		end
		return nil
	end,
}

_G.PlayerHasToy = function(itemID)
	for _, toy in ipairs(stub.toys) do
		if toy.itemID == itemID then return true end
	end
	return false
end

_G.InCombatLockdown = function() return stub.inCombat == true end

--------------------------------------------------------------------------------
-- Objets
--
-- Fixture : stub.items[itemID] = { name, expansionID }. Seul expansionID nous
-- intéresse : c'est le 15e retour de C_Item.GetItemInfo, et la seule source
-- EXACTE d'extension pour une monture.
--------------------------------------------------------------------------------

stub.items = {}

_G.C_Item = {
	GetItemInfo = function(itemID)
		local item = stub.items[itemID]
		if not item then return nil end
		return item.name or "Objet", "|Hitem:" .. itemID .. "|h", 4, 0, 0,
			"Divers", "Monture", 1, "", 0, 0, 15, 5, 1,
			item.expansionID, nil, false, ""
	end,

	RequestLoadItemDataByID = function() end,
	GetItemCount = function() return 0 end,
}

--------------------------------------------------------------------------------
-- Horloges de reset
--------------------------------------------------------------------------------

-- Les resets sont stockés comme des dates absolues, pas comme des compteurs :
-- sinon avancer l'horloge ne franchit jamais la frontière, et un test de reset
-- passerait au vert sans rien prouver. Le client, lui, décompte réellement.
stub.dailyResetAt = stub.now + 3600
stub.weeklyResetAt = stub.now + 3 * 86400

--- Décompte restant, en faisant rouler la date de reset comme le fait le
--  serveur une fois l'échéance franchie. `period` nil = pas de roulement,
--  ce qui simule une API muette.
local function CountdownTo(field, period)
	local remaining = stub[field] - stub.now
	if remaining > 0 then return remaining end
	if not period then return 0 end
	while stub[field] <= stub.now do
		stub[field] = stub[field] + period
	end
	return stub[field] - stub.now
end

_G.C_DateAndTime = {
	GetSecondsUntilDailyReset = function()
		return CountdownTo("dailyResetAt", stub.dailyResetPeriod)
	end,
	GetSecondsUntilWeeklyReset = function()
		return CountdownTo("weeklyResetAt", stub.weeklyResetPeriod)
	end,
}

--------------------------------------------------------------------------------
-- Divers
--------------------------------------------------------------------------------

_G.SlashCmdList = {}
_G.UISpecialFrames = {}
_G.tinsert = table.insert
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

function stub.Reset()
	stub.now = 1700000000
	stub.gameTime = 1000.0
	stub.timers = {}
	stub.frames = {}
	stub.messages = {}
	stub.errors = {}
	stub.mounts = {}
	stub.savedInstances = {}
	stub.currentInstance = nil
	stub.maps = {}
	stub.playerMap = nil
	stub.spells = {}
	stub.toys = {}
	stub.cooldowns = {}
	stub.waypoint = nil
	stub.superTracked = nil
	stub.inCombat = false
	stub.tiers = {}
	stub.selectedTier = 1
	stub.selectedInstance = nil
	stub.selectedEncounter = nil
	stub.lfgDungeons = {}
	stub.items = {}
	stub.profileClock = 0
	stub.dailyResetAt = stub.now + 3600
	stub.weeklyResetAt = stub.now + 3 * 86400
	stub.dailyResetPeriod = 86400
	stub.weeklyResetPeriod = 7 * 86400
	_G.OnlyFarmDB = nil
	_G.OnlyFarmScanDB = nil
end

return stub
