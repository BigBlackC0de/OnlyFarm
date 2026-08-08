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
}

--- Libellé localisé d'un sourceType, tel que l'affiche l'interface Blizzard.
function Data.GetSourceTypeLabel(sourceType)
	if type(sourceType) ~= "number" then return nil end
	return _G["BATTLE_PET_SOURCE_" .. sourceType]
end

function Data.GetSourceKind(sourceType)
	return Data.SOURCE_TYPE_TO_KIND[sourceType] or K.UNKNOWN
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
