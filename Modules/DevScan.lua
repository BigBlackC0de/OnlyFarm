--[[---------------------------------------------------------------------------
	OnlyFarm — Modules/DevScan.lua

	Moissonneuse du Journal des rencontres : parcourt palier -> instance ->
	boss -> butin, garde ce qui est une monture, et écrit le résultat dans
	`OnlyFarmScanDB` (dump pour Build/generate_data.py) et dans
	`db.global.sourceCache` (utilisable immédiatement par Eligibility).

	C'est la brique qui débloque la phase 2 : Data/Mounts.lua ne peut pas être
	produit hors du jeu. Il faut d'abord ce scan, en jeu, sur un client à jour.

	Correction par rapport au document de spécification : sur 12.0.7,
	C_EncounterJournal.GetLootInfoByIndex renvoie une TABLE (EncounterJournalItemInfo)
	qui ne contient ni classID ni subClassID. Le filtre « classID == 15 and
	subClassID == 5 » n'est donc pas applicable tel quel. On passe directement
	par C_MountJournal.GetMountFromItem(itemID), qui est à la fois plus court
	et plus fiable.

	Effets de bord : le scan manipule l'état de l'interface du Journal des
	rencontres (palier, instance et boss sélectionnés). On restaure ce qu'on
	peut à la fin, mais mieux vaut le lancer Journal fermé.

	Le nom « DevScan » est un reste de la phase 1, où ce scan était un outil de
	développement lancé à la main. Ce n'en est plus un : sans lui, l'addon ne
	sait ni à quelle extension appartient une monture, ni où se trouve l'entrée
	d'une instance. Il tourne donc TOUT SEUL à la première connexion, et de
	nouveau après chaque changement de build du client — un joueur n'a pas à
	connaître une commande pour que le filtre par extension soit rempli.
-----------------------------------------------------------------------------]]

local _, ns = ...

local DevScan = ns:NewModule("DevScan", 60)

local FRAME_BUDGET = 0.006   -- 6 ms par frame, comme le solveur de route
local MAX_LOOT_PER_ENCOUNTER = 200

-- Délai après l'entrée en jeu avant de lancer le scan automatique. Le client
-- charge encore ses données pendant les premières secondes ; se précipiter
-- donne un Journal des rencontres à moitié peuplé, donc un scan à refaire.
local AUTO_SCAN_DELAY = 10
local AUTO_SCAN_RETRY = 30

function DevScan:OnInitialize()
	self.running = false
	self.driver = nil
	self.autoTried = false
end

function DevScan:OnEnable()
	self:RegisterMessage("OF_ENTERING_WORLD", "OnEnteringWorld")
end

function DevScan:OnEnteringWorld()
	if self.autoTried then return end
	self.autoTried = true
	C_Timer.After(AUTO_SCAN_DELAY, function() self:AutoScan() end)
end

--------------------------------------------------------------------------------
-- Scan automatique
--------------------------------------------------------------------------------

--- Le cache est-il périmé ? Un build différent, c'est un patch : des montures
--  ont pu changer de boss, des instances de palier.
function DevScan:IsStale()
	if not ns.db then return false end
	local meta = ns.db.global.scanMeta
	if type(meta) ~= "table" or not meta.at then return true end
	if ns.Util.Count(ns.db.global.sourceCache) == 0 then return true end
	local build = select(2, GetBuildInfo())
	return meta.build ~= build
end

--- Lance le scan si personne ne regarde. On s'abstient en combat et Journal
--  des rencontres ouvert : le scan déplace la sélection de l'interface, et le
--  faire sous le nez du joueur passerait pour un bug.
function DevScan:AutoScan()
	if not ns.db then return false end
	if ns.db.profile.autoScan == false then return false end
	if not self:IsStale() then
		self:Debug("cache de scan à jour, pas de scan automatique")
		return false
	end

	local busy = (InCombatLockdown and InCombatLockdown())
		or (EncounterJournal and EncounterJournal.IsShown and EncounterJournal:IsShown())
	if busy then
		self:Debug("scan automatique reporté (combat ou Journal ouvert)")
		C_Timer.After(AUTO_SCAN_RETRY, function() self:AutoScan() end)
		return false
	end

	self.silent = true
	return self:Start()
end

--------------------------------------------------------------------------------
-- Accès tolérant aux API historiques du Journal des rencontres
--------------------------------------------------------------------------------

local function EJReady()
	return type(EJ_GetNumTiers) == "function"
		and type(EJ_SelectTier) == "function"
		and type(EJ_GetInstanceByIndex) == "function"
		and type(EJ_SelectInstance) == "function"
		and type(EJ_GetEncounterInfoByIndex) == "function"
		and type(EJ_SelectEncounter) == "function"
		and C_EncounterJournal
		and type(C_EncounterJournal.GetLootInfoByIndex) == "function"
end

local function EnsureEJLoaded()
	if EJReady() then return true end
	if C_AddOns and C_AddOns.LoadAddOn then
		pcall(C_AddOns.LoadAddOn, "Blizzard_EncounterJournal")
	end
	return EJReady()
end

