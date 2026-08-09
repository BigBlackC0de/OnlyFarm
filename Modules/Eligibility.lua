--[[---------------------------------------------------------------------------
	OnlyFarm — Modules/Eligibility.lua

	Répond à « cette monture, je peux tenter de l'avoir maintenant, et sur quel
	personnage ? »

	Source de vérité, dans l'ordre :
	  1. Data.Sources — table statique générée (vide en phase 1).
	  2. db.global.sourceCache — moisson du Journal des rencontres faite en jeu
	     par `/of ejscan`. Écrase la table statique, parce qu'elle vient du
	     client courant, donc du patch courant.
	  3. Rien : statut « source non cartographiée ». On le dit, on ne l'invente
	     pas.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Eligibility = ns:NewModule("Eligibility", 40)

Eligibility.STATE = {
	AVAILABLE = "available",
	LOCKED = "locked",
	UNKNOWN = "unknown",      -- source connue mais horloge indéterminable
	UNMAPPED = "unmapped",    -- aucune source cartographiée
	INELIGIBLE = "ineligible",
}

local STATE = Eligibility.STATE

function Eligibility:OnInitialize()
	self.mountIndex = nil
end

function Eligibility:OnEnable()
	self:RegisterMessage("OF_SCAN_COMPLETE", "Invalidate")
	self:RegisterMessage("OF_COLLECTION_UPDATED", "Invalidate")
end

function Eligibility:Invalidate()
	self.mountIndex = nil
end

--------------------------------------------------------------------------------
-- Résolution de source
--------------------------------------------------------------------------------

--- Source cartographiée d'une monture, ou nil.
--  @return table { instanceName, instanceID, difficultyIDs, isRaid, lockout, … }
function Eligibility:GetSource(mountID)
	-- Cache du scan en jeu : prioritaire, il correspond au patch courant.
	local cached = ns.db and ns.db.global.sourceCache[mountID]
	if cached then return cached end

	-- Table statique générée (phase 2).
	if not self.mountIndex then
		self.mountIndex = ns.Data.BuildMountIndex()
	end
	local sourceIDs = self.mountIndex[mountID]
	if not sourceIDs then return nil end
	return ns.Data.Sources[sourceIDs[1]]
end

--- Instance moteur associée à une source, via le pont par nom.
function Eligibility:ResolveInstanceID(source)
	if not source then return nil end
	if type(source.instanceID) == "number" then return source.instanceID end
	if source.instanceName then
		return ns.Lockouts:GetInstanceIDByName(source.instanceName)
	end
	return nil
end

--- Horloge applicable. Un raid = hebdomadaire, un donjon = quotidien ; le
--  reste (rare, vendeur, métier) n'a pas de verrou du tout.
function Eligibility:GetLockoutKind(source)
	if not source then return nil end
	if source.lockout then return source.lockout end
	if source.isRaid == true then return ns.Data.LOCKOUT.WEEKLY end
	if source.isRaid == false then return ns.Data.LOCKOUT.DAILY end
	return nil
end

--------------------------------------------------------------------------------
-- Extensions
--
-- L'extension d'une monture n'est exposée par aucune API du Journal des
-- montures. On la tient du palier du Journal des rencontres, donc uniquement
-- pour les montures qu'un `/of ejscan` a cartographiées. Les autres tombent
-- dans un panier « inconnue » — assumé et affiché comme tel, plutôt que
-- rattachées au hasard à une extension plausible.
--------------------------------------------------------------------------------

Eligibility.UNKNOWN_EXPANSION = "?"

--- Nom localisé de l'extension d'une monture, ou UNKNOWN_EXPANSION.
function Eligibility:GetExpansion(mountID)
	local source = self:GetSource(mountID)
	if source and type(source.tierName) == "string" and source.tierName ~= "" then
		return source.tierName
	end
	return self.UNKNOWN_EXPANSION
end

-- GetKnownExpansions a été retiré avec le filtre par extension de l'onglet
-- Collection. Il listait les paliers présents dans le cache de cartographie,
-- donc uniquement les montures qu'un scan avait rattachées à un boss : le menu
-- proposait trois ou quatre extensions sur douze, et « inconnue » ramassait tout
-- le reste. Un filtre qui ne connaît pas la majorité de ses valeurs n'est pas un
-- filtre.
--
-- GetExpansion reste, lui : `/of export` s'en sert pour produire le fichier de
-- curation, et c'est là que la donnée a un sens — un outil de mainteneur qui
-- travaille précisément sur ce qui manque.

--------------------------------------------------------------------------------
-- Statut par personnage
--------------------------------------------------------------------------------

--- Statut d'une monture pour un personnage donné.
--  @param mountID  identifiant de monture
--  @param charKey  clé « Nom-Royaume » ; défaut : personnage courant
--  @return table { state, source, resetIn, detail, stale }
function Eligibility:GetStatus(mountID, charKey)
	charKey = charKey or (ns.db and ns.db.charKey)
	local result = { state = STATE.UNMAPPED, mountID = mountID, charKey = charKey }

	local source = self:GetSource(mountID)
	if not source then return result end
	result.source = source

	local charEntry = ns.Database:GetChar(charKey)
	if not charEntry then
		result.state = STATE.UNKNOWN
		return result
	end
	result.stale = ns.Database:IsStale(charEntry)

	-- Filtre de faction : une source réservée à la faction opposée n'est pas
	-- « verrouillée », elle est hors de portée.
	if source.faction and charEntry.faction and source.faction ~= charEntry.faction then
		result.state = STATE.INELIGIBLE
		result.detail = "faction"
		return result
	end

	if source.minLevel and charEntry.level and charEntry.level < source.minLevel then
		result.state = STATE.INELIGIBLE
		result.detail = "level"
		return result
	end

	local lockoutKind = self:GetLockoutKind(source)
	if lockoutKind == ns.Data.LOCKOUT.NONE or lockoutKind == ns.Data.LOCKOUT.RESPAWN then
		result.state = STATE.AVAILABLE
		result.detail = lockoutKind
		return result
	end

	local instanceID = self:ResolveInstanceID(source)
	result.instanceID = instanceID

	-- LE VERROU D'ABORD, avant toute question d'horloge.
	--
	-- Un verrou enregistré est un fait mesuré : le personnage a bel et bien
	-- terminé cette instance. Le chercher en dernier, après avoir exigé une
	-- instance correctement cartographiée, produisait l'incohérence la plus
	-- visible de l'addon — le tableau de bord affichait « Citadelle de la
	-- Couronne de glace, 11/12, reset dans 3j » pendant que la monture qui en
	-- tombe restait « incertain ».
	--
	-- Le nom de lieu brut sert de repli quand la cartographie n'a pas abouti :
	-- il est étiqueté (« Région : … »), et Lockouts sait le décoiffer.
	local lockName = source.instanceName or source.placeName
	local lock = ns.Lockouts:GetLock(charKey, instanceID, source.difficultyID, lockName)
	if lock then
		result.state = STATE.LOCKED
		result.resetIn = math.max(0, (lock.expires or 0) - time())
		result.detail = lock.difficultyName
		result.lock = lock
		return result
	end

	if not instanceID and not lockName then
		-- Ni identifiant moteur ni nom : rien pour rapprocher un verrou.
		result.state = STATE.UNKNOWN
		result.detail = "instance_unresolved"
		return result
	end

	if lockoutKind == ns.Data.LOCKOUT.WEEKLY then
		-- Pas de verrou enregistré : l'instance n'a jamais été entrée cette
		-- semaine, donc elle est disponible. C'est la règle n°2 du module
		-- Lockouts, et c'est contre-intuitif : l'absence vaut disponibilité.
		result.state = STATE.AVAILABLE
		return result
	end

	if lockoutKind == ns.Data.LOCKOUT.DAILY then
		-- Le verrou quotidien se lit dans NOS propres entrées d'instance, qui
		-- sont indexées par identifiant moteur. Sans lui, pas de réponse — et
		-- on le dit plutôt que de répondre « disponible » par défaut.
		if not instanceID then
			result.state = STATE.UNKNOWN
			result.detail = "instance_unresolved"
			return result
		end
		local entered = ns.Lockouts:HasEnteredToday(charKey, instanceID)
		if entered == nil then
			result.state = STATE.UNKNOWN
			result.detail = "reset_boundary_unknown"
		elseif entered then
			result.state = STATE.LOCKED
			result.detail = "entered_today"
			local nextReset = ns.Util.NextDailyReset()
			result.resetIn = nextReset and (nextReset - time()) or nil
		else
			result.state = STATE.AVAILABLE
		end
		return result
	end

	result.state = STATE.UNKNOWN
	return result
end

--------------------------------------------------------------------------------
-- Vue multi-personnage
--------------------------------------------------------------------------------

--- Statut de la monture sur tous les personnages connus.
--  @return liste triée { charKey, name, state, resetIn, stale }, nbDisponibles
function Eligibility:GetCharacterAvailability(mountID)
	local rows = {}
	local availableCount = 0

	for _, charKey in ipairs(ns.Database:GetCharKeys()) do
		local charEntry = ns.Database:GetChar(charKey)
		local status = self:GetStatus(mountID, charKey)
		rows[#rows + 1] = {
			charKey = charKey,
			name = charEntry and charEntry.name or charKey,
			class = charEntry and charEntry.class,
			lastSeen = charEntry and charEntry.lastSeen,
			state = status.state,
			resetIn = status.resetIn,
			detail = status.detail,
			stale = status.stale,
		}
		if status.state == STATE.AVAILABLE then
			availableCount = availableCount + 1
		end
	end

	table.sort(rows, function(a, b)
		if a.state ~= b.state then return a.state < b.state end
		return a.name < b.name
	end)
	return rows, availableCount
end

--------------------------------------------------------------------------------
-- Rendu
--------------------------------------------------------------------------------

local STATE_TO_COLOR = {
	[STATE.AVAILABLE] = "available",
	[STATE.LOCKED] = "locked",
	[STATE.UNKNOWN] = "unknown",
	[STATE.UNMAPPED] = "unknown",
	[STATE.INELIGIBLE] = "unknown",
}

--- Libellé coloré d'un statut, prêt à poser dans une FontString.
function Eligibility:FormatStatus(status)
	local L = ns.L
	local color = STATE_TO_COLOR[status.state] or "unknown"
	local text

	if status.state == STATE.AVAILABLE then
		text = L.STATUS_AVAILABLE
	elseif status.state == STATE.LOCKED then
		text = L.STATUS_LOCKED
		if status.resetIn then
			text = text .. " — " .. L.LOCK_RESETS_IN:format(ns.Util.FormatDuration(status.resetIn))
		end
	elseif status.state == STATE.UNMAPPED then
		text = L.STATUS_NO_SOURCE
	elseif status.state == STATE.INELIGIBLE then
		text = L.STATUS_INELIGIBLE
	else
		text = L.STATUS_UNKNOWN
	end

	if status.stale and status.state ~= STATE.UNMAPPED then
		color = "stale"
	end
	return ns.Util.Colorize(color, text)
end
