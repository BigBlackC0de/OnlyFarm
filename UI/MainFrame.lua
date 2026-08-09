--[[---------------------------------------------------------------------------
	OnlyFarm — UI/MainFrame.lua

	Fenêtre principale : barre de titre, onglets, et le contenu de l'onglet
	Collection. Le tableau de bord vit dans UI/Dashboard.lua.

	La fenêtre n'utilise plus ButtonFrameTemplate. Le parchemin de Blizzard est
	très bien pour un journal de quêtes ; il est mauvais pour ce que fait cet
	addon, qui est d'aligner des chiffres et des barres. Sur fond sombre, une
	couleur porte du sens ; sur parchemin, elle porte du bruit. Tout le dessin
	passe donc par UI/Theme.lua.

	La liste reste virtualisée (ScrollBox + ScrollBoxListLinearView) : on
	n'instancie jamais 300 lignes, seulement celles visibles.
-----------------------------------------------------------------------------]]

local _, ns = ...

local UI = ns:NewModule("UI", 80)

local ROW_HEIGHT = 26
local FRAME_WIDTH, FRAME_HEIGHT = 900, 620
-- En dessous, les colonnes se chevauchent quoi qu'on fasse : les libellés de
-- filtres et les noms de montures ont une largeur plancher.
local MIN_WIDTH, MIN_HEIGHT = 820, 420
local TITLE_HEIGHT = 38
local TAB_HEIGHT = 30
local CONTENT_PADDING = 12

UI.TAB_DASHBOARD, UI.TAB_COLLECTION, UI.TAB_ROUTE, UI.TAB_EDITOR = 1, 2, 3, 4

--------------------------------------------------------------------------------
-- Colonnes de la liste
--
-- UN seul endroit décide des largeurs et de l'ordre : l'en-tête cliquable et les
-- lignes s'en servent tous les deux, donc ils ne peuvent pas se désaligner. Des
-- abscisses recopiées à la main de part et d'autre, c'était la garantie qu'un
-- ajout de colonne décale l'un sans l'autre.
--
-- AUCUNE colonne ne peut être vide, et c'est un critère de conception, pas un
-- détail : une cellule vide se lit comme une donnée manquante, alors qu'elle
-- signifiait le plus souvent « l'addon n'a pas rattaché cette monture à une
-- instance » — ce dont le joueur n'a rien à faire.
--
--   Monture   nom, toujours fourni par le client
--   Source    texte de source du Journal, avec repli sur la catégorie
--   Catégorie sourceType (Butin, Vendeur, Quête…), affiné en Raid / Donjon
--             quand la cartographie le sait. Toujours fourni.
--   Type      mode de déplacement (mountTypeID). Toujours fourni.
--   Essais    compteur de tentatives, zéro compris.
--   Possédée  oui / non. Le nom doré le dit déjà, mais une colonne se trie et
--             se lit en balayant du regard, ce qu'une couleur ne permet pas.
--------------------------------------------------------------------------------

UI.COLUMNS = {
	{ key = "name", label = "COL_MOUNT", width = 200, justify = "LEFT" },
	{ key = "source", label = "COL_SOURCE", width = 206, justify = "LEFT" },
	{ key = "category", label = "COL_CATEGORY", width = 78, justify = "LEFT" },
	{ key = "type", label = "COL_TYPE", width = 74, justify = "LEFT" },
	{ key = "tries", label = "COL_TRIES", width = 44, justify = "RIGHT", numeric = true },
	{ key = "owned", label = "COL_OWNED", width = 54, justify = "RIGHT" },
}

UI.COLUMNS_BY_KEY = {}
for _, column in ipairs(UI.COLUMNS) do
	UI.COLUMNS_BY_KEY[column.key] = column
end

local COLUMN_GAP = 6
-- Marge (6) + icône (18) + écart (8).
local ICON_SPAN = 32
-- Encastrement du ScrollBox dans la carte de liste.
local LIST_INSET = 4

function UI:OnEnable()
	self:RegisterMessage("OF_COLLECTION_UPDATED", "Refresh")
	self:RegisterMessage("OF_LOCKOUTS_UPDATED", "Refresh")
	self:RegisterMessage("OF_SCAN_COMPLETE", "Refresh")
	self:RegisterMessage("OF_SCAN_STARTED", "Refresh")
	self:RegisterMessage("OF_ATTEMPTS_UPDATED", "Refresh")
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

function UI:CreateFrame()
	if self.frame then return self.frame end
	local Theme = ns.Theme

	local frame = CreateFrame("Frame", "OnlyFarmFrame", UIParent)
	frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:SetClampedToScreen(true)
	frame:Hide()

	Theme.Fill(frame, Theme.colors.bg)
	Theme.Border(frame, Theme.colors.border)

	-- Redimensionnable. Aucune largeur ne convient à tout le monde : entre les
	-- locales longues, les échelles d'interface et les résolutions, la seule
	-- réponse durable est de laisser le joueur trancher et de retenir son choix.
	frame:SetResizable(true)
	if frame.SetResizeBounds then
		frame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT)
	elseif frame.SetMinResize then
		frame:SetMinResize(MIN_WIDTH, MIN_HEIGHT)
	end
	self:CreateResizeGrip(frame)

	-- Fermeture par Échap.
	tinsert(UISpecialFrames, "OnlyFarmFrame")

	self.frame = frame
	self:CreateTitleBar(frame)
	self:CreateTabs(frame)
	self:CreateContent(frame)
	self:CreateCollectionTab(frame)
	ns.Dashboard:Create(frame.Content)
	ns.RoutePage:Create(frame.Content)
	self:CreatePlaceholder(frame)
	self:RestorePosition()
	return frame
end

--- Poignée de redimensionnement en bas à droite. Trois traits en diagonale,
--  dessinés à la main : la texture de Blizzard est du métal doré, qui jurerait.
function UI:CreateResizeGrip(frame)
	local Theme = ns.Theme

	local grip = CreateFrame("Button", nil, frame)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -2, 2)
	grip:EnableMouse(true)

	for index = 1, 3 do
		local tick = grip:CreateTexture(nil, "OVERLAY")
		tick:SetSize(2 + index * 3, 1)
		tick:SetPoint("BOTTOMRIGHT", -2, 1 + index * 3)
		local c = Theme.colors.faint
		tick:SetColorTexture(c[1], c[2], c[3], 1)
	end

	grip:SetScript("OnMouseDown", function()
		frame:StartSizing("BOTTOMRIGHT")
	end)
	grip:SetScript("OnMouseUp", function()
		frame:StopMovingOrSizing()
		self:SavePosition()
		-- Les tuiles du tableau de bord sont réparties à la largeur : elles se
		-- replacent seules, mais la liste a besoin qu'on la relance.
		self:Refresh()
	end)

	frame.Grip = grip
end