local function ClearLootFilters()
	-- Sans ça, le butin listé est filtré par la spé du joueur et on rate des
	-- montures. Les deux API coexistent selon les versions : on tente les deux.
	if C_EncounterJournal and C_EncounterJournal.ResetSlotFilter then
		pcall(C_EncounterJournal.ResetSlotFilter)
	end
	if type(EJ_ResetLootFilter) == "function" then
		pcall(EJ_ResetLootFilter)
	end
	if type(EJ_SetLootFilter) == "function" then
		pcall(EJ_SetLootFilter, 0, 0)
	end
end

--------------------------------------------------------------------------------
-- Parcours
--------------------------------------------------------------------------------

--- Butin d'un boss déjà sélectionné, filtré sur les montures.
--  @return liste de { itemID, mountID, itemName }
local function CollectMountLoot()
	local found = {}
	for index = 1, MAX_LOOT_PER_ENCOUNTER do
		local ok, itemInfo = pcall(C_EncounterJournal.GetLootInfoByIndex, index)
		if not ok or type(itemInfo) ~= "table" or not itemInfo.itemID then
			break
		end
		local mountID = C_MountJournal.GetMountFromItem(itemInfo.itemID)
		if mountID then
			found[#found + 1] = {
				itemID = itemInfo.itemID,
				mountID = mountID,
				itemName = itemInfo.name,
			}
		end
	end
	return found
end

--------------------------------------------------------------------------------
-- Entrées d'instance (géographie de la phase 3)
--
-- C_EncounterJournal.GetDungeonEntrancesForMap est la source qu'utilise la
-- carte du monde pour poser ses icônes d'entrée de donjon. Elle est donc juste
-- par construction, et elle suit les patchs sans qu'on écrive une coordonnée.
--------------------------------------------------------------------------------

-- Carte cosmique : la racine de l'arbre des cartes. Tout descend d'elle.
local COSMIC_MAP_ID = 946
local WORLD_MAP_ID = 947

local function EntrancesReady()
	return C_Map and type(C_Map.GetMapChildrenInfo) == "function"
		and C_EncounterJournal
		and type(C_EncounterJournal.GetDungeonEntrancesForMap) == "function"
end

--- Toutes les cartes descendantes de la racine, entrée cosmique comprise.
local function AllMaps()
	local maps = {}
	for _, rootID in ipairs({ COSMIC_MAP_ID, WORLD_MAP_ID }) do
		local ok, children = pcall(C_Map.GetMapChildrenInfo, rootID, nil, true)
		if ok and type(children) == "table" then
			for _, info in ipairs(children) do
				if info.mapID then maps[info.mapID] = info end
			end
		end
	end
	return maps
end

--- Extrait x, y d'une position, qu'elle soit un Vector2DMixin ou une table nue.
local function ReadPosition(position)
	if type(position) ~= "table" then return nil end
	if type(position.GetXY) == "function" then
		local ok, x, y = pcall(position.GetXY, position)
		if ok then return x, y end
		return nil
	end
	return position.x, position.y
end

--- Moissonne les entrées d'instance de toutes les cartes.
--  @return table [nodeID] = nœud, nombre de nœuds
local function CollectEntrances()
	local nodes = {}
	local count = 0
	if not EntrancesReady() then return nodes, count end

	local since = 0
	for uiMapID in pairs(AllMaps()) do
		local ok, entrances = pcall(C_EncounterJournal.GetDungeonEntrancesForMap, uiMapID)
		if ok and type(entrances) == "table" then
			for _, entrance in ipairs(entrances) do
				local x, y = ReadPosition(entrance.position)
				if type(x) == "number" and type(y) == "number" and entrance.journalInstanceID then
					local nodeID = ns.Data.InstanceNodeID(entrance.journalInstanceID)
					if not nodes[nodeID] then
						local continentID, wx, wy = ns.Nodes:ResolveWorldPos(uiMapID, x, y)
						nodes[nodeID] = {
							nodeID = nodeID,
							name = entrance.name,
							kind = ns.Data.NODE_KINDS.INSTANCE,
							uiMapID = uiMapID,
							x = x,
							y = y,
							continentID = continentID,
							wx = wx,
							wy = wy,
							journalInstanceID = entrance.journalInstanceID,
						}
						count = count + 1
					end
				end
			end
		end

		-- Il y a plus d'un millier de cartes : sans respiration régulière, la
		-- boucle rendrait la main trop tard et le client saccaderait.
		since = since + 1
		if since >= 25 then
			since = 0
			coroutine.yield()
		end
	end

	return nodes, count
end

