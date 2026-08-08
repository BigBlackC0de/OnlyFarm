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

local CURRENT_SCHEMA = 1

local GLOBAL_DEFAULTS = {
	chars = {},              -- [charKey] = { …, lockouts = {}, dungeonEntries = {} }
	excluded = {},           -- [mountID] = true — montures que le joueur ignore
	routes = {},             -- phase 5
	travelTimings = {},      -- phase 3 : auto-apprentissage des durées de vol
	sourceCache = {},        -- [mountID] = source résolue par DevScan (phase 2)
	instanceIDsByName = {},  -- [nom normalisé] = instanceID moteur (pont EJ <-> verrous)
	scanMeta = {},           -- horodatage et build du dernier DevScan
}

local PROFILE_DEFAULTS = {
	ui = {
		point = "CENTER",
		x = 0,
		y = 0,
		scale = 1.0,
		activeTab = 1,
	},
	filters = {
		search = "",
		availableOnly = false,
		hideUnmapped = false,
		hideExcluded = true,
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
-- Vide aujourd'hui : la 1 est la version initiale publiée.
local migrations = {}
Database.migrations = migrations

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
