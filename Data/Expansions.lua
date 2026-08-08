--[[---------------------------------------------------------------------------
	OnlyFarm — Data/Expansions.lua

	Table canonique des extensions.

	Elle existe pour trois raisons, et aucune n'est cosmétique :

	  1. ORDRE. Le client donne un « niveau d'extension » (0 = l'originale) mais
	     le Journal des rencontres donne un numéro de palier (1 = l'originale).
	     Sans conversion, deux sources qui parlent de la même extension la
	     classent à deux endroits différents.

	  2. NOM UNIQUE. La liste du Recherche de groupe et le Journal des
	     rencontres n'appellent pas toujours une extension pareil. Deux noms
	     pour la même chose, ce sont deux barres dans le graphe.

	  3. LISIBILITÉ. Le client nomme l'extension originale « World of
	     Warcraft », ce qui, dans une liste où toutes les lignes sont des
	     extensions de World of Warcraft, ne distingue rien. Tout le monde
	     l'appelle Vanilla.

	On ne traduit RIEN ici : les noms viennent du client, donc de la locale du
	joueur. Seules les exceptions explicites ci-dessous sont réécrites.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Data = ns.Data

--- Niveau d'extension du client -> nom affiché, quand celui du client ne
--  convient pas. Tout ce qui n'est pas listé garde son nom localisé.
Data.EXPANSION_OVERRIDES = {
	-- « World of Warcraft » ne distingue rien dans une liste d'extensions.
	[0] = "Vanilla",
}

--- Repère chronologique, uniquement pour l'ordre et le repli d'affichage.
--  Les noms ne servent QUE si le client n'en fournit aucun : sur un client
--  français, EXPANSION_NAME* gagne toujours.
Data.EXPANSION_FALLBACK = {
	[0] = "Vanilla",
	[1] = "The Burning Crusade",
	[2] = "Wrath of the Lich King",
	[3] = "Cataclysm",
	[4] = "Mists of Pandaria",
	[5] = "Warlords of Draenor",
	[6] = "Legion",
	[7] = "Battle for Azeroth",
	[8] = "Shadowlands",
	[9] = "Dragonflight",
	[10] = "The War Within",
	[11] = "Midnight",
}

Data.MAX_EXPANSION_LEVEL = 11

--- Nom affiché d'une extension, à partir de son niveau.
function Data.ExpansionName(level)
	if type(level) ~= "number" then return nil end

	local override = Data.EXPANSION_OVERRIDES[level]
	if override then return override end

	local fromClient = _G["EXPANSION_NAME" .. level]
	if type(fromClient) == "string" and fromClient ~= "" then return fromClient end

	return Data.EXPANSION_FALLBACK[level]
end

--- Niveau d'extension à partir d'un numéro de palier du Journal des
--  rencontres. Le Journal compte à partir de 1, le client à partir de 0.
function Data.TierToExpansionLevel(tier)
	if type(tier) ~= "number" or tier < 1 then return nil end
	return tier - 1
end

--- Index inverse « nom normalisé -> niveau », construit à la demande.
--  Sert à rattacher un nom de palier du Journal au niveau du client, donc à
--  faire converger les deux sources vers une seule barre.
local reverseIndex

-- Sous ce seuil, une correspondance partielle rapproche n'importe quoi.
local MIN_ALIAS_LENGTH = 6

local function BuildReverseIndex()
	reverseIndex = {}
	for level = 0, Data.MAX_EXPANSION_LEVEL do
		for _, candidate in ipairs({
			_G["EXPANSION_NAME" .. level],
			Data.EXPANSION_FALLBACK[level],
			Data.EXPANSION_OVERRIDES[level],
		}) do
			local candidateKey = ns.Util.NormalizeName(candidate)
			if candidateKey and reverseIndex[candidateKey] == nil then
				reverseIndex[candidateKey] = level
			end
		end
	end
	for key, level in pairs(Data.extraAliases or {}) do
		if reverseIndex[key] == nil then reverseIndex[key] = level end
	end
end

--- Enregistre un nom supplémentaire pour une extension.
--
--  Les catégories de hauts faits et les paliers du Journal désignent les mêmes
--  extensions avec des libellés qui ne se recouvrent pas toujours — « Wrath of
--  the Lich King » d'un côté, « Lich King » de l'autre selon la locale et
--  l'écran. Chaque source qui découvre un libellé le déclare ici, et il
--  devient utilisable par toutes les autres.
function Data.RegisterExpansionAlias(name, level)
	local key = ns.Util.NormalizeName(name)
	if not key or type(level) ~= "number" then return end
	Data.extraAliases = Data.extraAliases or {}
	Data.extraAliases[key] = level
	if reverseIndex then reverseIndex[key] = level end
end

function Data.ExpansionLevelFromName(name)
	local key = ns.Util.NormalizeName(name)
	if not key then return nil end

	if not reverseIndex then BuildReverseIndex() end

	local exact = reverseIndex[key]
	if exact then return exact end

	-- Repli par inclusion. « Donjons de Legion » doit tomber sur Legion, et
	-- « Lich King » sur « Wrath of the Lich King ». Sans ce repli, seules les
	-- catégories nommées EXACTEMENT comme l'extension se rattachaient — et
	-- elles sont minoritaires.
	if #key < MIN_ALIAS_LENGTH then return nil end
	for candidate, level in pairs(reverseIndex) do
		if #candidate >= MIN_ALIAS_LENGTH then
			if key:find(candidate, 1, true) or candidate:find(key, 1, true) then
				return level
			end
		end
	end

	return nil
end

--- À appeler si la locale change en cours de session (elle ne change pas, mais
--  les tests rechargent l'addon avec d'autres globales).
function Data.ResetExpansionIndex()
	reverseIndex = nil
	Data.extraAliases = nil
end