--- Coroutine principale. `yield` après chaque boss : le client a besoin d'une
--  frame pour répondre à EJ_SelectEncounter, et l'interface ne doit pas geler.
local function ScanRoutine(self)
	local results = {}     -- [mountID] = source
	local instanceCount = 0
	local mountCount = 0

	ClearLootFilters()

	local numTiers = EJ_GetNumTiers()
	for tier = 1, numTiers do
		EJ_SelectTier(tier)
		coroutine.yield()

		-- Nom localisé du palier : c'est l'extension, et c'est la seule source
		-- fiable de cette information. Le Journal des montures ne l'expose pas.
		local tierName
		if type(EJ_GetTierInfo) == "function" then
			local ok, name = pcall(EJ_GetTierInfo, tier)
			if ok then tierName = name end
		end

		for _, isRaid in ipairs({ true, false }) do
			local index = 1
			while true do
				local journalInstanceID, instanceName = EJ_GetInstanceByIndex(index, isRaid)
				if not journalInstanceID then break end

				EJ_SelectInstance(journalInstanceID)
				coroutine.yield()

				instanceCount = instanceCount + 1
				local encounterIndex = 1
				while true do
					local encounterName, _, journalEncounterID =
						EJ_GetEncounterInfoByIndex(encounterIndex, journalInstanceID)
					if not journalEncounterID then break end

					EJ_SelectEncounter(journalEncounterID)
					coroutine.yield()

					for _, loot in ipairs(CollectMountLoot()) do
						if not results[loot.mountID] then
							mountCount = mountCount + 1
						end
						results[loot.mountID] = {
							kind = ns.Data.SOURCE_KINDS.BOSS,
							mountID = loot.mountID,
							itemID = loot.itemID,
							itemName = loot.itemName,
							instanceName = instanceName,
							journalInstanceID = journalInstanceID,
							encounterName = encounterName,
							journalEncounterID = journalEncounterID,
							isRaid = isRaid,
							tier = tier,
							tierName = tierName,
							-- instanceID moteur volontairement absent : il est
							-- résolu à l'exécution par le pont de Lockouts.
						}
					end
					encounterIndex = encounterIndex + 1
				end
				index = index + 1
			end
		end
	end

	local nodes, nodeCount = CollectEntrances()

	-- Un seul retour agrégé : `coroutine.resume` rend les valeurs une à une, et
	-- une signature qui s'allonge à chaque passe ajoutée finit toujours par
	-- perdre un champ en route.
	return {
		sources = results,
		instances = instanceCount,
		mounts = mountCount,
		nodes = nodes,
		nodeCount = nodeCount,
	}
end

--------------------------------------------------------------------------------
-- Pilote
--------------------------------------------------------------------------------

function DevScan:Start()
	local L = ns.L
	if self.running then
		ns:Print(L.SCAN_BUSY)
		return false
	end
	if not EnsureEJLoaded() then
		ns:Print(L.SCAN_NEEDS_EJ)
		return false
	end

	ns:Print(self.silent and L.SCAN_AUTO_START or L.SCAN_START)
	self.running = true
	self.startedAt = time()
	self:SendMessage("OF_SCAN_STARTED")

	local thread = coroutine.create(ScanRoutine)
	local driver = self.driver or CreateFrame("Frame")
	self.driver = driver

	driver:SetScript("OnUpdate", function()
		local deadline = debugprofilestop() + (FRAME_BUDGET * 1000)
		repeat
			local ok, payload = coroutine.resume(thread, self)
			if not ok then
				driver:SetScript("OnUpdate", nil)
				self.running = false
				self.silent = false
				local handler = geterrorhandler and geterrorhandler()
				if handler then handler(payload) end
				return
			end
			if coroutine.status(thread) == "dead" then
				driver:SetScript("OnUpdate", nil)
				self.running = false
				self:Finish(payload)
				return
			end
		until debugprofilestop() >= deadline
	end)
	return true
end

function DevScan:Finish(payload)
	local silent = self.silent
	self.silent = false
	if type(payload) ~= "table" or type(payload.sources) ~= "table" then return end

	if type(OnlyFarmScanDB) ~= "table" then OnlyFarmScanDB = {} end
	OnlyFarmScanDB.sources = payload.sources
	OnlyFarmScanDB.nodes = payload.nodes
	OnlyFarmScanDB.scannedAt = time()
	OnlyFarmScanDB.build = select(2, GetBuildInfo())
	OnlyFarmScanDB.version = select(1, GetBuildInfo())
	OnlyFarmScanDB.locale = GetLocale()
	OnlyFarmScanDB.addonVersion = ns.VERSION

	if ns.db then
		ns.db.global.sourceCache = payload.sources
		-- Les nœuds moissonnés remplacent le cache précédent, mais seulement si
		-- la passe a effectivement trouvé quelque chose : sur un client où
		-- l'API des entrées de donjon a disparu, on garde ce qu'on avait plutôt
		-- que de vider la géographie de l'addon.
		if payload.nodeCount and payload.nodeCount > 0 then
			ns.db.global.nodeCache = payload.nodes
		end
		ns.db.global.scanMeta = {
			at = OnlyFarmScanDB.scannedAt,
			build = OnlyFarmScanDB.build,
			mounts = payload.mounts,
			instances = payload.instances,
			nodes = payload.nodeCount,
		}
	end

	ns:Print(ns.L.SCAN_DONE, payload.mounts or 0, payload.instances or 0, payload.nodeCount or 0)
	if silent then ns:Print(ns.L.SCAN_AUTO_DONE) end
	self:SendMessage("OF_SCAN_COMPLETE")
end
