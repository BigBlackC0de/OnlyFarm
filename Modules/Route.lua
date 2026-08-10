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
--  Renvoyer nil reste une réponse légitime — une monture de boutique ou de JCC
--  n'a aucun endroit où l'on puisse aller — mais c'est devenu RARE. Le nœud est
--  cherché du plus précis au plus grossier (entrée d'instance, puis carte du
--  lieu cité par le texte de source), et une zone entière est une destination
--  acceptable : elle met le joueur sur le bon continent, ce qui est l'essentiel
--  du trajet. Le manque de précision est porté par `zoneWide`, pas caché.
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
		-- « Quelque part dans cette zone » : à dire, sinon des coordonnées au
		-- dixième laissent croire à un point précis.
		zoneWide = node.zoneWide == true,
		continentName = ns.Nodes:ContinentName(node),
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
					-- Une destination précise avant une zone entière : à égalité
					-- par ailleurs, mieux vaut envoyer le joueur sur une porte
					-- que dans une province.
					mission.zoneWide and 1 or 0,
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

--- Compare deux clés de tri composites : des nombres, puis un nom en dernier
--  pour départager. Écrire la comparaison une fois évite autant de `if`
--  imbriqués que de critères — et permet d'en ajouter un sans y revenir.
function Route.CompareKeys(a, b)
	local last = #a
	for index = 1, last - 1 do
		if a[index] ~= b[index] then
			return a[index] < b[index] and -1 or 1
		end
	end
	if a[last] == b[last] then return 0 end
	return a[last] < b[last] and -1 or 1
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
--
--  ON REND TOUJOURS AU MOINS UNE ÉTAPE quand la cible est connue. L'ancienne
--  version rendait nil dès que Dijkstra ne trouvait rien — c'est-à-dire dès que
--  la cible était sur un autre continent sans téléport, soit le cas le plus
--  courant — et le joueur se retrouvait avec un plan vide et aucune consigne.
--  « Je ne sais pas t'y conduire » et « je ne sais pas où c'est » sont deux
--  réponses différentes, et seule la seconde justifie de ne rien dire.
--
--  L'étape de repli porte `far = true` : l'interface annonce alors le voyage
--  comme long au lieu de le présenter comme un simple vol.
--
--  @return liste de { kind, nodeID, node, name, spellName, cost, far }, ou nil
function Route:BuildSteps(mission)
	if not mission or not mission.node or not mission.node.nodeID then return nil end
	local targetID = mission.node.nodeID

	local universe = ns.TravelGraph:BuildUniverse({ targetID })
	local playerID = ns.TravelGraph.PLAYER_NODE

	if universe[playerID] and universe[targetID] then
		local _, previous = ns.TravelGraph:ShortestPaths(playerID, universe)
		local path = ns.TravelGraph:Path(previous, playerID, targetID)
		if path and #path > 0 then
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
	end

	return { self:FarStep(mission) }
end

--- Étape unique vers une cible qu'aucun trajet connu ne relie à ici.
--
--  Elle ne prétend pas conduire : elle DÉSIGNE. La flèche pointera dessus dès
--  que le joueur sera sur le bon continent, et d'ici là la consigne nomme la
--  zone et le continent — ce qui suffit à savoir quel portail prendre.
function Route:FarStep(mission)
	local node = mission.node
	local playerNode = ns.Nodes:GetPlayerNode()
	local far = not playerNode or ns.Nodes:Vector(playerNode, node) == nil

	return {
		index = 1,
		kind = far and ns.Data.EDGE_KINDS.WALK or ns.Data.EDGE_KINDS.FLY,
		nodeID = node.nodeID,
		node = node,
		name = mission.zoneName or mission.instanceName or node.name,
		far = far,
		continentName = mission.continentName,
	}
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
--  La preuve d'arrivée ne dépend pas de la nature de l'étape : un téléport est
--  « fait » quand on est à destination, un vol aussi. Pas besoin d'écouter le
--  lancement du sort, ce qui traiterait de toute façon mal le joueur qui y va
--  autrement. C'est `HasReached` qui décide, et il sait répondre même quand la
--  distance n'existe pas.
--  @return true si l'étape a changé
function Route:Advance()
	local plan = self.plan
	if not plan or not plan.steps then return false end

	local step = plan.steps[plan.current]
	if not step then return false end
	if not self:HasReached(step) then return false end

	plan.current = plan.current + 1
	if plan.current > #plan.steps then
		plan.arrived = true
		self:SendMessage("OF_ROUTE_ARRIVED")
	else
		-- Le point de passage suit le plan. Sans ça il restait planté sur
		-- l'étape franchie : le suivi de quêtes continuait d'annoncer une
		-- distance vers un endroit où le joueur se tenait déjà.
		self:PointAtCurrentStep()
	end
	self:SendMessage("OF_ROUTE_STEP")
	return true