function UI:CreateTitleBar(frame)
	local Theme = ns.Theme
	local L = ns.L

	local bar = CreateFrame("Frame", nil, frame)
	bar:SetPoint("TOPLEFT")
	bar:SetPoint("TOPRIGHT")
	bar:SetHeight(TITLE_HEIGHT)
	bar:EnableMouse(true)
	bar:RegisterForDrag("LeftButton")
	bar:SetScript("OnDragStart", function() frame:StartMoving() end)
	bar:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		self:SavePosition()
	end)
	Theme.Fill(bar, Theme.colors.panel)

	local underline = Theme.Separator(bar)
	underline:SetPoint("BOTTOMLEFT")
	underline:SetPoint("BOTTOMRIGHT")

	local icon = bar:CreateTexture(nil, "ARTWORK")
	icon:SetSize(24, 24)
	icon:SetPoint("LEFT", 10, 0)
	icon:SetTexture(ns.LOGO_TEXTURE)

	local title = Theme.Text(bar, "GameFontNormalLarge", Theme.colors.text)
	title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
	title:SetText(L.TITLE)

	local version = Theme.Text(bar, "GameFontHighlightSmall", Theme.colors.faint)
	version:SetPoint("LEFT", title, "RIGHT", 6, -1)
	version:SetText(ns.VERSION)

	local close = CreateFrame("Button", nil, bar, "UIPanelCloseButton")
	close:SetPoint("RIGHT", -4, 0)
	close:SetScript("OnClick", function() self:Hide() end)

	-- Compteur du cap d'instances : visible en permanence, comme le demande la
	-- spécification. C'est lui qui devient le facteur limitant sur une route
	-- legacy, bien avant la distance.
	local counter = Theme.Text(bar, "GameFontHighlightSmall", Theme.colors.muted, "RIGHT")
	counter:SetPoint("RIGHT", close, "LEFT", -10, 0)
	frame.InstanceCounter = counter

	frame.TitleBar = bar
end

function UI:CreateTabs(frame)
	local Theme = ns.Theme
	local L = ns.L
	local labels = { L.TAB_DASHBOARD, L.TAB_COLLECTION, L.TAB_ROUTE, L.TAB_EDITOR }

	local strip = CreateFrame("Frame", nil, frame)
	strip:SetPoint("TOPLEFT", frame.TitleBar, "BOTTOMLEFT")
	strip:SetPoint("TOPRIGHT", frame.TitleBar, "BOTTOMRIGHT")
	strip:SetHeight(TAB_HEIGHT)
	Theme.Fill(strip, Theme.colors.panel)

	local underline = Theme.Separator(strip)
	underline:SetPoint("BOTTOMLEFT")
	underline:SetPoint("BOTTOMRIGHT")

	frame.Tabs = {}
	local offset = 8
	for index, label in ipairs(labels) do
		local tab = CreateFrame("Button", nil, strip)
		tab:SetHeight(TAB_HEIGHT)
		tab:SetPoint("LEFT", offset, 0)
		tab:SetID(index)

		tab.Text = Theme.Text(tab, "GameFontHighlightSmall", Theme.colors.muted, "CENTER")
		tab.Text:SetPoint("CENTER", 0, 0)
		tab.Text:SetText(label)
		tab:SetWidth(tab.Text:GetStringWidth() + 28)

		-- Soulignement de l'onglet actif : le repère le plus lisible sans art
		-- dédié, et celui qu'attend un œil habitué aux interfaces web.
		tab.Marker = tab:CreateTexture(nil, "OVERLAY")
		tab.Marker:SetHeight(2)
		tab.Marker:SetPoint("BOTTOMLEFT", 6, 0)
		tab.Marker:SetPoint("BOTTOMRIGHT", -6, 0)
		local a = Theme.colors.accent
		tab.Marker:SetColorTexture(a[1], a[2], a[3], 1)
		tab.Marker:Hide()

		tab:SetScript("OnClick", function(button) self:SelectTab(button:GetID()) end)
		tab:SetScript("OnEnter", function(button)
			if not button.selected then
				local c = Theme.colors.text
				button.Text:SetTextColor(c[1], c[2], c[3])
			end
		end)
		tab:SetScript("OnLeave", function(button)
			if not button.selected then
				local c = Theme.colors.muted
				button.Text:SetTextColor(c[1], c[2], c[3])
			end
		end)

		offset = offset + tab:GetWidth()
		frame.Tabs[index] = tab
	end

	frame.TabStrip = strip
end

function UI:CreateContent(frame)
	local content = CreateFrame("Frame", nil, frame)
	content:SetPoint("TOPLEFT", frame.TabStrip, "BOTTOMLEFT", CONTENT_PADDING, -CONTENT_PADDING)
	content:SetPoint("BOTTOMRIGHT", -CONTENT_PADDING, CONTENT_PADDING)
	frame.Content = content
end

function UI:CreatePlaceholder(frame)
	local Theme = ns.Theme
	local page = CreateFrame("Frame", nil, frame.Content)
	page:SetAllPoints()
	page:Hide()

	local banner = page:CreateTexture(nil, "ARTWORK")
	banner:SetSize(340, 170)
	banner:SetPoint("CENTER", 0, 40)
	banner:SetTexture(ns.BANNER_TEXTURE)

	local text = Theme.Text(page, "GameFontNormalLarge", Theme.colors.muted, "CENTER")
	text:SetPoint("TOP", banner, "BOTTOM", 0, 0)
	page.Text = text

	frame.Placeholder = page
end

--------------------------------------------------------------------------------
-- Onglet Collection
--------------------------------------------------------------------------------

