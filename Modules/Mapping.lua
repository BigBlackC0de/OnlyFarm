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

-- Valeur rendue par coroutine.yield pour exiger une VRAIE frame.
--
-- Le pilote enchaîne plusieurs reprises par frame tant qu'il lui reste du
-- budget : un `coroutine.yield()` nu ne rend donc PAS la main au client, il
-- rend seulement la main au pilote. C'est ce qui rendait la passe de butin
-- quasi muette — on sélectionnait un boss puis on lisait son butin dans la
-- même frame, avant que le client ait eu la moindre chance de le charger.
--
-- `coroutine.yield(WAIT_FRAME)` termine la frame en cours, pour de bon.
local WAIT_FRAME = "frame"

--- Cède la main pour `count` frames réelles.
local function WaitFrames(count)
	for _ = 1, (count or 1) do
		coroutine.yield(WAIT_FRAME)
	end
end

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

-- Version de l'ALGORITHME de cartographie, à incrémenter dès que la façon de
-- construire l'index change. C'est ce qui force un recalcul chez les joueurs
-- qui ont déjà un cache : sans ça, une correction de la logique reste sans
-- effet tant que le client ne change pas de build, et le bug corrigé continue
-- de s'afficher.
--   1 — parcours du butin du Journal
--   2 — texte de source + index des paliers
--   3 — ajout de la liste du Recherche de groupe comme seconde source
--   4 — découpage tolérant aux deux séparateurs de ligne, replis de
--       rapprochement, extensions ramenées à un repère unique
--   5 — le lieu est souvent étiqueté (« Région : … ») : on sait enlever
--       l'étiquette, et plus seulement le suffixe d'aile
--   6 — extension des montures de haut fait, via l'arbre des catégories
--   7 — extension EXACTE par l'objet (C_Item.GetItemInfo.expansionID), avec
--       mémorisation de l'itemID pour ne pas refaire la passe approfondie
--   8 — le pilote rend enfin la main au client entre deux lectures de butin :
--       les yields étaient consommés dans la même frame, donc la passe de
--       butin lisait avant que le client ait chargé quoi que ce soit
local MAPPING_VERSION = 9

-- Une cartographie qui ne rattache rien est ratée, pas fraîche : on la
-- retente. Mais pas indéfiniment — sur un client où rien ne répondrait, on
-- s'arrêterait de relancer une passe inutile à chaque connexion.
local MAX_EMPTY_RETRIES = 3

--- La cartographie est-elle à refaire ?
function Mapping:IsStale()
	if not ns.db then return false end
	local meta = ns.db.global.scanMeta
	if type(meta) ~= "table" or not meta.at then return true end
	if ns.Util.Count(ns.db.global.sourceCache) == 0 then return true end

	-- L'algorithme a changé depuis ce cache : il est périmé par construction.
	if (meta.mappingVersion or 0) ~= MAPPING_VERSION then return true end

	-- Changement de build = patch : des montures ont pu changer de source.
	if meta.build ~= select(2, GetBuildInfo()) then return true end

	-- Le scan précédent n'a rattaché AUCUNE monture à une instance. Il a beau
	-- avoir « réussi » — il a bien écrit 1600 entrées — le résultat est
	-- inexploitable, et le considérer comme frais empêchait justement toute
	-- nouvelle tentative.
	if (meta.mapped or 0) == 0 and (meta.emptyRuns or 0) < MAX_EMPTY_RETRIES then
		return true
	end

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
--
-- DEUX sources, et c'est délibéré.
--
-- Le parcours par paliers du Journal des rencontres donne le journalInstanceID
-- (dont la géographie a besoin) mais il s'est révélé muet en jeu : selon l'état
-- du client, EJ_GetNumTiers peut renvoyer 0 tant que la fenêtre du Journal n'a
-- jamais été ouverte. Résultat, index vide et cartographie à zéro, sans la
-- moindre erreur pour le signaler.
--
-- La liste des donjons du Recherche de groupe, elle, est faite de globales
-- toujours présentes, sans addon à charger ni fenêtre à ouvrir, et elle porte
-- directement le niveau d'extension de chaque instance. Elle ne donne pas
-- d'identifiant de Journal, mais elle donne le nom et l'extension — c'est-à-dire
-- ce dont l'affichage a besoin.
--
-- On construit donc les deux et on les fusionne. Si l'une est vide, l'autre
-- suffit.
--------------------------------------------------------------------------------

-- Les identifiants du Recherche de groupe sont épars ; on balaie large et on
-- ignore les trous. Le coût est négligeable, la boucle respire régulièrement.
local MAX_LFG_ID = 3000
local LFG_IDS_PER_SLICE = 400

-- subtypeID du Recherche de groupe : 3 = raid, 5 = raid flexible.
local LFG_RAID_SUBTYPES = { [3] = true, [5] = true }