end

--- L'étape est-elle franchie ?
--
--  Deux preuves, et la seconde vaut mieux que la première : être DANS
--  l'instance visée est un fait que le client affirme, là où la distance n'est
--  qu'une mesure — et une mesure qui n'existe pas toujours. Sans elle, la
--  flèche restait affichée alors que le joueur était déjà devant le boss.
--  `playerNode` est facultatif : la flèche mesure et redessine dix fois par
--  seconde, et recalculer trois fois la même position à chaque battement est du
--  travail pur pour rien.
function Route:HasReached(step, playerNode)
	if type(step) ~= "table" or not step.node then return false end

	playerNode = playerNode or ns.Nodes:GetPlayerNode()
	if playerNode and ns.Nodes:IsNear(playerNode, step.node, self.ARRIVAL_YARDS) then
		return true
	end

	-- Une cible à l'échelle de la zone est atteinte quand on EST dans la zone.
	-- Exiger soixante yards autour d'un centre géométrique reviendrait à ne
	-- jamais arriver : le centre d'une zone n'est pas un endroit où l'on va.
	if step.node.zoneWide and playerNode
		and ns.Nodes:IsOnMap(playerNode, step.node.uiMapID)
	then
		return true
	end

	return self:IsInsideTarget(step)
end

--- Le joueur est-il à l'intérieur de l'instance visée par cette étape ?
function Route:IsInsideTarget(step)
	local node = step and step.node
	if not node or node.kind ~= ns.Data.NODE_KINDS.INSTANCE then return false end
	if type(GetInstanceInfo) ~= "function" then return false end

	local ok, name, instanceType = pcall(GetInstanceInfo)
	if not ok or type(name) ~= "string" or instanceType == "none" then return false end

	local current = ns.Util.NormalizeName(name)
	local target = ns.Util.NormalizeName(node.name)
	return current ~= nil and current == target
end

--- Cap et distance vers un nœud, depuis la position courante.
--
--  CONVENTIONS, parce qu'elles ne se devinent pas et qu'un signe inversé donne
--  une flèche qui pointe pile à l'opposé :
--
--    * coordonnées de carte : x croît vers l'EST, y croît vers le SUD ;
--    * coordonnées monde : x croît vers le NORD, y croît vers l'OUEST ;
--    * GetPlayerFacing() : radians, 0 = nord, croissant dans le sens
--      ANTIHORAIRE (donc pi/2 = ouest) ;
--    * Texture:SetRotation() : positif = antihoraire.
--
--  On veut une rotation nulle quand la cible est droit devant, d'où
--  `rotation = cap - orientation`, les deux mesurés antihoraire depuis le nord.
--
--  Le choix de la mesure appartient à `Nodes:Vector` : carte commune d'abord,
--  monde ensuite. Ce qui compte ici, c'est qu'un cap SANS distance reste un cap
--  — l'ancienne version renonçait aux deux dès que l'une manquait.
--  @return rotation en radians|nil, distance en yards|nil
function Route:GetBearing(node, playerNode)
	if type(node) ~= "table" then return nil end
	playerNode = playerNode or ns.Nodes:GetPlayerNode()
	if not playerNode then return nil end

	local north, west, distance = ns.Nodes:Vector(playerNode, node)
	if not north then return nil end
	if type(GetPlayerFacing) ~= "function" then return nil, distance end
	local facing = GetPlayerFacing()
	if type(facing) ~= "number" then return nil, distance end

	if north == 0 and west == 0 then return 0, distance end
	return math.atan2(west, north) - facing, distance
