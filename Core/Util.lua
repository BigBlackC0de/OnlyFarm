--[[---------------------------------------------------------------------------
	OnlyFarm — Core/Util.lua

	Helpers sans état : temps, formatage, tables, anti-rebond.
	Rien ici ne doit dépendre d'un module d'OnlyFarm.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Util = {}
ns.Util = Util

--------------------------------------------------------------------------------
-- Identité du personnage
--------------------------------------------------------------------------------

--- Clé stable d'un personnage dans la base account-wide : « Nom-Royaume ».
--  GetNormalizedRealmName() retire espaces et apostrophes ; on retombe sur
--  GetRealmName() si l'API n'est pas encore prête (très tôt au login).
function Util.PlayerKey()
	local name = UnitName("player")
	if not name then return nil end
	local realm = (GetNormalizedRealmName and GetNormalizedRealmName())
		or (GetRealmName and GetRealmName())
		or "?"
	return name .. "-" .. realm
end

--- Instantané du personnage courant, stocké à chaque connexion.
function Util.PlayerSnapshot()
	local _, class = UnitClass("player")
	local faction = UnitFactionGroup("player")
	return {
		name = UnitName("player"),
		realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or nil,
		class = class,
		faction = faction,             -- "Alliance" | "Horde" | "Neutral"
		level = UnitLevel("player"),
		lastSeen = time(),
	}
end

--------------------------------------------------------------------------------
-- Temps et frontières de reset
--------------------------------------------------------------------------------

local SECONDS_PER_DAY = 86400

--- Horodatage du prochain reset quotidien du royaume, ou nil si l'API n'a pas
--  encore de réponse (elle renvoie parfois nil très tôt après le login).
function Util.NextDailyReset()
	local remaining = C_DateAndTime and C_DateAndTime.GetSecondsUntilDailyReset
		and C_DateAndTime.GetSecondsUntilDailyReset()
	if type(remaining) ~= "number" or remaining <= 0 then return nil end
	return time() + remaining
end

--- Horodatage du prochain reset hebdomadaire du royaume (mardi ou mercredi
--  selon la région — c'est le client qui tranche, on ne le devine pas).
function Util.NextWeeklyReset()
	local remaining = C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset
		and C_DateAndTime.GetSecondsUntilWeeklyReset()
	if type(remaining) ~= "number" or remaining <= 0 then return nil end
	return time() + remaining
end

--- Début de la journée de jeu courante = dernier reset quotidien passé.
--  Sert à décider si « je suis déjà entré dans ce donjon aujourd'hui ».
function Util.LastDailyReset()
	local nextReset = Util.NextDailyReset()
	if not nextReset then return nil end
	return nextReset - SECONDS_PER_DAY
end

--- true si `timestamp` est postérieur au dernier reset quotidien.
--  Renvoie nil (et non false) quand la frontière est inconnue : l'appelant
--  doit alors afficher « incertain » plutôt qu'une réponse inventée.
function Util.IsSinceDailyReset(timestamp)
	if type(timestamp) ~= "number" then return false end
	local boundary = Util.LastDailyReset()
	if not boundary then return nil end
	return timestamp >= boundary
end

--- « 3 j 4 h », « 4 h 12 min », « 12 min », « 45 s ».
function Util.FormatDuration(seconds)
	seconds = tonumber(seconds)
	if not seconds or seconds <= 0 then return "—" end
	local L = ns.L
	local days = math.floor(seconds / SECONDS_PER_DAY)
	local hours = math.floor((seconds % SECONDS_PER_DAY) / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	if days > 0 then
		return string.format("%d%s %d%s", days, L.UNIT_DAY, hours, L.UNIT_HOUR)
	elseif hours > 0 then
		return string.format("%d%s %d%s", hours, L.UNIT_HOUR, minutes, L.UNIT_MIN)
	elseif minutes > 0 then
		return string.format("%d%s", minutes, L.UNIT_MIN)
	end
	return string.format("%d%s", seconds, L.UNIT_SEC)
end

--- Ancienneté lisible d'un `lastSeen`.
function Util.FormatAge(timestamp)
	if type(timestamp) ~= "number" then return "?" end
	return Util.FormatDuration(time() - timestamp)
end

--------------------------------------------------------------------------------
-- Anti-rebond / limitation de débit
--------------------------------------------------------------------------------

--- Retourne une fonction qui, appelée n fois en rafale, n'exécute `func`
--  qu'une seule fois, `delay` secondes après le dernier appel.
--  Utilisé pour les rescans (SPELLS_CHANGED, NEW_MOUNT_ADDED en masse…).
function Util.Debounce(delay, func)
	local pending = false
	return function(...)
		if pending then return end
		pending = true
		local args = { ... }
		local n = select("#", ...)
		C_Timer.After(delay, function()
			pending = false
			ns.SafeCall(func, unpack(args, 1, n))
		end)
	end
end

--- Comme Debounce, mais garantit au moins `interval` secondes entre deux
--  exécutions réelles (premier appel immédiat).
function Util.Throttle(interval, func)
	local lastRun = 0
	local scheduled = false
	return function(...)
		local now = GetTime and GetTime() or time()
		local elapsed = now - lastRun
		if elapsed >= interval then
			lastRun = now
			return ns.SafeCall(func, ...)
		end
		if scheduled then return end
		scheduled = true
		local args = { ... }
		local n = select("#", ...)
		C_Timer.After(interval - elapsed, function()
			scheduled = false
			lastRun = GetTime and GetTime() or time()
			ns.SafeCall(func, unpack(args, 1, n))
		end)
	end
end

--------------------------------------------------------------------------------
-- Tables
--------------------------------------------------------------------------------

function Util.Count(tbl)
	local n = 0
	for _ in pairs(tbl) do n = n + 1 end
	return n
end

--- Copie récursive des valeurs manquantes de `defaults` vers `target`.
--  Ne détruit jamais une valeur existante : c'est la brique des migrations.
function Util.ApplyDefaults(target, defaults)
	for key, value in pairs(defaults) do
		if type(value) == "table" then
			if type(target[key]) ~= "table" then target[key] = {} end
			Util.ApplyDefaults(target[key], value)
		elseif target[key] == nil then
			target[key] = value
		end
	end
	return target
end

function Util.CopyTable(source)
	local copy = {}
	for key, value in pairs(source) do
		copy[key] = type(value) == "table" and Util.CopyTable(value) or value
	end
	return copy
end

--- Clé de comparaison insensible à la casse et aux espaces, pour rapprocher
--  un nom d'instance du Journal des rencontres d'un nom de verrou sauvegardé.
--  Les deux viennent du même client, donc de la même locale.
function Util.NormalizeName(name)
	if type(name) ~= "string" then return nil end
	return (name:lower():gsub("%s+", " "):gsub("^%s", ""):gsub("%s$", ""))
end

--------------------------------------------------------------------------------
-- Couleurs
--------------------------------------------------------------------------------

Util.COLORS = {
	available = "|cff40ff40",
	locked = "|cffff5555",
	unknown = "|cff999999",
	stale = "|cffbbbb55",
	accent = "|cff7ac1ff",
	reset = "|r",
}

function Util.Colorize(color, text)
	return (Util.COLORS[color] or "") .. tostring(text) .. Util.COLORS.reset
end
