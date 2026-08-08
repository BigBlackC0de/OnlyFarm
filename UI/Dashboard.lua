--[[---------------------------------------------------------------------------
	OnlyFarm — UI/Dashboard.lua

	Le tableau de bord : ce qu'on voit en ouvrant l'addon.

	Il répond à quatre questions, dans cet ordre, parce que c'est l'ordre dans
	lequel elles se posent :

	  1. où j'en suis  — tuiles de compteurs et barre de progression globale ;
	  2. qu'est-ce qui est ouvert maintenant — barre empilée par statut ;
	  3. où il me reste du travail — progression par extension, les moins
	     avancées en haut ;
	  4. par quoi je commence — les cibles disponibles, les plus attendues
	     d'abord.

	Aucun chiffre n'est calculé ici : tout vient de Modules/Stats.lua, qui se
	teste hors du jeu. Ce fichier ne fait que poser des frames.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Dashboard = ns:NewModule("Dashboard", 82)

local TILE_HEIGHT = 62
local TILE_GAP = 8
local BAR_ROW_HEIGHT = 18
local TARGET_ROW_HEIGHT = 22

function Dashboard:OnEnable()
	-- Le rafraîchissement est piloté par UI:Refresh : un seul chef d'orchestre,
	-- sinon deux abonnements recalculent la même chose sur le même événement.
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

function Dashboard:Create(parent)
	if self.page then return self.page end

	local page = CreateFrame("Frame", nil, parent)
	page:SetAllPoints()
	page:Hide()
	self.page = page

	self:CreateTiles(page)
	self:CreateAvailability(page)
	self:CreateExpansions(page)
	self:CreateTargets(page)

	return page
end

--- Rangée de tuiles de compteurs, réparties à parts égales sur la largeur.
function Dashboard:CreateTiles(page)
	local Theme = ns.Theme
	local L = ns.L

	local definitions = {
		{ key = "owned", label = L.KPI_OWNED, color = Theme.colors.accent },
		{ key = "missing", label = L.KPI_MISSING, color = Theme.colors.text },
		{ key = "available", label = L.KPI_AVAILABLE, color = Theme.colors.green },
		{ key = "attempts", label = L.KPI_ATTEMPTS, color = Theme.colors.purple },
		{ key = "locks", label = L.KPI_LOCKS, color = Theme.colors.red },
	}

	local row = CreateFrame("Frame", nil, page)
	row:SetPoint("TOPLEFT")
	row:SetPoint("TOPRIGHT")
	row:SetHeight(TILE_HEIGHT)
	page.TileRow = row

	-- Les tuiles ne sont pas ancrées ici : leur largeur dépend de celle de la
	-- fenêtre, qui vaut encore zéro à la construction. Tout le placement se
	-- fait dans LayoutTiles, rappelé dès que la largeur change.
	self.tiles = {}
	self.tileCount = #definitions
	for index, definition in ipairs(definitions) do
		local tile = Theme.StatTile(row, definition.label, definition.color)
		self.tiles[definition.key] = tile
		self.tiles[index] = tile
	end

	row:SetScript("OnSizeChanged", function() self:LayoutTiles() end)
end

function Dashboard:LayoutTiles()
	local row = self.page and self.page.TileRow
	if not row then return end
	local width = row:GetWidth()
	if not width or width <= 0 then return end

	local count = self.tileCount or 0
	if count == 0 then return end
	local tileWidth = (width - TILE_GAP * (count - 1)) / count
	for index = 1, count do
		local tile = self.tiles[index]
		if tile then
			tile:ClearAllPoints()
			tile:SetPoint("TOPLEFT", row, "TOPLEFT", (index - 1) * (tileWidth + TILE_GAP), 0)
			tile:SetSize(tileWidth, TILE_HEIGHT)
		end
	end
end

--- Barre empilée « disponible / verrouillé / incertain / non cartographié »,
--  avec sa légende. Une barre empilée plutôt qu'un camembert : le client n'a
--  pas de primitive circulaire, et une barre se lit mieux de toute façon.
function Dashboard:CreateAvailability(page)
	local Theme = ns.Theme
	local L = ns.L

	local card = Theme.Card(page)
	card:SetPoint("TOPLEFT", page.TileRow, "BOTTOMLEFT", 0, -TILE_GAP)
	card:SetPoint("TOPRIGHT", page.TileRow, "BOTTOMRIGHT", 0, -TILE_GAP)
	card:SetHeight(78)
	page.AvailabilityCard = card

	local title = Theme.Text(card, "GameFontNormal", Theme.colors.text)
	title:SetPoint("TOPLEFT", 10, -8)
	title:SetText(L.DASH_AVAILABILITY)

	local progress = Theme.Text(card, "GameFontHighlightSmall", Theme.colors.muted, "RIGHT")
	progress:SetPoint("TOPRIGHT", -10, -9)
	card.Progress = progress

	local bar = Theme.StackedBar(card)
	bar:SetPoint("TOPLEFT", 10, -30)
	bar:SetPoint("TOPRIGHT", -10, -30)
	bar:SetHeight(14)
	card.Bar = bar

	local legend = Theme.Text(card, "GameFontHighlightSmall", Theme.colors.muted)
	legend:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -8)
	legend:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, -8)
	card.Legend = legend
