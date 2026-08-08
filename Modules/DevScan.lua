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
-----------------------------------------------------------------------------]]

local _, ns = ...

local DevScan = ns:NewModule("DevScan", 60)

local FRAME_BUDGET = 0.006   -- 6 ms par frame, comme le futur solveur de route
local MAX_LOOT_PER_ENCOUNTER = 200

function DevScan:OnInitialize()
	self.running = false
	self.driver = nil
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

	return results, instanceCount, mountCount
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

	ns:Print(L.SCAN_START)
	self.running = true
	self.startedAt = time()

	local thread = coroutine.create(ScanRoutine)
	local driver = self.driver or CreateFrame("Frame")
	self.driver = driver

	driver:SetScript("OnUpdate", function()
		local deadline = debugprofilestop() + (FRAME_BUDGET * 1000)
		repeat
			local ok, a, b, c = coroutine.resume(thread, self)
			if not ok then
				driver:SetScript("OnUpdate", nil)
				self.running = false
				local handler = geterrorhandler and geterrorhandler()
				if handler then handler(a) end
				return
			end
			if coroutine.status(thread) == "dead" then
				driver:SetScript("OnUpdate", nil)
				self.running = false
				self:Finish(a, b, c)
				return
			end
		until debugprofilestop() >= deadline
	end)
	return true
end

function DevScan:Finish(results, instanceCount, mountCount)
	if type(results) ~= "table" then return end

	if type(OnlyFarmScanDB) ~= "table" then OnlyFarmScanDB = {} end
	OnlyFarmScanDB.sources = results
	OnlyFarmScanDB.scannedAt = time()
	OnlyFarmScanDB.build = select(2, GetBuildInfo())
	OnlyFarmScanDB.version = select(1, GetBuildInfo())
	OnlyFarmScanDB.locale = GetLocale()
	OnlyFarmScanDB.addonVersion = ns.VERSION

	if ns.db then
		ns.db.global.sourceCache = results
		ns.db.global.scanMeta = {
			at = OnlyFarmScanDB.scannedAt,
			build = OnlyFarmScanDB.build,
			mounts = mountCount,
			instances = instanceCount,
		}
	end

	ns:Print(ns.L.SCAN_DONE, mountCount or 0, instanceCount or 0)
	self:SendMessage("OF_SCAN_COMPLETE")
end
