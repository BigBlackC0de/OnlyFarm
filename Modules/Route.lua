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
-- Pose du point de passage
--------------------------------------------------------------------------------

function Route:HasTomTom()
	return TomTom ~= nil and type(TomTom.AddWaypoint) == "function"
end

--- Pose le point de passage de la mission et l'allume.
--  @return "tomtom" | "native" | nil, plus un message d'échec le cas échéant
function Route:Start(mission)
	mission = mission or self:GetMission()
	if not mission then return nil, "no_mission" end

	local node = mission.node
	local title = mission.instanceName or mission.name

	if self:HasTomTom() then
		-- TomTom attend des coordonnées normalisées, comme celles du client.
		-- `persistent = false` : ce point est une proposition de l'addon, il n'a
		-- pas à survivre à la session dans la base de TomTom.
		local ok = pcall(TomTom.AddWaypoint, TomTom, node.uiMapID, node.x, node.y, {
			title = title,
			from = ns.ADDON_NAME or "OnlyFarm",
			persistent = false,
			crazy = true,
		})
		if ok then
			self.started = mission.mountID
			return "tomtom"
		end
	end

	-- Point de passage du client. Il faut vérifier la carte d'abord : les cartes
	-- d'intérieur d'instance et les cartes cosmiques le refusent, et poser sans
	-- demander lève une erreur au lieu de ne rien faire.
	if not C_Map or type(C_Map.SetUserWaypoint) ~= "function" then
		return nil, "no_api"
	end
	if type(C_Map.CanSetUserWaypointOnMap) == "function"
		and not C_Map.CanSetUserWaypointOnMap(node.uiMapID)
	then
		return nil, "map_refuses"
	end

	local point = self.MakePoint(node.uiMapID, node.x, node.y)
	if not point then return nil, "no_api" end

	local ok = pcall(C_Map.SetUserWaypoint, point)
	if not ok then return nil, "set_failed" end

	if C_SuperTrack and type(C_SuperTrack.SetSuperTrackedUserWaypoint) == "function" then
		pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
	end

	self.started = mission.mountID
	return "native"
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

--- Retire le point de passage posé par l'addon.
function Route:Stop()
	self.started = nil
	if self:HasTomTom() then
		-- TomTom n'offre pas de retrait par coordonnées sans garder la référence
		-- du point ; le joueur nettoie depuis TomTom, qui a son propre menu.
		return
	end
	if C_Map and type(C_Map.ClearUserWaypoint) == "function" then
		pcall(C_Map.ClearUserWaypoint)
	end
end
