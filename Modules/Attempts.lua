--[[---------------------------------------------------------------------------
	OnlyFarm — Modules/Attempts.lua

	Journal des tentatives : combien de fois ce boss a été tué en visant cette
	monture, et depuis quand.

	Pourquoi ça existe : sans ce compteur, faire un raid entier ne change RIEN à
	l'écran. Le verrou passe à « verrouillé », et c'est tout. Le joueur a
	l'impression que l'addon n'a pas vu ce qu'il vient de faire — et il a
	raison, parce qu'il ne le voyait effectivement pas.

	Le pont vers les montures se fait par le NOM localisé de la rencontre.
	`ENCOUNTER_END` renvoie un `encounterID` qui est un DungeonEncounterID, pas
	le `journalEncounterID` du Journal des rencontres : les deux ne se
	rapprochent par aucune API. Le nom, lui, vient du même client des deux
	côtés, donc de la même locale. C'est exactement le contournement déjà
	retenu pour le pont instance <-> verrou, et il se corrige tout seul à
	l'usage.

	Repli assumé : `ENCOUNTER_END` est fiable en instance solo legacy, mais
	« fiable » n'est pas « garanti ». D'où le +1 manuel (Maj+clic sur une ligne)
	plutôt qu'un blocage si l'automatique rate.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Attempts = ns:NewModule("Attempts", 35)

-- ENCOUNTER_END et BOSS_KILL décrivent souvent le même kill. On ignore le
-- second signal reçu pour une même rencontre dans cette fenêtre.
local DEDUPE_WINDOW = 60

function Attempts:OnInitialize()
	self.recent = {}      -- [nom normalisé] = horodatage du dernier comptage
	self.byEncounter = nil
end

function Attempts:OnEnable()
	self:RegisterEvent("ENCOUNTER_END", "OnEncounterEnd")
	self:RegisterEvent("BOSS_KILL", "OnBossKill")
	self:RegisterEvent("NEW_MOUNT_ADDED", "OnMountAdded")
	self:RegisterMessage("OF_SCAN_COMPLETE", "Invalidate")
end

function Attempts:Invalidate()
	self.byEncounter = nil
end

--------------------------------------------------------------------------------
-- Index rencontre -> montures
--------------------------------------------------------------------------------

--- Index « nom de rencontre normalisé » -> liste de mountID.
function Attempts:BuildIndex()
	local index = {}
	if not ns.db then return index end

	for mountID, source in pairs(ns.db.global.sourceCache) do
		local key = ns.Util.NormalizeName(source.encounterName)
		if key then
			index[key] = index[key] or {}
			table.insert(index[key], mountID)
		end
	end

	self.byEncounter = index
	return index
end

function Attempts:GetMountsForEncounter(encounterName)
	local key = ns.Util.NormalizeName(encounterName)
	if not key then return nil end
	if not self.byEncounter then self:BuildIndex() end
	return self.byEncounter[key]
end

--------------------------------------------------------------------------------
-- Comptage
--------------------------------------------------------------------------------

--- Un kill réussi vaut une tentative pour chaque monture encore manquante que
--  cette rencontre peut lâcher. Une monture déjà possédée ne compte pas : le
--  journal sert à mesurer une attente, pas une fréquentation.
function Attempts:RecordKill(encounterName, difficultyID)
	if not encounterName or not ns.db then return 0 end

	local key = ns.Util.NormalizeName(encounterName)
	local now = time()
	if self.recent[key] and (now - self.recent[key]) < DEDUPE_WINDOW then
		self:Debug("kill déjà compté : %s", tostring(encounterName))
		return 0
	end
	self.recent[key] = now

	local mountIDs = self:GetMountsForEncounter(encounterName)
	if not mountIDs then
		self:Debug("rencontre sans monture cartographiée : %s", tostring(encounterName))
		return 0
	end

	local counted = 0
	for _, mountID in ipairs(mountIDs) do
		if not ns.Collection:IsOwned(mountID) then
			self:Bump(mountID, difficultyID)
			counted = counted + 1
		end
	end

	if counted > 0 then
		self:Debug("%d tentative(s) enregistrée(s) sur %s", counted, tostring(encounterName))
		self:SendMessage("OF_ATTEMPTS_UPDATED")
	end
	return counted
end

--- Incrémente le compteur d'une monture.
function Attempts:Bump(mountID, difficultyID, delta)
	if not ns.db then return nil end
	delta = delta or 1

	local store = ns.db.global.attempts
	local entry = store[mountID]
	if type(entry) ~= "table" then
		entry = { count = 0, byChar = {} }
		store[mountID] = entry
	end

	entry.count = math.max(0, (entry.count or 0) + delta)
	entry.lastAt = time()
	entry.lastDifficulty = difficultyID

	local charKey = ns.db.charKey
	if charKey then
		entry.lastChar = charKey
		entry.byChar[charKey] = math.max(0, (entry.byChar[charKey] or 0) + delta)
	end

	return entry
end

function Attempts:OnEncounterEnd(_, _, encounterName, difficultyID, _, success)
	if success ~= 1 and success ~= true then return end
	self:RecordKill(encounterName, difficultyID)
end

--- BOSS_KILL ne donne pas la difficulté ; on la prend de l'instance courante.
function Attempts:OnBossKill(_, _, encounterName)
	local difficultyID = select(3, GetInstanceInfo())
	self:RecordKill(encounterName, difficultyID)
end

--- La monture est tombée : on fige le compte, il devient l'histoire de cette
--  monture au lieu d'un compteur qui continuerait de courir.
function Attempts:OnMountAdded(_, mountID)
	if not ns.db or not mountID then return end
	local entry = ns.db.global.attempts[mountID]
	if type(entry) ~= "table" then return end
	entry.obtainedAt = time()
	self:SendMessage("OF_ATTEMPTS_UPDATED")
end

--------------------------------------------------------------------------------
-- Interrogation
--------------------------------------------------------------------------------

function Attempts:Get(mountID)
	if not ns.db then return nil end
	return ns.db.global.attempts[mountID]
end

function Attempts:GetCount(mountID)
	local entry = self:Get(mountID)
	return entry and entry.count or 0
end

--- Probabilité cumulée de n'avoir TOUJOURS rien après `count` tentatives.
--  Renvoie nil si le taux de drop est inconnu — et il l'est presque toujours
--  pour l'instant. Afficher une probabilité calculée sur un taux inventé
--  serait précisément le genre de mensonge tranquille que ce dépôt refuse.
function Attempts:GetDryChance(mountID)
	local source = ns.Eligibility:GetSource(mountID)
	local rate = source and tonumber(source.dropRate)
	if not rate or rate <= 0 or rate > 1 then return nil end
	local count = self:GetCount(mountID)
	if count <= 0 then return 1 end
	return (1 - rate) ^ count
end

--- Total de tentatives, tous personnages confondus, pour l'entête.
function Attempts:GetTotals()
	if not ns.db then return 0, 0 end
	local mounts, total = 0, 0
	for _, entry in pairs(ns.db.global.attempts) do
		if type(entry) == "table" and (entry.count or 0) > 0 and not entry.obtainedAt then
			mounts = mounts + 1
			total = total + entry.count
		end
	end
	return total, mounts
end

function Attempts:Reset(mountID)
	if not ns.db then return end
	ns.db.global.attempts[mountID] = nil
	self:SendMessage("OF_ATTEMPTS_UPDATED")
end
