--[[---------------------------------------------------------------------------
	OnlyFarm — UI/RoutePage.lua

	L'onglet Route. Une mission à la fois, et de quoi la lancer.

	  ┌───────────────────────────────┬─────────────────────┐
	  │ [icône] Proto-drake fumeronde │                     │
	  │ Raid · Ulduar                 │    carte de zone    │
	  │ Boss  Yogg-Saron              │    avec épingle     │
	  │ Zone  Désolation des Dragons  │                     │
	  │ Essais 12 · disponible        │                     │
	  │                    [ Start ]  │                     │
	  └───────────────────────────────┴─────────────────────┘

	Rien n'est calculé ici : Modules/Route.lua choisit la mission et pose le
	point de passage. Cette page pose des frames et affiche ce qu'on lui donne.

	Le chemin est découpé en ÉTAPES (téléport, vol, entrée) par Dijkstra, dans
	Modules/Route.lua. La liste les montre toutes, la flèche d'UI/ArrowHUD.lua
	pointe celle en cours. C'est ce qui fait la différence entre « Ulduar est par
	là, à quatre kilomètres » et « prends le portail de Dalaran, devant toi ».
-----------------------------------------------------------------------------]]

local _, ns = ...

local RoutePage = ns:NewModule("RoutePage", 83)

local GAP = 8
local LINE_HEIGHT = 20

function RoutePage:OnEnable()
	self:RegisterMessage("OF_ROUTE_UPDATED", "Refresh")
	self:RegisterMessage("OF_ROUTE_STARTED", "Refresh")
	self:RegisterMessage("OF_ROUTE_STOPPED", "Refresh")
	self:RegisterMessage("OF_ROUTE_STEP", "Refresh")
	self:RegisterMessage("OF_ROUTE_ARRIVED", "OnArrived")
end

--- Arrivée : on le dit dans le chat, parce que la flèche disparaît et qu'une
--  disparition sans un mot se lit comme une panne.
function RoutePage:OnArrived()
	ns:Print(ns.L.ROUTE_ARRIVED)
	self:Refresh()
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

function RoutePage:Create(parent)
	if self.page then return self.page end
	local Theme = ns.Theme
	local L = ns.L

	local page = CreateFrame("Frame", nil, parent)
	page:SetAllPoints()
	page:Hide()
	self.page = page

	self:CreateMission(page)
	self:CreateMap(page)

	return page
end

function RoutePage:CreateMission(page)
	local Theme = ns.Theme
	local L = ns.L

	local card = Theme.Card(page)
	card:SetPoint("TOPLEFT")
	card:SetPoint("BOTTOMLEFT")
	card:SetWidth(360)
	page.MissionCard = card

	local title = Theme.Text(card, "GameFontNormal", Theme.colors.text)
	title:SetPoint("TOPLEFT", 10, -8)
	title:SetText(L.ROUTE_MISSION)

	card.Icon = card:CreateTexture(nil, "ARTWORK")
	card.Icon:SetSize(36, 36)
	card.Icon:SetPoint("TOPLEFT", 10, -32)

	card.MountName = Theme.Text(card, "GameFontNormalLarge", Theme.colors.accent)
	card.MountName:SetPoint("TOPLEFT", card.Icon, "TOPRIGHT", 10, -2)
	card.MountName:SetPoint("RIGHT", -10, 0)
	card.MountName:SetWordWrap(false)

	card.Pinned = Theme.Text(card, "GameFontHighlightSmall", Theme.colors.gold)
	card.Pinned:SetPoint("TOPLEFT", card.MountName, "BOTTOMLEFT", 0, -2)

	-- Lignes de description : libellé discret à gauche, valeur à droite. Elles
	-- sont créées une fois et masquées quand elles n'ont rien à dire, plutôt que
	-- de laisser une étiquette sans valeur.
	card.Lines = {}
	local anchor = card.Icon
	for index = 1, 5 do
		local row = CreateFrame("Frame", nil, card)
		row:SetHeight(LINE_HEIGHT)
		row:SetPoint("LEFT", 10, 0)
		row:SetPoint("RIGHT", -10, 0)
		if index == 1 then
			row:SetPoint("TOP", anchor, "BOTTOM", 0, -10)
		else
			row:SetPoint("TOP", card.Lines[index - 1], "BOTTOM", 0, 0)
		end

		row.Label = Theme.Text(row, "GameFontHighlightSmall", Theme.colors.faint)
		row.Label:SetPoint("LEFT")
		row.Label:SetWidth(84)

		row.Value = Theme.Text(row, "GameFontHighlightSmall", Theme.colors.text)
		row.Value:SetPoint("LEFT", row.Label, "RIGHT", 6, 0)
		row.Value:SetPoint("RIGHT")
		row.Value:SetWordWrap(false)

		row:Hide()
		card.Lines[index] = row
	end

	-- Pied : le bouton et ce qu'il va faire. Le joueur doit savoir avant de
	-- cliquer si la flèche viendra du client ou de TomTom.
	local rule = Theme.Separator(card)
	rule:SetPoint("BOTTOMLEFT", 1, 52)
	rule:SetPoint("BOTTOMRIGHT", -1, 52)

	card.StartButton = Theme.Button(card, L.ROUTE_START, 120, 24)
	card.StartButton:SetPoint("BOTTOMLEFT", 10, 20)
	card.StartButton:SetScript("OnClick", function() RoutePage:OnStart() end)

	card.ClearButton = Theme.Button(card, L.ROUTE_UNPIN, 120, 24)
	card.ClearButton:SetPoint("BOTTOMLEFT", card.StartButton, "BOTTOMRIGHT", GAP, 0)
	card.ClearButton:SetScript("OnClick", function() ns.Route:ClearTarget() end)

	card.Backend = Theme.Text(card, "GameFontHighlightSmall", Theme.colors.faint)
	card.Backend:SetPoint("BOTTOMLEFT", 10, 8)
	card.Backend:SetPoint("BOTTOMRIGHT", -10, 8)
	card.Backend:SetWordWrap(false)

	card.Empty = Theme.Text(card, "GameFontHighlightSmall", Theme.colors.faint, "CENTER")
	card.Empty:SetPoint("CENTER", 0, 0)
	card.Empty:SetPoint("LEFT", 20, 0)
	card.Empty:SetPoint("RIGHT", -20, 0)
	card.Empty:Hide()

	self:CreateSteps(card)
