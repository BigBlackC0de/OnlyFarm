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

	-- Les quatre menus se suivent, chacun ancré au précédent : ajouter ou
	-- retirer un filtre ne demande pas de recalculer des abscisses.
	local anchor = search
	page.ExpansionDropdown = self:CreateExpansionDropdown(filters, anchor)
	anchor = page.ExpansionDropdown or anchor
	page.SourceDropdown = self:CreateSourceDropdown(filters, anchor)
	anchor = page.SourceDropdown or anchor
	page.TypeDropdown = self:CreateTypeDropdown(filters, anchor)
	anchor = page.TypeDropdown or anchor
	page.SortDropdown = self:CreateSortDropdown(filters, anchor)

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

	page.ShowOwned = PlaceFilter(L.FILTER_SHOW_OWNED, "showOwned")
	page.AvailableOnly = PlaceFilter(L.FILTER_AVAILABLE_ONLY, "availableOnly")
	page.HideUnmapped = PlaceFilter(L.FILTER_HIDE_UNMAPPED, "hideUnmapped")
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

	local header = Theme.Text(list, "GameFontHighlightSmall", Theme.colors.faint)
	header:SetPoint("TOPLEFT", 34, -8)
	header:SetText(L.COL_MOUNT)
	-- Les abscisses suivent celles des colonnes d'une ligne : icône (6+18+8),
	-- nom (216+4), source (212+4), type (62+4), essais (46+16).
	local headerSource = Theme.Text(list, "GameFontHighlightSmall", Theme.colors.faint)
	headerSource:SetPoint("LEFT", header, "LEFT", 220, 0)
	headerSource:SetText(L.COL_SOURCE)
	local headerType = Theme.Text(list, "GameFontHighlightSmall", Theme.colors.faint)
	headerType:SetPoint("LEFT", header, "LEFT", 436, 0)
	headerType:SetText(L.COL_TYPE)
	local headerTries = Theme.Text(list, "GameFontHighlightSmall", Theme.colors.faint)
	headerTries:SetPoint("LEFT", header, "LEFT", 502, 0)
	headerTries:SetText(L.COL_TRIES)
	local headerStatus = Theme.Text(list, "GameFontHighlightSmall", Theme.colors.faint)
	headerStatus:SetPoint("LEFT", header, "LEFT", 570, 0)
	headerStatus:SetText(L.COL_STATUS)

	local rule = Theme.Separator(list)
	rule:SetPoint("TOPLEFT", 1, -24)
	rule:SetPoint("TOPRIGHT", -1, -24)

	local scrollBox = CreateFrame("Frame", nil, list, "WowScrollBoxList")
	scrollBox:SetPoint("TOPLEFT", 4, -28)
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

		rootDescription:CreateButton(L.FILTER_EXPANSION_ALL, function()
			wipe(ns.db.profile.filters.kindsHidden)
			self:Refresh()
		end)
		rootDescription:CreateButton(L.FILTER_EXPANSION_NONE, function()
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

--- Menu raid / donjon. Une monture de raid et une monture de donjon ne se
--  farment pas de la même façon : l'une est hebdomadaire et se fait sur tous
--  les alts, l'autre est quotidienne. Les séparer est le tri le plus utile
--  après l'extension.
function UI:CreateTypeDropdown(parent, anchor)
	local L = ns.L
	local dropdown = self:CreateDropdown(parent, "OnlyFarmTypeDropdown", anchor, L.FILTER_TYPE, 118)
	if not dropdown then return nil end

	local choices = {
		{ value = "all", label = L.FILTER_TYPE_ALL },
		{ value = "raid", label = L.FILTER_TYPE_RAID },
		{ value = "dungeon", label = L.FILTER_TYPE_DUNGEON },
		{ value = "outdoor", label = L.FILTER_TYPE_OUTDOOR },
	}

	dropdown:SetupMenu(function(_, rootDescription)
		rootDescription:CreateTitle(L.FILTER_TYPE)
		for _, choice in ipairs(choices) do
			rootDescription:CreateRadio(choice.label,
				function() return ns.db.profile.filters.instanceType == choice.value end,
				function()
					ns.db.profile.filters.instanceType = choice.value
					self:Refresh()
					return MenuResponse.Close
				end)
		end
	end)

	return dropdown
end

--- Menu de tri.
function UI:CreateSortDropdown(parent, anchor)
	local L = ns.L
	local dropdown = self:CreateDropdown(parent, "OnlyFarmSortDropdown", anchor, L.SORT_BY, 126)
	if not dropdown then return nil end

	dropdown:SetupMenu(function(_, rootDescription)
		rootDescription:CreateTitle(L.SORT_BY)
		for _, choice in ipairs(UI.SORTS) do
			rootDescription:CreateRadio(L[choice.label],
				function() return ns.db.profile.filters.sort == choice.value end,
				function()
					ns.db.profile.filters.sort = choice.value
					self:Refresh()
					return MenuResponse.Close
				end)
		end
	end)

	return dropdown
end

--- Menu des extensions.
function UI:CreateExpansionDropdown(parent, anchor)
	local L = ns.L
	local dropdown = self:CreateDropdown(parent, "OnlyFarmExpansionDropdown", anchor,
		L.FILTER_EXPANSION)
	if not dropdown then return nil end

	local function IsShown(name)
		return not ns.db.profile.filters.expansionsHidden[name]
	end
	local function SetShown(name, shown)
		ns.db.profile.filters.expansionsHidden[name] = (not shown) or nil
		self:Refresh()
	end

	dropdown:SetupMenu(function(_, rootDescription)
		rootDescription:CreateTitle(L.FILTER_EXPANSION)

		local expansions = ns.Eligibility:GetKnownExpansions()

		rootDescription:CreateButton(L.FILTER_EXPANSION_ALL, function()
			wipe(ns.db.profile.filters.expansionsHidden)
			self:Refresh()
		end)
		rootDescription:CreateButton(L.FILTER_EXPANSION_NONE, function()
			local hidden = ns.db.profile.filters.expansionsHidden
			for _, expansion in ipairs(expansions) do hidden[expansion.name] = true end
			self:Refresh()
		end)

		for _, expansion in ipairs(expansions) do
			local label = expansion.name
			if label == ns.Eligibility.UNKNOWN_EXPANSION then
				label = L.EXPANSION_UNKNOWN
			end
			rootDescription:CreateCheckbox(label,
				function() return IsShown(expansion.name) end,
				function()
					SetShown(expansion.name, not IsShown(expansion.name))
					return MenuResponse.Refresh
				end)
		end

		-- Sans scan, la seule entrée est « inconnue ». On dit pourquoi plutôt
		-- que de laisser croire à un menu cassé — et si le scan automatique
		-- est justement en train de tourner, on le dit aussi : « lance une
		-- commande » serait un mauvais conseil pendant qu'elle s'exécute.
		if #expansions <= 1 then
			rootDescription:CreateTitle(ns.Mapping.running
				and L.EXPANSION_SCANNING or L.EXPANSION_NEEDS_SCAN)
		end
	end)

	return dropdown
end

--------------------------------------------------------------------------------
-- Lignes
--------------------------------------------------------------------------------

local TYPE_LABELS = { raid = "TYPE_RAID", dungeon = "TYPE_DUNGEON", outdoor = "TYPE_OUTDOOR" }

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

		button.Name = Theme.Text(button, "GameFontHighlightSmall", Theme.colors.text)
		button.Name:SetPoint("LEFT", button.Icon, "RIGHT", 8, 0)
		button.Name:SetWidth(216)
		button.Name:SetWordWrap(false)

		button.Source = Theme.Text(button, "GameFontHighlightSmall", Theme.colors.muted)
		button.Source:SetPoint("LEFT", button.Name, "RIGHT", 4, 0)
		button.Source:SetWidth(212)
		button.Source:SetWordWrap(false)

		button.Type = Theme.Text(button, "GameFontHighlightSmall", Theme.colors.faint)
		button.Type:SetPoint("LEFT", button.Source, "RIGHT", 4, 0)
		button.Type:SetWidth(62)
		button.Type:SetWordWrap(false)

		button.Tries = Theme.Text(button, "GameFontHighlightSmall", Theme.colors.faint, "RIGHT")
		button.Tries:SetPoint("LEFT", button.Type, "RIGHT", 4, 0)
		button.Tries:SetWidth(46)

		button.Pill = Theme.Pill(button)
		button.Pill:SetPoint("LEFT", button.Tries, "RIGHT", 16, 0)

		button.Highlight = button:CreateTexture(nil, "HIGHLIGHT")
		button.Highlight:SetAllPoints()
		button.Highlight:SetColorTexture(1, 1, 1, 0.06)

		button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		button:SetScript("OnEnter", function(row) UI:ShowRowTooltip(row) end)
		button:SetScript("OnLeave", function() GameTooltip:Hide() end)
		button:SetScript("OnClick", function(row, mouseButton)
			if not row.mountID then return end
			if mouseButton == "RightButton" then
				ns.Collection:SetExcluded(row.mountID, not ns.Collection:IsExcluded(row.mountID))
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
	if elementData.excluded then
		local faint = Theme.colors.faint
		button.Name:SetText(elementData.name)
		button.Name:SetTextColor(faint[1], faint[2], faint[3])
		button.Source:SetText(ns.L.TAG_EXCLUDED)
		button.Type:SetText("")
		button.Tries:SetText("")
		button.Pill:Hide()
		button.Icon:SetDesaturated(true)
		button.Icon:SetAlpha(0.4)
	else
		local text = Theme.colors.text
		button.Name:SetText(elementData.name)
		button.Name:SetTextColor(text[1], text[2], text[3])
		button.Source:SetText(elementData.sourceSummary or "")
		button.Type:SetText(elementData.typeLabel or "")
		local tc = elementData.typeColor or Theme.colors.faint
		button.Type:SetTextColor(tc[1], tc[2], tc[3])
		button.Tries:SetText(elementData.triesText or "")
		button.Pill:Set(elementData.statusLabel, elementData.statusColor)
		button.Pill:Show()
		button.Icon:SetDesaturated(false)
		button.Icon:SetAlpha(1)
	end
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
		if source.encounterName and source.encounterName ~= "" then
			GameTooltip:AddDoubleLine(L.TOOLTIP_BOSS, source.encounterName,
				0.6, 0.6, 0.6, 0.9, 0.9, 0.9)
		end
	end

	local status = ns.Eligibility:GetStatus(row.mountID)
	if status.lock and status.lock.difficultyName then
		GameTooltip:AddDoubleLine(L.TOOLTIP_DIFFICULTY, status.lock.difficultyName,
			0.6, 0.6, 0.6, 0.9, 0.9, 0.9)
	end

	local rows, availableCount = ns.Eligibility:GetCharacterAvailability(row.mountID)
	if #rows > 0 then
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
	GameTooltip:AddLine(entry.excluded and L.HINT_INCLUDE or L.HINT_EXCLUDE, 0.5, 0.5, 0.5)
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

local STATE_LABELS = {
	available = "STATUS_AVAILABLE",
	locked = "STATUS_LOCKED",
	unknown = "STATUS_UNKNOWN",
	unmapped = "STATUS_NO_SOURCE_SHORT",
	ineligible = "STATUS_INELIGIBLE",
}

-- Ordre d'urgence, pour le tri par disponibilité : ce qui est jouable
-- maintenant en tête, ce dont on ne sait rien à la fin.
local STATE_RANK = {
	available = 1,
	locked = 2,
	unknown = 3,
	unmapped = 4,
	ineligible = 5,
}

UI.SORTS = {
	{ value = "name", label = "SORT_NAME" },
	{ value = "source", label = "SORT_SOURCE" },
	{ value = "expansion", label = "SORT_EXPANSION" },
	{ value = "status", label = "SORT_STATUS" },
	{ value = "attempts", label = "SORT_ATTEMPTS" },
	{ value = "owned", label = "SORT_OWNED" },
}

--- Comparateurs de tri. Tous retombent sur le nom en cas d'égalité : sans ce
--  départage, l'ordre de deux lignes équivalentes change d'un rafraîchissement
--  à l'autre et la liste paraît instable.
local SORT_FUNCTIONS = {
	name = function(a, b) return a.name < b.name end,

	source = function(a, b)
		if a.kind ~= b.kind then return a.kind < b.kind end
		return a.name < b.name
	end,

	expansion = function(a, b)
		if a.tier ~= b.tier then return a.tier < b.tier end
		return a.name < b.name
	end,

	status = function(a, b)
		if a.rank ~= b.rank then return a.rank < b.rank end
		return a.name < b.name
	end,

	attempts = function(a, b)
		if a.tries ~= b.tries then return a.tries > b.tries end
		return a.name < b.name
	end,

	-- Manquantes d'abord : c'est la question que pose l'addon. Les possédées
	-- suivent, groupées, ce qui revient à trier sur une colonne « possédée
	-- oui / non ».
	owned = function(a, b)
		if a.owned ~= b.owned then return not a.owned end
		return a.name < b.name
	end,
}

--- Libellé et couleur de la pastille d'une ligne.
function UI:StatusVisual(status)
	local L = ns.L
	local Theme = ns.Theme
	local label = L[STATE_LABELS[status.state] or "STATUS_UNKNOWN"] or L.STATUS_UNKNOWN
	local color = Theme.STATE_COLORS[status.state] or Theme.colors.faint

	if status.state == ns.Eligibility.STATE.LOCKED and status.resetIn then
		label = ns.Util.FormatDuration(status.resetIn)
	end
	-- Un personnage pas revu depuis longtemps rend son statut douteux : on
	-- bascule en ambre plutôt que d'afficher un vert qui ment.
	if status.stale and status.state ~= ns.Eligibility.STATE.UNMAPPED then
		color = Theme.colors.amber
	end
	return label, color
end

local function MatchesSearch(entry, needle)
	if needle == "" then return true end
	return entry.name:lower():find(needle, 1, true) ~= nil
end

--- Type d'endroit d'une monture, pour la colonne et le filtre.
--  @return "raid" | "dungeon" | "outdoor"
function UI:GetInstanceType(source)
	if type(source) ~= "table" then return "outdoor" end
	if source.isRaid == true then return "raid" end
	if source.isRaid == false then return "dungeon" end
	return "outdoor"
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

	-- Les possédées ne sont ajoutées que sur demande. Elles n'ont pas de
	-- disponibilité — elles sont acquises — donc les filtres de statut ne
	-- s'appliquent pas à elles ; seuls la recherche, l'extension, la source et
	-- le type les concernent.
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
		if keep and filters.expansionsHidden[ns.Eligibility:GetExpansion(entry.mountID)] then
			keep = false
		end
		if keep and filters.kindsHidden[entry.kind] then keep = false end

		local source, instanceType
		if keep then
			source = ns.Eligibility:GetSource(entry.mountID)
			instanceType = self:GetInstanceType(source)
			if filters.instanceType and filters.instanceType ~= "all"
				and filters.instanceType ~= instanceType
			then
				keep = false
			end
		end

		local status
		if keep and not entry.owned then
			status = ns.Eligibility:GetStatus(entry.mountID)
			if filters.availableOnly and status.state ~= ns.Eligibility.STATE.AVAILABLE then
				keep = false
			end
			if keep and filters.hideUnmapped and status.state == ns.Eligibility.STATE.UNMAPPED then
				keep = false
			end
		end

		if keep then
			local label, color
			if entry.owned then
				label, color = L.STATUS_OWNED, Theme.colors.green
			else
				label, color = self:StatusVisual(status)
			end
			rows[#rows + 1] = {
				mountID = entry.mountID,
				name = entry.name,
				icon = entry.icon,
				kind = entry.kind or "unknown",
				excluded = entry.excluded,
				sourceSummary = ns.Collection:GetSourceSummary(entry.mountID),
				statusLabel = label,
				statusColor = color,
				owned = entry.owned,
				-- Les possédées ferment la marche au tri par disponibilité :
				-- elles ne demandent plus rien.
				rank = entry.owned and 0 or (STATE_RANK[status.state] or 9),
				tries = ns.Attempts:GetCount(entry.mountID),
				-- math.huge pour les extensions inconnues : elles ferment la
				-- marche au tri, comme sur le tableau de bord.
				tier = (source and tonumber(source.tier)) or math.huge,
				typeKey = instanceType,
				typeLabel = ns.L[TYPE_LABELS[instanceType]],
				typeColor = instanceType == "raid" and Theme.colors.purple
					or instanceType == "dungeon" and Theme.colors.accent
					or Theme.colors.faint,
			}
		end
	end

	table.sort(rows, SORT_FUNCTIONS[filters.sort or "name"] or SORT_FUNCTIONS.name)

	local provider = CreateDataProvider()
	for index, row in ipairs(rows) do
		row.index = index
		row.triesText = row.tries > 0 and tostring(row.tries) or "—"
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

	local isPlaceholder = (index == self.TAB_ROUTE or index == self.TAB_EDITOR)
	frame.Placeholder:SetShown(isPlaceholder)
	if isPlaceholder then
		frame.Placeholder.Text:SetText(index == self.TAB_ROUTE
			and ns.L.ROUTE_PLACEHOLDER or ns.L.EDITOR_PLACEHOLDER)
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
	page.AvailableOnly:SetChecked(filters.availableOnly)
	page.HideUnmapped:SetChecked(filters.hideUnmapped)
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