function UI:CreateCollectionTab(frame)
	local Theme = ns.Theme
	local L = ns.L

	local page = CreateFrame("Frame", nil, frame.Content)
	page:SetAllPoints()
	page:Hide()
	frame.CollectionPage = page

	-- Barre de filtres, dans une carte : ça la détache de la liste.
	local filters = Theme.Card(page, Theme.colors.panel)
	filters:SetPoint("TOPLEFT")
	filters:SetPoint("TOPRIGHT")
	filters:SetHeight(62)
	page.Filters = filters

	local search = CreateFrame("EditBox", "OnlyFarmSearchBox", filters, "SearchBoxTemplate")
	search:SetSize(210, 20)
	search:SetPoint("TOPLEFT", 10, -9)
	-- Ne PAS filtrer sur `userInput`. La petite croix de SearchBoxTemplate vide
	-- le champ par SetText(""), ce qui déclenche OnTextChanged avec
	-- userInput = false : en ignorant ce cas, la recherche restait collée sur
	-- le dernier terme saisi et la croix ne servait à rien. On se recale donc
	-- systématiquement sur le contenu réel du champ.
	search:SetScript("OnTextChanged", function(box)
		if SearchBoxTemplate_OnTextChanged then
			pcall(SearchBoxTemplate_OnTextChanged, box)
		end
		local text = box:GetText() or ""
		if text == ns.db.profile.filters.search then return end
		ns.db.profile.filters.search = text
		self:Refresh()
	end)
	-- Échap rend la main sans laisser le filtre en place : c'est le réflexe
	-- attendu quand on s'est trompé de recherche.
	search:SetScript("OnEscapePressed", function(box)
		box:SetText("")
		box:ClearFocus()
	end)
	page.SearchBox = search

	-- UN seul menu reste, et c'est le seul qui portait sur une donnée fiable.
	--
	-- « Extension » est parti avec la frise du tableau de bord : le client ne
	-- donne pas l'extension d'une monture, le menu ne listait donc que les
	-- paliers qu'un scan avait rattachés.
	--
	-- « Type » (raid / donjon / hors instance) faisait doublon avec « Source »,
	-- en moins fiable : il classait « hors instance » tout ce que la
	-- cartographie n'avait pas rattaché, c'est-à-dire aussi des raids.
	--
	-- « Trier » est devenu inutile : les titres de colonnes se cliquent.
	page.SourceDropdown = self:CreateSourceDropdown(filters, search)

	local function MakeFilter(label, key)
		local check = CreateFrame("CheckButton", nil, filters, "UICheckButtonTemplate")
		check:SetSize(20, 20)
		local caption = check.text or check.Text
		if caption then
			caption:SetText(label)
			caption:SetFontObject("GameFontHighlightSmall")
			local c = Theme.colors.muted
			caption:SetTextColor(c[1], c[2], c[3])
		end
		check:SetScript("OnClick", function(button)
			ns.db.profile.filters[key] = button:GetChecked() and true or false
			self:Refresh()
		end)
		return check
	end

	-- Les trois cases sont posées les unes après les autres à partir de la
	-- largeur réelle de leur libellé. Des abscisses fixes marchaient en anglais
	-- et se chevauchaient en français, où « Masquer les sources non
	-- cartographiées » fait deux fois la longueur de son équivalent.
	local previous
	local function PlaceFilter(label, key)
		local check = MakeFilter(label, key)
		if previous then
			local caption = previous.text or previous.Text
			local span = caption and caption:GetStringWidth() or 0
			check:SetPoint("BOTTOMLEFT", previous, "BOTTOMLEFT", span + 44, 0)
		else
			check:SetPoint("BOTTOMLEFT", 8, 8)
		end
		previous = check
		return check
	end

	-- Deux cases, et elles portent toutes les deux sur un fait : cette monture
	-- est possédée, cette monture a été mise de côté. Les deux autres filtraient
	-- sur la disponibilité (« dispo maintenant », « masquer les sources non
	-- cartographiées ») : elles trient sur un état que l'addon déduit, et que la
	-- liste ne montre plus.
	page.ShowOwned = PlaceFilter(L.FILTER_SHOW_OWNED, "showOwned")
	page.HideExcluded = PlaceFilter(L.FILTER_HIDE_EXCLUDED, "hideExcluded")

	-- Le résumé occupe la fin de la seconde ligne : la première est pleine de
	-- menus, et le borner à gauche l'empêche de passer par-dessus la dernière
	-- case à cocher.
	local summary = Theme.Text(filters, "GameFontHighlightSmall", Theme.colors.muted, "RIGHT")
	summary:SetPoint("BOTTOMRIGHT", -10, 12)
	summary:SetPoint("BOTTOMLEFT", page.HideExcluded, "BOTTOMRIGHT", 150, 12)
	summary:SetWordWrap(false)
	page.Summary = summary

	-- Liste.
	local list = Theme.Card(page, Theme.colors.panel)
	list:SetPoint("TOPLEFT", filters, "BOTTOMLEFT", 0, -8)
	list:SetPoint("BOTTOMRIGHT")
	page.List = list

	self:CreateListHeader(list)

	local rule = Theme.Separator(list)
	rule:SetPoint("TOPLEFT", 1, -24)
	rule:SetPoint("TOPRIGHT", -1, -24)

	local scrollBox = CreateFrame("Frame", nil, list, "WowScrollBoxList")
	scrollBox:SetPoint("TOPLEFT", LIST_INSET, -28)
	scrollBox:SetPoint("BOTTOMRIGHT", -22, 4)
	page.ScrollBox = scrollBox

	local scrollBar = CreateFrame("EventFrame", nil, list, "MinimalScrollBar")
	scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 4, 0)
	scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 4, 0)
	page.ScrollBar = scrollBar

	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(ROW_HEIGHT)
	view:SetElementInitializer("Button", function(button, elementData)
		self:InitRow(button, elementData)
	end)
	ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

	local empty = Theme.Text(list, "GameFontNormal", Theme.colors.faint, "CENTER")
	empty:SetPoint("CENTER", scrollBox, "CENTER")
	empty:SetText(L.NO_RESULT)
	empty:Hide()
	page.EmptyLabel = empty
end

--------------------------------------------------------------------------------
-- En-tête de liste, triable à la souris
--
-- Un menu « Trier » demandait deux clics et cachait le critère actif derrière
-- son libellé. Des titres de colonnes cliquables mettent le critère là où il
-- porte — sur la colonne — et c'est le geste qu'attend n'importe qui ayant déjà
-- ouvert un tableur.
--------------------------------------------------------------------------------

--- Un clic sur un titre trie dessus ; un second inverse le sens.
function UI:ToggleSort(key)
	local filters = ns.db.profile.filters
	if filters.sort == key then
		filters.sortDesc = not filters.sortDesc
	else
		filters.sort = key
		-- Premier clic : le sens le plus utile pour la colonne. Sur un nombre
		-- d'essais, c'est le plus gros d'abord ; sur du texte, l'ordre
		-- alphabétique.
		filters.sortDesc = UI.COLUMNS_BY_KEY[key] and UI.COLUMNS_BY_KEY[key].numeric or false
	end
	self:Refresh()
end

