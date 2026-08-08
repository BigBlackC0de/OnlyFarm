--[[---------------------------------------------------------------------------
	OnlyFarm — Modules/Nodes.lua

	Registre des nœuds géographiques : la table statique générée au build,
	recouverte par le cache moissonné en jeu, plus la position du joueur.

	Un nœud, c'est un endroit où le routeur peut vouloir aller. Sa seule
	obligation est d'avoir des coordonnées monde exploitables : sans elles, il
	reste dans le registre (l'interface peut l'afficher) mais il ne participe
	pas au calcul de distance.

	Deux nœuds ne sont comparables que sur le même `continentID`. C'est la
	garantie qui empêche le routeur de proposer un vol de Kalimdor à Draenor.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Nodes = ns:NewModule("Nodes", 32)

function Nodes:OnInitialize()
	self.registry = nil
end

function Nodes:OnEnable()
	self:RegisterMessage("OF_SCAN_COMPLETE", "Invalidate")
end

function Nodes:Invalidate()
	self.registry = nil
	self:SendMessage("OF_NODES_UPDATED")
end

--------------------------------------------------------------------------------
-- Registre
--------------------------------------------------------------------------------

--- Fusionne table statique et cache de scan. Le cache gagne : il vient du
--  client courant, donc du patch courant.
function Nodes:Build()
	local registry = {}

	for nodeID, node in pairs(ns.Data.Nodes) do
		registry[nodeID] = node
	end

	if ns.db and type(ns.db.global.nodeCache) == "table" then
		for nodeID, node in pairs(ns.db.global.nodeCache) do
			registry[nodeID] = node
		end
	end

	-- Les nœuds libres posés depuis l'éditeur de route vivent avec les autres :
	-- le routeur n'a pas à savoir d'où vient une coordonnée.
	if ns.db and type(ns.db.global.customNodes) == "table" then
		for nodeID, node in pairs(ns.db.global.customNodes) do
			registry[nodeID] = node
		end
	end

	self.registry = registry
	return registry
end

function Nodes:All()
	if not self.registry then self:Build() end
	return self.registry
end

function Nodes:Get(nodeID)
	if not nodeID then return nil end
	return self:All()[nodeID]
end

function Nodes:Count()
	return ns.Util.Count(self:All())
end

--- Nœud d'une instance du Journal des rencontres, ou nil s'il n'a pas encore
--  été moissonné.
function Nodes:GetForJournalInstance(journalInstanceID)
	if type(journalInstanceID) ~= "number" then return nil end
	return self:Get(ns.Data.InstanceNodeID(journalInstanceID))
end

--- Nœud d'une source de monture. Une source non cartographiée n'a pas de nœud,
--  et c'est un état normal — pas une erreur.
function Nodes:GetForSource(source)
	if type(source) ~= "table" then return nil end
	if source.nodeID then return self:Get(source.nodeID) end
	return self:GetForJournalInstance(source.journalInstanceID)
end

--------------------------------------------------------------------------------
-- Enregistrement
--------------------------------------------------------------------------------

--- Écrit un nœud dans le cache de scan.
function Nodes:Record(node)
	if not ns.db or type(node) ~= "table" or not node.nodeID then return false end
	ns.db.global.nodeCache[node.nodeID] = node
	if self.registry then self.registry[node.nodeID] = node end
	return true
end

--- Nœud libre créé par le joueur (« Bijoutier de Valdrakken », un point sur la
--  carte…). Stocké à part du cache de scan : un rescan ne doit jamais effacer
--  ce que le joueur a posé lui-même.
function Nodes:CreateCustom(label, uiMapID, x, y)
	if not ns.db then return nil end
	local nodeID = "custom:" .. tostring(time()) .. ":" .. tostring(math.random(1000, 9999))
	local node = {
		nodeID = nodeID,
		name = label,
		kind = ns.Data.NODE_KINDS.CUSTOM,
		uiMapID = uiMapID,
		x = x,
		y = y,
	}
	local continentID, wx, wy = self:ResolveWorldPos(uiMapID, x, y)
	node.continentID, node.wx, node.wy = continentID, wx, wy

	ns.db.global.customNodes[nodeID] = node
	if self.registry then self.registry[nodeID] = node end
	return node
end

function Nodes:DeleteCustom(nodeID)
	if not ns.db then return end
	ns.db.global.customNodes[nodeID] = nil
	if self.registry then self.registry[nodeID] = nil end
end

--------------------------------------------------------------------------------
-- Coordonnées monde
--------------------------------------------------------------------------------

--- Convertit des coordonnées de carte en coordonnées monde (yards).
--  @return continentID, wx, wy — ou nil si la carte n'est pas projetable
--          (intérieurs d'instance, cartes cosmiques…). C'est fréquent et
--          normal : le nœud existe quand même, il ne sert juste pas au calcul
--          de distance.
function Nodes:ResolveWorldPos(uiMapID, x, y)
	if type(uiMapID) ~= "number" or type(x) ~= "number" or type(y) ~= "number" then
		return nil
	end
	if not C_Map or type(C_Map.GetWorldPosFromMapPos) ~= "function" then return nil end

	local ok, continentID, worldPos = pcall(C_Map.GetWorldPosFromMapPos, uiMapID, { x = x, y = y })
	if not ok or type(continentID) ~= "number" or not worldPos then return nil end

	local wx, wy
	if type(worldPos.GetXY) == "function" then
		wx, wy = worldPos:GetXY()
	else
		wx, wy = worldPos.x, worldPos.y
	end
	if type(wx) ~= "number" or type(wy) ~= "number" then return nil end
	return continentID, wx, wy
end

--- Nœud virtuel de la position courante du joueur. Recalculé à chaque appel :
--  c'est le point de départ de toute route, il n'a aucune raison d'être en cache.
function Nodes:GetPlayerNode()
	if not C_Map or type(C_Map.GetBestMapForUnit) ~= "function" then return nil end
	local uiMapID = C_Map.GetBestMapForUnit("player")
	if not uiMapID then return nil end

	local position = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(uiMapID, "player")
	if not position then return nil end

	local x, y
	if type(position.GetXY) == "function" then
		x, y = position:GetXY()
	else
		x, y = position.x, position.y
	end
	if type(x) ~= "number" or type(y) ~= "number" then return nil end

	local continentID, wx, wy = self:ResolveWorldPos(uiMapID, x, y)
	return {
		nodeID = ns.TravelGraph and ns.TravelGraph.PLAYER_NODE or "player",
		name = ns.L.NODE_PLAYER,
		kind = ns.Data.NODE_KINDS.OUTDOOR,
		uiMapID = uiMapID,
		x = x,
		y = y,
		continentID = continentID,
		wx = wx,
		wy = wy,
	}
end

--------------------------------------------------------------------------------
-- Distance
--------------------------------------------------------------------------------

--- Distance en yards entre deux nœuds, ou nil s'ils ne sont pas comparables
--  (continents différents, ou coordonnées monde absentes).
function Nodes:Distance(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then return nil end
	if type(a.wx) ~= "number" or type(b.wx) ~= "number" then return nil end
	if a.continentID == nil or a.continentID ~= b.continentID then return nil end
	local dx, dy = a.wx - b.wx, a.wy - b.wy
	return math.sqrt(dx * dx + dy * dy)
end

--- Vitesse de vol retenue pour ce joueur.
function Nodes:GetFlySpeed()
	local speed = ns.db and ns.db.profile.routing.flySpeed
	if type(speed) ~= "number" or speed <= 0 then
		return ns.Data.DEFAULT_FLY_SPEED
	end
	return speed
end

--- Coût d'un vol libre entre deux nœuds, en secondes, ou nil si impossible.
function Nodes:FlightCost(a, b)
	local distance = self:Distance(a, b)
	if not distance then return nil end
	return distance / self:GetFlySpeed() + ns.Data.COST.FLIGHT_OVERHEAD
end
