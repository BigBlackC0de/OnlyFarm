--[[---------------------------------------------------------------------------
	OnlyFarm — Modules/Stats.lua

	Agrégats du tableau de bord. Séparé de l'interface exprès : ce sont des
	chiffres, donc ça se teste hors du jeu, et ça évite qu'une frame calcule.

	Tout est recalculé à la demande et mis en cache jusqu'au prochain
	changement. Un scan de collection, un verrou, une tentative : le cache
	tombe. Rien ne tourne en continu.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Stats = ns:NewModule("Stats", 45)

-- Au-delà, le graphe par extension devient un mur de barres illisible ; on
-- garde les extensions les moins complètes, c'est là qu'il reste à faire.
local MAX_EXPANSION_ROWS = 12
local MAX_TOP_TARGETS = 6

function Stats:OnInitialize()
	self.cache = nil
end

function Stats:OnEnable()
	self:RegisterMessage("OF_COLLECTION_UPDATED", "Invalidate")
	self:RegisterMessage("OF_LOCKOUTS_UPDATED", "Invalidate")
	self:RegisterMessage("OF_SCAN_COMPLETE", "Invalidate")
	self:RegisterMessage("OF_ATTEMPTS_UPDATED", "Invalidate")
end

function Stats:Invalidate()
	self.cache = nil
end

--------------------------------------------------------------------------------
-- Calcul
--------------------------------------------------------------------------------

function Stats:Get()
	if not self.cache then self.cache = self:Compute() end
	return self.cache
end

function Stats:Compute()
	local STATE = ns.Eligibility.STATE
	local counts = ns.Collection.counts or { total = 0, owned = 0, missing = 0, hidden = 0 }

	local result = {
		total = counts.total,
		owned = counts.owned,
		missing = counts.missing,
		hidden = counts.hidden,
		ratio = counts.total > 0 and (counts.owned / counts.total) or 0,
		byState = {
			[STATE.AVAILABLE] = 0,
			[STATE.LOCKED] = 0,
			[STATE.UNKNOWN] = 0,
			[STATE.UNMAPPED] = 0,
			[STATE.INELIGIBLE] = 0,
		},
		expansions = {},
		kinds = {},
		topTargets = {},
	}

	-- Progression par extension, possédées comprises : sans le dénominateur,
	-- une barre ne dit rien.
	local buckets, order = {}, {}
	for _, mountID in ipairs(ns.Collection.allIDs or {}) do
		local name = ns.Eligibility:GetExpansion(mountID)
		local bucket = buckets[name]
		if not bucket then
			local source = ns.Eligibility:GetSource(mountID)
			bucket = {
				name = name,
				tier = (source and tonumber(source.tier)) or math.huge,
				owned = 0,
				total = 0,
			}
			buckets[name] = bucket
			order[#order + 1] = bucket
		end
		bucket.total = bucket.total + 1
		if ns.Collection:IsOwned(mountID) then
			bucket.owned = bucket.owned + 1
		end
	end

	-- Les moins avancées d'abord : c'est la question posée au tableau de bord,
	-- « où me reste-t-il du travail ». Une extension terminée n'apprend rien.
	--
	-- Le panier « inconnue » est renvoyé en dernier quel que soit son ratio.
	-- C'est mécaniquement le moins avancé — rien n'y est cartographié — donc
	-- il trusterait la première ligne en permanence, alors qu'il ne désigne
	-- aucun endroit où aller.
	local UNKNOWN = ns.Eligibility.UNKNOWN_EXPANSION
	table.sort(order, function(a, b)
		local ua, ub = a.name == UNKNOWN, b.name == UNKNOWN
		if ua ~= ub then return ub end
		local ra = a.total > 0 and a.owned / a.total or 1
		local rb = b.total > 0 and b.owned / b.total or 1
		if ra ~= rb then return ra < rb end
		return a.name < b.name
	end)
	for i = 1, math.min(#order, MAX_EXPANSION_ROWS) do
		result.expansions[i] = order[i]
	end

	-- Statuts et natures de source, sur les seules montures manquantes.
	local kindBuckets, kindOrder = {}, {}
	local candidates = {}
	for _, entry in ipairs(ns.Collection:GetMissing()) do
		if not entry.excluded then
			local status = ns.Eligibility:GetStatus(entry.mountID)
			result.byState[status.state] = (result.byState[status.state] or 0) + 1

			local kind = entry.kind or "unknown"
			local bucket = kindBuckets[kind]
			if not bucket then
				bucket = { kind = kind, label = entry.sourceTypeLabel or kind, count = 0 }
				kindBuckets[kind] = bucket
				kindOrder[#kindOrder + 1] = bucket
			end
			bucket.count = bucket.count + 1

			if status.state == STATE.AVAILABLE then
				candidates[#candidates + 1] = {
					mountID = entry.mountID,
					name = entry.name,
					icon = entry.icon,
					attempts = ns.Attempts:GetCount(entry.mountID),
				}
			end
		end
	end

	table.sort(kindOrder, function(a, b)
		if a.count ~= b.count then return a.count > b.count end
		return a.label < b.label
	end)
	result.kinds = kindOrder

	-- Cibles du moment : ce qui est ouvert maintenant, le plus attendu devant.
	-- Un joueur qui a fait Ulduar quinze fois veut voir Ulduar en tête.
	table.sort(candidates, function(a, b)
		if a.attempts ~= b.attempts then return a.attempts > b.attempts end
		return a.name < b.name
	end)
	for i = 1, math.min(#candidates, MAX_TOP_TARGETS) do
		result.topTargets[i] = candidates[i]
	end
	result.availableCount = #candidates

	local attemptTotal, attemptMounts = ns.Attempts:GetTotals()
	result.attempts = { total = attemptTotal, mounts = attemptMounts }

	local hour, day = ns.Lockouts:GetInstanceCounts()
	result.instances = { hour = hour, day = day }

	-- Verrous actifs du personnage courant : le chiffre qui dit « cette
	-- semaine est déjà entamée ».
	local lockCount = 0
	if ns.db and ns.db.char and type(ns.db.char.lockouts) == "table" then
		local now = time()
		for _, lock in pairs(ns.db.char.lockouts) do
			if (lock.expires or 0) > now then lockCount = lockCount + 1 end
		end
	end
	result.lockCount = lockCount

	return result
end

--------------------------------------------------------------------------------
-- Mise en forme
--------------------------------------------------------------------------------

--- Segments de la barre empilée de disponibilité, dans un ordre stable.
function Stats:GetAvailabilityParts()
	local STATE = ns.Eligibility.STATE
	local stats = self:Get()
	local colors = ns.Theme and ns.Theme.STATE_COLORS
	if not colors then return {} end

	return {
		{ state = STATE.AVAILABLE, value = stats.byState[STATE.AVAILABLE] or 0, color = colors.available },
		{ state = STATE.LOCKED, value = stats.byState[STATE.LOCKED] or 0, color = colors.locked },
		{ state = STATE.UNKNOWN, value = stats.byState[STATE.UNKNOWN] or 0, color = colors.unknown },
		{ state = STATE.UNMAPPED, value = stats.byState[STATE.UNMAPPED] or 0, color = colors.unmapped },
	}
end
