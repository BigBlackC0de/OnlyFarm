--[[---------------------------------------------------------------------------
	OnlyFarm — Modules/TravelGraph.lua

	Le graphe pondéré des déplacements, construit pour CE personnage.

	C'est ce qui fait la différence entre un ordre correct et un ordre juste :
	un joueur qui possède les téléports Mythique+ de Dragonflight n'a pas la
	même route qu'un joueur qui ne les a pas. Le graphe ne contient donc que les
	arêtes réellement disponibles (cf. Modules/Teleports.lua).

	Trois familles d'arêtes :
	  * téléport — depuis n'importe où vers un nœud, coût fixe ;
	  * portail  — d'un nœud vers un autre, coût fixe ;
	  * vol      — implicite entre deux nœuds du MÊME continent, coût calculé
	               depuis la distance monde.

	Deux nœuds sur des continents différents et sans téléport ne sont pas
	reliés. Le routeur le dit (« inatteignable ») au lieu d'inventer un trajet.

	Écart assumé avec la spécification (§6.3) : elle propose une affectation
	gloutonne des téléports à cooldown, avec réoptimisation jusqu'à stabilité.
	On fait plus simple et plus lisible — Dijkstra utilise librement les
	téléports, puis une passe de retarification repère ceux qu'une route
	emploierait deux fois et refacture la seconde utilisation au prix du vol.
	Le résultat est identique dans l'écrasante majorité des cas, et on ne
	promet pas une optimalité qu'un solveur de 200 lignes n'atteindrait pas.
-----------------------------------------------------------------------------]]

local _, ns = ...

local TravelGraph = ns:NewModule("TravelGraph", 34)

TravelGraph.PLAYER_NODE = "player"

-- Au-delà, deux nœuds sont considérés comme non reliés.
local INFINITY = math.huge

function TravelGraph:OnInitialize()
	self.matrixCache = nil
end

function TravelGraph:OnEnable()
	self:RegisterMessage("OF_TRAVEL_UPDATED", "Invalidate")
	self:RegisterMessage("OF_NODES_UPDATED", "Invalidate")
end

function TravelGraph:Invalidate()
	self.matrixCache = nil
end

--------------------------------------------------------------------------------
-- Univers de calcul
--
-- On ne construit jamais le graphe complet : il n'y a aucune raison de
-- calculer un plus court chemin vers un donjon qui n'est sur la route de
-- personne. L'univers d'un calcul, c'est la position du joueur, les nœuds à
-- visiter, et les destinations de téléport (qui servent de correspondances).
--------------------------------------------------------------------------------

--- @param visitNodeIDs liste des nœuds à visiter
--  @return table [nodeID] = nœud, incluant le nœud virtuel du joueur
function TravelGraph:BuildUniverse(visitNodeIDs)
	local universe = {}

	local playerNode = ns.Nodes:GetPlayerNode()
	if playerNode then
		playerNode.nodeID = self.PLAYER_NODE
		universe[self.PLAYER_NODE] = playerNode
	end

	for _, nodeID in ipairs(visitNodeIDs or {}) do
		local node = ns.Nodes:Get(nodeID)
		if node then universe[nodeID] = node end
	end

	-- Les destinations de téléport entrent dans l'univers même si personne ne
	-- les visite : c'est par elles qu'on change de continent.
	for _, edge in ipairs(ns.Teleports:GetEdges()) do
		if edge.to and not universe[edge.to] then
			local node = ns.Nodes:Get(edge.to)
			if node then universe[edge.to] = node end
		end
	end

	return universe
end

--------------------------------------------------------------------------------
-- Arêtes sortantes
--------------------------------------------------------------------------------

