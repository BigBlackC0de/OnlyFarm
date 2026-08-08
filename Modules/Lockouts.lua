--[[---------------------------------------------------------------------------
	OptiFarm — Modules/Lockouts.lua

	Verrous d'instance, agrégés sur tout le compte.

	Trois vérités à garder en tête :
	  1. Les montures sont account-wide, les verrous sont par personnage.
	     C'est là que se trouve le gain de temps réel : un raid déjà fait sur
	     le main reste disponible sur les alts.
	  2. Le verrou n'existe pas avant le premier kill. Une instance absente de
	     GetSavedInstanceInfo est donc *disponible*, pas « inconnue ».
	  3. On ne peut pas lire les verrous des autres personnages. Il faut s'y
	     connecter une fois pour que leur état atterrisse dans les
	     SavedVariables account-wide.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Lockouts = ns:NewModule("Lockouts", 30)

-- Retours de GetSavedInstanceInfo(index) :
--  1 name           2 lockoutID       3 reset (secondes restantes)
--  4 difficultyID   5 locked          6 extended
--  7 instanceIDMostSig                8 isRaid
--  9 maxPlayers    10 difficultyName 11 numEncounters
-- 12 encounterProgress               13 extendDisabled
-- 14 instanceID (identifiant moteur, celui de GetInstanceInfo)
--
-- Les positions 1-10 et 13-14 sont confirmées par le code de Blizzard
-- (Blizzard_RaidFrame/Mainline/RaidFrame.lua). 11 et 12 viennent de la
-- documentation communautaire : on valide leur type avant de s'en servir.

local REQUEST_THROTTLE = 10

function Lockouts:OnInitialize()
	self.lastRequest = 0
	self.currentInstanceID = nil
end

function Lockouts:OnEnable()
	self:RegisterEvent("UPDATE_INSTANCE_INFO", "OnInstanceInfo")
	self:RegisterEvent("BOSS_KILL", "RequestScan")
	self:RegisterEvent("ENCOUNTER_END", "OnEncounterEnd")
	self:RegisterMessage("OF_ENTERING_WORLD", "OnEnteringWorld")

	self:PurgeExpired()
	self:RequestScan()
end

--------------------------------------------------------------------------------
-- Demande de rafraîchissement
--------------------------------------------------------------------------------

--- RequestRaidInfo() est asynchrone : la réponse arrive sur UPDATE_INSTANCE_INFO.
--  On limite le débit, l'appel n'est pas gratuit côté serveur.
function Lockouts:RequestScan()
	local now = GetTime and GetTime() or time()
	if now - self.lastRequest < REQUEST_THROTTLE then return false end
	self.lastRequest = now
	if RequestRaidInfo then RequestRaidInfo() end
	return true
end

function Lockouts:OnEncounterEnd(_, _, _, _, _, success)
	if success == 1 or success == true then
		-- Le verrou n'est écrit qu'après le kill : on laisse le serveur souffler.
		C_Timer.After(2, function() self:RequestScan() end)
	end
end

function Lockouts:OnEnteringWorld()
	self:RecordInstanceEntry()
	self:RequestScan()
end

--------------------------------------------------------------------------------
-- Lecture des verrous
--------------------------------------------------------------------------------

local function LockKey(instanceID, difficultyID, name)
	if type(instanceID) == "number" and instanceID > 0 then
		return instanceID .. ":" .. tostring(difficultyID or 0)
	end
	-- Repli si l'identifiant moteur n'est pas exposé : la clé par nom reste
	-- utilisable dans la même locale, ce qui est toujours le cas ici.
	return "name:" .. tostring(ns.Util.NormalizeName(name)) .. ":" .. tostring(difficultyID or 0)
end
Lockouts.LockKey = LockKey

function Lockouts:OnInstanceInfo()
	if not ns.db or not ns.db.char then return end

	local store = {}
	local now = time()
	local count = GetNumSavedInstances and GetNumSavedInstances() or 0

	for i = 1, count do
		local name, lockoutID, reset, difficultyID, locked, extended,
			_, isRaid, maxPlayers, difficultyName, numEncounters,
			encounterProgress, _, instanceID = GetSavedInstanceInfo(i)

		-- `locked` faux avec `extended` faux = verrou expiré que le client
		-- garde affiché ; il ne bloque plus rien.
		if name and (locked or extended) then
			if type(numEncounters) ~= "number" then numEncounters = 0 end
			if type(encounterProgress) ~= "number" then encounterProgress = 0 end
			if type(instanceID) ~= "number" then instanceID = nil end

			local entry = {
				name = name,
				lockoutID = lockoutID,
				instanceID = instanceID,
				difficultyID = difficultyID,
				difficultyName = difficultyName,
				isRaid = isRaid and true or false,
				maxPlayers = maxPlayers,
				expires = now + (tonumber(reset) or 0),
				numEncounters = numEncounters,
				encounterProgress = encounterProgress,
				bosses = self:ReadEncounters(i, numEncounters),
			}
			store[LockKey(instanceID, difficultyID, name)] = entry
			self:LearnInstanceID(name, instanceID)
		end
	end

	ns.db.char.lockouts = store
	ns.db.char.lockoutsUpdated = now
	ns.db.char.lastSeen = now

	self:Debug("verrous : %d instance(s) verrouillée(s)", ns.Util.Count(store))
	self:SendMessage("OF_LOCKOUTS_UPDATED")
end

--- Détail boss par boss. GetSavedInstanceEncounterInfo n'apparaît ni dans la
--  documentation générée ni dans l'interface de Blizzard : on la teste avant
--  de l'appeler et on se rabat sur `encounterProgress` si elle a disparu.
function Lockouts:ReadEncounters(instanceIndex, numEncounters)
	if numEncounters <= 0 then return nil end
	if type(GetSavedInstanceEncounterInfo) ~= "function" then return nil end

	local bosses = nil
	for e = 1, numEncounters do
		local ok, bossName, _, isKilled = pcall(GetSavedInstanceEncounterInfo, instanceIndex, e)
		if ok and bossName then
			bosses = bosses or {}
			bosses[bossName] = isKilled and true or false
		end
	end
	return bosses
end

--------------------------------------------------------------------------------
-- Pont nom d'instance <-> instanceID moteur
--
-- Le Journal des rencontres parle en journalInstanceID, les verrous en
-- instanceID moteur, et rien n'expose la correspondance. On l'apprend à
-- l'usage, par le nom localisé : les deux côtés viennent du même client.
--------------------------------------------------------------------------------

function Lockouts:LearnInstanceID(name, instanceID)
	if not ns.db or type(instanceID) ~= "number" then return end
	local key = ns.Util.NormalizeName(name)
	if not key then return end
	ns.db.global.instanceIDsByName[key] = instanceID
end

function Lockouts:GetInstanceIDByName(name)
	if not ns.db then return nil end
	local key = ns.Util.NormalizeName(name)
	return key and ns.db.global.instanceIDsByName[key] or nil
end

--------------------------------------------------------------------------------
-- Entrées d'instance (donjons legacy et compteur de cap)
--
-- Les donjons legacy n'apparaissent quasiment jamais dans les verrous
-- sauvegardés : leur reset est quotidien et court. On suit donc nos propres
-- entrées et on les compare à la frontière de reset du royaume.
--
-- Limite assumée : « je suis entré » n'est pas « j'ai tué le boss ». C'est une
-- heuristique, et l'interface doit le dire.
--------------------------------------------------------------------------------

function Lockouts:RecordInstanceEntry()
	if not ns.db or not ns.db.char then return end
	if not IsInInstance or not IsInInstance() then
		self.currentInstanceID = nil
		return
	end

	local name, instanceType, difficultyID, _, _, _, _, instanceID = GetInstanceInfo()
	if type(instanceID) ~= "number" then return end
	if self.currentInstanceID == instanceID then return end
	self.currentInstanceID = instanceID

	self:LearnInstanceID(name, instanceID)

	local entries = ns.db.char.dungeonEntries
	entries[instanceID] = {
		at = time(),
		name = name,
		instanceType = instanceType,
		difficultyID = difficultyID,
	}

	local history = ns.db.char.entryHistory or {}
	history[#history + 1] = time()
	-- On ne garde que 24 h : c'est tout ce dont le compteur de cap a besoin.
	local cutoff = time() - 86400
	local trimmed = {}
	for i = 1, #history do
		if history[i] >= cutoff then trimmed[#trimmed + 1] = history[i] end
	end
	ns.db.char.entryHistory = trimmed

	self:Debug("entrée instance : %s (%d)", tostring(name), instanceID)
	self:SendMessage("OF_INSTANCE_ENTERED", instanceID)
end

--- Compteur de cap d'instances : 10 par heure, 30 par jour.
--  @return utiliséesHeure, utiliséesJour
function Lockouts:GetInstanceCounts()
	if not ns.db or not ns.db.char then return 0, 0 end
	local history = ns.db.char.entryHistory or {}
	local now = time()
	local hour, day = 0, 0
	for i = 1, #history do
		local at = history[i]
		if now - at < 3600 then hour = hour + 1 end
		if now - at < 86400 then day = day + 1 end
	end
	return hour, day
end

--------------------------------------------------------------------------------
-- Interrogation
--------------------------------------------------------------------------------

--- Verrou d'un personnage sur une instance.
--  @return entrée de verrou, ou nil si aucun verrou (= disponible).
function Lockouts:GetLock(charKey, instanceID, difficultyID)
	local charEntry = ns.Database:GetChar(charKey)
	if not charEntry or not charEntry.lockouts then return nil end
	local now = time()

	for _, lock in pairs(charEntry.lockouts) do
		if lock.instanceID == instanceID
			and (difficultyID == nil or lock.difficultyID == difficultyID)
			and (lock.expires or 0) > now
		then
			return lock
		end
	end
	return nil
end

--- Entré dans ce donjon depuis le dernier reset quotidien ?
--  @return true / false / nil (frontière de reset inconnue)
function Lockouts:HasEnteredToday(charKey, instanceID)
	local charEntry = ns.Database:GetChar(charKey)
	if not charEntry or not charEntry.dungeonEntries then return false end
	local entry = charEntry.dungeonEntries[instanceID]
	if not entry then return false end
	return ns.Util.IsSinceDailyReset(entry.at)
end

--- Nettoie les verrous expirés de tous les personnages. Sans ça, la base
--  accumule des verrous morts qui font croire à des blocages inexistants.
function Lockouts:PurgeExpired()
	if not ns.db then return 0 end
	local now = time()
	local removed = 0
	for _, charEntry in pairs(ns.db.global.chars) do
		if type(charEntry.lockouts) == "table" then
			for key, lock in pairs(charEntry.lockouts) do
				if (lock.expires or 0) <= now then
					charEntry.lockouts[key] = nil
					removed = removed + 1
				end
			end
		end
	end
	if removed > 0 then self:Debug("%d verrou(s) expiré(s) purgé(s)", removed) end
	return removed
end
