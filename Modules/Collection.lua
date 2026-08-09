--[[---------------------------------------------------------------------------
	OnlyFarm — Modules/Collection.lua

	Diff de collection : croise le Journal des montures avec ce que le
	personnage courant peut réellement obtenir, et produit la liste des
	montures manquantes.

	Toute la donnée vient du client, donc elle est exacte et suit les patchs
	sans intervention. Le seul piège est le timing : le Journal des montures
	n'est pas garanti peuplé à PLAYER_LOGIN.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Collection = ns:NewModule("Collection", 20)

-- Retours de C_MountJournal.GetMountInfoByID (vérifié sur 12.0.7) :
--  1 name  2 spellID  3 icon  4 isActive  5 isUsable  6 sourceType
--  7 isFavorite  8 isFactionSpecific  9 faction  10 shouldHideOnChar
-- 11 isCollected  12 mountID  13 isSteadyFlight
-- La fonction est marquée MayReturnNothing : `name` peut être nil.

function Collection:OnInitialize()
	self.owned = {}      -- [mountID] = true
	self.missing = {}    -- tableau d'entrées triées par nom
	self.byID = {}       -- [mountID] = entrée
	self.allIDs = {}     -- tous les mountID obtenables sur ce perso, possédés compris
	self.collected = {}  -- entrées des montures possédées, pour l'affichage
	self.counts = { total = 0, owned = 0, missing = 0, hidden = 0 }
	self.ready = false
	self.retries = 0
end

function Collection:OnEnable()
	self:RegisterEvent("NEW_MOUNT_ADDED", "OnCollectionChanged")
	-- COMPANION_LEARNED est un événement historique ; s'il a disparu,
	-- RegisterEvent le signale et l'ignore proprement.
	self:RegisterEvent("COMPANION_LEARNED", "OnCollectionChanged")
	self:RegisterMessage("OF_ENTERING_WORLD", "OnEnteringWorld")

	self.scheduleScan = ns.Util.Debounce(1.0, function() self:Scan() end)
	self.scheduleScan()
end

function Collection:OnEnteringWorld()
	-- Filet de sécurité : le Journal se peuple parfois après l'entrée en jeu.
	self.retries = 0
	self.scheduleScan()
end

function Collection:OnCollectionChanged(_, mountID)
	self:Debug("collection modifiée (mountID=%s)", tostring(mountID))
	self.scheduleScan()
end

--------------------------------------------------------------------------------
-- Scan
--------------------------------------------------------------------------------

local MAX_RETRIES = 5
local RETRY_DELAY = 2

--- Reconstruit `owned` / `missing`.
--  @return true si le scan a abouti, false si le Journal n'était pas prêt.
function Collection:Scan()
	local mountIDs = C_MountJournal and C_MountJournal.GetMountIDs()
	if type(mountIDs) ~= "table" or #mountIDs == 0 then
		self.ready = false
		self:Retry()
		return false
	end

	local owned, missing, byID, allIDs, collected = {}, {}, {}, {}, {}
	local counts = { total = 0, owned = 0, missing = 0, hidden = 0 }
	local excluded = (ns.db and ns.db.global.excluded) or {}

	for i = 1, #mountIDs do
		local mountID = mountIDs[i]
		local name, spellID, icon, _, _, sourceType, _, isFactionSpecific,
			faction, shouldHideOnChar, isCollected = C_MountJournal.GetMountInfoByID(mountID)

		if name then
			if shouldHideOnChar then
				-- Monture d'une autre faction ou d'une autre classe : elle ne
				-- tombera JAMAIS sur ce personnage. Elle sort du total, et le
				-- compteur n'est gardé que pour le diagnostic — l'afficher
				-- revenait à mettre en avant un chiffre sur lequel le joueur ne
				-- peut rien.
				counts.hidden = counts.hidden + 1
			else
				counts.total = counts.total + 1
				-- Possédées comprises : le tableau de bord a besoin du
				-- dénominateur pour dire « 12/31 sur Ulduar », pas seulement
				-- de ce qui manque.
				allIDs[#allIDs + 1] = mountID

				-- Une entrée est construite pour TOUTES les montures, possédées
				-- comprises : la liste doit pouvoir les afficher, et une
				-- monture obtenue ne perd pas son intérêt (on veut savoir d'où
				-- elle venait). Le coût est d'environ 1600 petites tables.
				local entry = {
					mountID = mountID,
					name = name,
					spellID = spellID,
					icon = icon,
					sourceType = sourceType,
					kind = ns.Data.GetSourceKind(sourceType),
					sourceTypeLabel = ns.Data.GetSourceTypeLabel(sourceType),
					isFactionSpecific = isFactionSpecific,
					faction = faction,
					owned = isCollected and true or false,
					excluded = excluded[mountID] and true or false,
				}
				byID[mountID] = entry

				if isCollected then
					owned[mountID] = true
					counts.owned = counts.owned + 1
					collected[#collected + 1] = entry
				else
					missing[#missing + 1] = entry
					counts.missing = counts.missing + 1
				end
			end
		end
	end

	local function ByKindThenName(a, b)
		if a.kind ~= b.kind then return a.kind < b.kind end
		return a.name < b.name
	end
	table.sort(missing, ByKindThenName)
	table.sort(collected, ByKindThenName)

	self.owned = owned
	self.missing = missing
	self.byID = byID
	self.allIDs = allIDs
	self.collected = collected
	self.counts = counts
	self.ready = true
	self.retries = 0
	self.lastScan = time()

	self:Debug("collection : %d possédées / %d obtenables, %d masquées sur ce perso",
		counts.owned, counts.total, counts.hidden)
	self:SendMessage("OF_COLLECTION_UPDATED")
	return true
end

function Collection:Retry()
	if self.retries >= MAX_RETRIES then
		self:Debug("Journal des montures toujours vide après %d tentatives, abandon.",
			MAX_RETRIES)
		return
	end
	self.retries = self.retries + 1
	self:Debug("Journal des montures vide, nouvelle tentative %d/%d",
		self.retries, MAX_RETRIES)
	C_Timer.After(RETRY_DELAY, function() self:Scan() end)
end

--------------------------------------------------------------------------------
-- Lecture
--------------------------------------------------------------------------------

function Collection:IsOwned(mountID)
	return self.owned[mountID] == true
end

function Collection:GetMissing()
	return self.missing
end

--- Montures déjà possédées, mêmes entrées que les manquantes.
function Collection:GetCollected()
	return self.collected
end

function Collection:GetEntry(mountID)
	return self.byID[mountID]
end

--- Informations « extra » du Journal, résolues à la demande et mises en cache.
--
--  Un seul appel pour les deux données qui en viennent — le texte de source et
--  le `mountTypeID` — parce que c'est l'appel qui coûte, pas ce qu'on en lit.
--  Le faire pour 800 montures au moment du scan doublerait sa durée pour des
--  colonnes que le joueur ne regarde peut-être jamais.
--
--  Retours de C_MountJournal.GetMountInfoExtraByID (vérifié sur 12.0.7) :
--   1 creatureDisplayInfoID  2 description  3 source  4 isSelfMount
--   5 mountTypeID  6 uiModelSceneID  7 animID  8 spellVisualKitID
--   9 disablePlayerMountPreview
function Collection:ResolveExtra(mountID)
	local entry = self.byID[mountID]
	if not entry then return nil end
	if entry.extraResolved then return entry end

	local _, _, source, _, mountTypeID = C_MountJournal.GetMountInfoExtraByID(mountID)
	entry.sourceText = source or false
	entry.mountTypeID = type(mountTypeID) == "number" and mountTypeID or false
	entry.movement = ns.Data.GetMovementKind(entry.mountTypeID or nil)
	entry.extraResolved = true
	return entry
end

--- Texte de source du Journal (« Butin : Yogg-Saron\nUlduar »).
function Collection:GetSourceText(mountID)
	local entry = self:ResolveExtra(mountID)
	if not entry then return nil end
	return entry.sourceText or nil
end

--- Mode de déplacement d'une monture : terrestre, volante, skyriding,
--  aquatique — ou « autre » quand le client renvoie un type qu'on ne sait pas
--  encore lire (cf. Data/MountTypes.lua).
function Collection:GetMovement(mountID)
	local entry = self:ResolveExtra(mountID)
	if not entry then return ns.Data.MOVEMENT.OTHER end
	return entry.movement or ns.Data.MOVEMENT.OTHER
end

--- Texte de source ramené sur une ligne, ce qui tient dans une colonne.
--
--  Attention au séparateur : le Journal des montures n'utilise PAS de vrai
--  retour à la ligne, il utilise la séquence d'échappement « |n » du client.
--  Ne traiter que « \n » laissait passer le « | » dans la colonne, et une
--  troncature en plein milieu affichait « Le roi-liche|... ».
--
--  On enlève aussi les codes couleur : tronqués par la FontString, ils
--  laissent des fragments de « |cffxxxxxx » à l'écran.
function Collection:GetSourceSummary(mountID)
	local text = self:GetSourceText(mountID)
	if not text then
		local entry = self.byID[mountID]
		return entry and entry.sourceTypeLabel or nil
	end

	local clean = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	clean = clean:gsub("|n", "\n"):gsub("[\r\n]+", " — ")
	return (clean:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Natures de source réellement présentes dans les montures manquantes, avec
--  leur libellé localisé et leur effectif.
--
--  On ne liste PAS les natures possibles mais celles qui existent chez ce
--  joueur : un menu où la moitié des entrées donne zéro résultat se lit comme
--  un menu cassé. Les effectifs sont affichés pour la même raison.
--  @return liste triée { kind, label, count }
function Collection:GetSourceKinds()
	local buckets, order = {}, {}

	for _, entry in ipairs(self.missing) do
		local kind = entry.kind or "unknown"
		local bucket = buckets[kind]
		if not bucket then
			bucket = {
				kind = kind,
				label = entry.sourceTypeLabel or kind,
				count = 0,
			}
			buckets[kind] = bucket
			order[#order + 1] = bucket
		end
		bucket.count = bucket.count + 1
	end

	table.sort(order, function(a, b)
		if a.count ~= b.count then return a.count > b.count end
		return a.label < b.label
	end)
	return order
end

function Collection:SetExcluded(mountID, excluded)
	if not ns.db then return end
	ns.db.global.excluded[mountID] = excluded or nil
	local entry = self.byID[mountID]
	if entry then entry.excluded = excluded and true or false end
	self:SendMessage("OF_COLLECTION_UPDATED")
end

function Collection:IsExcluded(mountID)
	return ns.db and ns.db.global.excluded[mountID] == true or false
end
