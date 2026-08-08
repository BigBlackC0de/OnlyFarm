--[[---------------------------------------------------------------------------
	OnlyFarm — Modules/Mapping.lua

	Cartographie des montures : à quelle extension appartient chaque monture,
	dans quelle instance elle tombe, et de quel boss.

	Remplace l'ancien DevScan, qui reposait entièrement sur l'API de butin du
	Journal des rencontres (EJ_SelectEncounter + GetLootInfoByIndex). Cette
	API est la plus fragile de la chaîne : le butin n'est pas prêt à la frame
	suivante, il dépend de la difficulté sélectionnée, et une liste vide est
	indiscernable d'une fin de liste. En jeu, le scan remontait zéro monture et
	tout l'addon restait « source non cartographiée » sans rien dire.

	Le scan tient maintenant en trois passes, de la plus sûre à la plus fine :

	  A. INDEX DES INSTANCES — pour chaque palier du Journal, la liste de ses
	     instances. Aucune sélection de boss, aucun butin : uniquement des noms
	     et des identifiants. C'est ce qui donne l'extension.

	  B. TEXTE DE SOURCE — chaque monture expose déjà, via
	     C_MountJournal.GetMountInfoExtraByID, un texte du genre
	     « Butin : Le roi-liche|nCitadelle de la Couronne de glace ». Il
	     contient le boss ET l'instance. On le découpe et on rapproche le lieu
	     de l'index de la passe A.

	  C. BUTIN (approfondie, à la demande) — l'ancien parcours boss par boss.
	     Il n'apporte plus que de la précision sur les cas que le texte de
	     source décrit mal. Il n'est plus sur le chemin critique, donc son
	     échec ne casse plus rien.

	A et B tournent automatiquement et suffisent. C se déclenche au bouton.

	Le résultat est écrit dans `db.global.sourceCache`, qui vit dans les
	SavedVariables : la cartographie survit à la déconnexion et n'est refaite
	que si le build du client change ou si le nombre de montures bouge.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Mapping = ns:NewModule("Mapping", 60)

local FRAME_BUDGET = 0.006     -- 6 ms par frame
local MOUNTS_PER_SLICE = 150   -- montures traitées entre deux respirations
local MAX_LOOT_PER_ENCOUNTER = 200

-- Délai après l'entrée en jeu avant le scan automatique. Le Journal des
-- montures n'est pas garanti peuplé à PLAYER_LOGIN ; se précipiter donne une
-- cartographie partielle, donc à refaire.
local AUTO_DELAY = 6
local AUTO_RETRY = 20

function Mapping:OnInitialize()
	self.running = false
	self.autoTried = false
	self.instanceIndex = nil
end

function Mapping:OnEnable()
	self:RegisterMessage("OF_ENTERING_WORLD", "OnEnteringWorld")
	-- Une monture apprise ne change pas la cartographie (elle est indexée par
	-- mountID, pas par possession). En revanche un patch qui AJOUTE des
	-- montures, si : on compare le nombre connu à celui du dernier scan.
	self:RegisterMessage("OF_COLLECTION_UPDATED", "OnCollectionUpdated")
end

function Mapping:OnEnteringWorld()
	if self.autoTried then return end
	self.autoTried = true
	C_Timer.After(AUTO_DELAY, function() self:AutoRun() end)
end

function Mapping:OnCollectionUpdated()
	if self.running or not ns.db then return end
	-- Débouncé : NEW_MOUNT_ADDED peut partir en rafale.
	if not self.scheduleCheck then
		self.scheduleCheck = ns.Util.Debounce(5, function()
			if self:IsStale() then self:Run(false) end
		end)
	end
	self.scheduleCheck()
end

--------------------------------------------------------------------------------
-- Fraîcheur
--------------------------------------------------------------------------------

--- La cartographie est-elle à refaire ?
function Mapping:IsStale()
	if not ns.db then return false end
	local meta = ns.db.global.scanMeta
	if type(meta) ~= "table" or not meta.at then return true end
	if ns.Util.Count(ns.db.global.sourceCache) == 0 then return true end

	-- Changement de build = patch : des montures ont pu changer de source.
	if meta.build ~= select(2, GetBuildInfo()) then return true end

	-- Le client a plus de montures qu'au dernier scan : il y a du nouveau à
	-- cartographier, et ça ne coûte qu'une passe rapide.
	local known = C_MountJournal and C_MountJournal.GetMountIDs
		and #(C_MountJournal.GetMountIDs() or {}) or 0
	if known > 0 and (meta.mountsSeen or 0) < known then return true end

	return false
end

function Mapping:AutoRun()
	if not ns.db then return false end
	if ns.db.profile.autoScan == false then return false end
	if not self:IsStale() then
		self:Debug("cartographie à jour, pas de scan automatique")
		return false
	end
	if InCombatLockdown and InCombatLockdown() then
		C_Timer.After(AUTO_RETRY, function() self:AutoRun() end)
		return false
	end

	self.silent = true
	return self:Run(false)
end

--------------------------------------------------------------------------------
-- Accès au Journal des rencontres
--------------------------------------------------------------------------------

local function TiersReady()
	return type(EJ_GetNumTiers) == "function"
		and type(EJ_SelectTier) == "function"
		and type(EJ_GetInstanceByIndex) == "function"
end

local function LootReady()
	return type(EJ_SelectInstance) == "function"
		and type(EJ_GetEncounterInfoByIndex) == "function"
		and type(EJ_SelectEncounter) == "function"
		and C_EncounterJournal
		and type(C_EncounterJournal.GetLootInfoByIndex) == "function"
end

local function EnsureEJLoaded()
	if TiersReady() then return true end
	if C_AddOns and C_AddOns.LoadAddOn then
		pcall(C_AddOns.LoadAddOn, "Blizzard_EncounterJournal")
	end
	return TiersReady()
end

--------------------------------------------------------------------------------
-- Passe A — index des instances
--------------------------------------------------------------------------------

--- Parcourt les paliers et enregistre chaque instance.
--  @return [nom normalisé] = { name, journalInstanceID, tier, tierName, isRaid }
local function BuildInstanceIndex()
	local index = {}
	if not TiersReady() then return index end

	local okTiers, numTiers = pcall(EJ_GetNumTiers)
	if not okTiers or type(numTiers) ~= "number" then return index end

	for tier = 1, numTiers do
		pcall(EJ_SelectTier, tier)
		-- Une frame pour laisser le client appliquer le palier : c'est lui qui
		-- filtre EJ_GetInstanceByIndex.
		coroutine.yield()

		local tierName
		if type(EJ_GetTierInfo) == "function" then
			local ok, name = pcall(EJ_GetTierInfo, tier)
			if ok then tierName = name end
		end

		for _, isRaid in ipairs({ true, false }) do
			local position = 1
			while true do
				local ok, journalInstanceID, instanceName =
					pcall(EJ_GetInstanceByIndex, position, isRaid)
				if not ok or not journalInstanceID then break end

				local key = ns.Util.NormalizeName(instanceName)
				if key and not index[key] then
					index[key] = {
						name = instanceName,
						journalInstanceID = journalInstanceID,
						tier = tier,
						tierName = tierName,
						isRaid = isRaid,
					}
				end
				position = position + 1
			end
		end
	end

	return index
end

--------------------------------------------------------------------------------
-- Passe B — texte de source
--------------------------------------------------------------------------------

local function Trim(text)
	-- Les libellés du client contiennent des espaces insécables (U+00A0, soit
	-- \194\160 en UTF-8) que « %s » ne reconnaît pas.
	text = text:gsub("\194\160", " ")
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Découpe un texte de source du Journal des montures.
--  « Butin : Le roi-liche|nCitadelle de la Couronne de glace »
--    -> encounterName = "Le roi-liche", placeName = "Citadelle de la Couronne de glace"
--  @return encounterName, placeName
local function ParseSourceText(text)
	if type(text) ~= "string" or text == "" then return nil, nil end

	-- Les codes couleur d'abord : ils traversent les découpages.
	local clean = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")

	local segments = {}
	for segment in (clean .. "|n"):gmatch("(.-)|n") do
		segment = Trim(segment)
		if segment ~= "" then segments[#segments + 1] = segment end
	end
	if #segments == 0 then return nil, nil end

	-- Première ligne : « <catégorie> : <nom> ». On coupe au premier deux-points
	-- seulement ; un nom de boss peut en contenir un.
	local first = segments[1]
	local subject = first:match("^[^:]*:%s*(.+)$") or first
	subject = Trim(subject)

	-- Dernière ligne : le lieu, quand il y en a un.
	local place = #segments >= 2 and segments[#segments] or nil

	return subject ~= "" and subject or nil, place
end

Mapping.ParseSourceText = ParseSourceText

--- Cartographie toutes les montures à partir de leur texte de source.
--  @return table [mountID] = source, nombre de montures rattachées à une instance
local function MapFromSourceText(index)
	local results = {}
	local mapped = 0

	local mountIDs = C_MountJournal and C_MountJournal.GetMountIDs()
	if type(mountIDs) ~= "table" then return results, 0 end

	local since = 0
	for position = 1, #mountIDs do
		local mountID = mountIDs[position]
		local _, _, sourceText = C_MountJournal.GetMountInfoExtraByID(mountID)
		local subject, place = ParseSourceText(sourceText)

		if subject or place then
			local sourceType = select(6, C_MountJournal.GetMountInfoByID(mountID))
			local entry = {
				kind = ns.Data.GetSourceKind(sourceType),
				mountID = mountID,
				encounterName = subject,
				origin = "sourceText",
			}

			-- Le lieu n'est retenu comme instance que s'il correspond à une
			-- instance réelle du Journal. Sinon c'est une zone, un vendeur, un
			-- événement — on garde le texte sans prétendre que c'est un raid.
			local match = place and index[ns.Util.NormalizeName(place)]
			if match then
				entry.instanceName = match.name
				entry.journalInstanceID = match.journalInstanceID
				entry.tier = match.tier
				entry.tierName = match.tierName
				entry.isRaid = match.isRaid
				mapped = mapped + 1
			elseif place then
				entry.placeName = place
			end

			results[mountID] = entry
		end

		since = since + 1
		if since >= MOUNTS_PER_SLICE then
			since = 0
			coroutine.yield()
		end
	end

	return results, mapped
end

--------------------------------------------------------------------------------
-- Passe C — butin, boss par boss (approfondie)
--------------------------------------------------------------------------------

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

--- Butin du boss sélectionné, filtré sur les montures.
local function CollectMountLoot()
	local found = {}

	-- GetNumLoot dit combien d'entrées existent. Sans elle, une liste pas
	-- encore chargée est indiscernable d'un boss sans butin, et on sort de la
	-- boucle en croyant avoir fini — c'est ce qui rendait l'ancien scan muet.
	local count = MAX_LOOT_PER_ENCOUNTER
	if type(C_EncounterJournal.GetNumLoot) == "function" then
		local ok, number = pcall(C_EncounterJournal.GetNumLoot)
		if ok and type(number) == "number" then count = math.min(number, MAX_LOOT_PER_ENCOUNTER) end
	end

	for position = 1, count do
		local ok, itemInfo = pcall(C_EncounterJournal.GetLootInfoByIndex, position)
		if ok and type(itemInfo) == "table" and itemInfo.itemID then
			local mountID = C_MountJournal.GetMountFromItem(itemInfo.itemID)
			if mountID then
				found[#found + 1] = {
					itemID = itemInfo.itemID,
					mountID = mountID,
					itemName = itemInfo.name,
				}
			end
		end
	end
	return found
end

--- Enrichit `results` avec le boss exact de chaque monture d'instance.
local function DeepScan(index, results)
	if not LootReady() then return 0 end
	ClearLootFilters()

	local refined = 0
	for _, instance in pairs(index) do
		pcall(EJ_SelectInstance, instance.journalInstanceID)
		coroutine.yield()

		local encounterIndex = 1
		while true do
			local ok, encounterName, _, journalEncounterID =
				pcall(EJ_GetEncounterInfoByIndex, encounterIndex, instance.journalInstanceID)
			if not ok or not journalEncounterID then break end

			pcall(EJ_SelectEncounter, journalEncounterID)
			coroutine.yield()

			for _, loot in ipairs(CollectMountLoot()) do
				local entry = results[loot.mountID] or { mountID = loot.mountID }
				entry.kind = ns.Data.SOURCE_KINDS.BOSS
				entry.itemID = loot.itemID
				entry.itemName = loot.itemName
				entry.encounterName = encounterName
				entry.journalEncounterID = journalEncounterID
				entry.instanceName = instance.name
				entry.journalInstanceID = instance.journalInstanceID
				entry.tier = instance.tier
				entry.tierName = instance.tierName
				entry.isRaid = instance.isRaid
				entry.origin = "loot"
				results[loot.mountID] = entry
				refined = refined + 1
			end

			encounterIndex = encounterIndex + 1
		end
	end

	return refined
end

--------------------------------------------------------------------------------
-- Entrées d'instance (géographie de la phase 3)
--------------------------------------------------------------------------------

local COSMIC_MAP_ID = 946
local WORLD_MAP_ID = 947

local function EntrancesReady()
	return C_Map and type(C_Map.GetMapChildrenInfo) == "function"
		and C_EncounterJournal
		and type(C_EncounterJournal.GetDungeonEntrancesForMap) == "function"
end

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

		since = since + 1
		if since >= 25 then
			since = 0
			coroutine.yield()
		end
	end

	return nodes, count
end

--------------------------------------------------------------------------------
-- Pilote
--------------------------------------------------------------------------------

local function ScanRoutine(self, deep)
	local index = BuildInstanceIndex()
	self.instanceIndex = index

	local results, mapped = MapFromSourceText(index)

	local refined = 0
	if deep then
		refined = DeepScan(index, results)
	end

	local nodes, nodeCount = CollectEntrances()

	local total = 0
	for _ in pairs(results) do total = total + 1 end

	return {
		sources = results,
		instances = ns.Util.Count(index),
		mounts = total,
		mapped = mapped,
		refined = refined,
		nodes = nodes,
		nodeCount = nodeCount,
		deep = deep,
	}
end

--- Lance la cartographie.
--  @param deep true pour ajouter la passe de butin (lente)
function Mapping:Run(deep)
	local L = ns.L
	if self.running then
		ns:Print(L.SCAN_BUSY)
		return false
	end
	if not EnsureEJLoaded() then
		ns:Print(L.SCAN_NEEDS_EJ)
		return false
	end

	ns:Print(deep and L.SCAN_DEEP_START or (self.silent and L.SCAN_AUTO_START or L.SCAN_START))
	self.running = true
	self.startedAt = time()
	self:SendMessage("OF_SCAN_STARTED")

	local thread = coroutine.create(ScanRoutine)
	local driver = self.driver or CreateFrame("Frame")
	self.driver = driver

	driver:SetScript("OnUpdate", function()
		local deadline = debugprofilestop() + (FRAME_BUDGET * 1000)
		repeat
			local ok, payload = coroutine.resume(thread, self, deep)
			if not ok then
				driver:SetScript("OnUpdate", nil)
				self.running = false
				self.silent = false
				self:SendMessage("OF_SCAN_COMPLETE")
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

function Mapping:Finish(payload)
	local silent = self.silent
	self.silent = false
	if type(payload) ~= "table" or type(payload.sources) ~= "table" then
		self:SendMessage("OF_SCAN_COMPLETE")
		return
	end

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
		-- On ne vide jamais la géographie sur une passe qui n'a rien trouvé :
		-- garder l'ancienne vaut mieux que n'en avoir aucune.
		if payload.nodeCount and payload.nodeCount > 0 then
			ns.db.global.nodeCache = payload.nodes
		end

		local mountIDs = C_MountJournal and C_MountJournal.GetMountIDs()
		ns.db.global.scanMeta = {
			at = OnlyFarmScanDB.scannedAt,
			build = OnlyFarmScanDB.build,
			mounts = payload.mounts,
			mapped = payload.mapped,
			instances = payload.instances,
			nodes = payload.nodeCount,
			deep = payload.deep or false,
			mountsSeen = type(mountIDs) == "table" and #mountIDs or 0,
		}
	end

	ns:Print(ns.L.SCAN_DONE, payload.mapped or 0, payload.mounts or 0, payload.instances or 0)
	if silent then ns:Print(ns.L.SCAN_AUTO_DONE) end
	self:SendMessage("OF_SCAN_COMPLETE")
end

--- Résumé du dernier scan, pour l'interface.
--  @return texte, ou nil si aucun scan n'a jamais tourné
function Mapping:GetSummary()
	if not ns.db then return nil end
	local meta = ns.db.global.scanMeta
	if type(meta) ~= "table" or not meta.at then return nil end
	return ns.L.SCAN_SUMMARY:format(
		meta.mapped or 0, meta.mounts or 0, ns.Util.FormatAge(meta.at))
end
