--[[---------------------------------------------------------------------------
	OnlyFarm — Modules/Teleports.lua

	Découverte des moyens de voyage du personnage courant, et apprentissage des
	durées réelles.

	Principe : on ne liste pas les téléports, on les TROUVE. Le grimoire du
	joueur contient les sorts qu'il possède vraiment ; les noms d'instance du
	Journal des rencontres viennent du même client, donc de la même locale. Un
	sort long dont le nom contient un nom d'instance connu est un téléport vers
	cette instance — et si Blizzard en ajoute quinze au prochain patch, ils sont
	trouvés sans qu'on touche à une table.

	Limite assumée, et affichée comme telle dans l'interface : ce rapprochement
	est heuristique. Il rate les téléports dont le nom ne cite pas l'instance
	(pierres de foyer, jouets de capitale), et il peut en inventer un si un sort
	sans rapport porte le nom d'un donjon. L'inverse — écrire 200 spellID à la
	main — rate plus souvent et se voit moins.

	Les téléports de donjon Mythique+ transforment une route Legion/BfA/DF.
	C'est précisément pour eux que ce module existe.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Teleports = ns:NewModule("Teleports", 33)

-- Un sort de voyage s'incante. Ce seuil élimine d'un coup tous les sorts de
-- combat instantanés, qui sont l'essentiel du grimoire.
local MIN_CAST_TIME_MS = 2000

-- Un nom d'instance plus court que ça produit trop de faux rapprochements.
local MIN_NAME_LENGTH = 5

function Teleports:OnInitialize()
	self.edges = nil
	self.pending = nil
end

function Teleports:OnEnable()
	self.scheduleRebuild = ns.Util.Debounce(2.0, function() self:Invalidate() end)

	-- Un sort appris, un jouet obtenu : le graphe change.
	self:RegisterEvent("SPELLS_CHANGED", "OnSourcesChanged")
	self:RegisterEvent("TOYS_UPDATED", "OnSourcesChanged")
	self:RegisterMessage("OF_NODES_UPDATED", "Invalidate")
end

function Teleports:OnSourcesChanged()
	self.scheduleRebuild()
end

function Teleports:Invalidate()
	self.edges = nil
	self:SendMessage("OF_TRAVEL_UPDATED")
end

--------------------------------------------------------------------------------
-- Index des noms de nœuds
--------------------------------------------------------------------------------

--- Index « nom normalisé -> nodeID », trié du nom le plus long au plus court.
--  L'ordre compte : « Donjon de la Cathédrale » doit gagner contre
--  « Cathédrale » si les deux existent.
function Teleports:BuildNameIndex()
	local entries = {}
	for nodeID, node in pairs(ns.Nodes:All()) do
		local name = ns.Util.NormalizeName(node.name)
		if name and #name >= MIN_NAME_LENGTH then
			entries[#entries + 1] = { name = name, nodeID = nodeID }
		end
	end
	table.sort(entries, function(a, b)
		if #a.name ~= #b.name then return #a.name > #b.name end
		return a.name < b.name
	end)
	return entries
end

--- Premier nœud dont le nom apparaît dans `text`, ou nil.
--
--  Deux registres consultés, dans cet ordre : les entrées d'instance d'abord,
--  parce qu'un téléport de donjon vise une porte précise ; les CARTES du client
--  ensuite.
--
--  Ce second registre est ce qui met enfin les portails de mage et les pierres
--  de foyer dans le graphe. « Téléportation : Orgrimmar » ne cite aucune
--  instance — l'ancien rapprochement ne trouvait donc rien et l'arête n'existait
--  pas — mais il cite une zone, et une zone est un nœud depuis que le routeur
--  sait en fabriquer. Sur un mage, c'est tout le réseau des capitales qui entre
--  d'un coup dans le calcul.
function Teleports:MatchNode(text, index)
	local needle = ns.Util.NormalizeName(text)
	if not needle then return nil end
	for i = 1, #index do
		if needle:find(index[i].name, 1, true) then
			return index[i].nodeID
		end
	end

	-- Le rapprochement PARTIEL est refusé ici, à la différence des textes de
	-- source. Une arête inventée est bien pire qu'une arête manquante : elle
	-- fait calculer tout un trajet autour d'un sort qui ne mène pas là. Or les
	-- vrais sorts de voyage citent leur destination après un deux-points —
	-- « Portail : Hurlevent », « Teleport: Stormwind » — donc les formes sûres
	-- suffisent à tous les attraper.
	local uiMapID, strategy = ns.Nodes:MatchPlace(text)
	if not uiMapID or strategy == "partial" then return nil end

	local node = ns.Nodes:MapNode(uiMapID)
	return node and node.nodeID or nil
end

--------------------------------------------------------------------------------
-- Lecture du grimoire
--------------------------------------------------------------------------------

local function SpellBookReady()
	return C_SpellBook
		and type(C_SpellBook.GetNumSpellBookSkillLines) == "function"
		and type(C_SpellBook.GetSpellBookSkillLineInfo) == "function"
		and type(C_SpellBook.GetSpellBookItemInfo) == "function"
		and Enum and Enum.SpellBookSpellBank
end

--- Durée d'incantation d'un sort, en millisecondes, ou nil.
local function CastTime(spellID)
	if not C_Spell or type(C_Spell.GetSpellInfo) ~= "function" then return nil end
	local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
	if not ok or type(info) ~= "table" then return nil end
	return tonumber(info.castTime)
end

--- Parcourt le grimoire du joueur et renvoie les sorts susceptibles d'être des
--  déplacements : incantés, non passifs.
--  @return liste de { spellID, name, castTime }
function Teleports:ReadSpellBook()
	local found = {}
	if not SpellBookReady() then return found end

	local bank = Enum.SpellBookSpellBank.Player
	local okLines, numLines = pcall(C_SpellBook.GetNumSpellBookSkillLines)
	if not okLines or type(numLines) ~= "number" then return found end

	for lineIndex = 1, numLines do
		local okInfo, lineInfo = pcall(C_SpellBook.GetSpellBookSkillLineInfo, lineIndex)
		if okInfo and type(lineInfo) == "table" and not lineInfo.isGuild then
			local offset = lineInfo.itemIndexOffset or 0
			local count = lineInfo.numSpellBookItems or 0
			for i = 1, count do
				local okItem, item = pcall(C_SpellBook.GetSpellBookItemInfo, offset + i, bank)
				if okItem and type(item) == "table" and item.spellID and not item.isPassive then
					local cast = CastTime(item.spellID)
					if cast and cast >= MIN_CAST_TIME_MS then
						found[#found + 1] = {
							spellID = item.spellID,
							name = item.name,
							castTime = cast,
						}
					end
				end
			end
		end
	end
	return found
end

--------------------------------------------------------------------------------
-- Lecture du coffre à jouets
--------------------------------------------------------------------------------

--- Jouets possédés, filtrés plus tard sur le rapprochement de nom.
--  @return liste de { itemID, name }
function Teleports:ReadToyBox()
	local found = {}
	if not C_ToyBox or type(C_ToyBox.GetNumToys) ~= "function" then return found end
	if type(PlayerHasToy) ~= "function" then return found end

	local okCount, count = pcall(C_ToyBox.GetNumToys)
	if not okCount or type(count) ~= "number" then return found end

	for index = 1, count do
		local okToy, itemID = pcall(C_ToyBox.GetToyFromIndex, index)
		if okToy and type(itemID) == "number" and itemID > 0 then
			local okHas, has = pcall(PlayerHasToy, itemID)
			if okHas and has then
				local okInfo, _, name = pcall(C_ToyBox.GetToyInfo, itemID)
				if okInfo and type(name) == "string" then
					found[#found + 1] = { itemID = itemID, name = name }
				end
			end
		end
	end
	return found
end

--------------------------------------------------------------------------------
-- Construction des arêtes
--------------------------------------------------------------------------------

--- Clé stable d'une arête, utilisée par l'apprentissage des durées.
local function EdgeKey(edge)
	if edge.spellID then return "spell:" .. edge.spellID .. ">" .. edge.to end
	if edge.itemID then return "item:" .. edge.itemID .. ">" .. edge.to end
	return tostring(edge.from) .. ">" .. tostring(edge.to)
end
Teleports.EdgeKey = EdgeKey

--- Toutes les arêtes de téléportation disponibles pour CE personnage.
function Teleports:Build()
	local index = self:BuildNameIndex()
	local edges = {}
	local seen = {}

	local function Add(edge)
		edge.key = EdgeKey(edge)
		-- Deux sorts vers le même nœud : on garde le moins cher.
		local existing = seen[edge.to]
		if existing and existing.cost <= edge.cost then return end
		if existing then
			for i = #edges, 1, -1 do
				if edges[i] == existing then table.remove(edges, i) break end
			end
		end
		seen[edge.to] = edge
		edges[#edges + 1] = edge
	end

	for _, spell in ipairs(self:ReadSpellBook()) do
		local nodeID = self:MatchNode(spell.name, index)
		if nodeID then
			Add({
				kind = ns.Data.EDGE_KINDS.TELEPORT,
				spellID = spell.spellID,
				name = spell.name,
				from = "*",
				to = nodeID,
				cost = self:CostOf(spell.castTime / 1000 + ns.Data.COST.LOADING_SCREEN, nodeID, spell.spellID),
				source = "spell",
			})
		end
	end

	for _, toy in ipairs(self:ReadToyBox()) do
		local nodeID = self:MatchNode(toy.name, index)
		if nodeID then
			Add({
				kind = ns.Data.EDGE_KINDS.TELEPORT,
				itemID = toy.itemID,
				name = toy.name,
				from = "*",
				to = nodeID,
				cost = ns.Data.COST.HEARTHSTONE_CAST + ns.Data.COST.LOADING_SCREEN,
				source = "toy:" .. toy.itemID,
			})
		end
	end

	-- Arêtes curées (portails fixes) : elles n'ont pas de source à vérifier,
	-- sauf mention explicite.
	for _, edge in ipairs(ns.Data.Travel) do
		if self:IsEdgeUsable(edge) then
			local copy = ns.Util.CopyTable(edge)
			copy.key = EdgeKey(copy)
			edges[#edges + 1] = copy
		end
	end

	self.edges = edges
	self:Debug("voyage : %d arête(s) de téléportation trouvée(s)", #edges)
	return edges
end

function Teleports:GetEdges()
	if not self.edges then self:Build() end
	return self.edges
end

--- Le joueur possède-t-il réellement la source de cette arête ?
function Teleports:IsEdgeUsable(edge)
	local source = edge.source
	if type(source) ~= "string" then return true end

	if source == "spell" then
		if C_SpellBook and type(C_SpellBook.IsSpellKnown) == "function" and Enum and Enum.SpellBookSpellBank then
			local ok, known = pcall(C_SpellBook.IsSpellKnown, edge.spellID, Enum.SpellBookSpellBank.Player)
			return ok and known or false
		end
		return false
	end

	local toyID = source:match("^toy:(%d+)$")
	if toyID then
		if type(PlayerHasToy) ~= "function" then return false end
		local ok, has = pcall(PlayerHasToy, tonumber(toyID))
		return ok and has or false
	end

	local itemID = source:match("^item:(%d+)$")
	if itemID then
		if not C_Item or type(C_Item.GetItemCount) ~= "function" then return false end
		local ok, count = pcall(C_Item.GetItemCount, tonumber(itemID), true)
		return ok and type(count) == "number" and count > 0
	end

	return true
end

--------------------------------------------------------------------------------
-- Apprentissage des durées
--
-- Le forfait de départ est une estimation. Chaque trajet réellement effectué
-- par le joueur la corrige. Quarante lignes, et le modèle devient exact pour
-- CE joueur au lieu d'être moyen pour tout le monde.
--------------------------------------------------------------------------------

local MAX_SAMPLES = 10
-- Un trajet de moins de 2 s n'est pas un trajet, et un de plus de 10 min est
-- un joueur parti faire autre chose. Les deux pollueraient la moyenne.
local MIN_SAMPLE, MAX_SAMPLE = 2, 600

--- Coût d'une arête, mesuré si on a des mesures, forfaitaire sinon.
function Teleports:CostOf(fallback, nodeID, spellID)
	local key = spellID and ("spell:" .. spellID .. ">" .. nodeID) or nodeID
	local learned = self:GetLearned(key)
	return learned or fallback
end

function Teleports:GetLearned(key)
	if not ns.db then return nil end
	local timing = ns.db.global.travelTimings[key]
	if type(timing) ~= "table" or type(timing.avg) ~= "number" then return nil end
	return timing.avg
end

--- Enregistre la durée réelle d'un trajet.
function Teleports:NoteTravel(key, seconds)
	if not ns.db or type(key) ~= "string" then return false end
	seconds = tonumber(seconds)
	if not seconds or seconds < MIN_SAMPLE or seconds > MAX_SAMPLE then return false end

	local timings = ns.db.global.travelTimings
	local timing = timings[key]
	if type(timing) ~= "table" then
		timing = { samples = {} }
		timings[key] = timing
	end

	local samples = timing.samples
	samples[#samples + 1] = seconds
	while #samples > MAX_SAMPLES do table.remove(samples, 1) end

	local total = 0
	for i = 1, #samples do total = total + samples[i] end
	timing.avg = total / #samples
	timing.count = #samples

	self:Debug("trajet mesuré : %s = %.0f s (moyenne %.0f s sur %d)",
		key, seconds, timing.avg, timing.count)
	return true
end

--------------------------------------------------------------------------------
-- Cooldowns
--------------------------------------------------------------------------------

--- Temps de recharge restant d'une arête, en secondes.
--  @return 0 si prête, un nombre positif si en recharge, nil si le client
--          refuse de répondre (valeurs secrètes de la 12.0 — cf. API-NOTES).
function Teleports:GetCooldownRemaining(edge)
	if type(edge) ~= "table" then return nil end

	if edge.spellID and C_Spell and type(C_Spell.GetSpellCooldown) == "function" then
		local ok, info = pcall(C_Spell.GetSpellCooldown, edge.spellID)
		if not ok or type(info) ~= "table" then return nil end
		-- isEnabled est marqué NeverSecret : c'est le seul champ sûr.
		if info.isEnabled == false then return nil end
		-- startTime et duration peuvent être des valeurs secrètes : le test de
		-- type est ce qui nous empêche de faire de l'arithmétique dessus.
		if type(info.startTime) ~= "number" or type(info.duration) ~= "number" then
			return nil
		end
		if info.duration <= 0 then return 0 end
		local remaining = info.startTime + info.duration - GetTime()
		return remaining > 0 and remaining or 0
	end

	if edge.itemID and C_Container and type(C_Container.GetItemCooldown) == "function" then
		local ok, startTime, duration = pcall(C_Container.GetItemCooldown, edge.itemID)
		if not ok or type(startTime) ~= "number" or type(duration) ~= "number" then
			return nil
		end
		if duration <= 0 then return 0 end
		local remaining = startTime + duration - GetTime()
		return remaining > 0 and remaining or 0
	end

	return nil
end

--- Une arête est prête si sa recharge est terminée. Une recharge indéterminable
--  compte comme prête : mieux vaut proposer un bouton grisé par le client
--  qu'omettre un téléport que le joueur a sous la main.
function Teleports:IsReady(edge)
	local remaining = self:GetCooldownRemaining(edge)
	return remaining == nil or remaining <= 0
end