function UI:CreateListHeader(list)
	local Theme = ns.Theme
	local L = ns.L

	list.Headers = {}
	-- Le ScrollBox est encastré de LIST_INSET dans la carte : sans ce décalage,
	-- l'en-tête serait décalé de quatre pixels par rapport aux cellules qu'il
	-- coiffe, ce qui se voit dès qu'une colonne est étroite.
	local offset = LIST_INSET + ICON_SPAN

	for _, column in ipairs(UI.COLUMNS) do
		local button = CreateFrame("Button", nil, list)
		button:SetPoint("TOPLEFT", offset, -6)
		button:SetSize(column.width, 18)
		button.sortKey = column.key

		button.Text = Theme.Text(button, "GameFontHighlightSmall", Theme.colors.faint,
			column.justify)
		button.Text:SetPoint("LEFT")
		button.Text:SetPoint("RIGHT")
		button.Text:SetText(L[column.label] or column.key)
		button.Text:SetWordWrap(false)

		-- La flèche de tri de Blizzard. Si la texture venait à disparaître, elle
		-- ne dessine rien et ne lève pas d'erreur : la couleur du titre suffit
		-- alors à désigner la colonne active, d'où les deux repères.
		button.Arrow = button:CreateTexture(nil, "OVERLAY")
		button.Arrow:SetSize(10, 10)
		button.Arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
		button.Arrow:Hide()
		if column.justify == "RIGHT" then
			button.Arrow:SetPoint("RIGHT", button.Text, "LEFT", -2, 0)
		else
			button.Arrow:SetPoint("LEFT", button.Text, "LEFT",
				button.Text:GetStringWidth() + 3, 0)
		end

		button:SetScript("OnClick", function(self_) UI:ToggleSort(self_.sortKey) end)
		button:SetScript("OnEnter", function(self_)
			if not self_.active then
				local c = Theme.colors.text
				self_.Text:SetTextColor(c[1], c[2], c[3])
			end
			GameTooltip:SetOwner(self_, "ANCHOR_TOP")
			GameTooltip:AddLine(L[column.label] or column.key, 1, 1, 1)
			GameTooltip:AddLine(L.SORT_HINT, 0.6, 0.6, 0.6)
			GameTooltip:Show()
		end)
		button:SetScript("OnLeave", function(self_)
			if not self_.active then
				local c = Theme.colors.faint
				self_.Text:SetTextColor(c[1], c[2], c[3])
			end
			GameTooltip:Hide()
		end)

		list.Headers[#list.Headers + 1] = button
		offset = offset + column.width + COLUMN_GAP
	end
end

--- Met l'en-tête au diapason du tri courant : titre en accent et flèche sur la
--  colonne active, titres discrets partout ailleurs.
function UI:UpdateListHeader()
	local page = self.frame and self.frame.CollectionPage
	local list = page and page.List
	if not list or not list.Headers then return end

	local Theme = ns.Theme
	local filters = ns.db.profile.filters
	local active = self:ResolveSort(filters.sort)

	for _, button in ipairs(list.Headers) do
		local isActive = button.sortKey == active
		button.active = isActive
		local c = isActive and Theme.colors.accent or Theme.colors.faint
		button.Text:SetTextColor(c[1], c[2], c[3])
		button.Arrow:SetShown(isActive)
		if isActive then
			-- La texture pointe vers le haut ; on la retourne pour le sens
			-- descendant plutôt que d'embarquer une seconde image.
			if filters.sortDesc then
				button.Arrow:SetTexCoord(0, 1, 1, 0)
			else
				button.Arrow:SetTexCoord(0, 1, 0, 1)
			end
		end
	end
end

--- Fabrique un menu déroulant de filtre, ancré au widget précédent.
--
--  Le type de frame « DropdownButton » et le template
--  WowStyle1FilterDropdownTemplate sont ceux qu'utilise le Journal des montures
--  de Blizzard ; le menu se décrit via SetupMenu depuis la 11.0.
--
--  CreateFrame lève une erreur sur un type ou un template inconnu, elle ne
--  renvoie pas nil. Sans le pcall, un changement côté Blizzard casserait toute
--  la fenêtre au lieu de faire disparaître un seul filtre.
function UI:CreateDropdown(parent, name, anchor, label, width)
	local ok, dropdown = pcall(CreateFrame, "DropdownButton", name,
		parent, "WowStyle1FilterDropdownTemplate")
	if not ok or not dropdown or type(dropdown.SetupMenu) ~= "function" then
		ns:Debug("menu %s indisponible : %s", tostring(name), tostring(dropdown))
		return nil
	end

	dropdown:SetSize(width or 132, 22)
	dropdown:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
	if dropdown.SetText then dropdown:SetText(label) end
	return dropdown
end

--- Menu des natures de source : butin, haut fait, vendeur, métier, événement…
--  C'est le filtre qui permet « je ne veux voir que les montures de haut
--  fait », et il vient entièrement du client : `sourceType` est fourni par le
--  Journal des montures, son libellé aussi.
function UI:CreateSourceDropdown(parent, anchor)
	local L = ns.L
	local dropdown = self:CreateDropdown(parent, "OnlyFarmSourceDropdown", anchor, L.FILTER_SOURCE)
	if not dropdown then return nil end

	local function IsShown(kind)
		return not ns.db.profile.filters.kindsHidden[kind]
	end
	local function SetShown(kind, shown)
		ns.db.profile.filters.kindsHidden[kind] = (not shown) or nil
		self:Refresh()
	end

	dropdown:SetupMenu(function(_, rootDescription)
		rootDescription:CreateTitle(L.FILTER_SOURCE)

		local kinds = ns.Collection:GetSourceKinds()

		rootDescription:CreateButton(L.FILTER_ALL, function()
			wipe(ns.db.profile.filters.kindsHidden)
			self:Refresh()
		end)
		rootDescription:CreateButton(L.FILTER_NONE, function()
			local hidden = ns.db.profile.filters.kindsHidden
			for _, entry in ipairs(kinds) do hidden[entry.kind] = true end
			self:Refresh()
		end)

		for _, entry in ipairs(kinds) do
			rootDescription:CreateCheckbox(
				string.format("%s (%d)", entry.label, entry.count),
				function() return IsShown(entry.kind) end,
				function()
					SetShown(entry.kind, not IsShown(entry.kind))
					return MenuResponse.Refresh
				end)
		end
	end)

	return dropdown
end

--------------------------------------------------------------------------------
-- Lignes
--------------------------------------------------------------------------------

local TYPE_LABELS = { raid = "TYPE_RAID", dungeon = "TYPE_DUNGEON" }

--- Construit les widgets d'une ligne la première fois qu'elle est acquise,
--  puis se contente de les remplir. Le pool de ScrollBox recycle les frames.
function UI:InitRow(button, elementData)
	local Theme = ns.Theme

	if not button.ofBuilt then
		button.ofBuilt = true
		button:SetHeight(ROW_HEIGHT)

		-- Alternance de lignes : posée par le rafraîchissement, pas ici, parce
		-- que le recyclage réattribue les frames à des index différents.
		button.Stripe = button:CreateTexture(nil, "BACKGROUND")
		button.Stripe:SetAllPoints()

		button.Icon = button:CreateTexture(nil, "ARTWORK")
		button.Icon:SetSize(18, 18)
		button.Icon:SetPoint("LEFT", 6, 0)

		-- Les cellules sont posées dans l'ordre de UI.COLUMNS et à ses largeurs :
		-- l'en-tête lit la même table, donc les deux restent alignés.
		button.Cells = {}
		local previous
		for _, column in ipairs(UI.COLUMNS) do
			local cell = Theme.Text(button, "GameFontHighlightSmall", Theme.colors.muted,
				column.justify)
			if previous then
				cell:SetPoint("LEFT", previous, "RIGHT", COLUMN_GAP, 0)
			else
				cell:SetPoint("LEFT", button.Icon, "RIGHT", 8, 0)
			end
			cell:SetWidth(column.width)
			cell:SetWordWrap(false)
			button.Cells[column.key] = cell
			previous = cell
		end

		button.Name = button.Cells.name
		button.Source = button.Cells.source
		button.Category = button.Cells.category
		button.Type = button.Cells.type
		button.Tries = button.Cells.tries
		button.Owned = button.Cells.owned

		-- Bouton d'exclusion, à droite de la ligne. L'action existait déjà au
		-- clic droit, mais une action qu'aucun élément à l'écran n'annonce n'est
		-- pas une action : c'est un secret.
		button.ExcludeButton = CreateFrame("Button", nil, button)
		button.ExcludeButton:SetSize(18, 18)
		button.ExcludeButton:SetPoint("LEFT", button.Owned, "RIGHT", 8, 0)
		button.ExcludeButton.Text = Theme.Text(button.ExcludeButton, "GameFontHighlightSmall",
			Theme.colors.faint, "CENTER")
		button.ExcludeButton.Text:SetPoint("CENTER")
		button.ExcludeButton:SetScript("OnClick", function(self_)
			local mountID = self_:GetParent().mountID
			if not mountID then return end
			ns.Collection:SetExcluded(mountID, not ns.Collection:IsExcluded(mountID))
		end)
		button.ExcludeButton:SetScript("OnEnter", function(self_)
			local c = Theme.colors.red
			self_.Text:SetTextColor(c[1], c[2], c[3])
			local mountID = self_:GetParent().mountID
			GameTooltip:SetOwner(self_, "ANCHOR_RIGHT")
			GameTooltip:AddLine(ns.Collection:IsExcluded(mountID)
				and ns.L.ACTION_INCLUDE or ns.L.ACTION_EXCLUDE, 1, 1, 1)
			GameTooltip:Show()
		end)
		button.ExcludeButton:SetScript("OnLeave", function(self_)
			local c = Theme.colors.faint
			self_.Text:SetTextColor(c[1], c[2], c[3])
			GameTooltip:Hide()
		end)

		button.Highlight = button:CreateTexture(nil, "HIGHLIGHT")
		button.Highlight:SetAllPoints()
		button.Highlight:SetColorTexture(1, 1, 1, 0.06)

		button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		button:SetScript("OnEnter", function(row) UI:ShowRowTooltip(row) end)
		button:SetScript("OnLeave", function() GameTooltip:Hide() end)
		button:SetScript("OnClick", function(row, mouseButton)
			if not row.mountID then return end
			if mouseButton == "RightButton" then
				UI:ShowRowMenu(row)
			-- Rattrapage manuel du compteur de tentatives. ENCOUNTER_END est
			-- fiable en solo legacy, mais pas garanti : mieux vaut un +1 sous
			-- la main qu'un compteur faux qu'on ne peut pas corriger.
			elseif IsShiftKeyDown and IsShiftKeyDown() then
				ns.Attempts:Bump(row.mountID, nil, 1)
				ns.Attempts:SendMessage("OF_ATTEMPTS_UPDATED")
				UI:ShowRowTooltip(row)
			elseif IsControlKeyDown and IsControlKeyDown() then
				ns.Attempts:Bump(row.mountID, nil, -1)
				ns.Attempts:SendMessage("OF_ATTEMPTS_UPDATED")
				UI:ShowRowTooltip(row)
			else
				ns.Preview:Toggle(row.mountID)
			end
		end)
	end

	button.mountID = elementData.mountID
	button.Icon:SetTexture(elementData.icon)

	local stripe = elementData.index % 2 == 0 and 0.03 or 0
	button.Stripe:SetColorTexture(1, 1, 1, stripe)

	-- Une monture exclue reste dans la liste, grisée et étiquetée. Elle ne
	-- disparaît que si le filtre « Masquer les exclues » est coché — le clic
	-- droit doit se lire comme une action, pas comme une perte.
	-- La croix devient une flèche de retour sur une ligne exclue : c'est le même
	-- bouton, il fait l'aller et le retour.
	button.ExcludeButton.Text:SetText(elementData.excluded and "+" or "×")

	if elementData.excluded then
		local faint = Theme.colors.faint
		button.Name:SetText(elementData.name)
		button.Name:SetTextColor(faint[1], faint[2], faint[3])
		button.Source:SetText(ns.L.TAG_EXCLUDED)
		button.Source:SetTextColor(faint[1], faint[2], faint[3])
		button.Category:SetText(elementData.categoryLabel or "")
		button.Category:SetTextColor(faint[1], faint[2], faint[3])
		button.Type:SetText(elementData.movementLabel or "")
		button.Type:SetTextColor(faint[1], faint[2], faint[3])
		button.Tries:SetText(elementData.triesText or "")
		button.Tries:SetTextColor(faint[1], faint[2], faint[3])
		button.Owned:SetText(elementData.ownedText or "")
		button.Owned:SetTextColor(faint[1], faint[2], faint[3])
		button.Icon:SetDesaturated(true)
		button.Icon:SetAlpha(0.4)
	else
		-- Possédée : le nom passe au doré. C'est tout ce que remplaçait la
		-- pastille de disponibilité — « je l'ai ou je l'ai pas ». Le reste de la
		-- ligne garde ses couleurs, parce que d'où venait une monture qu'on
		-- possède reste une information qu'on va chercher.
		local nameColor = elementData.owned and Theme.colors.gold or Theme.colors.text
		button.Name:SetText(elementData.name)
		button.Name:SetTextColor(nameColor[1], nameColor[2], nameColor[3])

		local muted = Theme.colors.muted
		button.Source:SetText(elementData.sourceSummary or "")
		button.Source:SetTextColor(muted[1], muted[2], muted[3])

		button.Category:SetText(elementData.categoryLabel or "")
		local cc = elementData.categoryColor or Theme.colors.muted
		button.Category:SetTextColor(cc[1], cc[2], cc[3])

		local faint = Theme.colors.faint
		button.Type:SetText(elementData.movementLabel or "")
		button.Type:SetTextColor(faint[1], faint[2], faint[3])

		button.Tries:SetText(elementData.triesText or "")
		button.Tries:SetTextColor(faint[1], faint[2], faint[3])

		-- « oui » en doré, « non » en discret : la colonne se balaie du regard
		-- sans avoir à lire chaque mot.
		button.Owned:SetText(elementData.ownedText or "")
		local oc = elementData.owned and Theme.colors.gold or Theme.colors.faint
		button.Owned:SetTextColor(oc[1], oc[2], oc[3])

		button.Icon:SetDesaturated(false)
		button.Icon:SetAlpha(1)
	end
end

--------------------------------------------------------------------------------
-- Menu contextuel d'une ligne
--
-- Le clic droit posait l'exclusion, directement. Deux défauts : l'action était
-- invisible tant qu'on ne lisait pas l'infobulle, et le clic droit ne pouvait
-- rien faire d'autre. Il ouvre maintenant un menu, et l'exclusion a son propre
-- bouton sur la ligne.
--------------------------------------------------------------------------------

--- Actions du menu, dans l'ordre d'affichage.
--  Chaque entrée décide elle-même de son libellé : « Exclure » et
--  « Réintégrer » sont le même item selon l'état de la ligne.
function UI:GetRowActions(mountID)
	local L = ns.L
	local excluded = ns.Collection:IsExcluded(mountID)
	local mission = ns.Route:GetMissionFor(mountID)

	return {
		{
			label = L.ACTION_PREVIEW,
			action = function() ns.Preview:Toggle(mountID) end,
		},
		{
			label = L.ACTION_COPY_NAME,
			-- Copy:Show(titre, texte), et le champ est présélectionné : un
			-- Ctrl+C suffit. Pas d'accès au presse-papiers depuis un addon, donc
			-- c'est le seul chemin possible.
			action = function()
				local entry = ns.Collection:GetEntry(mountID)
				ns.Copy:Show(L.COPY_TITLE, entry and entry.name or "")
			end,
		},
		{
			label = L.ACTION_ROUTE,
			-- Grisé plutôt qu'absent quand la monture n'a pas d'entrée
			-- cartographiée : un item qui disparaît fait douter de l'avoir vu,
			-- un item grisé dit qu'il existe et pourquoi il ne marche pas ici.
			disabled = mission == nil,
			tooltip = mission == nil and L.ACTION_ROUTE_IMPOSSIBLE or nil,
			action = function()
				ns.Route:SetTarget(mountID)
				self:SelectTab(self.TAB_ROUTE)
			end,
		},
		{
			label = excluded and L.ACTION_INCLUDE or L.ACTION_EXCLUDE,
			action = function() ns.Collection:SetExcluded(mountID, not excluded) end,
		},
	}
end

--- Ouvre le menu contextuel d'une ligne.
--
--  MenuUtil.CreateContextMenu est l'API de la 11.0 ; elle n'existe pas sur un
--  client plus ancien, et un menu manquant ne doit pas casser le clic droit. Le
--  repli applique alors l'action la plus attendue — l'exclusion — pour que le
--  geste garde son ancien effet plutôt que de ne rien faire.
function UI:ShowRowMenu(row)
	local mountID = row.mountID
	if not mountID then return end

	local actions = self:GetRowActions(mountID)

	if MenuUtil and type(MenuUtil.CreateContextMenu) == "function" then
		local ok = pcall(MenuUtil.CreateContextMenu, row, function(_, rootDescription)
			local entry = ns.Collection:GetEntry(mountID)
			rootDescription:CreateTitle(entry and entry.name or ns.L.COL_MOUNT)
			for _, item in ipairs(actions) do
				local button = rootDescription:CreateButton(item.label, item.action)
				if item.disabled and button then
					button:SetEnabled(false)
					if item.tooltip and type(button.SetTooltip) == "function" then
						button:SetTooltip(function(tooltip)
							if type(GameTooltip_AddNormalLine) == "function" then
								GameTooltip_AddNormalLine(tooltip, item.tooltip)
							elseif tooltip and type(tooltip.AddLine) == "function" then
								tooltip:AddLine(item.tooltip)
							end
						end)
					end
				end
			end
		end)
		if ok then return end
	end

	ns:Debug("menu contextuel indisponible, repli sur l'exclusion")
	ns.Collection:SetExcluded(mountID, not ns.Collection:IsExcluded(mountID))
end

function UI:ShowRowTooltip(row)
	if not row.mountID then return end
	local L = ns.L
	local entry = ns.Collection:GetEntry(row.mountID)
	if not entry then return end

	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip:AddLine(entry.name, 1, 1, 1)

	local sourceText = ns.Collection:GetSourceText(row.mountID)
	if sourceText then
		GameTooltip:AddLine(sourceText, 0.8, 0.8, 0.8, true)
	end

	-- Mode de déplacement. Le graphe du tableau de bord compte les montures
	-- volantes ; l'infobulle dit lesquelles, sinon le chiffre n'est vérifiable
	-- nulle part.
	--
	-- Gratuit : GetSourceText vient de résoudre le même appel, et les deux
	-- données en sortent ensemble (cf. Collection:ResolveExtra).
	local movement = ns.Collection:GetMovement(row.mountID)
	if movement ~= ns.Data.MOVEMENT.OTHER then
		GameTooltip:AddDoubleLine(L.TOOLTIP_MOVEMENT,
			ns.Data.GetMovementLabel(movement), 0.6, 0.6, 0.6, 0.9, 0.9, 0.9)
	end

	-- Où et sous quelle forme. La difficulté EXACTE d'une monture (« 25
	-- héroïque ») n'est exposée par aucune API : on affiche donc ce que le
	-- client sait vraiment — le type d'instance, et la difficulté du verrou
	-- quand il y en a un, parce que celle-là est mesurée et pas devinée.
	local source = ns.Eligibility:GetSource(row.mountID)
	if source then
		local instanceType = self:GetInstanceType(source)
		if source.instanceName then
			GameTooltip:AddDoubleLine(source.instanceName,
				ns.L[TYPE_LABELS[instanceType]] or "", 1, 0.82, 0, 0.7, 0.7, 0.7)
		end
		-- « Boss » seulement si c'en est un. `encounterName` porte le sujet
		-- extrait du texte de source, quel qu'il soit : sur « Vendeur : Gottum »
		-- c'est le nom du VENDEUR, et l'annoncer comme un boss est faux. Le
		-- sourceType du client tranche, lui ne se trompe pas.
		if source.encounterName and source.encounterName ~= ""
			and source.kind == ns.Data.SOURCE_KINDS.BOSS
		then
			GameTooltip:AddDoubleLine(L.TOOLTIP_BOSS, source.encounterName,
				0.6, 0.6, 0.6, 0.9, 0.9, 0.9)
		end
	end

	local status = ns.Eligibility:GetStatus(row.mountID)
	if status.lock and status.lock.difficultyName then
		GameTooltip:AddDoubleLine(L.TOOLTIP_DIFFICULTY, status.lock.difficultyName,
			0.6, 0.6, 0.6, 0.9, 0.9, 0.9)
	end

	-- Vue multi-personnage, mais SEULEMENT quand elle dit quelque chose.
	--
	-- Sans source cartographiée, chaque ligne valait « incertain » et l'en-tête
	-- annonçait « 0 perso disponible » : un tableau de non-réponses, coiffé d'un
	-- zéro qui se lit comme un « non » alors qu'il veut dire « on ne sait pas ».
	-- Le bloc n'apparaît donc que si au moins un personnage a un état mesuré —
	-- disponible parce que le verrou est tombé, ou verrouillé parce qu'il est là.
	local rows, availableCount = ns.Eligibility:GetCharacterAvailability(row.mountID)
	local STATE = ns.Eligibility.STATE
	local hasVerdict = false
	for _, charRow in ipairs(rows) do
		if charRow.state == STATE.AVAILABLE or charRow.state == STATE.LOCKED then
			hasVerdict = true
			break
		end
	end

	if hasVerdict then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(L.LOCK_CHARS:format(availableCount), 1, 0.82, 0)
		for _, charRow in ipairs(rows) do
			local status = { state = charRow.state, resetIn = charRow.resetIn, stale = charRow.stale }
			local suffix = ""
			if charRow.stale and charRow.lastSeen then
				suffix = " (" .. L.LOCK_STALE:format(ns.Util.FormatAge(charRow.lastSeen)) .. ")"
			end
			GameTooltip:AddDoubleLine(charRow.name,
				ns.Eligibility:FormatStatus(status) .. suffix)
		end
	end

	local attempts = ns.Attempts:Get(row.mountID)
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine(self:FormatAttempts(row.mountID), 1, 0.82, 0)
	if attempts and attempts.lastAt then
		GameTooltip:AddLine(L.ATTEMPTS_LAST:format(ns.Util.FormatAge(attempts.lastAt)),
			0.7, 0.7, 0.7)
	end
	local dry = ns.Attempts:GetDryChance(row.mountID)
	if dry then
		GameTooltip:AddLine(L.ATTEMPTS_DRY:format(dry * 100), 0.7, 0.7, 0.7)
	end

	GameTooltip:AddLine(" ")
	GameTooltip:AddLine(L.HINT_PREVIEW, 0.5, 0.5, 0.5)
	GameTooltip:AddLine(L.HINT_MENU, 0.5, 0.5, 0.5)
	GameTooltip:AddLine(L.HINT_ATTEMPT_ADD, 0.5, 0.5, 0.5)
	GameTooltip:AddLine(L.HINT_ATTEMPT_SUB, 0.5, 0.5, 0.5)
	GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- Rafraîchissement
