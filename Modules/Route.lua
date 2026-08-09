--[[---------------------------------------------------------------------------
	OnlyFarm — Modules/Route.lua

	« Où je vais, et comment j'y arrive. »

	Ce module répond à UNE question à la fois : quelle monture viser maintenant,
	et où se trouve son entrée. Il ne calcule pas encore d'itinéraire à plusieurs
	étapes — TravelGraph sait le faire, mais un enchaînement de sauts qu'on n'a
	pas pu vérifier en jeu ne vaut pas mieux qu'une flèche qui pointe juste.

	LE POINT DE PASSAGE : PAS DE DÉPENDANCE, PAS DE PUBLICITÉ

	Deux chemins existaient pour guider le joueur :

	  * exiger TomTom, et afficher « installe TomTom » à qui ne l'a pas. Refusé :
	    on ne renvoie pas quelqu'un vers un autre addon pour une fonction que le
	    client sait faire tout seul depuis Shadowlands ;
	  * écrire notre propre GPS de zéro. Inutile : la flèche, la distance et
	    l'épingle sur la carte existent déjà côté client.

	Le troisième chemin est celui retenu. `C_Map.SetUserWaypoint` pose le point,
	`C_SuperTrack.SetSuperTrackedUserWaypoint` allume la flèche et la distance
	dans le suivi des quêtes. Aucune dépendance, et ça marche pour tout le monde.
	Si TomTom est là, on l'utilise à la place — sa flèche est meilleure et le
	joueur l'a installée pour ça — mais on ne la réclame jamais.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Route = ns:NewModule("Route", 50)

function Route:OnInitialize()
	self.mission = nil
end

function Route:OnEnable()
	self:RegisterMessage("OF_COLLECTION_UPDATED", "Invalidate")
	self:RegisterMessage("OF_LOCKOUTS_UPDATED", "Invalidate")
	self:RegisterMessage("OF_SCAN_COMPLETE", "Invalidate")
	self:RegisterMessage("OF_ATTEMPTS_UPDATED", "Invalidate")
	self:RegisterMessage("OF_NODES_UPDATED", "Invalidate")
end

function Route:Invalidate()
	self.mission = nil
	self:SendMessage("OF_ROUTE_UPDATED")
end

--------------------------------------------------------------------------------
-- Cible choisie
--------------------------------------------------------------------------------

--- Monture épinglée par le joueur, ou nil s'il laisse l'addon choisir.
function Route:GetTarget()
	return ns.db and ns.db.profile.routing.target or nil
end

--- Épingle une monture. Elle reste la cible jusqu'à ce qu'elle soit obtenue,
--  exclue, ou que le joueur en choisisse une autre.
function Route:SetTarget(mountID)
	if not ns.db then return end
	ns.db.profile.routing.target = mountID
	self.mission = nil
	self:SendMessage("OF_ROUTE_UPDATED")
end

function Route:ClearTarget()
	self:SetTarget(nil)
end

--------------------------------------------------------------------------------
-- Construction d'une mission
--------------------------------------------------------------------------------

--- Mission pour une monture donnée, ou nil si on ne sait pas où l'envoyer.
--
--  Renvoyer nil est une réponse légitime et fréquente : sans entrée
--  cartographiée, il n'y a pas de coordonnées, donc pas de point de passage à
--  poser. Mieux vaut le dire que planter une épingle au hasard.
function Route:GetMissionFor(mountID)
	if type(mountID) ~= "number" then return nil end

	local entry = ns.Collection:GetEntry(mountID)
	if not entry then return nil end

	local source = ns.Eligibility:GetSource(mountID)
	local node = ns.Nodes:GetForSource(source)
	if not node or type(node.uiMapID) ~= "number"
		or type(node.x) ~= "number" or type(node.y) ~= "number"
	then
		return nil
	end

	local mission = {
		mountID = mountID,
		name = entry.name,
		icon = entry.icon,
		owned = entry.owned,
		node = node,
		source = source,
		instanceName = (source and source.instanceName) or node.name,
		isRaid = source and source.isRaid,
		attempts = ns.Attempts:GetCount(mountID),
		status = ns.Eligibility:GetStatus(mountID),
		zoneName = self:GetZoneName(node.uiMapID),
	}

	-- Le boss, mais seulement si c'en est un. `encounterName` porte le sujet du
	-- texte de source quel qu'il soit : sur un vendeur c'est le nom du vendeur.
	if source and source.encounterName and source.encounterName ~= ""
		and source.kind == ns.Data.SOURCE_KINDS.BOSS
	then
		mission.encounterName = source.encounterName
	end

	-- La difficulté n'est PAS devinée. Aucune API ne dit à quelle difficulté une
	-- monture tombe ; la seule que l'on connaisse est celle d'un verrou déjà
	-- posé, parce qu'elle est mesurée. « Raid mythique » écrit au hasard
	-- enverrait le joueur en mythique pour une monture qui tombe en normal.
	if mission.status and mission.status.lock then
		mission.difficultyName = mission.status.lock.difficultyName
	end

	return mission
end

--- Nom localisé de la carte d'un nœud.
function Route:GetZoneName(uiMapID)
	if not C_Map or type(C_Map.GetMapInfo) ~= "function" then return nil end
	local ok, info = pcall(C_Map.GetMapInfo, uiMapID)
	if not ok or type(info) ~= "table" then return nil end
	return info.name
end

--------------------------------------------------------------------------------
-- Choix automatique
--------------------------------------------------------------------------------

local STATE_PRIORITY = {
	available = 1,
	unknown = 2,
	locked = 3,
	unmapped = 4,
	ineligible = 5,
}

--- Mission proposée : la cible épinglée si elle tient toujours, sinon le
--  meilleur candidat.
function Route:GetMission()
	if self.mission ~= nil then
		-- `false` mémorise « on a déjà cherché et il n'y a rien » : sans ça, un
		-- rafraîchissement par seconde relancerait la recherche pour rien.
		if self.mission == false then return nil end
		return self.mission
	end

	local target = self:GetTarget()
	if target then
		local mission = self:GetMissionFor(target)
		-- Une cible obtenue depuis, ou exclue, ne tient plus : on repasse au
		-- choix automatique plutôt que d'afficher une mission périmée.
		if mission and not mission.owned and not ns.Collection:IsExcluded(target) then
			mission.pinned = true
			self.mission = mission
			return mission
		end
	end

	local mission = self:PickAuto()
	self.mission = mission or false
	return mission
end

--- Meilleur candidat parmi les montures manquantes.
--
--  Un raid d'abord, comme demandé : c'est le cas le plus net — une instance, une
--  entrée, un verrou hebdomadaire. Puis ce qui est ouvert maintenant, puis ce
--  sur quoi le joueur s'acharne déjà, et le nom pour départager.
function Route:PickAuto()
	local best, bestKey = nil, nil

	for _, entry in ipairs(ns.Collection:GetMissing()) do
		if not entry.excluded then
			local mission = self:GetMissionFor(entry.mountID)
			if mission then
				local key = {
					mission.isRaid == true and 0 or 1,
					STATE_PRIORITY[mission.status and mission.status.state] or 9,
					-mission.attempts,
					mission.name or "",
				}
				if not bestKey or self.CompareKeys(key, bestKey) < 0 then
					best, bestKey = mission, key
				end
			end
		end
	end

	return best
end

--- Compare deux clés de tri composites. Trois nombres puis un nom : écrire la
--  comparaison une fois évite quatre `if` imbriqués recopiés à chaque critère.
function Route.CompareKeys(a, b)
	for index = 1, 3 do
		if a[index] ~= b[index] then
			return a[index] < b[index] and -1 or 1
		end
	end
	if a[4] == b[4] then return 0 end
	return a[4] < b[4] and -1 or 1
end

--------------------------------------------------------------------------------
-- Trajet : les étapes jusqu'à la cible
--
-- C'est ici que « une flèche vers le prochain téléport » se fabrique. Dijkstra
-- vit déjà dans TravelGraph, et les arêtes dans Teleports (grimoire et boîte à
-- jouets du personnage) : il ne manquait que de s'en servir et de retenir le
-- plan.
--
-- Le plan est calculé UNE FOIS, au démarrage. Le recalculer à chaque pas
-- ferait danser la flèche : à mi-chemin d'un vol, un autre téléport peut
-- devenir marginalement moins cher, et la consigne changerait sous les pieds du
-- joueur. On mesure donc l'avancement le long du plan retenu, et on ne
-- replanifie que si le joueur le demande.
--------------------------------------------------------------------------------

-- Distance en yards sous laquelle une étape est considérée atteinte. Large
-- exprès : une entrée d'instance est un volume, pas un point, et le nœud est
-- posé sur l'icône de la carte.
Route.ARRIVAL_YARDS = 60

--- Construit les étapes de la position courante jusqu'à la cible.
--  @return liste de { kind, nodeID, node, name, spellName, cost }, ou nil
function Route:BuildSteps(mission)
	if not mission or not mission.node or not mission.node.nodeID then return nil end
	local targetID = mission.node.nodeID

	local universe = ns.TravelGraph:BuildUniverse({ targetID })
	local playerID = ns.TravelGraph.PLAYER_NODE
	if not universe[playerID] then return nil end
	if not universe[targetID] then return nil end

	local _, previous = ns.TravelGraph:ShortestPaths(playerID, universe)
	local path = ns.TravelGraph:Path(previous, playerID, targetID)
	-- Inatteignable : continents différents et aucun téléport pour les relier.
	-- On renvoie nil et l'interface le dit, plutôt que d'inventer un trajet.
	if not path then return nil end

	local steps = {}
	for index, hop in ipairs(path) do
		local node = universe[hop.to]
		steps[index] = {
			index = index,
			kind = hop.edge and hop.edge.kind or ns.Data.EDGE_KINDS.FLY,
			nodeID = hop.to,
			node = node,
			name = node and node.name or hop.to,
			spellName = hop.edge and hop.edge.name,
			spellID = hop.edge and hop.edge.spellID,
			itemID = hop.edge and hop.edge.itemID,
			cost = hop.cost,
		}
	end
	return steps
end

--- Plan en cours, ou nil si aucun trajet n'a été lancé.
function Route:GetPlan()
	return self.plan
end

--- Étape courante du plan.
function Route:GetCurrentStep()
	local plan = self.plan
	if not plan or not plan.steps then return nil end
	return plan.steps[plan.current]
end

--- Fait avancer le plan si le joueur a atteint l'étape courante.
--
--  La mesure est la même pour toutes les natures d'étape : la distance au nœud
--  d'arrivée. Un téléport est « fait » quand on est arrivé à destination, un vol
--  aussi. Pas besoin d'écouter le lancement du sort, ce qui éviterait de toute
--  façon mal le cas du joueur qui y va autrement.
--  @return true si l'étape a changé
function Route:Advance()
	local plan = self.plan
	if not plan or not plan.steps then return false end

	local step = plan.steps[plan.current]
	if not step then return false end

	local playerNode = ns.Nodes:GetPlayerNode()
	local distance = playerNode and ns.Nodes:Distance(playerNode, step.node)
	if not distance or distance > self.ARRIVAL_YARDS then return false end

	plan.current = plan.current + 1
	if plan.current > #plan.steps then
		plan.arrived = true
		self:SendMessage("OF_ROUTE_ARRIVED")
	end
	self:SendMessage("OF_ROUTE_STEP")
	return true
end

--- Cap et distance vers un nœud, depuis la position courante.
--
--  CONVENTIONS, parce qu'elles ne se devinent pas et qu'un signe inversé donne
--  une flèche qui pointe pile à l'opposé :
--
--    * coordonnées de carte : x croît vers l'EST, y croît vers le SUD ;
--    * GetPlayerFacing() : radians, 0 = nord, croissant dans le sens
--      ANTIHORAIRE (donc pi/2 = ouest) ;
--    * Texture:SetRotation() : positif = antihoraire.
--
--  On veut une rotation nulle quand la cible est droit devant, d'où
--  `rotation = cap - orientation`, les deux mesurés antihoraire depuis le nord.
--
--  Le cap se calcule en coordonnées de CARTE quand le joueur et la cible sont
--  sur la même, parce que cette convention-là est certaine. Sinon on retombe
--  sur les coordonnées monde, dont l'axe x pointe au nord et l'axe y à l'ouest
--  — c'est l'hypothèse à vérifier en jeu si la flèche part de travers.
--  @return rotation en radians, distance en yards — ou nil si incomparable
function Route:GetBearing(node)
	if type(node) ~= "table" then return nil end
	local playerNode = ns.Nodes:GetPlayerNode()
	if not playerNode then return nil end

	local distance = ns.Nodes:Distance(playerNode, node)
	if not distance then return nil end
	if type(GetPlayerFacing) ~= "function" then return nil, distance end
	local facing = GetPlayerFacing()
	if type(facing) ~= "number" then return nil, distance end

	local north, west
	if playerNode.uiMapID and playerNode.uiMapID == node.uiMapID then
		north = playerNode.y - node.y     -- y croît au sud
		west = playerNode.x - node.x      -- x croît à l'est
	else
		north = node.wx - playerNode.wx
		west = node.wy - playerNode.wy
	end

	if north == 0 and west == 0 then return 0, distance end
	return math.atan2(west, north) - facing, distance
end

--------------------------------------------------------------------------------
-- Pose du point de passage
--------------------------------------------------------------------------------

--- TomTom, s'il est là ET si on reconnaît sa signature.
--
--  Prudence obligatoire : `AddWaypoint` a changé de forme au fil des versions.
--  L'ancienne prenait `(x, y, description…)` en centièmes sur la carte
--  COURANTE ; la moderne prend `(uiMapID, x, y, opts)` en fractions. Appeler
--  l'une avec les arguments de l'autre ne lève aucune erreur : le point est
--  simplement posé n'importe où, ou nulle part. C'est exactement ce qui s'est
--  produit — « TomTom détecté », et aucune flèche.
--
--  `AddMFWaypoint(uiMapID, floor, x, y, opts)` est la forme stable depuis le
--  passage aux uiMapID. On la préfère, et TomTom n'est de toute façon plus
--  qu'un bonus : la flèche d'OnlyFarm ne dépend de personne.
function Route:HasTomTom()
	if TomTom == nil then return false end
	return type(TomTom.AddMFWaypoint) == "function"
		or type(TomTom.AddWaypoint) == "function"
end

function Route:SendToTomTom(node, title)
	if TomTom == nil then return false end
	local opts = {
		title = title,
		from = "OnlyFarm",
		persistent = false,
		minimap = true,
		world = true,
		crazy = true,
	}

	if type(TomTom.AddMFWaypoint) == "function" then
		local ok, uid = pcall(TomTom.AddMFWaypoint, TomTom, node.uiMapID, nil,
			node.x, node.y, opts)
		if ok then
			-- `crazy = true` ne suffit pas toujours : selon le réglage
			-- `arrow.autoqueue` du joueur, le point entre dans une file au lieu
			-- de prendre la flèche. On la réclame explicitement.
			if uid and type(TomTom.SetCrazyArrow) == "function" then
				pcall(TomTom.SetCrazyArrow, TomTom, uid, 15, title)
			end
			return true
		end
	end

	if type(TomTom.AddWaypoint) == "function" then
		local ok = pcall(TomTom.AddWaypoint, TomTom, node.uiMapID, node.x, node.y, opts)
		if ok then return true end
	end

	return false
end

--- Lance le trajet : calcule le plan, pose le point de passage sur la PREMIÈRE
--  étape, et allume la flèche.
--
--  Le point ne va pas sur la destination finale mais sur l'étape courante. C'est
--  toute la différence entre « Ulduar est par là, à 4000 mètres » et « prends le
--  portail de Dalaran, il est à 60 mètres devant toi ».
--
--  @return true si le trajet est lancé, sinon nil + une raison
function Route:Start(mission)
	mission = mission or self:GetMission()
	if not mission then return nil, "no_mission" end

	local steps = self:BuildSteps(mission)
	if not steps or #steps == 0 then
		-- Déjà sur place, ou aucun chemin. Le point de passage sur la cible
		-- reste utile dans les deux cas.
		steps = { {
			index = 1,
			kind = ns.Data.EDGE_KINDS.FLY,
			nodeID = mission.node.nodeID,
			node = mission.node,
			name = mission.instanceName or mission.node.name,
		} }
	end

	self.plan = {
		mountID = mission.mountID,
		mission = mission,
		steps = steps,
		current = 1,
		arrived = false,
		startedAt = time(),
	}

	self:PointAtCurrentStep()
	self:SendMessage("OF_ROUTE_STARTED")
	return true
end

--- (Re)pose le point de passage sur l'étape courante.
--  @return "tomtom" | "native" | "arrow" — le meilleur guidage obtenu
function Route:PointAtCurrentStep()
	local step = self:GetCurrentStep()
	if not step or not step.node then return nil, "no_step" end

	local node = step.node
	local title = step.name or (self.plan.mission and self.plan.mission.name)
	local best = "arrow"

	-- TomTom d'abord s'il est là : sa flèche est meilleure que la nôtre. Mais on
	-- ne s'arrête PAS là, contrairement à avant — le point du client coûte deux
	-- appels et il donne la distance dans le suivi de quêtes.
	if self:SendToTomTom(node, title) then best = "tomtom" end

	-- Point de passage du client. Vérifier la carte d'abord : les cartes
	-- d'intérieur d'instance et les cartes cosmiques le refusent, et poser sans
	-- demander lève une erreur au lieu de ne rien faire.
	if C_Map and type(C_Map.SetUserWaypoint) == "function" then
		local allowed = true
		if type(C_Map.CanSetUserWaypointOnMap) == "function" then
			allowed = C_Map.CanSetUserWaypointOnMap(node.uiMapID) and true or false
		end
		if allowed then
			local point = self.MakePoint(node.uiMapID, node.x, node.y)
			if point and pcall(C_Map.SetUserWaypoint, point) then
				if C_SuperTrack and type(C_SuperTrack.SetSuperTrackedUserWaypoint) == "function" then
					pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
				end
				if best == "arrow" then best = "native" end
			end
		end
	end

	self:SendMessage("OF_ROUTE_STEP")
	return best
end

--- Fabrique un UiMapPoint. `UiMapPoint.CreateFromCoordinates` est un utilitaire
--  de l'interface, pas une API documentée : on s'en sert s'il est là, et on
--  construit la table à la main sinon. C_Map.SetUserWaypoint n'attend qu'un
--  `uiMapID` et une `position`.
function Route.MakePoint(uiMapID, x, y)
	if UiMapPoint and type(UiMapPoint.CreateFromCoordinates) == "function" then
		local ok, point = pcall(UiMapPoint.CreateFromCoordinates, uiMapID, x, y)
		if ok and point then return point end
	end

	local position
	if type(CreateVector2D) == "function" then
		position = CreateVector2D(x, y)
	else
		position = { x = x, y = y }
	end
	return { uiMapID = uiMapID, position = position }
end

--- Arrête le trajet et retire le point de passage.
function Route:Stop()
	self.plan = nil
	if C_Map and type(C_Map.ClearUserWaypoint) == "function" then
		pcall(C_Map.ClearUserWaypoint)
	end
	-- TomTom garde son point : il a son propre menu pour l'effacer, et le retirer
	-- dans son dos supprimerait peut-être un point que le joueur avait posé.
	self:SendMessage("OF_ROUTE_STOPPED")
end
