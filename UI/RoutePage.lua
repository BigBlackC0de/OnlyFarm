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

	Ce qu'elle ne fait PAS encore : enchaîner plusieurs étapes (téléport, vol,
	entrée). TravelGraph sait calculer ce chemin, mais un itinéraire à sauts
	multiples qu'on n'a pas vérifié en jeu ne vaut pas mieux qu'une flèche qui
	pointe juste — et la flèche, elle, marche partout.
-----------------------------------------------------------------------------]]

local _, ns = ...

local RoutePage = ns:NewModule("RoutePage", 83)

local GAP = 8
local LINE_HEIGHT = 20

function RoutePage:OnEnable()
	self:RegisterMessage("OF_ROUTE_UPDATED", "Refresh")
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
	local mission = ns.Route:GetMission()
	if not mission then return end

	local backend, reason = ns.Route:Start(mission)
	local L = ns.L

	if backend then
		ns:Print(L.ROUTE_STARTED:format(mission.instanceName or mission.name))
		-- Épingler la cible au démarrage : le joueur vient de dire qu'il y va,
		-- l'addon n'a plus à en proposer une autre au prochain rafraîchissement.
		ns.Route:SetTarget(mission.mountID)
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
	SetLine(Next(), L.ROUTE_COORDS,
		string.format("%.1f, %.1f", mission.node.x * 100, mission.node.y * 100),
		Theme.colors.muted)
	SetLine(Next(), L.COL_STATUS_SHORT, statusText, Theme.colors.text)
	for index = used + 1, #lines do lines[index]:Hide() end

	card.StartButton:SetEnabled(true)
	card.Backend:SetText(ns.Route:HasTomTom() and L.ROUTE_VIA_TOMTOM or L.ROUTE_VIA_CLIENT)

	page.MapCard.Preview:SetTarget(mission.node.uiMapID, mission.node.x, mission.node.y,
		mission.zoneName or mission.node.name)
end