--- Index tiré de la liste des donjons du Recherche de groupe.
local function BuildLFGIndex()
	local index = {}
	if type(GetLFGDungeonInfo) ~= "function" then return index end

	local since = 0
	for dungeonID = 1, MAX_LFG_ID do
		local ok, name, _, subtypeID, _, _, _, _, _, expansionLevel =
			pcall(GetLFGDungeonInfo, dungeonID)

		if ok and type(name) == "string" and name ~= "" then
			local key = ns.Util.NormalizeName(name)
			local tierName = ns.Data.ExpansionName(expansionLevel)
			-- On ne retient que si on a effectivement une extension à en tirer,
			-- et on garde la première vue : un même nom apparaît en normal, en
			-- héroïque et en Recherche de raid, avec la même extension.
			if key and tierName and not index[key] then
				index[key] = {
					name = name,
					tier = expansionLevel,
					tierName = tierName,
					isRaid = LFG_RAID_SUBTYPES[subtypeID] or false,
					origin = "lfg",
				}
			end
		end

		since = since + 1
		if since >= LFG_IDS_PER_SLICE then
			since = 0
			coroutine.yield()
		end
	end

	return index
end

--- Parcourt les paliers du Journal et enregistre chaque instance.
--  @return [nom normalisé] = { name, journalInstanceID, tier, tierName, isRaid }
local function BuildJournalIndex()
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

		-- Le Journal compte ses paliers à partir de 1, le client ses extensions
		-- à partir de 0. On ramène les deux au même repère, sinon la même
		-- extension apparaît deux fois dans le graphe sous deux noms.
		local level = ns.Data.ExpansionLevelFromName(tierName)
			or ns.Data.TierToExpansionLevel(tier)
		local displayName = ns.Data.ExpansionName(level) or tierName

		-- Le nom de palier est un libellé d'extension dans la langue du client.
		-- On le déclare comme alias : les catégories de hauts faits, elles
		-- aussi localisées, pourront s'y rattacher.
		ns.Data.RegisterExpansionAlias(tierName, level)

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
						tier = level,
						tierName = displayName,
						isRaid = isRaid,
						origin = "journal",
					}
				end
				position = position + 1
			end
		end
	end

	return index
end

--- Fusion des deux index. Le Journal gagne quand il répond : il apporte le
--  journalInstanceID, qui relie une instance à son entrée sur la carte. La
--  liste du Recherche de groupe comble le reste, et sauve le cas où le Journal
--  ne répond pas du tout.
local function BuildInstanceIndex()
	local lfg = BuildLFGIndex()
	local journal = BuildJournalIndex()

	local index = {}
	for key, entry in pairs(lfg) do index[key] = entry end
	for key, entry in pairs(journal) do
		local existing = index[key]
		if existing then
			-- Le Journal n'a pas toujours de nom de palier exploitable ; on
			-- garde alors celui du Recherche de groupe plutôt que de le perdre.
			entry.tierName = entry.tierName or existing.tierName
			entry.tier = entry.tier or existing.tier
		end
		index[key] = entry
	end

	return index, ns.Util.Count(lfg), ns.Util.Count(journal)
end

--------------------------------------------------------------------------------
-- Passe A bis — index des hauts faits
--
-- Une monture sur cinq vient d'un haut fait, et son texte de source dit
-- « Haut fait : <nom> » sans aucun lieu. L'index des instances ne peut rien
-- pour elles : elles tombaient toutes dans le panier « inconnue ».
--
-- Or l'arbre des catégories de hauts faits EST organisé par extension —
-- « Donjons et raids > Wrath of the Lich King », « Exploration > Legion ». En
-- remontant les parents d'une catégorie jusqu'à trouver un nom qui correspond
-- à une extension connue, on récupère l'extension du haut fait, donc celle de
-- la monture. Entièrement dérivé du client, comme le reste.
--------------------------------------------------------------------------------

local ACHIEVEMENTS_PER_SLICE = 300

local function AchievementsReady()
	return type(GetCategoryList) == "function"
		and type(GetCategoryInfo) == "function"
		and type(GetCategoryNumAchievements) == "function"
		and type(GetAchievementInfo) == "function"
end

--- Remonte l'arbre des catégories jusqu'à un nom d'extension reconnu.
--  @return niveau d'extension, ou nil
local function ResolveCategoryExpansion(categoryID, cache)
	if cache[categoryID] ~= nil then
		return cache[categoryID] or nil
	end

	local visited = 0
	local cursor = categoryID
	while cursor and cursor > 0 and visited < 8 do
		local ok, name, parentID = pcall(GetCategoryInfo, cursor)
		if not ok then break end

		local level = ns.Data.ExpansionLevelFromName(name)
		if level then
			cache[categoryID] = level
			return level
		end
		cursor = parentID
		visited = visited + 1
	end

	-- `false` et pas nil : on retient aussi les échecs, sinon on refait le
	-- parcours pour chaque haut fait de la même catégorie.
	cache[categoryID] = false
	return nil
end

--- Index « nom de haut fait normalisé » -> { tier, tierName }.
local function BuildAchievementIndex()
	local index = {}
	local stats = { categories = 0, resolved = 0, achievements = 0 }
	if not AchievementsReady() then return index, stats end

	local okList, categories = pcall(GetCategoryList)
	if not okList or type(categories) ~= "table" then return index, stats end

	local categoryCache = {}
	local since = 0

	for _, categoryID in ipairs(categories) do
		stats.categories = stats.categories + 1
		local level = ResolveCategoryExpansion(categoryID, categoryCache)
		if level then
			stats.resolved = stats.resolved + 1
			local tierName = ns.Data.ExpansionName(level)
			local okCount, count = pcall(GetCategoryNumAchievements, categoryID, true)
			if okCount and type(count) == "number" then
				for position = 1, count do
					local okInfo, _, name = pcall(GetAchievementInfo, categoryID, position)
					if okInfo and type(name) == "string" and name ~= "" then
						local key = ns.Util.NormalizeName(name)
						if key and not index[key] then
							index[key] = { tier = level, tierName = tierName }
							stats.achievements = stats.achievements + 1
						end
					end

					since = since + 1
					if since >= ACHIEVEMENTS_PER_SLICE then
						since = 0
						coroutine.yield()
					end
				end
			end
		end
	end

	return index, stats