--------------------------------------------------------------------------------

--- « aucun essai » / « 1 essai » / « 12 essais ».
function UI:FormatAttempts(mountID)
	local L = ns.L
	local count = ns.Attempts:GetCount(mountID)
	if count <= 0 then return L.ATTEMPTS_NONE end
	if count == 1 then return L.ATTEMPTS_ONE end
	return L.ATTEMPTS:format(count)
end

--- Comparaison sur la colonne demandée, en trois états : -1, 0, 1.
--
--  Renvoyer un ORDRE plutôt qu'un booléen est ce qui rend l'inversion possible
--  sans dupliquer six comparateurs. Le départage par le nom, lui, ne s'inverse
--  jamais : sinon deux lignes égales sur la colonne triée échangeraient leur
--  place d'un rafraîchissement à l'autre.
local function CompareText(a, b)
	if a == b then return 0 end
	return a < b and -1 or 1
end

local function CompareNumber(a, b)
	if a == b then return 0 end
	return a < b and -1 or 1
end

local COMPARATORS = {
	name = function(a, b) return CompareText(a.sortName, b.sortName) end,
	source = function(a, b) return CompareText(a.sortSource, b.sortSource) end,
	category = function(a, b) return CompareText(a.sortCategory, b.sortCategory) end,
	-- Le type suit l'ordre de Data.MOVEMENT_ORDER, pas l'alphabet : terrestre,
	-- volante, skyriding, aquatique, autre. C'est celui du graphe.
	type = function(a, b) return CompareNumber(a.movementRank, b.movementRank) end,
	tries = function(a, b) return CompareNumber(a.tries, b.tries) end,
	-- Les manquantes d'abord au premier clic : c'est la question que pose
	-- l'addon. Un second clic remonte les possédées.
	owned = function(a, b)
		return CompareNumber(a.owned and 1 or 0, b.owned and 1 or 0)
	end,
}

