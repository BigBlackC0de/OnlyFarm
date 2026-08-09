--[[---------------------------------------------------------------------------
	OnlyFarm — Core/Database.lua

	Persistance. Remplit le rôle d'AceDB-3.0 sans la dépendance :
	  ns.db.global   — partagé par tout le compte (verrous, routes, exclusions)
	  ns.db.profile  — réglages du personnage courant
	  ns.db.char     — entrée `global.chars[clé du perso]` du personnage courant

	Migrations : un entier `schema` + une chaîne de fonctions v -> v+1 rejouée
	au chargement. Ne jamais réutiliser un numéro déjà publié.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Database = ns:NewModule("Database", 10)

local CURRENT_SCHEMA = 2

local GLOBAL_DEFAULTS = {
	chars = {},              -- [charKey] = { …, lockouts = {}, dungeonEntries = {} }
	excluded = {},           -- [mountID] = true — montures que le joueur ignore
	attempts = {},           -- [mountID] = { count, lastAt, byChar = {} }
	routes = {},             -- phase 5
	travelTimings = {},      -- phase 3 : auto-apprentissage des durées de vol
	sourceCache = {},        -- [mountID] = source résolue par Mapping
	nodeCache = {},          -- [nodeID] = entrée d'instance moissonnée par Mapping
	customNodes = {},        -- [nodeID] = point posé par le joueur (éditeur de route)
	instanceIDsByName = {},  -- [nom normalisé] = instanceID moteur (pont EJ <-> verrous)
	scanMeta = {},           -- horodatage et build du dernier scan
}

local PROFILE_DEFAULTS = {
	-- Le scan du Journal des rencontres tourne tout seul à la première
	-- connexion et après chaque patch. C'est lui qui remplit le filtre par
	-- extension et la géographie ; sans lui l'addon est à moitié muet, donc il
	-- est actif par défaut et se coupe explicitement.
	autoScan = true,
	ui = {
		point = "CENTER",
		x = 0,
		y = 0,
		width = 900,
		height = 620,
		scale = 1.0,
		activeTab = 1,
	},
	minimap = {
		angle = 205,       -- degrés, position sur l'anneau de la minicarte
		hide = false,
	},
	dashboard = {
		-- Axe du graphe de répartition : "source" | "movement". La nature de la
		-- source d'abord, parce que c'est celle sur laquelle on agit — c'est
		-- elle qui dit où aller farmer.
		axis = "source",
	},
	filters = {
		search = "",
		-- Les possédées sont masquées par défaut : l'addon répond d'abord à
		-- « qu'est-ce qu'il me manque ». Les revoir reste à un clic.
		showOwned = false,
		availableOnly = false,
		hideUnmapped = false,
		-- Une monture exclue reste visible, grisée. La faire disparaître d'un
		-- clic droit donnait l'impression d'avoir cassé quelque chose.
		hideExcluded = false,
		-- Extensions décochées dans le menu. Vide = tout est affiché : on ne
		-- veut pas qu'un nouveau palier ajouté par un patch soit masqué par
		-- défaut parce qu'il n'était pas dans la liste au moment du réglage.
		expansionsHidden = {},
		-- Même règle pour les natures de source (butin, haut fait, vendeur…).
		kindsHidden = {},
		-- "all" | "raid" | "dungeon" | "outdoor"
		instanceType = "all",
		-- "name" | "source" | "expansion" | "status" | "attempts"
		sort = "name",
	},
	routing = {
		flySpeed = 75,          -- yd/s, calibré par le joueur (phase 3)
		budgetMinutes = 0,      -- 0 = pas de budget
		respectInstanceCap = true,
	},
}

local CHAR_DEFAULTS = {
	lockouts = {},        -- ["instanceID:difficultyID"] = { … }
	dungeonEntries = {},  -- [instanceID] = horodatage de la dernière entrée
	lastSeen = 0,
}

--------------------------------------------------------------------------------
-- Migrations
--------------------------------------------------------------------------------

-- migrations[v] transforme un schéma de version v en version v+1.
local migrations = {}
Database.migrations = migrations

--- 1 -> 2 : les montures exclues étaient masquées par défaut. Un clic droit
--  les faisait donc littéralement disparaître de la liste, ce qui se lit comme
--  un bug et pas comme une action. Elles restent désormais affichées, grisées.
--  ApplyDefaults ne corrige pas les profils existants — il ne remplace jamais
--  une valeur présente — d'où cette migration.
migrations[1] = function(sv)
	if type(sv.profiles) ~= "table" then return end
	for _, profile in pairs(sv.profiles) do
		if type(profile.filters) == "table" and profile.filters.hideExcluded == true then
			profile.filters.hideExcluded = false
		end
	end
end

local function Migrate(sv)
	local from = sv.schema or 0
	if from == 0 then
		-- Base neuve : rien à migrer, on estampille directement.
		sv.schema = CURRENT_SCHEMA
		return
	end
	while from < CURRENT_SCHEMA do
		local step = migrations[from]
		if not step then
			ns:Print("aucune migration %d -> %d, base laissée telle quelle.",
				from, from + 1)
			break
		end
		ns.SafeCall(step, sv)
		from = from + 1
		sv.schema = from
	end
	if sv.schema and sv.schema > CURRENT_SCHEMA then
		ns:Print("base écrite par une version plus récente d'OnlyFarm (schéma %d > %d).",
			sv.schema, CURRENT_SCHEMA)
	end
end

--------------------------------------------------------------------------------
-- Initialisation
--------------------------------------------------------------------------------

function Database:OnInitialize()
	if type(OnlyFarmDB) ~= "table" then OnlyFarmDB = {} end
	local sv = OnlyFarmDB

	Migrate(sv)

	sv.global = sv.global or {}
	sv.profiles = sv.profiles or {}
	ns.Util.ApplyDefaults(sv.global, GLOBAL_DEFAULTS)

	local charKey = ns.Util.PlayerKey()
	self.charKey = charKey

	local profile = {}
	if charKey then
		sv.profiles[charKey] = sv.profiles[charKey] or {}
		profile = sv.profiles[charKey]
	end
	ns.Util.ApplyDefaults(profile, PROFILE_DEFAULTS)

	local charEntry = {}
	if charKey then
		sv.global.chars[charKey] = sv.global.chars[charKey] or {}
		charEntry = sv.global.chars[charKey]
		ns.Util.ApplyDefaults(charEntry, CHAR_DEFAULTS)
	end

	ns.db = {
		sv = sv,
		global = sv.global,
		profile = profile,
		char = charEntry,
		charKey = charKey,
	}

	self:Debug("base prête (schéma %d, %d perso(s) connus)",
		sv.schema or 0, ns.Util.Count(sv.global.chars))
end

function Database:OnEnable()
	-- L'instantané n'est fiable qu'à PLAYER_LOGIN (niveau, faction, classe).
	if not ns.db or not ns.db.char then return end
	local snapshot = ns.Util.PlayerSnapshot()
	for key, value in pairs(snapshot) do
		ns.db.char[key] = value
	end
end

--------------------------------------------------------------------------------
-- Accès
--------------------------------------------------------------------------------

--- Entrée d'un personnage arbitraire (nil si inconnu).
function Database:GetChar(charKey)
	return ns.db and ns.db.global.chars[charKey] or nil
end

--- Liste des personnages connus, triée par nom.
function Database:GetCharKeys()
	local keys = {}
	if not ns.db then return keys end
	for key in pairs(ns.db.global.chars) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return keys
end

--- Un perso pas revu depuis plus de STALE_AFTER a des verrous « incertains » :
--  il a pu faire l'instance depuis, on n'en sait rien.
Database.STALE_AFTER = 7 * 86400

function Database:IsStale(charEntry)
	if not charEntry or type(charEntry.lastSeen) ~= "number" then return true end
	return (time() - charEntry.lastSeen) > Database.STALE_AFTER
end

--- Efface tout et reconstruit une base neuve. On ne laisse jamais `ns.db` à
--  nil : l'interface et les commandes continueraient de tourner et
--  planteraient au premier accès. Un /reload reste conseillé pour repartir
--  d'un état propre côté modules.
function Database:Wipe()
	OnlyFarmDB = nil
	OnlyFarmScanDB = nil
	self:OnInitialize()
	self:OnEnable()
end