end

--------------------------------------------------------------------------------
-- Extension EXACTE, par l'objet
--
-- C_Item.GetItemInfo renvoie un `expansionID` en 15e position : l'extension de
-- l'objet, donc celle de la monture qu'il enseigne. C'est la seule source
-- exacte du lot — pas un rapprochement de noms, pas une inférence, une donnée
-- du client. Elle prime donc sur toutes les heuristiques.
--
-- Le prix à payer : il faut connaître l'itemID, et le Journal des montures ne
-- l'expose pas. Seul le butin du Journal des rencontres le donne, donc la passe
-- approfondie. D'où le stockage de l'itemID dans le cache : une fois la passe
-- approfondie faite UNE fois, chaque scan rapide ultérieur retrouve l'extension
-- exacte sans y revenir.
--------------------------------------------------------------------------------

-- Retours de C_Item.GetItemInfo : itemName(1) … bindType(14) expansionID(15).
local ITEM_EXPANSION_RETURN = 15

local function ItemExpansion(itemID)
	if type(itemID) ~= "number" then return nil end
	if not C_Item or type(C_Item.GetItemInfo) ~= "function" then return nil end

	local results = { pcall(C_Item.GetItemInfo, itemID) }
	if not results[1] then return nil end

	-- results[1] est le booléen de pcall : le n-ième retour est en n+1.
	local expansion = results[ITEM_EXPANSION_RETURN + 1]
	if type(expansion) ~= "number" then return nil end
	return expansion
end

local function RequestItem(itemID)
	if type(itemID) ~= "number" then return end
	if C_Item and type(C_Item.RequestLoadItemDataByID) == "function" then
		pcall(C_Item.RequestLoadItemDataByID, itemID)
	end
end