--- Ramène un critère de tri sauvegardé à une colonne qui existe encore. Les
--  réglages « extension », « statut » et « possédée » viennent de versions où
--  ces colonnes étaient là.
function UI:ResolveSort(key)
	if COMPARATORS[key] then return key end
	return "name"
end

local function MatchesSearch(entry, needle)
	if needle == "" then return true end
	return entry.name:lower():find(needle, 1, true) ~= nil
end

--- Type d'endroit d'une monture, quand la cartographie le sait.
--  @return "raid" | "dungeon" | "outdoor"
function UI:GetInstanceType(source)
	if type(source) ~= "table" then return "outdoor" end
	if source.isRaid == true then return "raid" end
	if source.isRaid == false then return "dungeon" end
	return "outdoor"
end

--- Catégorie affichée d'une monture : libellé, couleur, clé de tri.
--
--  Elle part du `sourceType` du client — toujours fourni, donc jamais vide — et
--  se précise en « Raid » ou « Donjon » quand la cartographie a rattaché la
--  monture à une instance. L'ancienne colonne faisait l'inverse : elle partait
--  de la cartographie et retombait sur un tiret, ce qui affichait « — » sur la
--  majorité des lignes alors que le client, lui, savait répondre.
function UI:GetCategoryVisual(entry, source)
	local Theme = ns.Theme
	local instanceType = self:GetInstanceType(source)

	if instanceType == "raid" then
		return ns.L.TYPE_RAID, Theme.colors.purple, "1" .. (ns.L.TYPE_RAID or "")
	end
	if instanceType == "dungeon" then
		return ns.L.TYPE_DUNGEON, Theme.colors.accent, "2" .. (ns.L.TYPE_DUNGEON or "")
	end

	local label = entry.sourceTypeLabel or ns.L.SOURCE_UNKNOWN
	-- Les catégories du client passent après raid et donjon dans le tri : ce
	-- sont les deux seules qui portent un verrou, donc les deux qui commandent
	-- une semaine de farm.
	return label, Theme.colors.muted, "3" .. label
