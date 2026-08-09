--[[---------------------------------------------------------------------------
	OnlyFarm — UI/ArrowHUD.lua

	La flèche. Un cadre flottant, déplaçable, qui pointe vers l'ÉTAPE COURANTE du
	trajet — pas vers la destination finale.

	POURQUOI ON LA DESSINE NOUS-MÊMES

	TomTom en a une, meilleure. Mais elle n'est pas venue : `AddWaypoint` a changé
	de signature au fil des versions de TomTom, l'ancienne forme prend des
	centièmes sur la carte courante et la moderne un uiMapID en fractions.
	Appeler l'une avec les arguments de l'autre ne lève AUCUNE erreur — le point
	part n'importe où, ou nulle part. Résultat : « TomTom détecté », et rien à
	l'écran.

	Le client, de son côté, n'a pas de flèche flottante : son point de passage
	donne une épingle sur la carte et une distance dans le suivi de quêtes, ce
	qui n'est pas ce qu'on demande quand on demande une flèche.

	D'où celle-ci. Elle ne dépend de rien, et surtout elle suit NOTRE plan : c'est
	la seule façon de pointer vers le prochain téléport plutôt que vers l'arrivée.

	CE QU'ELLE AFFICHE

	Un anneau avec un point sur le cap — le repère qui marche toujours, puisqu'il
	ne demande aucune texture — une flèche par-dessus quand le client nous en
	fournit une, la distance, et la consigne de l'étape (« Portail de Dalaran »,
	« Citadelle des Flammes infernales »).

	Quand l'étape est un téléport vers un autre continent, il n'y a pas de cap :
	on ne marche pas jusqu'à Dalaran. L'anneau s'efface et la consigne reste.
-----------------------------------------------------------------------------]]

local _, ns = ...

local ArrowHUD = ns:NewModule("ArrowHUD", 86)

local SIZE = 132
local RING_RADIUS = 44
local DOT_SIZE = 12
local UPDATE_PERIOD = 0.1

-- Le client n'expose pas d'atlas de flèche dont on soit sûr d'un patch à
-- l'autre. On sonde les candidats — C_Texture.GetAtlasInfo dit lequel existe —
-- et si aucun ne répond, l'anneau et son point suffisent. Pas de carré blanc
-- mystérieux à l'écran faute de mieux.
local ARROW_ATLAS_CANDIDATES = {
	"Navigation-Arrow",
	"Waypoint-Arrow",
	"minimap-positionarrow",
}

function ArrowHUD:OnEnable()
	self:RegisterMessage("OF_ROUTE_STARTED", "OnRouteChanged")
	self:RegisterMessage("OF_ROUTE_STOPPED", "OnRouteChanged")
	self:RegisterMessage("OF_ROUTE_STEP", "OnRouteChanged")
end

function ArrowHUD:OnRouteChanged()
	local plan = ns.Route:GetPlan()
	if plan and not plan.arrived then
		self:Show()
	else
		self:Hide()
	end
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function FindArrowAtlas()
	if not C_Texture or type(C_Texture.GetAtlasInfo) ~= "function" then return nil end
	for _, name in ipairs(ARROW_ATLAS_CANDIDATES) do
		local ok, info = pcall(C_Texture.GetAtlasInfo, name)
		if ok and info then return name end
	end
	return nil
end

function ArrowHUD:Create()
	if self.frame then return self.frame end
	local Theme = ns.Theme

	local frame = CreateFrame("Frame", "OnlyFarmArrow", UIParent)
	frame:SetSize(SIZE, SIZE + 34)
	frame:SetFrameStrata("MEDIUM")
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self_) self_:StartMoving() end)
	frame:SetScript("OnDragStop", function(self_)
		self_:StopMovingOrSizing()
		self:SavePosition()
	end)
	frame:Hide()
	self.frame = frame

	-- Anneau : douze petits traits en cercle. Un cercle dessiné à la main plutôt
	-- qu'une texture, comme le reste de l'addon — le client n'a pas de primitive
	-- circulaire, et douze points en donnent l'idée.
	local faint = Theme.colors.faint
	for index = 1, 12 do
		local angle = (index - 1) * math.pi / 6
		local tick = frame:CreateTexture(nil, "BACKGROUND")
		tick:SetSize(3, 3)
		tick:SetPoint("CENTER", frame, "TOP", RING_RADIUS * math.sin(angle),
			-SIZE / 2 + RING_RADIUS * math.cos(angle))
		tick:SetColorTexture(faint[1], faint[2], faint[3], 0.5)
	end

	-- Le point de cap : c'est lui qui porte l'information, et il ne dépend
	-- d'aucune texture d'art.
	frame.Dot = frame:CreateTexture(nil, "OVERLAY")
	frame.Dot:SetSize(DOT_SIZE, DOT_SIZE)

	-- La flèche, si le client nous en prête une.
	local atlas = FindArrowAtlas()
	if atlas then
		frame.Arrow = frame:CreateTexture(nil, "ARTWORK")
		frame.Arrow:SetSize(48, 48)
		frame.Arrow:SetPoint("CENTER", frame, "TOP", 0, -SIZE / 2)
		pcall(frame.Arrow.SetAtlas, frame.Arrow, atlas)
	end

	frame.Distance = Theme.Text(frame, "GameFontNormalLarge", Theme.colors.text, "CENTER")
	frame.Distance:SetPoint("CENTER", frame, "TOP", 0, -SIZE / 2)

	frame.Step = Theme.Text(frame, "GameFontHighlightSmall", Theme.colors.accent, "CENTER")
	frame.Step:SetPoint("TOP", frame, "TOP", 0, -SIZE + 6)
	frame.Step:SetPoint("LEFT")
	frame.Step:SetPoint("RIGHT")
	frame.Step:SetWordWrap(false)

	frame.Progress = Theme.Text(frame, "GameFontHighlightSmall", Theme.colors.faint, "CENTER")
	frame.Progress:SetPoint("TOP", frame.Step, "BOTTOM", 0, -2)
	frame.Progress:SetPoint("LEFT")
	frame.Progress:SetPoint("RIGHT")

	-- Un seul OnUpdate, bridé : la flèche doit suivre la souris du joueur qui
	-- tourne, pas recalculer une distance monde soixante fois par seconde.
	-- Il ne tourne pas quand la frame est masquée, donc pas de trajet en cours =
	-- aucun coût.
	frame.elapsed = 0
	frame:SetScript("OnUpdate", function(self_, delta)
		self_.elapsed = self_.elapsed + delta
		if self_.elapsed < UPDATE_PERIOD then return end
		self_.elapsed = 0
		ArrowHUD:Tick()
	end)

	self:RestorePosition()
	return frame
