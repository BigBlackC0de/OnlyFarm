--[[---------------------------------------------------------------------------
	OnlyFarm — Modules/Nodes.lua

	Registre des nœuds géographiques, et toute la géométrie du routeur.

	Un nœud, c'est un endroit où le routeur peut vouloir aller. Trois familles,
	par ordre de précision décroissante :

	  * `ej:<journalInstanceID>` — une entrée d'instance, moissonnée du client ;
	  * `map:<uiMapID>`          — une carte entière, visée en son centre ;
	  * `custom:<…>`             — un point posé par le joueur.

	LA CARTE ENTIÈRE EST UN NŒUD LÉGITIME, et c'est le changement qui fait
	passer le routeur de « quelques raids » à « presque toutes les montures ».
	Une monture de vendeur ne tombe dans aucune instance : son texte de source
	dit « Zone : Nazjatar », pas davantage. Refuser de router faute d'un point
	exact revient à ne rien dire alors qu'on sait quelque chose. Un centre de
	zone est grossier — il est signalé comme tel (`zoneWide`) — mais il envoie
	le joueur sur le bon continent, dans la bonne zone, ce qui est l'essentiel
	du trajet.

	PROJECTION CARTE <-> MONDE

	Le client ne donne qu'un sens : `C_Map.GetWorldPosFromMapPos`. L'autre sens
	est pourtant indispensable — sans lui, impossible de poser un point de
	passage sur la carte de zone quand la cible est décrite sur celle du donjon.
	On l'obtient sans deviner : la projection d'une carte vers le monde est
	AFFINE et à axes alignés, donc deux coins opposés la décrivent entièrement.
	D'où `MapRect`, et l'inverse qui s'en déduit exactement.

	Deux nœuds ne sont comparables en distance que sur le même `continentID`.
	C'est la garantie qui empêche le routeur de proposer un vol de Kalimdor à
	Draenor.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Nodes = ns:NewModule("Nodes", 32)

-- Racines de l'arbre des cartes. Tout le reste en descend.
local COSMIC_MAP_ID = 946
local WORLD_MAP_ID = 947

-- Enum.UIMapType, recopié plutôt que lu : `Enum` n'existe pas dans le harnais
-- de test, et une comparaison contre `nil` serait vraie une fois sur deux sans
-- que rien ne le signale.
local MAP_TYPE = {
	COSMIC = 0,
	WORLD = 1,
	CONTINENT = 2,
	ZONE = 3,
	DUNGEON = 4,
	MICRO = 5,
	ORPHAN = 6,
}
Nodes.MAP_TYPE = MAP_TYPE

-- Une carte plus haute que la zone ne désigne pas un endroit : « Kalimdor » ou
-- « Azeroth » comme destination, c'est une flèche vers un centre géométrique
-- au milieu de l'océan.
local ROUTABLE_MAP_TYPES = {
	[MAP_TYPE.CONTINENT] = 2,
	[MAP_TYPE.ZONE] = 1,      -- le plus précis gagne, donc le rang le plus bas
	[MAP_TYPE.DUNGEON] = 3,
	[MAP_TYPE.MICRO] = 4,
}

-- En dessous, un nom rapproche n'importe quoi (« Cave », « Hall »…).
local MIN_PLACE_LENGTH = 5
local MIN_PARTIAL_LENGTH = 10

function Nodes:OnInitialize()
	self.registry = nil
	-- Les caches de cartographie du client survivent aux invalidations : les
	-- cartes ne bougent pas d'un scan à l'autre, seulement d'un patch à l'autre.
	self.maps = nil
	self.rects = {}
	self.mapInfo = {}
	self.placeIndex = nil
	self.placeCache = {}
end

function Nodes:OnEnable()
	self:RegisterMessage("OF_SCAN_COMPLETE", "Invalidate")
end

function Nodes:Invalidate()
	self.registry = nil
	-- Les caches de cartographie du client repartent aussi. Ils ne changent
	-- qu'entre deux patchs, donc les garder serait tentant — mais un scan est
	-- justement ce qu'on lance APRÈS un patch, et une projection périmée pointe
	-- une flèche à côté sans jamais rien signaler.
	self.maps = nil
	self.rects = {}
	self.mapInfo = {}
	self.placeIndex = nil
	self.placeCache = {}
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

	-- Un nœud sans coordonnées monde ne participe à aucun calcul de distance :
	-- il est invisible pour le routeur alors qu'on sait où il est. On complète
	-- donc ce qui manque, quitte à retomber sur la carte parente.
	for _, node in pairs(registry) do
		self:EnsureWorldPos(node)
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

--- Nœud d'une source de monture, du plus précis au plus grossier :
--
--    1. un nœud explicitement désigné (édition manuelle) ;
--    2. l'entrée de l'instance, quand la source en nomme une ;
--    3. la carte du lieu cité par le texte de source.
--
--  Le troisième cas est celui de l'écrasante majorité des montures — vendeurs,
--  rares, événements, métiers. Sans lui, l'addon connaissait le lieu et
--  refusait quand même de router.
function Nodes:GetForSource(source)
	if type(source) ~= "table" then return nil end
	if source.nodeID then
		local node = self:Get(source.nodeID)
		if node then return node end
	end

	local node = self:GetForJournalInstance(source.journalInstanceID)
	if node then return node end

	-- `uiMapID` figé par un scan récent : on le croit sur parole, il a été
	-- rapproché une fois pour toutes.
	if type(source.uiMapID) == "number" then
		local mapNode = self:MapNode(source.uiMapID)
		if mapNode then return mapNode end
	end

	return self:GetForPlace(source.instanceName)
		or self:GetForPlace(source.placeName)
end

--------------------------------------------------------------------------------
-- Cartes du client
--------------------------------------------------------------------------------

--- Toutes les cartes descendant des deux racines, indexées par uiMapID.
function Nodes:AllMaps()
	if self.maps then return self.maps end

	local maps = {}
	if C_Map and type(C_Map.GetMapChildrenInfo) == "function" then
		for _, rootID in ipairs({ COSMIC_MAP_ID, WORLD_MAP_ID }) do
			local ok, children = pcall(C_Map.GetMapChildrenInfo, rootID, nil, true)
			if ok and type(children) == "table" then
				for _, info in ipairs(children) do
					if info.mapID then maps[info.mapID] = info end
				end
			end
		end
	end

	self.maps = maps
	return maps
end

--- Fiche d'une carte (nom, type, parent), mise en cache.
function Nodes:MapInfo(uiMapID)
	if type(uiMapID) ~= "number" then return nil end
	local cached = self.mapInfo[uiMapID]
	if cached ~= nil then
		if cached == false then return nil end
		return cached
	end

	local info = nil
	if C_Map and type(C_Map.GetMapInfo) == "function" then
		local ok, result = pcall(C_Map.GetMapInfo, uiMapID)
		if ok and type(result) == "table" then info = result end
	end
	-- Repli sur la moisson : `GetMapChildrenInfo` porte déjà nom et type, ce
	-- qui évite mille appels quand `GetMapInfo` n'est pas disponible.
	if not info then
		local listed = self:AllMaps()[uiMapID]
		if type(listed) == "table" then info = listed end
	end

	self.mapInfo[uiMapID] = info or false
	return info
end

function Nodes:MapName(uiMapID)
	local info = self:MapInfo(uiMapID)
	return info and info.name or nil
end

--- Remonte la chaîne des cartes parentes jusqu'à la première qui réponde à
--  `accept`. Bornée : une chaîne circulaire est possible sur un client abîmé,
--  et une boucle infinie au premier calcul de route serait un gel.
function Nodes:WalkUp(uiMapID, accept)
	local cursor = uiMapID
	for _ = 1, 8 do
		if type(cursor) ~= "number" or cursor == 0 then return nil end
		if accept(cursor) then return cursor end
		local info = self:MapInfo(cursor)
		local parent = info and info.parentMapID
		if parent == cursor then return nil end
		cursor = parent
	end
	return nil
end

--- Le nœud est-il sur cette carte, ou sur l'une de ses filles ? Un joueur dans
--  une échoppe de Valdrakken est sur une micro-carte, pas sur celle de la
--  ville : comparer les identifiants tels quels répondrait « non ».
function Nodes:IsOnMap(node, uiMapID)
	if type(node) ~= "table" or type(uiMapID) ~= "number" then return false end
	if node.uiMapID == uiMapID then return true end
	return self:WalkUp(node.uiMapID, function(candidate)
		return candidate == uiMapID
	end) ~= nil
end

--- Nom du continent d'un nœud, tel que l'affiche la carte du monde.
function Nodes:ContinentName(node)
	if type(node) ~= "table" then return nil end
	local continentMap = self:WalkUp(node.uiMapID, function(uiMapID)
		local info = self:MapInfo(uiMapID)
		return info ~= nil and info.mapType == MAP_TYPE.CONTINENT
	end)
	return continentMap and self:MapName(continentMap) or nil
end

--------------------------------------------------------------------------------
-- Projection carte <-> monde
--
-- La projection est affine et à axes alignés : la coordonnée monde `x` (axe
-- nord-sud, croissant vers le NORD) ne dépend que de la coordonnée de carte
-- `y`, et la coordonnée monde `y` (axe est-ouest, croissant vers l'OUEST) ne
-- dépend que de `x`. Deux coins opposés suffisent donc à décrire la carte
-- entière — et à faire l'inverse, que le client n'expose pas.
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

--- Rectangle monde d'une carte, ou nil si elle ne se projette pas.
--  @return { continentID, originNS, spanNS, originEW, spanEW } avec
--          wx = originNS + spanNS * y  et  wy = originEW + spanEW * x
function Nodes:MapRect(uiMapID)
	if type(uiMapID) ~= "number" then return nil end
	local cached = self.rects[uiMapID]
	if cached ~= nil then
		if cached == false then return nil end
		return cached
	end

	local rect = false
	local continentA, ax, ay = self:ResolveWorldPos(uiMapID, 0, 0)
	local continentB, bx, by = self:ResolveWorldPos(uiMapID, 1, 1)
	-- Une carte dont les deux coins tombent sur des continents différents, ou
	-- dont un axe est plat, n'est pas une carte exploitable.
	if continentA and continentA == continentB and ax ~= bx and ay ~= by then
		rect = {
			continentID = continentA,
			originNS = ax, spanNS = bx - ax,
			originEW = ay, spanEW = by - ay,
		}
	end

	self.rects[uiMapID] = rect
	if rect == false then return nil end
	return rect
end

--- Coordonnées de carte d'une position monde, ou nil si la carte ne couvre pas
--  ce continent. Le résultat peut sortir de [0,1] : c'est une information, pas
--  une erreur — cela veut dire « hors de cette carte ».
function Nodes:MapPosFromWorld(uiMapID, continentID, wx, wy)
	local rect = self:MapRect(uiMapID)
	if not rect or rect.continentID ~= continentID then return nil end
	if type(wx) ~= "number" or type(wy) ~= "number" then return nil end
	return (wy - rect.originEW) / rect.spanEW, (wx - rect.originNS) / rect.spanNS
end

--- Première carte parente projetable, en partant de `uiMapID` lui-même.
function Nodes:FirstProjectableAncestor(uiMapID)
	return self:WalkUp(uiMapID, function(candidate)
		local info = self:MapInfo(candidate)
		if info and info.mapType == MAP_TYPE.COSMIC then return false end
		return self:MapRect(candidate) ~= nil
	end)
end

--- Complète les coordonnées monde d'un nœud, en place.
--
--  Le repli est le point important : la carte d'un intérieur d'instance ne se
--  projette pas, et sans repli l'entrée de raid moissonnée sur cette carte
--  était invisible pour le routeur — pas de distance, pas de cap, une flèche
--  muette à trois pas du portail. On adopte alors le CENTRE de la première
--  carte parente projetable, et on le dit : `approxMapID`.
function Nodes:EnsureWorldPos(node)
	if type(node) ~= "table" then return node end
	if type(node.wx) == "number" and type(node.wy) == "number"
		and type(node.continentID) == "number"
	then
		return node
	end

	local continentID, wx, wy = self:ResolveWorldPos(node.uiMapID, node.x, node.y)
	if continentID then
		node.continentID, node.wx, node.wy = continentID, wx, wy
		return node
	end

	local ancestor = self:FirstProjectableAncestor(node.uiMapID)
	if ancestor and ancestor ~= node.uiMapID then
		local rect = self:MapRect(ancestor)
		node.continentID = rect.continentID
		node.wx = rect.originNS + rect.spanNS * 0.5
		node.wy = rect.originEW + rect.spanEW * 0.5
		node.approxMapID = ancestor
	end
	return node
end

--------------------------------------------------------------------------------
-- Nœuds de carte
--------------------------------------------------------------------------------

--- Nœud « toute la zone », créé à la demande et gardé pour la session.
--  Il n'est pas persisté : il se recalcule en deux appels et le client est sa
--  seule source de vérité.
function Nodes:MapNode(uiMapID)
	if type(uiMapID) ~= "number" then return nil end
	local nodeID = ns.Data.MapNodeID(uiMapID)

	local registry = self:All()
	if registry[nodeID] then return registry[nodeID] end

	local node = {
		nodeID = nodeID,
		name = self:MapName(uiMapID) or tostring(uiMapID),
		kind = ns.Data.NODE_KINDS.ZONE,
		uiMapID = uiMapID,
		x = 0.5,
		y = 0.5,
		-- « Quelque part dans cette zone » : l'interface doit le dire plutôt que
		-- d'afficher des coordonnées au dixième qui ne veulent rien dire.
		zoneWide = true,
	}
	-- Une carte de donjon ne se projette pas, et c'est justement le cas d'une
	-- instance dont l'entrée n'a jamais été moissonnée : le repli par carte
	-- parente donne alors « le donjon est dans cette zone », qui est vrai et
	-- utilisable, au lieu de « je ne sais pas où c'est ».
	self:EnsureWorldPos(node)
	if type(node.wx) ~= "number" then return nil end

	registry[nodeID] = node
	return node
end

--- Index « nom de carte normalisé -> uiMapID ». Une seule entrée par nom : à
--  nom égal, la carte la plus précise gagne (une zone avant un continent), et
--  à type égal le plus petit identifiant — c'est arbitraire mais STABLE, ce qui
--  vaut mieux qu'un ordre de parcours de table qui diffère d'un joueur à
--  l'autre.
function Nodes:BuildPlaceIndex()
	if self.placeIndex then return self.placeIndex end

	local index, ranks = {}, {}
	for uiMapID, info in pairs(self:AllMaps()) do
		local rank = ROUTABLE_MAP_TYPES[info.mapType]
		-- Sans type déclaré, on garde la carte au rang le plus faible plutôt que
		-- de l'écarter : un client qui ne renseigne pas `mapType` ne doit pas
		-- vider l'index.
		if info.mapType == nil then rank = 5 end
		local name = rank and ns.Util.NormalizeName(info.name)
		-- Projetable elle-même OU rattachable à une carte qui l'est : la seconde
		-- branche est ce qui rend routable un donjon dont l'entrée n'a pas été
		-- moissonnée. Sans elle, l'index écartait précisément les cartes pour
		-- lesquelles on n'avait rien d'autre.
		if name and #name >= MIN_PLACE_LENGTH and self:FirstProjectableAncestor(uiMapID) then
			local previous = ranks[name]
			if not previous or rank < previous
				or (rank == previous and uiMapID < index[name])
			then
				index[name] = uiMapID
				ranks[name] = rank
			end
		end
	end

	self.placeIndex = index
	return index
end

--- Carte désignée par un texte de lieu, avec les mêmes replis que le
--  rapprochement des instances : le client écrit « Zone : Nazjatar », le
--  Recherche de groupe « Nazjatar : le Gouffre », et il faut savoir couper des
--  deux côtés du deux-points.
--  @return uiMapID, stratégie
function Nodes:MatchPlace(text)
	local key = ns.Util.NormalizeName(text)
	if not key or #key < MIN_PLACE_LENGTH then return nil end

	-- Le rapprochement partiel balaie tout l'index. Le routeur, lui, demande la
	-- destination de CHAQUE monture manquante à chaque choix automatique : sans
	-- mémo, c'est un million de comparaisons de chaînes par rafraîchissement.
	-- Les textes de lieu se répètent énormément d'une monture à l'autre.
	local memo = self.placeCache[key]
	if memo ~= nil then
		if memo == false then return nil end
		return memo.uiMapID, memo.strategy
	end

	local uiMapID, strategy = self:MatchPlaceUncached(key)
	self.placeCache[key] = uiMapID and { uiMapID = uiMapID, strategy = strategy } or false
	return uiMapID, strategy
end

function Nodes:MatchPlaceUncached(key)
	local index = self:BuildPlaceIndex()

	if index[key] then return index[key], "exact" end

	local after = key:match("^[^:]+:%s*(.+)$")
	if after and index[after] then return index[after], "labelled" end

	local before = key:match("^(.-)%s*:%s*.+$")
	if before and index[before] then return index[before], "prefix" end

	-- Partiel, dans un seul sens : le texte de lieu CONTIENT le nom de carte.
	-- L'autre sens rapprocherait « Le Bastion » de « Le bastion du Crépuscule »,
	-- et c'est un bug qu'on a déjà payé une fois.
	for _, candidate in ipairs({ key, after, before }) do
		if candidate and #candidate >= MIN_PARTIAL_LENGTH then
			local best, bestName, ambiguous = nil, nil, false
			for name, uiMapID in pairs(index) do
				if #name >= MIN_PARTIAL_LENGTH and candidate:find(name, 1, true) then
					if not bestName or #name > #bestName then
						best, bestName, ambiguous = uiMapID, name, false
					elseif #name == #bestName and uiMapID ~= best then
						ambiguous = true
					end
				end
			end
			if best and not ambiguous then return best, "partial" end
			if ambiguous then return nil end
		end
	end

	return nil
end

--- Nœud de la carte nommée par un texte de lieu, ou nil.
function Nodes:GetForPlace(text)
	local uiMapID = self:MatchPlace(text)
	if not uiMapID then return nil end
	return self:MapNode(uiMapID)
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
	self:EnsureWorldPos(node)

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
-- Position du joueur
--------------------------------------------------------------------------------

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

	local node = {
		nodeID = ns.TravelGraph and ns.TravelGraph.PLAYER_NODE or "player",
		name = ns.L.NODE_PLAYER,
		kind = ns.Data.NODE_KINDS.OUTDOOR,
		uiMapID = uiMapID,
		x = x,
		y = y,
	}
	-- Le repli par carte parente vaut aussi pour le joueur : dans une instance,
	-- sa carte ne se projette pas, et sans coordonnées monde il n'y a de route
	-- vers nulle part.
	self:EnsureWorldPos(node)
	return node
end

--------------------------------------------------------------------------------
-- Distance et direction
--------------------------------------------------------------------------------

--- Vecteur de `a` vers `b`, exprimé en composantes NORD et OUEST.
--
--  DIRECTION ET DISTANCE SONT DEUX QUESTIONS SÉPARÉES, et les confondre est
--  exactement ce qui rendait la flèche muette. L'ancienne version abandonnait
--  le cap dès que la distance était incalculable — or une entrée moissonnée sur
--  la carte d'un intérieur d'instance n'a pas de coordonnées monde, donc pas de
--  distance, alors que la direction, elle, se lit très bien sur la carte.
--  Résultat : trois pas devant le portail, et rien à l'écran.
--
--  La direction se prend donc sur la CARTE quand les deux points la partagent
--  (`x` croît vers l'est, `y` vers le sud — la convention la plus sûre), et sur
--  les coordonnées monde sinon. La distance, elle, n'existe qu'en coordonnées
--  monde : sans elles on rend nil, et l'appelant le dit plutôt que d'afficher
--  un chiffre inventé.
--
--  @return north, west, distance|nil — ou nil si les deux points sont
--          incomparables (continents différents, cartes différentes et pas de
--          projection commune).
function Nodes:Vector(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then return nil end

	local distance = nil
	local comparable = type(a.wx) == "number" and type(b.wx) == "number"
		and a.continentID ~= nil and a.continentID == b.continentID
	if comparable then
		local dx, dy = b.wx - a.wx, b.wy - a.wy
		distance = math.sqrt(dx * dx + dy * dy)
	end

	if a.uiMapID ~= nil and a.uiMapID == b.uiMapID
		and type(a.x) == "number" and type(b.x) == "number"
	then
		return a.y - b.y, a.x - b.x, distance
	end

	if comparable then
		return b.wx - a.wx, b.wy - a.wy, distance
	end

	return nil
end

--- Distance en yards entre deux nœuds, ou nil s'ils ne sont pas comparables.
function Nodes:Distance(a, b)
	local _, _, distance = self:Vector(a, b)
	return distance
end

-- Sur une carte non projetable, faute d'échelle, « tout près » se mesure en
-- fraction de carte. Un intérieur d'instance fait quelques centaines de yards
-- de côté : 2 %, c'est l'ordre de grandeur d'une salle.
local NEAR_MAP_FRACTION = 0.02

--- `a` est-il à moins de `yards` de `b` ? Répond aussi quand la distance vraie
--  est inconnue, en retombant sur la fraction de carte.
function Nodes:IsNear(a, b, yards)
	local north, west, distance = self:Vector(a, b)
	if not north then return false end
	if distance then return distance <= yards end
	return math.sqrt(north * north + west * west) <= NEAR_MAP_FRACTION
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

--------------------------------------------------------------------------------
-- Point de passage
--------------------------------------------------------------------------------

local function CanPin(uiMapID)
	if not C_Map or type(C_Map.SetUserWaypoint) ~= "function" then return false end
	if type(C_Map.CanSetUserWaypointOnMap) ~= "function" then return true end
	local ok, allowed = pcall(C_Map.CanSetUserWaypointOnMap, uiMapID)
	return ok and allowed and true or false
end

--- Où poser le point de passage du client pour viser ce nœud.
--
--  Les cartes d'intérieur d'instance et les cartes cosmiques refusent le point
--  de passage. Renoncer là était le second silence de la flèche : ni épingle,
--  ni distance dans le suivi de quêtes, et rien pour l'expliquer. On remonte
--  donc à la première carte parente qui l'accepte, et on y reprojette la
--  position — ce qui donne une épingle juste sur la carte de zone.
--
--  @return uiMapID, x, y — ou nil si aucune carte de la chaîne n'accepte
function Nodes:WaypointFor(node)
	if type(node) ~= "table" then return nil end

	if type(node.uiMapID) == "number" and type(node.x) == "number" and CanPin(node.uiMapID) then
		return node.uiMapID, node.x, node.y
	end

	if type(node.wx) ~= "number" then return nil end
	local target = self:WalkUp(node.uiMapID, function(candidate)
		if candidate == node.uiMapID then return false end
		return CanPin(candidate) and self:MapPosFromWorld(candidate,
			node.continentID, node.wx, node.wy) ~= nil
	end)
	if not target then return nil end

	local x, y = self:MapPosFromWorld(target, node.continentID, node.wx, node.wy)
	if not x then return nil end
	-- Une position hors de la carte visée serait une épingle posée dans le vide.
	if x < 0 or x > 1 or y < 0 or y > 1 then return nil end
	return target, x, y
end