end

--- Graphe en barres horizontales : progression par extension.
function Dashboard:CreateExpansions(page)
	local Theme = ns.Theme
	local L = ns.L

	local card = Theme.Card(page)
	card:SetPoint("TOPLEFT", page.AvailabilityCard, "BOTTOMLEFT", 0, -TILE_GAP)
	card:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -260, 0)
	page.ExpansionCard = card

	local title = Theme.Text(card, "GameFontNormal", Theme.colors.text)
	title:SetPoint("TOPLEFT", 10, -8)
	title:SetText(L.DASH_EXPANSIONS)

	local hint = Theme.Text(card, "GameFontHighlightSmall", Theme.colors.faint, "RIGHT")
	hint:SetPoint("TOPRIGHT", -10, -9)
	hint:SetText(L.DASH_EXPANSIONS_HINT)
	card.Hint = hint

	card.Rows = {}
	for index = 1, 12 do
		local row = Theme.BarRow(card, 150, 56)
		row:SetHeight(BAR_ROW_HEIGHT)
		row:SetPoint("LEFT", 10, 0)
		row:SetPoint("RIGHT", -10, 0)
		row:SetPoint("TOP", card, "TOP", 0, -28 - (index - 1) * BAR_ROW_HEIGHT)
		row:Hide()
		card.Rows[index] = row
	end

	card.Empty = Theme.Text(card, "GameFontHighlightSmall", Theme.colors.faint, "CENTER")
	card.Empty:SetPoint("CENTER", 0, -10)
	card.Empty:SetText(L.DASH_NEEDS_SCAN)
	card.Empty:Hide()

	-- Pied de carte : état de la cartographie et relance manuelle. C'est ici
	-- que le manque se voit, donc c'est ici que doit se trouver le remède.
	local rule = Theme.Separator(card)
	rule:SetPoint("BOTTOMLEFT", 1, 30)
	rule:SetPoint("BOTTOMRIGHT", -1, 30)

	local deep = Theme.Button(card, L.SCAN_BUTTON_DEEP, 120, 20)
	deep:SetPoint("BOTTOMRIGHT", -10, 6)
	deep:SetScript("OnClick", function() ns.Mapping:Run(true) end)
	card.DeepButton = deep

	local rescan = Theme.Button(card, L.SCAN_BUTTON, 96, 20)
	rescan:SetPoint("BOTTOMRIGHT", deep, "BOTTOMLEFT", -6, 0)
	rescan:SetScript("OnClick", function() ns.Mapping:Run(false) end)
	card.RescanButton = rescan

	card.ScanInfo = Theme.Text(card, "GameFontHighlightSmall", Theme.colors.faint)
	card.ScanInfo:SetPoint("BOTTOMLEFT", 10, 10)
	card.ScanInfo:SetPoint("BOTTOMRIGHT", rescan, "BOTTOMLEFT", -10, 10)
	card.ScanInfo:SetWordWrap(false)
end