end

function UI:BuildDataProvider()
	local filters = ns.db.profile.filters
	local needle = (filters.search or ""):lower()
	local Theme = ns.Theme
	-- `L` n'est PAS une variable de fichier dans ce module : chaque fonction le
	-- reprend de ns. L'oublier ici faisait planter la construction de la liste
	-- dès qu'une monture possédée devait être étiquetée, et comme le bus avale
	-- les erreurs de handler, la case « Afficher les possédées » ne faisait
	-- simplement rien.
	local L = ns.L
	local rows = {}

	-- Les possédées ne sont ajoutées que sur demande. La liste répond d'abord à
	-- « qu'est-ce qu'il me manque » ; les revoir reste à un clic, et elles
	-- s'affichent alors avec leur nom en doré.
	local candidates = ns.Collection:GetMissing()
	if filters.showOwned then
		candidates = {}
		for _, entry in ipairs(ns.Collection:GetMissing()) do
			candidates[#candidates + 1] = entry
		end
		for _, entry in ipairs(ns.Collection:GetCollected()) do
			candidates[#candidates + 1] = entry
		end
	end

	for _, entry in ipairs(candidates) do
		local keep = true

		if filters.hideExcluded and entry.excluded then keep = false end
		if keep and not MatchesSearch(entry, needle) then keep = false end
		if keep and filters.kindsHidden[entry.kind] then keep = false end

		if keep then
			local source = ns.Eligibility:GetSource(entry.mountID)
			local categoryLabel, categoryColor, categorySort =
				self:GetCategoryVisual(entry, source)
			local movement = ns.Collection:GetMovement(entry.mountID)
			local sourceSummary = ns.Collection:GetSourceSummary(entry.mountID) or ""

			rows[#rows + 1] = {
				mountID = entry.mountID,
				name = entry.name,
				icon = entry.icon,
				kind = entry.kind or "unknown",
				excluded = entry.excluded,
				owned = entry.owned,

				sourceSummary = sourceSummary,
				categoryLabel = categoryLabel,
				categoryColor = categoryColor,
				movementLabel = ns.Data.GetMovementLabel(movement),
				movementRank = ns.Data.GetMovementRank(movement),
				tries = ns.Attempts:GetCount(entry.mountID),

				-- Clés de tri en minuscules : sinon « Ulduar » passe avant
				-- « alliance » sur un octet de casse, ce qui n'a aucun sens à
				-- l'écran.
				sortName = entry.name:lower(),
				sortSource = sourceSummary:lower(),
				sortCategory = categorySort:lower(),
			}
		end
	end

	local sortKey = self:ResolveSort(filters.sort)
	local comparator = COMPARATORS[sortKey]
	local descending = filters.sortDesc and true or false
	table.sort(rows, function(a, b)
		local order = comparator(a, b)
		if order ~= 0 then
			if descending then return order > 0 end
			return order < 0
		end
		return a.sortName < b.sortName
	end)

	local provider = CreateDataProvider()
	for index, row in ipairs(rows) do
		row.index = index
		-- Zéro s'écrit « 0 », pas « — ». Un tiret dans une colonne de nombres se
		-- lit comme une donnée absente, alors que la donnée est là et vaut zéro.
		row.triesText = tostring(row.tries)
		row.ownedText = row.owned and L.YES or L.NO
		provider:Insert(row)
	end

	return provider, #rows
end

function UI:Refresh()
	local frame = self.frame
	if not frame or not frame:IsShown() then return end

	local L = ns.L
	local hour, day = ns.Lockouts:GetInstanceCounts()
	frame.InstanceCounter:SetText(L.INSTANCE_COUNTER:format(hour, 10, day, 30))

	if ns.db.profile.ui.activeTab == self.TAB_DASHBOARD then
		ns.Dashboard:Refresh()
		return
	end
	if ns.db.profile.ui.activeTab == self.TAB_ROUTE then
		ns.RoutePage:Refresh()
		return
	end
	if ns.db.profile.ui.activeTab ~= self.TAB_COLLECTION then return end

	local page = frame.CollectionPage
	if not ns.Collection.ready then
		page.Summary:SetText(L.JOURNAL_NOT_READY)
		return
	end

	local counts = ns.Collection.counts
	local provider, shown = self:BuildDataProvider()

	-- `total` ne compte que ce que CE personnage peut obtenir. Les montures
	-- d'une autre faction ou d'une autre classe sont comptées à part : les
	-- noyer dans le total donnerait un nombre de « manquantes » démoralisant
	-- et faux, puisqu'elles ne tomberont jamais ici.
	local summary = L.SUMMARY:format(counts.owned, counts.total, counts.missing)
	if shown ~= counts.missing then
		summary = summary .. "  ·  " .. L.SUMMARY_FILTERED:format(shown)
	end
	page.Summary:SetText(summary)

	page.ScrollBox:SetDataProvider(provider, ScrollBoxConstants.RetainScrollPosition)
	page.EmptyLabel:SetShown(shown == 0)
	self:UpdateListHeader()
end

--------------------------------------------------------------------------------
-- Onglets, position, visibilité
--------------------------------------------------------------------------------

function UI:SelectTab(index)
	local frame = self.frame
	if not frame then return end
	local Theme = ns.Theme
	index = math.max(1, math.min(#frame.Tabs, index or 1))
	ns.db.profile.ui.activeTab = index

	for i, tab in ipairs(frame.Tabs) do
		tab.selected = (i == index)
		tab.Marker:SetShown(tab.selected)
		local c = tab.selected and Theme.colors.text or Theme.colors.muted
		tab.Text:SetTextColor(c[1], c[2], c[3])
	end

	frame.CollectionPage:SetShown(index == self.TAB_COLLECTION)
	ns.Dashboard:SetShown(index == self.TAB_DASHBOARD)
	ns.RoutePage:SetShown(index == self.TAB_ROUTE)

	-- L'écran d'attente ne sert plus qu'à l'éditeur.
	local isPlaceholder = (index == self.TAB_EDITOR)
	frame.Placeholder:SetShown(isPlaceholder)
	if isPlaceholder then
		frame.Placeholder.Text:SetText(ns.L.EDITOR_PLACEHOLDER)
	end

	self:Refresh()
end

function UI:SavePosition()
	if not self.frame or not ns.db then return end
	local point, _, _, x, y = self.frame:GetPoint()
	local uiConfig = ns.db.profile.ui
	uiConfig.point, uiConfig.x, uiConfig.y = point, x, y
	uiConfig.width = math.floor(self.frame:GetWidth() + 0.5)
	uiConfig.height = math.floor(self.frame:GetHeight() + 0.5)
end

function UI:RestorePosition()
	if not self.frame or not ns.db then return end
	local uiConfig = ns.db.profile.ui
	self.frame:ClearAllPoints()
	self.frame:SetPoint(uiConfig.point or "CENTER", UIParent, uiConfig.point or "CENTER",
		uiConfig.x or 0, uiConfig.y or 0)
	self.frame:SetSize(
		math.max(MIN_WIDTH, uiConfig.width or FRAME_WIDTH),
		math.max(MIN_HEIGHT, uiConfig.height or FRAME_HEIGHT))
	self.frame:SetScale(uiConfig.scale or 1)
end

function UI:Show()
	local frame = self:CreateFrame()
	frame:Show()
	-- Les filtres persistés doivent se refléter dans les widgets.
	local filters = ns.db.profile.filters
	local page = frame.CollectionPage
	page.SearchBox:SetText(filters.search or "")
	page.ShowOwned:SetChecked(filters.showOwned)
	page.HideExcluded:SetChecked(filters.hideExcluded)
	self:SelectTab(ns.db.profile.ui.activeTab or self.TAB_DASHBOARD)
end

function UI:Hide()
	if self.frame then self.frame:Hide() end
end

function UI:Toggle()
	if self.frame and self.frame:IsShown() then
		self:Hide()
	else
		self:Show()
	end
end
