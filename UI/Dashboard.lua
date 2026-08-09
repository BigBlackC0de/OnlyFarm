--[[---------------------------------------------------------------------------
	OnlyFarm — UI/Dashboard.lua

	Le tableau de bord : ce qu'on voit en ouvrant l'addon.

	Il répond à trois questions, dans cet ordre, parce que c'est l'ordre dans
	lequel elles se posent :

	  1. où j'en suis — quatre compteurs : possédées, manquantes, obtenues
	     depuis l'installation, verrous actifs ;
	  2. comment se répartit ma collection — graphe de répartition, par nature
	     de source ou par type de monture ;
	  3. par quoi je commence — les cibles disponibles, les plus attendues
	     d'abord, et ce que la semaine a déjà consommé.

	CE QUI A ÉTÉ RETIRÉ, ET POURQUOI

	Une frise des extensions occupait la question 2. Le client n'expose pas
	l'extension d'une monture : elle dépendait d'un scan qui n'en rattachait
	qu'une fraction, et l'essentiel de la collection s'entassait dans une barre
	« inconnue ».

	Une barre empilée « disponible / verrouillé / incertain » occupait le haut.
	Sur une collection réelle elle affichait « 65 disponible, 679 incertain » :
	elle décrivait l'état du scan, pas celui de la collection.

	Deux tuiles enfin — « dispo maintenant », qui comptait la même chose que
	cette barre, et « essais comptés », un total d'essais toutes montures
	confondues, qui additionne ce qui n'est pas additionnable.

	Le fil commun : ces quatre éléments répondaient à des questions que l'addon
	se pose, pas à des questions qu'un joueur se pose. Ce qu'il reste vient du
	client pour toutes les montures, sans scan.

	Aucun chiffre n'est calculé ici : tout vient de Modules/Stats.lua, qui se
	teste hors du jeu. Ce fichier ne fait que poser des frames.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Dashboard = ns:NewModule("Dashboard", 82)

local TILE_HEIGHT = 62
local TILE_GAP = 8
local BAR_ROW_HEIGHT = 19
local TARGET_ROW_HEIGHT = 22

-- Onze natures de source côté client, plus de la marge pour celles qu'un patch
-- ajoutera. L'axe du déplacement n'en demande que cinq : la même carte sert aux
-- deux, et les lignes en trop restent masquées. Le nombre réellement affiché
-- dépend en plus de la hauteur de la fenêtre, cf. BreakdownRowBudget.
local MAX_BREAKDOWN_ROWS = 14

-- Verrous de la semaine : autant que la carte peut en montrer.
local MAX_LOCKOUT_ROWS = 12

function Dashboard:OnEnable()
	-- Le rafraîchissement général est piloté par UI:Refresh : un seul chef
	-- d'orchestre, sinon deux abonnements recalculent la même chose sur le
	-- même événement.
	--
	-- L'avancement du scan fait exception : il change des dizaines de fois par
	-- seconde, et déclencher un recalcul complet à chaque fois coûterait plus
	-- cher que le scan lui-même. On ne touche donc QUE le libellé.
	self:RegisterMessage("OF_SCAN_PROGRESS", "OnScanProgress")
end

function Dashboard:OnScanProgress()
	local page = self.page
	if not page or not page:IsShown() then return end
	page.BreakdownCard.ScanInfo:SetText(self:ScanProgressText())
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
	self:CreateBreakdown(page)
	self:CreateTargets(page)

	return page
end

--- Rangée de tuiles de compteurs, réparties à parts égales sur la largeur.
function Dashboard:CreateTiles(page)
	local Theme = ns.Theme
	local L = ns.L

	-- Quatre chiffres, et chacun répond à une question qu'un joueur se pose
	-- vraiment : ce que j'ai, ce qu'il me reste, ce que j'ai décroché depuis que
	-- l'addon tourne, et ce que cette semaine a déjà consommé.
	--
	-- Deux tuiles ont été retirées. « Dispo maintenant » comptait ce que la
	-- cartographie savait ouvrir, soit un chiffre qui dit surtout où en est le
	-- scan. « Essais comptés » additionnait des tentatives sur des montures sans
	-- rapport entre elles : cinquante essais répartis sur trente montures et
	-- cinquante sur une seule donnaient le même nombre, alors que ce ne sont pas
	-- les mêmes situations. Le compte par monture, lui, reste dans l'infobulle,
	-- où il porte du sens parce qu'il porte sur UNE monture.
	local definitions = {
		{ key = "owned", label = L.KPI_OWNED, color = Theme.colors.accent },
		{ key = "missing", label = L.KPI_MISSING, color = Theme.colors.text },
		{ key = "obtained", label = L.KPI_OBTAINED, color = Theme.colors.gold },
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

--- Graphe de répartition de la collection, avec son sélecteur d'axe.
--
--  Les barres sont à l'échelle des effectifs (cf. Theme.ShareRow) : la plus
--  longue est la catégorie la plus fournie, et la part pleine dit où on en est
--  dedans. Le classement se lit donc d'un coup d'œil, sans légende à décoder.
function Dashboard:CreateBreakdown(page)
	local Theme = ns.Theme
	local L = ns.L

	local card = Theme.Card(page)
	card:SetPoint("TOPLEFT", page.TileRow, "BOTTOMLEFT", 0, -TILE_GAP)
	card:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -260, 0)
	page.BreakdownCard = card

	local title = Theme.Text(card, "GameFontNormal", Theme.colors.text)
	title:SetPoint("TOPLEFT", 10, -8)
	title:SetText(L.DASH_BREAKDOWN)

	-- Sélecteur d'axe. Deux axes, donc deux boutons collés : le choix se voit
	-- et se change d'un clic, sans ouvrir de menu.
	local choices = {}
	for index, axis in ipairs(ns.Stats.AXES) do
		choices[index] = { key = axis.key, label = L[axis.label] or axis.key }
	end
	local selector = Theme.Segmented(card, choices, function(key)
		self:SetAxis(key)
	end)
	selector:SetPoint("TOPRIGHT", -10, -8)
	-- Peint dès la construction : sans ça, le sélecteur reste transparent tant
	-- que le premier rafraîchissement n'a pas eu lieu — et il n'a pas lieu si le
	-- Journal des montures se peuple lentement.
	selector:SetValue(self:GetAxis())
	card.Selector = selector

	-- La légende partage la ligne du titre, bornée entre lui et le sélecteur :
	-- sous le sélecteur elle recouvrait la première barre, et en pied elle est
	-- désormais à la place de l'état de la cartographie.
	local hint = Theme.Text(card, "GameFontHighlightSmall", Theme.colors.faint, "RIGHT")
	hint:SetPoint("LEFT", title, "RIGHT", 12, 0)
	hint:SetPoint("RIGHT", selector, "LEFT", -12, 0)
	hint:SetText(L.DASH_BREAKDOWN_HINT)
	hint:SetWordWrap(false)
	card.Hint = hint

	-- Pied de carte : état de la cartographie et relance manuelle. Elle a perdu
	-- son ancien logement avec la barre de disponibilité, mais elle a toujours
	-- sa raison d'être — c'est elle qui rattache une monture à une instance,
	-- donc qui alimente les cibles du moment et les verrous.
	local rule = Theme.Separator(card)
	rule:SetPoint("BOTTOMLEFT", 1, 30)
	rule:SetPoint("BOTTOMRIGHT", -1, 30)

	-- UN seul bouton. « Scan » et « Scan approfondi » demandaient au joueur de
	-- trancher une question technique — faut-il parcourir le butin ? — dont il
	-- n'a pas les éléments. L'addon sait y répondre : il le fait.
	local rescan = Theme.Button(card, L.SCAN_BUTTON, 130, 20)
	rescan:SetPoint("BOTTOMRIGHT", -10, 6)
	rescan:SetScript("OnClick", function() ns.Mapping:Run() end)
	card.RescanButton = rescan

	card.ScanInfo = Theme.Text(card, "GameFontHighlightSmall", Theme.colors.faint)
	card.ScanInfo:SetPoint("BOTTOMLEFT", 10, 10)
	card.ScanInfo:SetPoint("BOTTOMRIGHT", rescan, "BOTTOMLEFT", -10, 10)
	card.ScanInfo:SetWordWrap(false)

	card.Rows = {}
	for index = 1, MAX_BREAKDOWN_ROWS do
		local row = Theme.ShareRow(card, 185, 62)
		row:SetHeight(BAR_ROW_HEIGHT)
		row:SetPoint("LEFT", 10, 0)
		row:SetPoint("RIGHT", -10, 0)
		row:SetPoint("TOP", card, "TOP", 0, -32 - (index - 1) * BAR_ROW_HEIGHT)
		row:Hide()
		card.Rows[index] = row
	end

	card.Empty = Theme.Text(card, "GameFontHighlightSmall", Theme.colors.faint, "CENTER")
	card.Empty:SetPoint("CENTER", 0, 0)
	card.Empty:SetPoint("LEFT", 24, 0)
	card.Empty:SetPoint("RIGHT", -24, 0)
	card.Empty:SetText(L.JOURNAL_NOT_READY)
	card.Empty:Hide()
end

--- Nombre de lignes qu'une carte peut afficher sans déborder de sa bordure.
--
--  La fenêtre est redimensionnable : à la hauteur minimale, une carte de 140
--  pixels ne peut pas montrer douze barres de dix-neuf. Les dessiner quand même
--  les faisait sortir de la carte et de la fenêtre.
--
--  @param header  hauteur du titre et de ce qui l'accompagne
--  @param footer  hauteur du pied, zéro s'il n'y en a pas
function Dashboard:RowBudget(card, header, footer, rowHeight, maximum)
	if not card then return maximum end
	local height = card:GetHeight() or 0
	local budget = math.floor((height - header - footer) / rowHeight)
	if budget < 1 then return 1 end
	return math.min(budget, maximum)
end

function Dashboard:BreakdownRowBudget()
	-- 32 pixels d'en-tête (titre et sélecteur), 34 de pied (le trait, l'état de
	-- la cartographie et son bouton).
	return self:RowBudget(self.page and self.page.BreakdownCard, 32, 34,
		BAR_ROW_HEIGHT, MAX_BREAKDOWN_ROWS)
end

--- Axe de répartition retenu, ramené à un axe valide.
function Dashboard:GetAxis()
	local saved = ns.db and ns.db.profile.dashboard and ns.db.profile.dashboard.axis
	return ns.Stats:ResolveAxis(saved)
end

function Dashboard:SetAxis(axis)
	axis = ns.Stats:ResolveAxis(axis)
	if ns.db and ns.db.profile.dashboard then
		ns.db.profile.dashboard.axis = axis
	end
	self:Refresh()
end

--- Colonne de droite, en deux cartes : ce qui est ouvert, puis ce qui est déjà
--  consommé cette semaine.
function Dashboard:CreateTargets(page)
	local Theme = ns.Theme
	local L = ns.L

	local card = Theme.Card(page)
	card:SetPoint("TOPLEFT", page.BreakdownCard, "TOPRIGHT", TILE_GAP, 0)
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

	-- Douze lignes, contre six auparavant : cette carte a hérité de la place
	-- libérée par la barre de disponibilité, et un raideur qui enchaîne les
	-- verrous legacy en a facilement plus de six sur la semaine. Le nombre
	-- réellement affiché suit la hauteur de la carte.
	card.Rows = {}
	for index = 1, MAX_LOCKOUT_ROWS do
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

--- Avancement de la cartographie en cours, en pourcentage quand il est connu.
function Dashboard:ScanProgressText()
	local progress = ns.Mapping.progress
	if type(progress) == "table" and (progress.total or 0) > 0 then
		return string.format("%s %d %%", ns.L.SCAN_RUNNING,
			math.floor(progress.done / progress.total * 100))
	end
	return ns.L.SCAN_RUNNING
end

function Dashboard:Refresh()
	local page = self.page
	if not page or not page:IsShown() then return end

	local L = ns.L
	local Theme = ns.Theme

	if not ns.Collection.ready then
		self.tiles.owned:Set("—", L.JOURNAL_NOT_READY)
		-- Le graphe le dit aussi : une carte vide sans un mot se lit comme une
		-- panne, alors que le Journal est simplement encore en train de se
		-- peupler.
		page.BreakdownCard.Empty:Show()
		page.BreakdownCard.Hint:Hide()
		return
	end

	self:LayoutTiles()
	local stats = ns.Stats:Get()

	-- 1. Tuiles.
	self.tiles.owned:Set(string.format("%d", stats.owned),
		string.format("%d %%", math.floor(stats.ratio * 100 + 0.5)))
	-- Pas de « N hors de portée sur ce perso » ici. Les montures de la faction
	-- ou de la classe adverse ne tomberont jamais sur ce personnage : ce n'est
	-- pas du travail restant, c'est du bruit. Elles sont déjà absentes de la
	-- liste et du total ; ne pas les compter non plus en marge.
	self.tiles.missing:Set(string.format("%d", stats.missing), "")

	-- Obtenues depuis l'installation. Le détail dit DEPUIS QUAND, sinon « 3 »
	-- ne veut rien dire — trois en une semaine et trois en deux ans ne racontent
	-- pas la même histoire.
	local obtained = stats.obtained or { count = 0 }
	self.tiles.obtained:Set(string.format("%d", obtained.count),
		obtained.since and L.KPI_OBTAINED_DETAIL:format(ns.Util.FormatAge(obtained.since)) or "")

	self.tiles.locks:Set(string.format("%d", stats.lockCount),
		L.KPI_INSTANCES:format(stats.instances.hour, stats.instances.day))

	-- 2. Répartition de la collection, selon l'axe choisi.
	--
	-- Aucun scan là-dedans : les deux axes viennent du client, monture par
	-- monture. La carte a donc quelque chose à montrer dès la première
	-- connexion, ce que la frise des extensions n'a jamais su faire.
	local breakdownCard = page.BreakdownCard
	local axis = self:GetAxis()
	breakdownCard.Selector:SetValue(axis)

	local breakdown = ns.Stats:GetBreakdown(axis)
	local visible = self:BreakdownRowBudget()
	for index, row in ipairs(breakdownCard.Rows) do
		local bucket = index <= visible and breakdown[index] or nil
		if bucket then
			row:Set(bucket.label, bucket.owned, bucket.total, breakdown.max)
			row:Show()
		else
			row:Hide()
		end
	end
	breakdownCard.Empty:SetShown(#breakdown == 0)

	-- Sur une fenêtre rétrécie, toutes les catégories ne tiennent pas. Les
	-- dernières sont les moins fournies, donc les moins intéressantes à voir —
	-- mais on ne les escamote pas en silence : le nombre manquant est dit, avec
	-- le remède.
	local hidden = math.max(0, #breakdown - visible)
	if hidden > 0 then
		breakdownCard.Hint:SetText(L.DASH_BREAKDOWN_MORE:format(hidden))
	else
		breakdownCard.Hint:SetText(L.DASH_BREAKDOWN_HINT)
	end
	breakdownCard.Hint:SetShown(#breakdown > 0)

	-- État de la cartographie, et bouton coupé pendant qu'elle tourne.
	if ns.Mapping.running then
		breakdownCard.ScanInfo:SetText(self:ScanProgressText())
	else
		breakdownCard.ScanInfo:SetText(ns.Mapping:GetSummary() or L.SCAN_NEVER)
	end
	breakdownCard.RescanButton:SetEnabled(not ns.Mapping.running)

	-- 3. Cibles du moment.
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

	-- 4. Verrous de la semaine.
	local lockCard = page.LockoutCard
	local locks = ns.Lockouts:GetActiveLocks()
	local lockBudget = self:RowBudget(lockCard, 28, 8, TARGET_ROW_HEIGHT, MAX_LOCKOUT_ROWS)
	for index, row in ipairs(lockCard.Rows) do
		local lock = index <= lockBudget and locks[index] or nil
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