--- Colonne de droite, en deux cartes : ce qui est ouvert, puis ce qui est déjà
--  consommé cette semaine.
function Dashboard:CreateTargets(page)
	local Theme = ns.Theme
	local L = ns.L

	local card = Theme.Card(page)
	card:SetPoint("TOPLEFT", page.ExpansionCard, "TOPRIGHT", TILE_GAP, 0)
	card:SetPoint("RIGHT", page, "RIGHT", 0, 0)
	card:SetHeight(28 + 6 * TARGET_ROW_HEIGHT + 8)
	page.TargetCard = card

	local title = Theme.Text(card, "GameFontNormal", Theme.colors.text)
	title:SetPoint("TOPLEFT", 10, -8)
	title:SetText(L.DASH_TARGETS)

	card.Rows = {}
	for index = 1, 6 do
		local row = CreateFrame("Button", nil, card)
		row:SetHeight(TARGET_ROW_HEIGHT)
		row:SetPoint("LEFT", 8, 0)
		row:SetPoint("RIGHT", -8, 0)
		row:SetPoint("TOP", card, "TOP", 0, -28 - (index - 1) * TARGET_ROW_HEIGHT)

		row.Icon = row:CreateTexture(nil, "ARTWORK")
		row.Icon:SetSize(16, 16)
		row.Icon:SetPoint("LEFT")

		row.Name = Theme.Text(row, "GameFontHighlightSmall", Theme.colors.text)
		row.Name:SetPoint("LEFT", row.Icon, "RIGHT", 6, 0)
		row.Name:SetPoint("RIGHT", -44, 0)
		row.Name:SetWordWrap(false)

		row.Tries = Theme.Text(row, "GameFontHighlightSmall", Theme.colors.faint, "RIGHT")
		row.Tries:SetPoint("RIGHT")

		row.Highlight = row:CreateTexture(nil, "HIGHLIGHT")
		row.Highlight:SetAllPoints()
		row.Highlight:SetColorTexture(1, 1, 1, 0.06)

		row:SetScript("OnClick", function(button)
			if button.mountID then ns.Preview:Toggle(button.mountID) end
		end)

		row:Hide()
		card.Rows[index] = row
	end

	card.Empty = Theme.Text(card, "GameFontHighlightSmall", Theme.colors.faint, "CENTER")
	card.Empty:SetPoint("CENTER", 0, 0)
	card.Empty:SetWidth(200)
	card.Empty:SetText(L.DASH_NO_TARGET)
	card.Empty:Hide()

	self:CreateLockouts(page)
end

--- « Ce que tu as déjà fait cette semaine ».
--
--  Cette carte ne dépend d'AUCUNE cartographie de monture : elle lit
--  directement les verrous du client. Elle répond donc toujours, même quand
--  l'addon ne sait pas encore quel boss lâche quoi — et c'est exactement le
--  reproche qui lui était fait : avoir terminé un raid sans que rien ne le
--  montre à l'écran.
function Dashboard:CreateLockouts(page)
	local Theme = ns.Theme
	local L = ns.L

	local card = Theme.Card(page)
	card:SetPoint("TOPLEFT", page.TargetCard, "BOTTOMLEFT", 0, -TILE_GAP)
	card:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	page.LockoutCard = card

	local title = Theme.Text(card, "GameFontNormal", Theme.colors.text)
	title:SetPoint("TOPLEFT", 10, -8)
	title:SetText(L.DASH_LOCKOUTS)

	card.Rows = {}
	for index = 1, 6 do
		local row = CreateFrame("Frame", nil, card)
		row:SetHeight(TARGET_ROW_HEIGHT)
		row:SetPoint("LEFT", 8, 0)
		row:SetPoint("RIGHT", -8, 0)
		row:SetPoint("TOP", card, "TOP", 0, -28 - (index - 1) * TARGET_ROW_HEIGHT)

		row.Name = Theme.Text(row, "GameFontHighlightSmall", Theme.colors.text)
		row.Name:SetPoint("LEFT")
		row.Name:SetPoint("RIGHT", -96, 0)
		row.Name:SetWordWrap(false)

		row.Progress = Theme.Text(row, "GameFontHighlightSmall", Theme.colors.muted, "RIGHT")
		row.Progress:SetPoint("RIGHT", -52, 0)
		row.Progress:SetWidth(40)

		row.Reset = Theme.Text(row, "GameFontHighlightSmall", Theme.colors.red, "RIGHT")
		row.Reset:SetPoint("RIGHT")
		row.Reset:SetWidth(48)

		row:Hide()
		card.Rows[index] = row
	end

	card.Empty = Theme.Text(card, "GameFontHighlightSmall", Theme.colors.faint, "CENTER")
	card.Empty:SetPoint("CENTER", 0, 0)
	card.Empty:SetWidth(200)
	card.Empty:SetText(L.DASH_NO_LOCKOUT)
	card.Empty:Hide()
end

--------------------------------------------------------------------------------
-- Rafraîchissement
--------------------------------------------------------------------------------

--- Affiche ou masque la page. Le rafraîchissement n'est PAS déclenché ici :
--  c'est UI:SelectTab qui l'appelle juste après, et deux recalculs pour un
--  seul clic ne servent à rien.
function Dashboard:SetShown(shown)
	if not self.page then return end
	self.page:SetShown(shown)
	if shown then self:LayoutTiles() end
end