end

--- Le chemin, étape par étape. C'est la réponse à « une flèche vers le prochain
--  téléport » : la flèche montre l'étape courante, cette liste montre la suite.
function RoutePage:CreateSteps(card)
	local Theme = ns.Theme
	local L = ns.L

	local title = Theme.Text(card, "GameFontNormal", Theme.colors.text)
	title:SetPoint("TOPLEFT", card.Lines[#card.Lines], "BOTTOMLEFT", 0, -14)
	title:SetText(L.ROUTE_STEPS)
	card.StepsTitle = title

	card.Steps = {}
	for index = 1, 6 do
		local row = CreateFrame("Frame", nil, card)
		row:SetHeight(LINE_HEIGHT)
		row:SetPoint("LEFT", 10, 0)
		row:SetPoint("RIGHT", -10, 0)
		if index == 1 then
			row:SetPoint("TOP", title, "BOTTOM", 0, -4)
		else
			row:SetPoint("TOP", card.Steps[index - 1], "BOTTOM", 0, 0)
		end

		-- Pastille de rang : elle dit d'un coup d'œil où on en est, et laquelle
		-- est l'étape courante.
		row.Index = Theme.Text(row, "GameFontHighlightSmall", Theme.colors.faint, "CENTER")
		row.Index:SetPoint("LEFT")
		row.Index:SetWidth(18)

		row.Text = Theme.Text(row, "GameFontHighlightSmall", Theme.colors.muted)
		row.Text:SetPoint("LEFT", row.Index, "RIGHT", 6, 0)
		row.Text:SetPoint("RIGHT", -44, 0)
		row.Text:SetWordWrap(false)

		row.Cost = Theme.Text(row, "GameFontHighlightSmall", Theme.colors.faint, "RIGHT")
		row.Cost:SetPoint("RIGHT")
		row.Cost:SetWidth(40)

		row:Hide()
		card.Steps[index] = row
	end

	card.StepsEmpty = Theme.Text(card, "GameFontHighlightSmall", Theme.colors.faint)
	card.StepsEmpty:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	card.StepsEmpty:SetPoint("RIGHT", -10, 0)
	card.StepsEmpty:SetHeight(34)
	card.StepsEmpty:SetJustifyV("TOP")
	card.StepsEmpty:Hide()
end

function RoutePage:CreateMap(page)
	local Theme = ns.Theme
	local L = ns.L

	local card = Theme.Card(page)
	card:SetPoint("TOPLEFT", page.MissionCard, "TOPRIGHT", GAP, 0)
	card:SetPoint("BOTTOMRIGHT")
	page.MapCard = card

	local title = Theme.Text(card, "GameFontNormal", Theme.colors.text)
	title:SetPoint("TOPLEFT", 10, -8)
	title:SetText(L.ROUTE_WHERE)

	local preview = ns.MapPreview.Create(card)
	preview:SetPoint("TOPLEFT", 8, -30)
	preview:SetPoint("BOTTOMRIGHT", -8, 8)
	card.Preview = preview
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

function RoutePage:OnStart()
	local L = ns.L

	-- Le bouton fait aussi l'arrêt : un trajet en cours et un bouton « Start »
	-- qui le relance, c'est un bouton qui ne dit pas ce qu'il fait.
	local plan = ns.Route:GetPlan()
	if plan and not plan.arrived then
		ns.Route:Stop()
		self:Refresh()
		return
	end

	local mission = ns.Route:GetMission()
	if not mission then return end

	local ok, reason = ns.Route:Start(mission)
	if ok then
		local step = ns.Route:GetCurrentStep()
		ns:Print(L.ROUTE_STARTED:format(step and step.name or mission.name))
		-- Épingler la cible au démarrage : le joueur vient de dire qu'il y va,
		-- l'addon n'a plus à en proposer une autre au prochain rafraîchissement.
		ns.Route:SetTarget(mission.mountID)
		ns.ArrowHUD:Show()
	else
		ns:Print(L.ROUTE_FAILED:format(tostring(reason)))
	end
	self:Refresh()
end

--------------------------------------------------------------------------------
-- Rafraîchissement
--------------------------------------------------------------------------------

function RoutePage:SetShown(shown)
	if not self.page then return end
	self.page:SetShown(shown)
end

--- Remplit une ligne de description, ou la masque si la valeur manque.
local function SetLine(row, label, value, color)
	if not value or value == "" then
		row:Hide()
		return false
	end
	row.Label:SetText(label)
	row.Value:SetText(value)
	local c = color or ns.Theme.colors.text
	row.Value:SetTextColor(c[1], c[2], c[3])
	row:Show()
	return true
end

function RoutePage:Refresh()
	local page = self.page
	if not page or not page:IsShown() then return end

	local L = ns.L
	local Theme = ns.Theme
	local card = page.MissionCard
	local mission = ns.Route:GetMission()

	if not mission then
		card.Icon:Hide()
		card.MountName:SetText("")
		card.Pinned:SetText("")
		for _, row in ipairs(card.Lines) do row:Hide() end
		card.StartButton:SetEnabled(false)
		card.ClearButton:Hide()
		card.Backend:SetText("")
		card.StepsTitle:Hide()
		card.StepsEmpty:Hide()
		for _, row in ipairs(card.Steps) do row:Hide() end
		-- Deux causes possibles, deux messages : la cartographie n'a pas encore
		-- tourné, ou elle a tourné et rien n'est routable.
		local meta = ns.db and ns.db.global.scanMeta
		local hasScanned = type(meta) == "table" and meta.at ~= nil
		card.Empty:SetText(hasScanned and L.ROUTE_NONE or L.ROUTE_NEEDS_SCAN)
		card.Empty:Show()
		page.MapCard.Preview:Clear()
		return
	end

	card.Empty:Hide()
	card.StepsTitle:Show()
	card.Icon:SetTexture(mission.icon)
	card.Icon:Show()
	card.MountName:SetText(mission.name)
	card.Pinned:SetText(mission.pinned and L.ROUTE_PINNED or "")
	card.ClearButton:SetShown(mission.pinned == true)

	-- Type d'endroit. « Raid » et « Donjon » viennent de la cartographie ; on
	-- n'écrit PAS la difficulté sauf si un verrou nous l'a apprise, parce que la
	-- difficulté à laquelle une monture tombe n'est exposée par aucune API.
	local where = L.TYPE_OUTDOOR_LABEL
	if mission.isRaid == true then
		where = L.TYPE_RAID
	elseif mission.isRaid == false then
		where = L.TYPE_DUNGEON
	end
	if mission.instanceName then
		where = where .. " · " .. mission.instanceName
	end
	if mission.difficultyName and mission.difficultyName ~= "" then
		where = where .. " (" .. mission.difficultyName .. ")"
	end

	local status = mission.status or {}
	local statusText = ns.Eligibility:FormatStatus(status)

	local lines = card.Lines
	local used = 0
	local function Next() used = used + 1 return lines[used] end

	SetLine(Next(), L.ROUTE_TARGET, where, Theme.colors.text)
	if mission.encounterName then
		SetLine(Next(), L.TOOLTIP_BOSS, mission.encounterName, Theme.colors.gold)
	end
	SetLine(Next(), L.ROUTE_ZONE, mission.zoneName or mission.node.name, Theme.colors.text)
	-- Des coordonnées au dixième pour une cible qui est une zone entière
	-- feraient croire à une précision qu'on n'a pas : on écrit ce qu'on sait.
	SetLine(Next(), L.ROUTE_COORDS,
		mission.zoneWide and L.ROUTE_ZONE_WIDE
			or string.format("%.1f, %.1f", mission.node.x * 100, mission.node.y * 100),
		Theme.colors.muted)
	SetLine(Next(), L.COL_STATUS_SHORT, statusText, Theme.colors.text)
	for index = used + 1, #lines do lines[index]:Hide() end

	-- `plan` doit être lu AVANT de s'en servir : déclaré plus bas, il valait le
	-- global nil, et le bouton affichait « Start » même trajet en cours.
	local plan = ns.Route:GetPlan()

	card.StartButton:SetEnabled(true)
	local running = plan ~= nil and not plan.arrived
	card.StartButton.Text:SetText(running and L.ROUTE_STOP or L.ROUTE_START)
	card.Backend:SetText(ns.Route:HasTomTom() and L.ROUTE_VIA_TOMTOM or L.ROUTE_VIA_CLIENT)

	self:RefreshSteps(card, mission)

	-- La carte montre l'étape courante quand un trajet tourne, la destination
	-- sinon : pendant le trajet, ce qu'on veut voir c'est où on va MAINTENANT.
	local step = ns.Route:GetCurrentStep()
	local shown = (plan and step and step.node) and step.node or mission.node
	local label = (plan and step) and step.name or (mission.zoneName or mission.node.name)
	page.MapCard.Preview:SetTarget(shown.uiMapID, shown.x, shown.y, label)
end

--- Liste des étapes. Sans trajet lancé, on affiche déjà le chemin prévu : le
--  joueur doit pouvoir juger de la route AVANT de cliquer.
function RoutePage:RefreshSteps(card, mission)
	local L = ns.L
	local Theme = ns.Theme

	local plan = ns.Route:GetPlan()
	local steps = plan and plan.steps or ns.Route:BuildSteps(mission)
	local current = plan and plan.current or 0

	if not steps or #steps == 0 then
		for _, row in ipairs(card.Steps) do row:Hide() end
		self:SetStepsNote(card, card.StepsTitle, L.ROUTE_UNREACHABLE)
		return
	end

	local lastShown = card.StepsTitle
	for index, row in ipairs(card.Steps) do
		local step = steps[index]
		if step then
			local done = current > index
			local active = current == index

			row.Index:SetText(done and "•" or tostring(index))
			row.Text:SetText(self:StepText(step))
			row.Cost:SetText(step.cost and ns.Util.FormatDuration(step.cost) or "")

			-- Trois états, trois couleurs : franchie, en cours, à venir.
			local color = Theme.colors.muted
			if done then
				color = Theme.colors.faint
			elseif active then
				color = Theme.colors.accent
			end
			row.Index:SetTextColor(color[1], color[2], color[3])
			row.Text:SetTextColor(color[1], color[2], color[3])
			row:Show()
			lastShown = row
		else
			row:Hide()
		end
	end

	-- Une étape « lointaine » n'est pas un itinéraire, c'est une désignation :
	-- on garde la ligne ET l'explication, au lieu de choisir entre les deux.
	-- La note se pose sous la dernière ligne visible, jamais par-dessus.
	self:SetStepsNote(card, lastShown, steps[1].far and L.ROUTE_UNREACHABLE or nil)
end

--- Note sous la liste des étapes, ancrée sous `anchor`, masquée si vide.
function RoutePage:SetStepsNote(card, anchor, text)
	if not text then
		card.StepsEmpty:Hide()
		return
	end
	card.StepsEmpty:ClearAllPoints()
	card.StepsEmpty:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)
	card.StepsEmpty:SetPoint("RIGHT", card, "RIGHT", -10, 0)
	card.StepsEmpty:SetText(text)
	card.StepsEmpty:Show()
end

--- Consigne d'une étape, en clair.
function RoutePage:StepText(step)
	local L = ns.L
	local kinds = ns.Data.EDGE_KINDS
	if step.far then
		local text = L.ROUTE_STEP_FAR:format(step.name or "?")
		-- Le continent est ce qui manque le plus quand la cible est loin : il
		-- dit quel portail prendre, ce qu'aucun nom de zone ne dit tout seul.
		if step.continentName then text = text .. " (" .. step.continentName .. ")" end
		return text
	end
	if step.kind == kinds.TELEPORT and step.spellName then
		return L.ROUTE_STEP_TELEPORT:format(step.spellName)
	end
	if step.kind == kinds.PORTAL then
		return L.ROUTE_STEP_PORTAL:format(step.name or "?")
	end
	if step.kind == kinds.WALK then
		return L.ROUTE_STEP_WALK:format(step.name or "?")
	end
	return L.ROUTE_STEP_FLY:format(step.name or "?")
end
