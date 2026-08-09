--[[---------------------------------------------------------------------------
	OnlyFarm — Data/Sources.lua

	Schéma de la base des sources + table statique.

	>>> ÉTAT PHASE 1 : la table `Sources` est VOLONTAIREMENT VIDE. <<<

	Elle sera générée en phase 2 par Build/generate_data.py à partir du dump
	produit en jeu par Modules/Mapping.lua. Aucun identifiant n'est écrit à la
	main ici : un mountID ou un instanceID inventé produit un addon qui ment
	silencieusement, ce qui est pire que pas de données du tout.

	En attendant, OnlyFarm fonctionne sans cette table :
	  * la liste des montures manquantes vient entièrement du client
	    (C_MountJournal), donc elle est exacte et se met à jour toute seule ;
	  * la catégorie de source vient de `sourceType` + du texte de source du
	    Journal des montures, également fournis par le client ;
	  * la disponibilité fine (verrou d'instance) s'appuie sur le cache écrit
	    par `/of ejscan`, fusionné par-dessus cette table (cf. Eligibility).
-----------------------------------------------------------------------------]]

local _, ns = ...

local Data = ns.Data

--------------------------------------------------------------------------------
-- Vocabulaire
--------------------------------------------------------------------------------

--- Nature d'une source. `boss` est la seule que le pipeline sait générer ;
--  les autres restent curées à la main (~80 entrées, stables entre patchs).
Data.SOURCE_KINDS = {
	BOSS = "boss",
	RARE = "rare",
	VENDOR = "vendor",
	PROFESSION = "profession",
	EVENT = "event",
	PVP = "pvp",
	QUEST = "quest",
	ACHIEVEMENT = "achievement",
	UNKNOWN = "unknown",
}

--- Horloge qui gouverne la disponibilité d'une source.
--  Deux horloges distinctes, c'est la règle la plus souvent ratée :
--  un raid legacy reset à la semaine, un donjon legacy reset au jour.
Data.LOCKOUT = {
	WEEKLY = "weekly",
	DAILY = "daily",
	RESPAWN = "respawn",  -- pas de verrou, seulement un temps de réapparition
	NONE = "none",
}

--------------------------------------------------------------------------------
-- Correspondance sourceType (client) -> nature de source (OnlyFarm)
--
-- `sourceType` est le 6e retour de C_MountJournal.GetMountInfoByID. Le libellé
-- localisé correspondant est toujours _G["BATTLE_PET_SOURCE_"..sourceType] :
-- c'est ce que fait l'interface Blizzard elle-même, donc on l'utilise pour
-- l'affichage plutôt que de traduire nous-mêmes.
--------------------------------------------------------------------------------

local K = Data.SOURCE_KINDS

Data.SOURCE_TYPE_TO_KIND = {
	[1] = K.BOSS,         -- Drop
	[2] = K.QUEST,        -- Quest
	[3] = K.VENDOR,       -- Vendor
	[4] = K.PROFESSION,   -- Profession
	[5] = K.UNKNOWN,      -- Pet Battle (sans objet pour les montures)
	[6] = K.ACHIEVEMENT,  -- Achievement
	[7] = K.EVENT,        -- World Event
	[8] = K.UNKNOWN,      -- Promotion
	[9] = K.UNKNOWN,      -- Trading Card Game
	[10] = K.UNKNOWN,     -- In-Game Store
	[11] = K.UNKNOWN,     -- Discovery
	[12] = K.UNKNOWN,     -- Comptoir (Trading Post)
}

-- Note sur les `UNKNOWN` ci-dessus : ce n'est PAS un aveu d'ignorance, c'est le
-- sens de `kind`. Promotion, JCC, boutique, découverte et comptoir n'ont aucun
-- verrou et ne se farment pas : pour la logique de disponibilité, elles se
-- comportent identiquement. À l'affichage, en revanche, ce sont cinq catégories
-- distinctes — d'où la mise en garde qui suit.

--- Libellé localisé d'un sourceType, tel que l'affiche l'interface Blizzard.
function Data.GetSourceTypeLabel(sourceType)
	if type(sourceType) ~= "number" then return nil end
	return _G["BATTLE_PET_SOURCE_" .. sourceType]
end

function Data.GetSourceKind(sourceType)
	return Data.SOURCE_TYPE_TO_KIND[sourceType] or K.UNKNOWN
end

--------------------------------------------------------------------------------
-- Deux axes, et il ne faut pas les confondre
--
-- `kind` (ci-dessus) est la taxonomie INTERNE : elle sert à la logique — cette
-- monture tombe-t-elle d'un boss, donc y a-t-il un verrou ? Elle écrase exprès
-- ce qui se comporte pareil : promotion, JCC, boutique, découverte et comptoir
-- n'ont aucun verrou, donc tous `unknown`.
--
-- `sourceType` est l'axe D'AFFICHAGE. Il ne doit JAMAIS passer par `kind`, et
-- c'est l'erreur qui a produit un menu de filtre affichant « Promotion (66) »
-- pour un seau qui contenait cinq catégories : le libellé venait de la première
-- monture croisée, et l'effectif de toutes les autres. Cinq réponses fausses
-- sous une étiquette juste.
--
-- Règle : tout ce qui s'affiche ou se filtre par source part de `sourceType` et
-- de son libellé client. Tout ce qui raisonne sur les verrous part de `kind`.
--------------------------------------------------------------------------------

--- Seau de source d'une entrée : clé, libellé, rang d'affichage.
--  Un seul endroit décide, pour que le graphe du tableau de bord et le menu de
--  filtre de la collection listent exactement les mêmes catégories.
--  @return sourceType, libellé, rang (0 = nommé par le client, 1 = panier)
function Data.GetSourceBucket(entry)
	local sourceType = entry and entry.sourceType
	local label = Data.GetSourceTypeLabel(sourceType)
	if label then return sourceType or 0, label, 0 end
	-- Pas de libellé côté client : un sourceType plus récent que nos constantes.
	-- Il tombe dans « Autres », qui ferme la marche.
	return sourceType or 0, ns.L.SOURCE_UNKNOWN, 1
end

--- Ordre d'affichage des seaux de source : les nommés d'abord, puis par
--  effectif décroissant, puis par libellé.
--
--  L'effectif retenu est `total` (possédées comprises) et non le nombre de
--  manquantes : il ne bouge qu'à un patch, donc l'ordre des lignes ne change pas
--  quand une monture rentre — et les deux écrans qui l'utilisent restent dans le
--  même ordre l'un que l'autre.
function Data.CompareSourceBuckets(a, b)
	if a.rank ~= b.rank then return a.rank < b.rank end
	if a.total ~= b.total then return a.total > b.total end
	return tostring(a.label) < tostring(b.label)
end

--------------------------------------------------------------------------------
-- Table statique
--------------------------------------------------------------------------------

--[[
	Forme d'une entrée, pour référence (générée en phase 2) :

	Data.Sources["srcULD_Yogg"] = {
		kind         = "boss",
		mountIDs     = { 264 },        -- montures obtenues ici
		instanceName = "Ulduar",       -- nom localisé, sert de pont vers les verrous
		instanceID   = 759,            -- instanceID moteur (GetSavedInstanceInfo)
		journalID    = 187,            -- journalInstanceID (Journal des rencontres)
		encounterID  = 1143,
		difficulty   = { 14, 15, 16 },
		nodeID       = "node_ulduar",  -- phase 3
		lockout      = "weekly",
		dropRate     = 0.01,           -- estimation communautaire, jamais exacte
		runTime      = 420,            -- secondes, solo au niveau max
		verified     = true,
	}
--]]
Data.Sources = {}

--- Index inverse mountID -> { sourceID, … }, reconstruit à la volée.
function Data.BuildMountIndex()
	local index = {}
	for sourceID, source in pairs(Data.Sources) do
		if type(source.mountIDs) == "table" then
			for _, mountID in ipairs(source.mountIDs) do
				index[mountID] = index[mountID] or {}
				table.insert(index[mountID], sourceID)
			end
		end
	end
	return index
end