end

--------------------------------------------------------------------------------
-- Position retenue
--------------------------------------------------------------------------------

function ArrowHUD:SavePosition()
	if not self.frame or not ns.db then return end
	local point, _, _, x, y = self.frame:GetPoint()
	ns.db.profile.arrow.point = point
	ns.db.profile.arrow.x = x
	ns.db.profile.arrow.y = y
end

function ArrowHUD:RestorePosition()
	if not self.frame or not ns.db then return end
	local config = ns.db.profile.arrow
	self.frame:ClearAllPoints()
	self.frame:SetPoint(config.point or "CENTER", UIParent, config.point or "CENTER",
		config.x or 240, config.y or 0)
end

--------------------------------------------------------------------------------
-- Affichage
--------------------------------------------------------------------------------

function ArrowHUD:Show()
	local frame = self:Create()
	frame:Show()
	self:Update()
end

function ArrowHUD:Hide()
	if self.frame then self.frame:Hide() end
end

--- Un battement : on mesure l'avancement, puis on redessine.
--
--  Les deux sont séparés, et le drapeau n'est pas décoratif : `Advance` émet
--  OF_ROUTE_STEP, ce message rallume la flèche, et rallumer la flèche redessine.
--  Mesurer DANS le dessin faisait donc s'appeler l'un l'autre. Ça terminait —
--  `current` ne fait que croître — mais par chance, pas par construction.
function ArrowHUD:Tick()
	if self.ticking then return end
	self.ticking = true
	ns.Route:Advance()
	self:Update()
	self.ticking = false
end

--- Recalcule cap, distance et consignes.
function ArrowHUD:Update()
	local frame = self.frame
	if not frame or not frame:IsShown() then return end

	local step = ns.Route:GetCurrentStep()
	if not step then
		self:Hide()
		return
	end

	local plan = ns.Route:GetPlan()
	frame.Step:SetText(self:StepLabel(step))
	frame.Progress:SetText(plan and ns.L.ARROW_PROGRESS:format(plan.current, #plan.steps) or "")

	local rotation, distance = ns.Route:GetBearing(step.node)

	if distance then
		frame.Distance:SetText(ns.L.ARROW_YARDS:format(distance))
	else
		-- Pas de distance comparable : l'étape est sur un autre continent, donc
		-- elle se franchit par un sort, pas à pied.
		frame.Distance:SetText("—")
	end

	local Theme = ns.Theme
	local color = Theme.colors.accent
	if distance and distance <= ns.Route.ARRIVAL_YARDS then
		color = Theme.colors.green
	end

	if rotation then
		-- Le point se pose sur l'anneau au cap calculé. Rotation antihoraire
		-- depuis le haut : x = -sin, y = cos.
		frame.Dot:ClearAllPoints()
		frame.Dot:SetPoint("CENTER", frame, "TOP",
			-RING_RADIUS * math.sin(rotation),
			-SIZE / 2 + RING_RADIUS * math.cos(rotation))
		frame.Dot:SetColorTexture(color[1], color[2], color[3], 1)
		frame.Dot:Show()
		if frame.Arrow then
			frame.Arrow:SetRotation(rotation)
			frame.Arrow:SetVertexColor(color[1], color[2], color[3])
			frame.Arrow:Show()
		end
	else
		frame.Dot:Hide()
		if frame.Arrow then frame.Arrow:Hide() end
	end
end

--- Consigne d'une étape : ce que le joueur doit faire, pas où il doit aller.
function ArrowHUD:StepLabel(step)
	local L = ns.L
	if step.kind == ns.Data.EDGE_KINDS.TELEPORT and step.spellName then
		return L.ARROW_USE:format(step.spellName)
	end
	if step.kind == ns.Data.EDGE_KINDS.PORTAL then
		return L.ARROW_PORTAL:format(step.name or "?")
	end
	return step.name or "?"
end
