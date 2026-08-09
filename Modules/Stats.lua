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

local MAX_TOP_TARGETS = 6

function Stats:OnInitialize()
	self.cache = nil
	self.breakdowns = nil
end

function Stats:OnEnable()
	self:RegisterMessage("OF_COLLECTION_UPDATED", "Invalidate")
	self:RegisterMessage("OF_LOCKOUTS_UPDATED", "Invalidate")
	self:RegisterMessage("OF_SCAN_COMPLETE", "Invalidate")
	self:RegisterMessage("OF_ATTEMPTS_UPDATED", "Invalidate")
end

function Stats:Invalidate()
	self.cache = nil
	self.breakdowns = nil
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
		topTargets = {},
	}

	-- Statuts, sur les seules montures manquantes.
	local candidates = {}
	for _, entry in ipairs(ns.Collection:GetMissing()) do
		if not entry.excluded then
			local status = ns.Eligibility:GetStatus(entry.mountID)
			result.byState[status.state] = (result.byState[status.state] or 0) + 1

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

	-- Ce que l'addon t'a vu obtenir. Un compteur d'essais global additionne des
	-- montures qui n'ont rien à voir entre elles et ne dit rien ; un compteur
	-- d'acquisitions dit quelque chose, parce que chaque unité est un résultat.
	local obtained, obtainedSince = ns.Collection:GetObtainedSinceInstall()
	result.obtained = { count = obtained, since = obtainedSince }

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
-- Répartition de la collection
--
-- Le graphe central du tableau de bord. Il montrait la progression par
-- EXTENSION : bon axe, mauvaise donnée. Aucune API ne donne l'extension d'une
-- monture (cf. docs/API-NOTES.md) ; la frise ne se remplissait qu'après un scan
-- du Journal des rencontres, pour la fraction des montures qui tombent d'un
-- boss, et rangeait tout le reste — vendeurs, métiers, événements, PvP, quêtes —
-- dans un panier « inconnue ». Un graphe dont la plus grosse barre est « je ne
-- sais pas » ne classe rien. Il est retiré.
--
-- Les deux axes ci-dessous n'ont pas ce défaut. Ils viennent du client, monture
-- par monture, pour TOUTES les montures, sans scan et sans table curée :
--
--   * la nature de la source — `sourceType`, 6e retour de GetMountInfoByID,
--     affiché avec le libellé localisé de Blizzard lui-même ;
--   * le mode de déplacement — `mountTypeID`, 5e retour de
--     GetMountInfoExtraByID (cf. Data/MountTypes.lua).
--
-- Chaque seau porte `owned` ET `total` : sans dénominateur, une barre ne dit
-- rien. Le champ `max` de la liste donne le plus gros effectif, pour que
-- l'interface puisse dessiner des barres à l'échelle — c'est ce qui fait la
-- différence entre une répartition et une pile de pourcentages.
--------------------------------------------------------------------------------

Stats.AXES = {
	{ key = "source", label = "DASH_AXIS_SOURCE" },
	{ key = "movement", label = "DASH_AXIS_MOVEMENT" },
}

Stats.DEFAULT_AXIS = "source"

--- Seau d'une monture selon l'axe : clé, libellé, rang d'affichage.
--  Le rang sépare ce qui est nommé de ce qui ne l'est pas : un panier « autre »
--  ferme toujours la marche, quel que soit son effectif.
local AXIS_BUCKET = {
	-- Le seau de source vient de Data : le menu de filtre de la collection
	-- appelle la même fonction, donc les deux écrans ne peuvent pas diverger.
	source = function(entry) return ns.Data.GetSourceBucket(entry) end,

	movement = function(entry)
		local kind = ns.Collection:GetMovement(entry.mountID)
		return kind, ns.Data.GetMovementLabel(kind), ns.Data.GetMovementRank(kind)
	end,
}

function Stats:IsValidAxis(axis)
	return AXIS_BUCKET[axis] ~= nil
end

--- Axe valide le plus proche de `axis` : le réglage sauvegardé peut venir d'une
--  version où un axe existait encore.
function Stats:ResolveAxis(axis)
	if self:IsValidAxis(axis) then return axis end
	return self.DEFAULT_AXIS
end

--- Répartition de la collection selon un axe.
--  @return liste triée { key, label, owned, total }, avec le champ `max`
function Stats:GetBreakdown(axis)
	axis = self:ResolveAxis(axis)
	self.breakdowns = self.breakdowns or {}
	if not self.breakdowns[axis] then
		self.breakdowns[axis] = self:ComputeBreakdown(axis)
	end
	return self.breakdowns[axis]
end

function Stats:ComputeBreakdown(axis)
	local bucketOf = AXIS_BUCKET[axis]
	local buckets, list = {}, {}

	-- Toutes les montures obtenables sur ce personnage, possédées comprises.
	for _, mountID in ipairs(ns.Collection.allIDs or {}) do
		local entry = ns.Collection:GetEntry(mountID)
		if entry then
			local key, label, rank = bucketOf(entry)
			local bucket = buckets[key]
			if not bucket then
				bucket = { key = key, label = label, rank = rank or 0, owned = 0, total = 0 }
				buckets[key] = bucket
				list[#list + 1] = bucket
			end
			bucket.total = bucket.total + 1
			if entry.owned then bucket.owned = bucket.owned + 1 end
		end
	end

	-- Tri par effectif décroissant, PAS par avancement. Un tri par avancement
	-- réordonne les lignes à chaque monture obtenue, et l'œil perd ses repères ;
	-- l'effectif d'une catégorie, lui, ne bouge qu'à un patch.
	--
	-- Le comparateur est celui de Data, partagé avec le menu de filtre de la
	-- collection : deux tris écrits séparément finissent toujours par différer.
	table.sort(list, ns.Data.CompareSourceBuckets)

	local max = 0
	for _, bucket in ipairs(list) do
		if bucket.total > max then max = bucket.total end
	end
	list.max = max

	return list
end

-- La barre empilée « disponible / verrouillé / incertain / non cartographié » a
-- été retirée du tableau de bord, et avec elle GetAvailabilityParts.
--
-- Elle décrivait honnêtement l'état de la cartographie, et c'était le problème :
-- sur une collection réelle elle affichait « 65 disponible, 679 incertain », donc
-- une barre presque entièrement ambre. « Incertain » n'est pas une information
-- sur laquelle un joueur agit, et occuper le haut du tableau de bord avec elle
-- revenait à mettre en avant ce que l'addon ne sait pas.
--
-- `byState` reste calculé : c'est lui qui désigne les cibles du moment, et
-- l'infobulle de chaque monture porte son statut, là où il est utile — au moment
-- de choisir cette monture-là.
