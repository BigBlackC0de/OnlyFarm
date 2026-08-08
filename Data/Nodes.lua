--[[---------------------------------------------------------------------------
	OnlyFarm — Data/Nodes.lua

	Schéma de la base des nœuds géographiques + table statique.

	>>> La table `Nodes` est VOLONTAIREMENT VIDE. <<<

	Même règle que Data/Sources.lua : aucune coordonnée n'est écrite à la main.
	Elles viennent toutes du client, moissonnées par `/of ejscan` via
	C_EncounterJournal.GetDungeonEntrancesForMap — c'est exactement la source
	qu'utilise la carte du monde pour poser ses icônes d'entrée de donjon, donc
	elle est juste par construction et suit les patchs toute seule.

	Build/generate_data.py fige ce moissonnage dans ce fichier au moment du
	build ; en attendant, le cache de `db.global.nodeCache` fait le travail.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Data = ns.Data

--------------------------------------------------------------------------------
-- Vocabulaire
--------------------------------------------------------------------------------

Data.NODE_KINDS = {
	INSTANCE = "instance",  -- entrée d'instance, moissonnée depuis le client
	HUB = "hub",            -- ancre de voyage (capitale, camp de portails)
	OUTDOOR = "outdoor",    -- point de spawn d'un rare, vendeur, nœud de métier
	CUSTOM = "custom",      -- posé par le joueur depuis l'éditeur de route
}

--- Identifiant de nœud d'une instance. Le journalInstanceID est stable entre
--  patchs, contrairement au nom localisé : c'est lui qui sert de clé.
function Data.InstanceNodeID(journalInstanceID)
	return "ej:" .. tostring(journalInstanceID)
end

--------------------------------------------------------------------------------
-- Table statique
--------------------------------------------------------------------------------

--[[
	Forme d'une entrée :

	Data.Nodes["ej:187"] = {
		nodeID            = "ej:187",
		name              = "Ulduar",       -- nom localisé, indicatif
		kind              = "instance",
		uiMapID           = 492,
		x                 = 0.415,          -- coordonnées normalisées de la carte
		y                 = 0.185,
		continentID       = 113,            -- continent des coordonnées monde
		wx                = 5820.4,         -- coordonnées monde, en yards
		wy                = -1042.7,
		journalInstanceID = 187,
	}

	`continentID` / `wx` / `wy` viennent de C_Map.GetWorldPosFromMapPos. Deux
	nœuds ne sont comparables en distance que s'ils partagent le même
	`continentID` — c'est ce qui interdit au routeur de croire qu'on peut voler
	de Kalimdor à Draenor.
--]]
Data.Nodes = {}