end

--------------------------------------------------------------------------------
-- Ce que la flèche doit montrer
--
-- Rassemblé ici plutôt que dans l'affichage : décider quoi dire quand il n'y a
-- pas de cap est une question de routage, pas de mise en page. Et il faut
-- TOUJOURS dire quelque chose — un cadre qui n'affiche ni distance ni direction
-- se lit comme une panne, alors que « c'est sur un autre continent » est une
-- réponse complète.
--------------------------------------------------------------------------------

--- @return { step, node, rotation, distance, arrived, label, hint } ou nil
function Route:GetGuidance()
	local step = self:GetCurrentStep()
	if not step or not step.node then return nil end

	local playerNode = ns.Nodes:GetPlayerNode()
	local rotation, distance = self:GetBearing(step.node, playerNode)
	local guidance = {
		step = step,
		node = step.node,
		rotation = rotation,
		distance = distance,
		arrived = self:HasReached(step, playerNode),
	}

	if not rotation then
		-- Pas de cap : la cible n'est pas sur cette portion du monde. On nomme
		-- l'endroit, ce qui est exactement ce qu'il faut pour choisir un portail.
		local L = ns.L
		local continent = step.continentName or ns.Nodes:ContinentName(step.node)
		if continent then
			guidance.hint = L.ARROW_OTHER_CONTINENT:format(continent)
		else
			guidance.hint = L.ARROW_ELSEWHERE:format(step.name or step.node.name or "?")
		end
	elseif step.node.zoneWide then
		guidance.hint = ns.L.ARROW_ZONE_WIDE
	end

	return guidance
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

function Route:SendToTomTom(uiMapID, x, y, title)
	if TomTom == nil then return false end
	if type(uiMapID) ~= "number" or type(x) ~= "number" or type(y) ~= "number" then
		return false
	end
	local opts = {
		title = title,
		from = "OnlyFarm",
		persistent = false,
		minimap = true,
		world = true,
		crazy = true,
	}

	if type(TomTom.AddMFWaypoint) == "function" then
		local ok, uid = pcall(TomTom.AddMFWaypoint, TomTom, uiMapID, nil, x, y, opts)
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
		local ok = pcall(TomTom.AddWaypoint, TomTom, uiMapID, x, y, opts)
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
		-- Déjà sur place : Dijkstra rend un chemin vide quand départ et arrivée
		-- se confondent. Le point de passage sur la cible reste utile.
		steps = { self:FarStep(mission) }
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

	-- La carte visée n'est pas forcément celle du nœud : un intérieur d'instance
	-- refuse le point de passage, et c'est la carte de zone au-dessus qui le
	-- prend. `Nodes:WaypointFor` remonte cette chaîne et reprojette la position.
	local uiMapID, x, y = ns.Nodes:WaypointFor(node)

	-- TomTom d'abord s'il est là : sa flèche est meilleure que la nôtre. Mais on
	-- ne s'arrête PAS là, contrairement à avant — le point du client coûte deux
	-- appels et il donne la distance dans le suivi de quêtes.
	if uiMapID and self:SendToTomTom(uiMapID, x, y, title) then best = "tomtom" end

	if uiMapID and C_Map and type(C_Map.SetUserWaypoint) == "function" then
		local point = self.MakePoint(uiMapID, x, y)
		if point and pcall(C_Map.SetUserWaypoint, point) then
			if C_SuperTrack and type(C_SuperTrack.SetSuperTrackedUserWaypoint) == "function" then
				pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
			end
			if best == "arrow" then best = "native" end
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