--- Toutes les arêtes utilisables depuis `fromID`.
--  @return liste de { to, cost, edge }
function TravelGraph:EdgesFrom(fromID, universe, options)
	options = options or {}
	local edges = {}
	local fromNode = universe[fromID]
	if not fromNode then return edges end

	for _, edge in ipairs(ns.Teleports:GetEdges()) do
		local usable = (edge.from == "*" or edge.from == fromID)
			and edge.to ~= fromID
			and universe[edge.to] ~= nil
		-- Un téléport déjà consommé plus tôt dans la route n'est plus une
		-- option : c'est la contrainte de ressource de la spécification, posée
		-- ici plutôt que dans le solveur.
		if usable and options.spent and options.spent[edge.key] then usable = false end
		if usable and options.noTeleports and edge.kind == ns.Data.EDGE_KINDS.TELEPORT then
			usable = false
		end
		if usable then
			edges[#edges + 1] = { to = edge.to, cost = edge.cost, edge = edge }
		end
	end

	-- Vol libre vers tout nœud du même continent.
	for toID, toNode in pairs(universe) do
		if toID ~= fromID then
			local cost = ns.Nodes:FlightCost(fromNode, toNode)
			if cost then
				edges[#edges + 1] = {
					to = toID,
					cost = cost,
					edge = { kind = ns.Data.EDGE_KINDS.FLY, from = fromID, to = toID },
				}
			end
		end
	end

	return edges
end

--------------------------------------------------------------------------------
-- Dijkstra
--------------------------------------------------------------------------------

--- Plus courts chemins depuis `sourceID` vers tous les nœuds de l'univers.
--  File de priorité par balayage linéaire : l'univers tient en quelques
--  dizaines de nœuds, un tas binaire coûterait plus en lignes qu'il ne
--  rapporte en microsecondes.
--  @return dist [nodeID] = secondes, prev [nodeID] = { from, edge }
function TravelGraph:ShortestPaths(sourceID, universe, options)
	local dist, prev, visited = {}, {}, {}

	for nodeID in pairs(universe) do dist[nodeID] = INFINITY end
	if dist[sourceID] == nil then return dist, prev end
	dist[sourceID] = 0

	while true do
		local currentID, best = nil, INFINITY
		for nodeID, d in pairs(dist) do
			if not visited[nodeID] and d < best then
				currentID, best = nodeID, d
			end
		end
		if not currentID then break end
		visited[currentID] = true

		for _, out in ipairs(self:EdgesFrom(currentID, universe, options)) do
			local candidate = best + out.cost
			if candidate < (dist[out.to] or INFINITY) then
				dist[out.to] = candidate
				prev[out.to] = { from = currentID, edge = out.edge, cost = out.cost }
			end
		end
	end

	return dist, prev
end

--- Reconstitue le trajet de `sourceID` à `targetID`.
--  @return liste de { from, to, edge, cost }, ou nil si inatteignable
function TravelGraph:Path(prev, sourceID, targetID)
	if sourceID == targetID then return {} end
	local steps = {}
	local cursor = targetID
	while cursor and cursor ~= sourceID do
		local link = prev[cursor]
		if not link then return nil end
		table.insert(steps, 1, {
			from = link.from,
			to = cursor,
			edge = link.edge,
			cost = link.cost,
		})
		cursor = link.from
	end
	return steps
end

--------------------------------------------------------------------------------
-- Matrice de coûts
--------------------------------------------------------------------------------

--- Matrice complète des coûts entre les nœuds demandés.
--  @param nodeIDs liste (le nœud du joueur est ajouté en tête s'il existe)
--  @return matrix [from][to] = secondes, paths [from][to] = trajet, universe
function TravelGraph:BuildMatrix(nodeIDs)
	local universe = self:BuildUniverse(nodeIDs)

	local sources = {}
	if universe[self.PLAYER_NODE] then sources[#sources + 1] = self.PLAYER_NODE end
	for _, nodeID in ipairs(nodeIDs) do
		if universe[nodeID] then sources[#sources + 1] = nodeID end
	end

	local matrix, paths = {}, {}
	for _, fromID in ipairs(sources) do
		local dist, prev = self:ShortestPaths(fromID, universe)
		matrix[fromID] = {}
		paths[fromID] = {}
		for _, toID in ipairs(sources) do
			if fromID ~= toID then
				matrix[fromID][toID] = dist[toID] or INFINITY
				paths[fromID][toID] = self:Path(prev, fromID, toID)
			end
		end
	end

	return matrix, paths, universe, sources
end

--- Un coût infini = pas de trajet connu. À dire, pas à masquer.
function TravelGraph:IsReachable(cost)
	return type(cost) == "number" and cost < INFINITY
end

TravelGraph.INFINITY = INFINITY