--- Applique l'extension de l'objet à toutes les entrées qui en ont un.
--  @return nombre d'entrées renseignées
local function ApplyItemExpansions(results)
	local pending = {}
	for _, entry in pairs(results) do
		if entry.itemID then
			RequestItem(entry.itemID)
			pending[#pending + 1] = entry
		end
	end
	if #pending == 0 then return 0 end

	-- Le client répond de façon asynchrone : quelques frames de battement
	-- valent mieux qu'une lecture immédiate qui rendrait nil partout.
	WaitFrames(5)

	local applied = 0
	for index, entry in ipairs(pending) do
		local level = ItemExpansion(entry.itemID)
		if level then
			entry.tier = level
			entry.tierName = ns.Data.ExpansionName(level)
			entry.matchedBy = "item"
			applied = applied + 1
		end
		if index % 100 == 0 then WaitFrames(1) end
	end
	return applied
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
--  « Butin : Le roi-liche<saut>Citadelle de la Couronne de glace »
--    -> encounterName = "Le roi-liche", placeName = "Citadelle de la Couronne de glace"
--
--  DEUX séparateurs possibles, et c'est tout le problème. Le client écrit
--  tantôt un vrai saut de ligne, tantôt la séquence d'échappement « |n », selon
--  la chaîne et la locale. Ne gérer que l'un des deux donne un texte d'une
--  seule ligne : le lieu n'est jamais extrait, donc aucune monture n'est
--  rattachée à une instance — et le scan rend « 0 sur 1619 » sans une erreur.
--
--  @return encounterName, placeName
local function ParseSourceText(text)
	if type(text) ~= "string" or text == "" then return nil, nil end

	-- Les codes couleur d'abord : ils traversent les découpages.
	local clean = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")

	-- On ramène les deux formes de saut de ligne à une seule avant de découper.
	clean = clean:gsub("|n", "\n"):gsub("\r\n", "\n"):gsub("\r", "\n")

	local segments = {}
	for segment in (clean .. "\n"):gmatch("(.-)\n") do
		segment = Trim(segment)
		if segment ~= "" then segments[#segments + 1] = segment end
	end
	if #segments == 0 then return nil, nil end

	-- Première ligne : « <catégorie> : <nom> ». On coupe au premier deux-points
	-- seulement ; un nom de boss peut en contenir un.
	local first = segments[1]
	local subject = first:match("^[^:]*:%s*(.+)$") or first
	subject = Trim(subject)

	-- Le lieu N'EST PAS forcément la dernière ligne.
	--
	-- Les données réelles le montrent : « Vendeur : Unger Statforth |n Zone :
	-- Wetlands |n Coût : 1 or ». La dernière ligne est le prix, pas le lieu.
	-- Prendre `segments[#segments]` marchait sur les montures à deux lignes et
	-- ratait toutes celles à trois.
	--
	-- On renvoie donc TOUTES les lignes candidates, et c'est le rapprochement
	-- qui tranche : un vrai nom d'instance correspondra, un prix ne
	-- correspondra à rien. Aucune étiquette localisée à reconnaître, donc rien
	-- à maintenir par langue.
	local places = {}
	for index = 2, #segments do
		places[#places + 1] = segments[index]
	end

	return subject ~= "" and subject or nil, places[1], places
end

Mapping.ParseSourceText = ParseSourceText

-- Sous ce seuil, une correspondance partielle rapproche n'importe quoi.
local MIN_PARTIAL_LENGTH = 10

--- Rapproche un lieu d'une instance de l'index, avec des replis.
--
--  Le rapprochement exact ne suffit pas, pour deux raisons opposées :
--
--    * la seconde ligne du texte de source est souvent ÉTIQUETÉE. Le Journal
--      des montures écrit « Région : Libération de Terremine », pas
--      « Libération de Terremine ». Il faut donc savoir enlever ce qui précède
--      le deux-points ;
--    * à l'inverse, le Recherche de groupe nomme ses ailes « Citadelle de la
--      Couronne de glace : Le Bastion inférieur » là où le Journal écrit juste
--      « Citadelle de la Couronne de glace ». Il faut alors enlever ce qui
--      SUIT le deux-points.
--
--  Les deux cas ont la même forme et demandent des découpages inverses : on
--  essaie les deux, dans cet ordre, puis une correspondance partielle bornée.
--
--  @return entrée d'index, nom de la stratégie qui a marché
local function MatchPlace(index, place)
	local key = ns.Util.NormalizeName(place)
	if not key then return nil, nil end

	-- 1. Correspondance exacte.
	if index[key] then return index[key], "exact" end

	-- 2. Après le deux-points : « région : libération de terremine ».
	--    Recherche EXACTE dans l'index : pas de borne de longueur ici, sans
	--    quoi une zone au nom court (« Wetlands », 8 signes) serait écartée
	--    alors que son entrée existe. La borne ne protège que le partiel.
	local after = key:match("^[^:]+:%s*(.+)$")
	if after and index[after] then
		return index[after], "labelled"
	end

	-- 3. Avant le deux-points : « citadelle … : le bastion inférieur ».
	local before = key:match("^(.-)%s*:%s*.+$")
	if before and index[before] then
		return index[before], "prefix"
	end

	-- 4. Correspondance partielle, dans un sens ou dans l'autre. Bornée en
	--    longueur : « Karazhan » ne doit pas attraper autre chose au hasard.
	for _, candidateKey in ipairs({ key, after, before }) do
		if candidateKey and #candidateKey >= MIN_PARTIAL_LENGTH then
			for indexKey, entry in pairs(index) do
				if #indexKey >= MIN_PARTIAL_LENGTH then
					if indexKey:find(candidateKey, 1, true)
						or candidateKey:find(indexKey, 1, true)
					then
						return entry, "partial"
					end
				end
			end
		end
	end

	return nil, nil
end

Mapping.MatchPlace = MatchPlace

--- Cartographie toutes les montures à partir de leur texte de source.
--  @return table [mountID] = source, statistiques du passage
local function MapFromSourceText(index, achievements, previous)
	local results = {}
	-- Compteurs par étape. Sans eux, « 0 rattachées » ne dit pas SI le texte a
	-- été lu, SI un lieu en a été extrait, ou SI le rapprochement a échoué —
	-- trois pannes très différentes qui donnent le même zéro.
	local stats = {
		withText = 0,
		withPlace = 0,
		mapped = 0,
		exact = 0,
		labelled = 0,
		prefix = 0,
		partial = 0,
		byAchievement = 0,
		byCurated = 0,
	}

	local mountIDs = C_MountJournal and C_MountJournal.GetMountIDs()
	if type(mountIDs) ~= "table" then return results, stats end

	local since = 0
	for position = 1, #mountIDs do
		local mountID = mountIDs[position]
		local _, _, sourceText = C_MountJournal.GetMountInfoExtraByID(mountID)
		if type(sourceText) == "string" and sourceText ~= "" then
			stats.withText = stats.withText + 1
		end

		local subject, place, places = ParseSourceText(sourceText)
		if place then stats.withPlace = stats.withPlace + 1 end

		local spellID, sourceType = select(2, C_MountJournal.GetMountInfoByID(mountID)),
			select(6, C_MountJournal.GetMountInfoByID(mountID))

		if subject or place then
			local entry = {
				kind = ns.Data.GetSourceKind(sourceType),
				mountID = mountID,
				spellID = spellID,
				encounterName = subject,
				origin = "sourceText",
			}

			-- L'itemID découvert par une passe approfondie passée est conservé :
			-- c'est lui qui donne l'extension exacte, et le reperdre à chaque
			-- scan obligerait à refaire la passe lente.
			local known = previous and previous[mountID]
			if known and known.itemID then entry.itemID = known.itemID end

			-- Le lieu n'est retenu comme instance que s'il correspond à une
			-- instance réelle. Sinon c'est une zone, un vendeur, un événement —
			-- on garde le texte sans prétendre que c'est un raid.
			-- Chaque ligne candidate est essayée, la première qui correspond
			-- gagne. Une ligne de coût ou de faction ne correspondra à rien.
			local match, strategy = nil, nil
			for _, candidate in ipairs(places or {}) do
				match, strategy = MatchPlace(index, candidate)
				if match then break end
			end

			if match then
				entry.instanceName = match.name
				entry.journalInstanceID = match.journalInstanceID
				entry.tier = match.tier
				entry.tierName = match.tierName
				entry.isRaid = match.isRaid
				entry.matchedBy = strategy
				stats.mapped = stats.mapped + 1
				stats[strategy] = (stats[strategy] or 0) + 1
			else
				if place then entry.placeName = place end

				-- Aucun lieu exploitable : le sujet est peut-être un haut
				-- fait, auquel cas l'arbre des catégories donne l'extension.
				-- Ça ne dit pas OÙ farmer, mais ça sort la monture du panier
				-- « inconnue », et c'est déjà l'essentiel du filtre.
				local achievement = achievements and subject
					and achievements[ns.Util.NormalizeName(subject)]
				if achievement then
					entry.tier = achievement.tier
					entry.tierName = achievement.tierName
					entry.matchedBy = "achievement"
					stats.byAchievement = stats.byAchievement + 1
				end
			end

			-- La table curée passe DEVANT les heuristiques, et non derrière.
			--
			-- Elle vient de ItemSparse.ExpansionID, c'est-à-dire exactement le
			-- champ que le client expose sous le nom `expansionID` : une donnée
			-- d'autorité, pas une déduction. Un rapprochement de noms de lieux
			-- ne doit jamais la contredire. Seule l'extension mesurée en direct
			-- sur l'objet (passe suivante) fait aussi bien — et pour cause,
			-- c'est la même donnée.
			--
			-- L'instance, elle, reste celle du lieu : la table curée ne la
			-- donne pas dans la langue du client, et c'est le nom localisé qui
			-- sert au rapprochement des verrous.
			local curated = ns.Data.GetCuratedMount(mountID, spellID)
			if curated then
				if curated.expansion ~= nil then
					entry.tier = curated.expansion
					entry.tierName = ns.Data.ExpansionName(curated.expansion)
					entry.matchedBy = "curated"
					stats.byCurated = (stats.byCurated or 0) + 1
				end
				entry.dropRate = entry.dropRate or curated.dropRate
				if not entry.instanceName then entry.kind = curated.kind or entry.kind end
			end

			results[mountID] = entry
		end

		since = since + 1
		if since >= MOUNTS_PER_SLICE then
			since = 0
			coroutine.yield()
		end
	end

	return results, stats
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
local function DeepScan(self, index, results)
	if not LootReady() then return 0 end
	ClearLootFilters()

	local refined = 0
	local total, done = ns.Util.Count(index), 0

	for _, instance in pairs(index) do
		done = done + 1
		self.progress = { done = done, total = total }
		-- Throttlé au pourcent : l'interface n'a pas besoin de plus, et un
		-- message par instance ferait plus de travail que le scan.
		local percent = math.floor(done / math.max(1, total) * 100)
		if percent ~= self.lastPercent then
			self.lastPercent = percent
			self:SendMessage("OF_SCAN_PROGRESS")
		end

		-- Une instance sans identifiant de Journal (venue du Recherche de
		-- groupe) n'a pas de butin à parcourir : on ne perd pas de frames dessus.
		if instance.journalInstanceID then
		pcall(EJ_SelectInstance, instance.journalInstanceID)
		WaitFrames(2)

		local encounterIndex = 1
		while true do
			local ok, encounterName, _, journalEncounterID =
				pcall(EJ_GetEncounterInfoByIndex, encounterIndex, instance.journalInstanceID)
			if not ok or not journalEncounterID then break end

			pcall(EJ_SelectEncounter, journalEncounterID)
			WaitFrames(2)

			-- Le butin arrive de façon asynchrone. Une liste vide à la première
			-- lecture ne veut pas dire « ce boss ne lâche rien » : on laisse
			-- une seconde chance avant de conclure.
			local loots = CollectMountLoot()
			if #loots == 0 then
				WaitFrames(3)
				loots = CollectMountLoot()
			end

			for _, loot in ipairs(loots) do
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
	end

	self.progress = nil
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
	local index, lfgCount, journalCount = BuildInstanceIndex()
	self.instanceIndex = index

	local achievements, achievementStats = BuildAchievementIndex()
	self.achievementIndex = achievements

	local previous = ns.db and ns.db.global.sourceCache or nil
	local results, stats = MapFromSourceText(index, achievements, previous)

	local refined = 0
	if deep then
		refined = DeepScan(self, index, results)
	end

	-- L'extension par l'objet passe en DERNIER et écrase les heuristiques :
	-- elle est exacte, elles sont approchées.
	local byItem = ApplyItemExpansions(results)

	local nodes, nodeCount = CollectEntrances()

	-- On recompte à la fin plutôt que de faire confiance aux compteurs de
	-- passage : la passe approfondie rattache elle aussi des montures, et un
	-- « mapped » qui ne comptait que le texte de source annonçait zéro alors
	-- que le tableau de bord affichait des extensions.
	-- « Rattachée » = l'addon sait quelque chose d'utile : une instance, ou au
	-- moins une extension. Compter uniquement les instances sous-estimait le
	-- résultat et cachait tout l'apport des hauts faits.
	local total, mapped = 0, 0
	for _, entry in pairs(results) do
		total = total + 1
		if entry.instanceName or entry.tierName then mapped = mapped + 1 end
	end

	return {
		sources = results,
		instances = ns.Util.Count(index),
		lfgInstances = lfgCount,
		journalInstances = journalCount,
		achievements = ns.Util.Count(achievements),
		achievementStats = achievementStats,
		mounts = total,
		mapped = mapped,
		textStats = stats,
		refined = refined,
		byItem = byItem,
		nodes = nodes,
		nodeCount = nodeCount,
		deep = deep,
	}
end

--- La passe de butin est-elle encore nécessaire ?
--
--  Elle ne sert qu'à récolter les itemID, et ceux-ci sont mémorisés. Une fois
--  qu'elle a tourné pour un build donné, les scans suivants s'en passent : ils
--  retrouvent l'extension exacte depuis les itemID du cache.
function Mapping:NeedsDeepPass()
	if not ns.db then return true end
	local meta = ns.db.global.scanMeta
	if type(meta) ~= "table" then return true end
	if not meta.deep then return true end
	if (meta.mappingVersion or 0) ~= MAPPING_VERSION then return true end
	return meta.build ~= select(2, GetBuildInfo())
end

--- Lance la cartographie.
--
--  @param deep true pour forcer la passe de butin, false pour l'interdire,
--         nil pour laisser l'addon décider — et c'est le cas normal. Deux
--         boutons « scan » et « scan approfondi » demandaient au joueur de
--         trancher une question technique dont il n'a pas les éléments ; la
--         réponse est déductible, donc c'est à l'addon de la déduire.
function Mapping:Run(deep)
	local L = ns.L
	if deep == nil then deep = self:NeedsDeepPass() end
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
	self.progress = nil
	self.lastPercent = nil
	self:SendMessage("OF_SCAN_STARTED")

	local thread = coroutine.create(ScanRoutine)
	local driver = self.driver or CreateFrame("Frame")
	self.driver = driver

	driver:SetScript("OnUpdate", function()
		local deadline = debugprofilestop() + (FRAME_BUDGET * 1000)
		repeat
			local ok, payload = coroutine.resume(thread, self, deep)
			if ok and payload == WAIT_FRAME and coroutine.status(thread) ~= "dead" then
				-- La coroutine réclame une frame entière : on sort de la boucle
				-- de budget au lieu de la relancer aussitôt.
				return
			end
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
		local previous = ns.db.global.scanMeta
		local previousEmpty = (type(previous) == "table" and previous.emptyRuns) or 0

		ns.db.global.scanMeta = {
			at = OnlyFarmScanDB.scannedAt,
			build = OnlyFarmScanDB.build,
			mappingVersion = MAPPING_VERSION,
			-- Compteur de passages infructueux, remis à zéro dès qu'une passe
			-- rattache quelque chose.
			emptyRuns = (payload.mapped or 0) == 0 and (previousEmpty + 1) or 0,
			mounts = payload.mounts,
			mapped = payload.mapped,
			instances = payload.instances,
			-- Détail par source : c'est ce qui permet de dire « le Journal n'a
			-- rien renvoyé » au lieu de « ça ne marche pas ».
			lfgInstances = payload.lfgInstances,
			journalInstances = payload.journalInstances,
			achievements = payload.achievements,
			achievementStats = payload.achievementStats,
			textStats = payload.textStats,
			refined = payload.refined,
			byItem = payload.byItem,
			nodes = payload.nodeCount,
			deep = payload.deep or false,
			mountsSeen = type(mountIDs) == "table" and #mountIDs or 0,
		}
	end

	ns:Print(ns.L.SCAN_DONE, payload.mapped or 0, payload.mounts or 0, payload.instances or 0)

	-- Détail par source : c'est ce qui permet de voir d'un coup d'œil quelle
	-- passe apporte quoi, au lieu d'un total qui ne bouge pas sans dire pourquoi.
	local stats = payload.textStats or {}
	local achievementStats = payload.achievementStats or {}
	ns:Print(ns.L.SCAN_BREAKDOWN,
		(stats.exact or 0) + (stats.labelled or 0) + (stats.prefix or 0) + (stats.partial or 0),
		stats.byAchievement or 0,
		payload.achievements or 0,
		achievementStats.resolved or 0,
		achievementStats.categories or 0)

	-- Quand rien n'est rattaché, on dit tout de suite à quelle étape ça a cédé
	-- au lieu de laisser un zéro nu. C'est la différence entre « il y a un
	-- problème » et « voilà le problème ».
	if (payload.mapped or 0) == 0 then
		local stats = payload.textStats or {}
		ns:Print(ns.L.SCAN_EMPTY_DETAIL,
			stats.withText or 0, stats.withPlace or 0, payload.instances or 0)
	end

	if silent then ns:Print(ns.L.SCAN_AUTO_DONE) end
	self:SendMessage("OF_SCAN_COMPLETE")
end

--------------------------------------------------------------------------------
-- Diagnostic
--
-- Quand la cartographie rend zéro, il y a exactement quatre endroits où ça peut
-- coincer : les paliers du Journal, la liste du Recherche de groupe, le
-- découpage du texte de source, ou le rapprochement des noms. Cette commande
-- dit lequel, au lieu de laisser deviner.
--------------------------------------------------------------------------------

local DIAG_SAMPLES = 8

--- Construit le rapport de diagnostic, ligne par ligne.
--  Renvoie une liste de chaînes pour que l'appelant décide quoi en faire :
--  l'afficher dans le chat, ou la poser dans une fenêtre copiable.
function Mapping:BuildReport()
	local lines = {}
	local function Line(fmt, ...)
		lines[#lines + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
	end

	Line("=== OnlyFarm — diagnostic de cartographie ===")
	Line("addon %s · client %s (%s) · locale %s",
		tostring(ns.VERSION), tostring((GetBuildInfo())),
		tostring(select(2, GetBuildInfo())), tostring(GetLocale()))
	Line("")

	-- 1. Journal des rencontres.
	Line("[1] Journal des rencontres")
	Line("    globales présentes : %s", tostring(TiersReady()))
	if type(EJ_GetNumTiers) == "function" then
		local ok, tiers = pcall(EJ_GetNumTiers)
		Line("    EJ_GetNumTiers() = %s", ok and tostring(tiers) or "ERREUR")
		if ok and type(tiers) == "number" and tiers > 0 then
			-- Un palier au hasard, pour voir si l'énumération répond vraiment.
			pcall(EJ_SelectTier, 1)
			local okInst, id, name = pcall(EJ_GetInstanceByIndex, 1, true)
			Line("    palier 1, 1re instance raid : %s (%s)",
				okInst and tostring(name) or "ERREUR", tostring(id))
		end
	else
		Line("    EJ_GetNumTiers ABSENTE")
	end
	Line("")

	-- 2. Recherche de groupe.
	Line("[2] Recherche de groupe")
	if type(GetLFGDungeonInfo) == "function" then
		local named, withExpansion = 0, 0
		local firstExample
		for dungeonID = 1, 1000 do
			local ok, name, _, _, _, _, _, _, _, expansionLevel =
				pcall(GetLFGDungeonInfo, dungeonID)
			if ok and type(name) == "string" and name ~= "" then
				named = named + 1
				if _G["EXPANSION_NAME" .. tostring(expansionLevel)] then
					withExpansion = withExpansion + 1
					if not firstExample then
						firstExample = string.format("%s -> %s", name,
							_G["EXPANSION_NAME" .. tostring(expansionLevel)])
					end
				end
			end
		end
		Line("    %d noms sur 1000 identifiants, dont %d avec extension", named, withExpansion)
		Line("    exemple : %s", tostring(firstExample))
	else
		Line("    GetLFGDungeonInfo ABSENTE")
	end
	Line("    EXPANSION_NAME0 = %s", tostring(_G.EXPANSION_NAME0))
	Line("")

	-- 3. Index effectivement construit.
	Line("[3] Index des instances en mémoire")
	if type(self.instanceIndex) == "table" then
		Line("    %d entrée(s)", ns.Util.Count(self.instanceIndex))
		local shown = 0
		for _, entry in pairs(self.instanceIndex) do
			if shown >= 3 then break end
			Line("    ex. %s [%s] %s", tostring(entry.name),
				tostring(entry.origin), tostring(entry.tierName))
			shown = shown + 1
		end
	else
		Line("    aucun index (scan jamais lancé dans cette session)")
	end
	Line("")

	-- 4. Ce qui RESTE non rattaché, par nature de source. C'est la question
	--    utile : « il en manque plein » ne dit pas lesquelles.
	Line("[4] Montures sans extension, par nature de source")
	local unmappedByKind, unmappedOrder, unmappedTotal = {}, {}, 0
	local unmappedSamples = {}
	for _, entry in ipairs(ns.Collection:GetMissing()) do
		local source = ns.db and ns.db.global.sourceCache[entry.mountID]
		if not source or not source.tierName then
			unmappedTotal = unmappedTotal + 1
			local kind = entry.sourceTypeLabel or entry.kind or "?"
			if not unmappedByKind[kind] then
				unmappedByKind[kind] = 0
				unmappedOrder[#unmappedOrder + 1] = kind
			end
			unmappedByKind[kind] = unmappedByKind[kind] + 1
			if #unmappedSamples < DIAG_SAMPLES then
				unmappedSamples[#unmappedSamples + 1] = entry
			end
		end
	end
	table.sort(unmappedOrder, function(a, b) return unmappedByKind[a] > unmappedByKind[b] end)
	Line("    %d manquantes sans extension", unmappedTotal)
	for _, kind in ipairs(unmappedOrder) do
		Line("    %-28s %d", kind, unmappedByKind[kind])
	end
	Line("")

	-- 5. Découpage et rapprochement, sur des montures RESTÉES sans extension :
	--    ce sont elles qui portent l'information manquante.
	Line("[5] Texte de source, %d montures encore sans extension", DIAG_SAMPLES)
	local shown = 0
	for _, entry in ipairs(unmappedSamples) do
		if shown >= DIAG_SAMPLES then break end
		local _, _, sourceText = C_MountJournal.GetMountInfoExtraByID(entry.mountID)
		local boss, place = ParseSourceText(sourceText)
		Line("    %s", tostring(entry.name))
		Line("      brut  : %s", tostring(sourceText):gsub("\n", "\\n"))
		Line("      boss  : %s", tostring(boss))
		Line("      lieu  : %s", tostring(place))
		if place then
			local match = self.instanceIndex
				and self.instanceIndex[ns.Util.NormalizeName(place)]
			Line("      match : %s", match
				and string.format("%s [%s]", tostring(match.tierName), tostring(match.origin))
				or "AUCUN")
		end
		shown = shown + 1
	end
	Line("")

	-- 6. Bilan du dernier passage.
	Line("[6] Dernier scan")
	local meta = ns.db and ns.db.global.scanMeta
	if type(meta) == "table" and meta.at then
		Line("    %d/%d montures rattachées à une instance", meta.mapped or 0, meta.mounts or 0)
		Line("    %d instances (%s via Recherche de groupe, %s via Journal)",
			meta.instances or 0, tostring(meta.lfgInstances), tostring(meta.journalInstances))
		Line("    %s entrées de carte · approfondi : %s · il y a %s",
			tostring(meta.nodes), tostring(meta.deep), ns.Util.FormatAge(meta.at))
		local achievementStats = meta.achievementStats or {}
		Line("    hauts faits indexés : %s (%s/%s catégories rattachées)",
			tostring(meta.achievements), tostring(achievementStats.resolved),
			tostring(achievementStats.categories))
		local textStats = meta.textStats or {}
		Line("    par lieu : exact %s, étiqueté %s, préfixe %s, partiel %s · par haut fait %s",
			tostring(textStats.exact), tostring(textStats.labelled),
			tostring(textStats.prefix), tostring(textStats.partial),
			tostring(textStats.byAchievement))
		Line("    algo v%s (courant v%d) · passages infructueux : %s · à refaire : %s",
			tostring(meta.mappingVersion), MAPPING_VERSION,
			tostring(meta.emptyRuns), tostring(self:IsStale()))
	else
		Line("    aucun scan enregistré")
	end

	Line("")
	Line("[7] Niveau de confiance de l'extension")
	local byConfidence, order, resolved, total = {}, {}, 0, 0
	for _, source in pairs((ns.db and ns.db.global.sourceCache) or {}) do
		total = total + 1
		local how = source.tierName and (source.matchedBy or "?") or "aucune"
		if not byConfidence[how] then
			byConfidence[how] = 0
			order[#order + 1] = how
		end
		byConfidence[how] = byConfidence[how] + 1
		if source.tierName then resolved = resolved + 1 end
	end
	table.sort(order, function(a, b) return byConfidence[a] > byConfidence[b] end)
	Line("    %d/%d montures datées", resolved, total)
	for _, how in ipairs(order) do
		Line("    %-14s %d", how, byConfidence[how])
	end
	Line("    table curée embarquée : %d entrée(s)", ns.Data.CountCuratedMounts())

	Line("")
	Line("[8] Collection")
	local counts = ns.Collection.counts or {}
	Line("    %s possédées / %s obtenables / %s masquées · journal prêt : %s",
		tostring(counts.owned), tostring(counts.total), tostring(counts.hidden),
		tostring(ns.Collection.ready))

	return lines
end

--- Affiche le diagnostic dans une fenêtre copiable, et un résumé dans le chat.
function Mapping:Diagnose()
	local lines = self:BuildReport()

	local meta = ns.db and ns.db.global.scanMeta
	ns:Print(ns.L.DIAG_SUMMARY,
		(type(meta) == "table" and meta.mapped) or 0,
		(type(meta) == "table" and meta.mounts) or 0)

	if ns.Copy then
		ns.Copy:ShowLines(ns.L.DIAG_TITLE, lines)
	else
		for _, line in ipairs(lines) do
			DEFAULT_CHAT_FRAME:AddMessage(line)
		end
	end
	return lines
end

--------------------------------------------------------------------------------
-- Export du fichier de curation
--
-- Aucune requête réseau n'est possible depuis un addon : la table curée doit
-- être compilée au build. Cette commande produit le fichier de travail — un
-- CSV de toutes les montures, avec leur spellID comme clé de jointure et ce
-- que l'addon a déjà su déduire.
--
-- Le spellID, et pas le nom : une liste extérieure est écrite dans UNE langue,
-- et un rapprochement par nom marcherait chez celui qui teste puis échouerait
-- partout ailleurs.
--------------------------------------------------------------------------------

--- Échappement CSV minimal : guillemets doublés si le champ en contient ou
--  contient un séparateur.
local function CsvField(value)
	local text = tostring(value == nil and "" or value)
	if text:find('[",\n]') then
		return '"' .. text:gsub('"', '""') .. '"'
	end
	return text
end

--- @param onlyMissing true pour n'exporter que ce qui reste sans extension
function Mapping:BuildExport(onlyMissing)
	local lines = { "spellID,mountID,name,sourceType,expansion,source,place" }

	for _, entry in ipairs(ns.Collection:GetMissing()) do
		local source = ns.db and ns.db.global.sourceCache[entry.mountID]
		local tierName = source and source.tierName
		if not onlyMissing or not tierName then
			lines[#lines + 1] = table.concat({
				CsvField(entry.spellID),
				CsvField(entry.mountID),
				CsvField(entry.name),
				CsvField(entry.sourceTypeLabel or entry.kind),
				CsvField(tierName),
				CsvField(source and (source.instanceName or source.encounterName)),
				CsvField(source and source.placeName),
			}, ",")
		end
	end

	return lines
end

function Mapping:Export(onlyMissing)
	local lines = self:BuildExport(onlyMissing)
	ns:Print(ns.L.EXPORT_DONE, #lines - 1)
	if ns.Copy then
		ns.Copy:ShowLines(ns.L.EXPORT_TITLE, lines)
	end
	return lines
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