function Dashboard:Refresh()
	local page = self.page
	if not page or not page:IsShown() then return end

	local L = ns.L
	local Theme = ns.Theme

	if not ns.Collection.ready then
		self.tiles.owned:Set("—", L.JOURNAL_NOT_READY)
		return
	end

	self:LayoutTiles()
	local stats = ns.Stats:Get()

	-- 1. Tuiles.
	self.tiles.owned:Set(string.format("%d", stats.owned),
		string.format("%d %%", math.floor(stats.ratio * 100 + 0.5)))
	self.tiles.missing:Set(string.format("%d", stats.missing),
		stats.hidden > 0 and L.SUMMARY_HIDDEN:format(stats.hidden) or "")
	self.tiles.available:Set(string.format("%d", stats.availableCount or 0), "")
	self.tiles.attempts:Set(string.format("%d", stats.attempts.total),
		stats.attempts.mounts > 0 and L.KPI_ATTEMPTS_DETAIL:format(stats.attempts.mounts) or "")
	self.tiles.locks:Set(string.format("%d", stats.lockCount),
		L.KPI_INSTANCES:format(stats.instances.hour, stats.instances.day))

	-- 2. Barre empilée de disponibilité.
	local card = page.AvailabilityCard
	local parts = ns.Stats:GetAvailabilityParts()
	card.Bar:SetParts(parts)
	card.Progress:SetText(L.DASH_PROGRESS:format(stats.owned, stats.total))

	local STATE = ns.Eligibility.STATE
	local labels = {
		[STATE.AVAILABLE] = L.STATUS_AVAILABLE,
		[STATE.LOCKED] = L.STATUS_LOCKED,
		[STATE.UNKNOWN] = L.STATUS_UNKNOWN,
		[STATE.UNMAPPED] = L.STATUS_NO_SOURCE,
	}
	local legend = {}
	for _, part in ipairs(parts) do
		if part.value > 0 then
			legend[#legend + 1] = Theme.Colorize(part.color,
				string.format("■ %d %s", part.value, labels[part.state] or ""))
		end
	end
	card.Legend:SetText(table.concat(legend, "   "))

	-- 3. Progression par extension.
	local expansionCard = page.ExpansionCard
	local hasExpansions = #stats.expansions > 0
		and not (#stats.expansions == 1
			and stats.expansions[1].name == ns.Eligibility.UNKNOWN_EXPANSION)

	for index, row in ipairs(expansionCard.Rows) do
		local bucket = stats.expansions[index]
		if bucket and hasExpansions then
			local name = bucket.name
			if name == ns.Eligibility.UNKNOWN_EXPANSION then name = L.EXPANSION_UNKNOWN end
			row:Set(name, bucket.owned, bucket.total)
			row:Show()
		else
			row:Hide()
		end
	end
	expansionCard.Empty:SetShown(not hasExpansions)
	expansionCard.Hint:SetShown(hasExpansions)

	-- État de la cartographie, et boutons coupés pendant qu'elle tourne.
	if ns.Mapping.running then
		expansionCard.ScanInfo:SetText(L.SCAN_RUNNING)
	else
		expansionCard.ScanInfo:SetText(ns.Mapping:GetSummary() or L.SCAN_NEVER)
	end
	expansionCard.RescanButton:SetEnabled(not ns.Mapping.running)
	expansionCard.DeepButton:SetEnabled(not ns.Mapping.running)

	-- 4. Cibles du moment.
	local targetCard = page.TargetCard
	for index, row in ipairs(targetCard.Rows) do
		local target = stats.topTargets[index]
		if target then
			row.mountID = target.mountID
			row.Icon:SetTexture(target.icon)
			row.Name:SetText(target.name)
			row.Tries:SetText(target.attempts > 0 and tostring(target.attempts) or "—")
			row:Show()
		else
			row.mountID = nil
			row:Hide()
		end
	end
	targetCard.Empty:SetShown(#stats.topTargets == 0)

	-- 5. Verrous de la semaine.
	local lockCard = page.LockoutCard
	local locks = ns.Lockouts:GetActiveLocks()
	for index, row in ipairs(lockCard.Rows) do
		local lock = locks[index]
		if lock then
			local name = lock.name or "?"
			if lock.difficultyName and lock.difficultyName ~= "" then
				name = name .. " " .. Theme.Colorize(Theme.colors.faint, lock.difficultyName)
			end
			row.Name:SetText(name)

			if (lock.numEncounters or 0) > 0 then
				row.Progress:SetText(string.format("%d/%d",
					lock.encounterProgress or 0, lock.numEncounters))
			else
				row.Progress:SetText("")
			end

			row.Reset:SetText(ns.Util.FormatDuration((lock.expires or 0) - time()))
			row:Show()
		else
			row:Hide()
		end
	end
	lockCard.Empty:SetShown(#locks == 0)
end
