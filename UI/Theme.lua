--[[---------------------------------------------------------------------------
	OnlyFarm — UI/Theme.lua

	Palette et briques visuelles. Tout ce qui se dessine dans l'addon passe par
	ici : un seul endroit à changer pour changer l'allure.

	Parti pris : on abandonne le parchemin de Blizzard pour un fond sombre à
	cartes, dans l'esprit d'un tableau de bord type Grafana. Deux raisons, et
	aucune n'est décorative :

	  * l'information de cet addon est chiffrée (des compteurs, des ratios, des
	    barres de progression). Sur fond de parchemin, un chiffre coloré est
	    illisible ; sur fond sombre, la couleur porte du sens ;
	  * la couleur devient un code cohérent — vert disponible, rouge verrouillé,
	    ambre incertain, gris hors de portée — au lieu d'être réinventée à
	    chaque écran.

	Contrainte technique : le client n'a pas de primitive « rectangle arrondi ».
	Tout est donc à angles droits, ce qui tombe bien, c'est aussi le genre de la
	maison côté tableaux de bord.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Theme = {}
ns.Theme = Theme

--------------------------------------------------------------------------------
-- Palette
--------------------------------------------------------------------------------

Theme.colors = {
	bg      = { 0.078, 0.086, 0.102 },  -- fond de fenêtre
	panel   = { 0.110, 0.121, 0.145 },  -- fond de zone
	card    = { 0.145, 0.159, 0.188 },  -- carte (KPI, graphe)
	cardHi  = { 0.184, 0.200, 0.235 },  -- carte survolée
	border  = { 0.216, 0.235, 0.278 },
	line    = { 0.169, 0.184, 0.216 },  -- séparateurs, alternance de lignes

	text    = { 0.902, 0.914, 0.937 },
	muted   = { 0.529, 0.573, 0.647 },
	faint   = { 0.361, 0.396, 0.459 },

	accent  = { 0.478, 0.757, 1.000 },  -- le bleu du logo
	green   = { 0.251, 0.831, 0.494 },
	red     = { 0.949, 0.329, 0.357 },
	amber   = { 1.000, 0.706, 0.329 },
	purple  = { 0.706, 0.612, 0.902 },
}

--- Couleur d'un statut d'éligibilité. Un seul endroit décide, pour que la
--  pastille d'une ligne, la barre du tableau de bord et la légende disent
--  toutes la même chose.
Theme.STATE_COLORS = {
	available   = Theme.colors.green,
	locked      = Theme.colors.red,
	unknown     = Theme.colors.amber,
	unmapped    = Theme.colors.faint,
	ineligible  = Theme.colors.faint,
}

-- Texture blanche unie de Blizzard : la brique de tout ce qui est aplat.
Theme.WHITE = "Interface\\Buttons\\WHITE8X8"

--- « |cff7ac1ff…|r » à partir d'une couleur de la palette.
function Theme.Hex(color)
	return string.format("|cff%02x%02x%02x",
		math.floor(color[1] * 255 + 0.5),
		math.floor(color[2] * 255 + 0.5),
		math.floor(color[3] * 255 + 0.5))
end

function Theme.Colorize(color, text)
	return Theme.Hex(color) .. tostring(text) .. "|r"
end

--------------------------------------------------------------------------------
-- Aplats et bordures
--------------------------------------------------------------------------------

--- Fond uni couvrant tout le parent.
function Theme.Fill(frame, color, alpha)
	local texture = frame:CreateTexture(nil, "BACKGROUND")
	texture:SetAllPoints()
	texture:SetColorTexture(color[1], color[2], color[3], alpha or 1)
	return texture
end

--- Bordure d'un pixel, dessinée en quatre traits. Une texture de bordure
--  étirée baverait aux angles à cette épaisseur.
function Theme.Border(frame, color, alpha)
	local edges = {}
	local sides = {
		{ "TOPLEFT", "TOPRIGHT", 0, 0, 0, 1 },
		{ "BOTTOMLEFT", "BOTTOMRIGHT", 0, 0, 0, 1 },
		{ "TOPLEFT", "BOTTOMLEFT", 0, 0, 1, 0 },
		{ "TOPRIGHT", "BOTTOMRIGHT", 0, 0, 1, 0 },
	}
	for i, side in ipairs(sides) do
		local edge = frame:CreateTexture(nil, "BORDER")
		edge:SetColorTexture(color[1], color[2], color[3], alpha or 1)
		edge:SetPoint(side[1])
		edge:SetPoint(side[2])
		if side[5] == 1 then edge:SetWidth(1) else edge:SetHeight(1) end
		edges[i] = edge
	end
	return edges
end

--- Carte : fond + bordure, la brique de tout le tableau de bord.
function Theme.Card(parent, color)
	local card = CreateFrame("Frame", nil, parent)
	card.Background = Theme.Fill(card, color or Theme.colors.card)
	card.Edges = Theme.Border(card, Theme.colors.border)
	return card
end

--- Trait de séparation horizontal.
function Theme.Separator(parent)
	local line = parent:CreateTexture(nil, "ARTWORK")
	line:SetHeight(1)
	local c = Theme.colors.border
	line:SetColorTexture(c[1], c[2], c[3], 1)
	return line
end

--------------------------------------------------------------------------------
-- Textes
--------------------------------------------------------------------------------

function Theme.Text(parent, template, color, justify)
	local text = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlightSmall")
	local c = color or Theme.colors.text
	text:SetTextColor(c[1], c[2], c[3])
	text:SetJustifyH(justify or "LEFT")
	return text
end

--------------------------------------------------------------------------------
-- Tuile de statistique
--
--   ┌──────────────┐
--   │ 412          │  valeur, grosse
--   │ possédées    │  libellé, petit et discret
--   │ ▁▁▁▁▁▁▔▔▔▔   │  barre facultative
--   └──────────────┘
--------------------------------------------------------------------------------

function Theme.StatTile(parent, label, accent)
	local tile = Theme.Card(parent)

	tile.Value = Theme.Text(tile, "GameFontNormalLarge", accent or Theme.colors.text)
	tile.Value:SetPoint("TOPLEFT", 10, -8)

	tile.Label = Theme.Text(tile, "GameFontHighlightSmall", Theme.colors.muted)
	tile.Label:SetPoint("TOPLEFT", tile.Value, "BOTTOMLEFT", 0, -2)
	tile.Label:SetText(label)

	tile.Detail = Theme.Text(tile, "GameFontHighlightSmall", Theme.colors.faint)
	tile.Detail:SetPoint("BOTTOMRIGHT", -10, 8)
	tile.Detail:SetJustifyH("RIGHT")

	function tile:Set(value, detail)
		self.Value:SetText(value)
		self.Detail:SetText(detail or "")
	end

	return tile
end

--------------------------------------------------------------------------------
-- Barre de progression
--------------------------------------------------------------------------------

--- Barre simple avec fond, remplissage coloré et libellé optionnel.
function Theme.Bar(parent, color)
	local bar = CreateFrame("StatusBar", nil, parent)
	bar:SetStatusBarTexture(Theme.WHITE)
	local c = color or Theme.colors.accent
	bar:SetStatusBarColor(c[1], c[2], c[3])
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)

	local track = bar:CreateTexture(nil, "BACKGROUND")
	track:SetAllPoints()
	local t = Theme.colors.line
	track:SetColorTexture(t[1], t[2], t[3], 1)
	bar.Track = track

	function bar:SetRatio(value, total)
		total = total or 0
		local ratio = total > 0 and (value / total) or 0
		self:SetValue(math.max(0, math.min(1, ratio)))
		return ratio
	end

	return bar
end

--------------------------------------------------------------------------------
-- Barre empilée
--
-- Une seule barre découpée en segments colorés : disponible / verrouillé /
-- incertain / non cartographié. Plus lisible qu'un camembert, et surtout
-- dessinable sans art dédié.
--------------------------------------------------------------------------------

function Theme.StackedBar(parent)
	local frame = CreateFrame("Frame", nil, parent)
	Theme.Fill(frame, Theme.colors.line)
	frame.segments = {}

	-- Les segments sont calculés en pixels à partir de la largeur réelle. Or
	-- cette largeur vaut encore zéro au premier rafraîchissement, tant que le
	-- client n'a pas résolu les ancrages : sans ce rappel, la barre restait
	-- vide jusqu'au prochain événement.
	frame:SetScript("OnSizeChanged", function(self_)
		if self_.lastParts then self_:SetParts(self_.lastParts) end
	end)

	--- @param parts liste de { value, color }
	function frame:SetParts(parts)
		self.lastParts = parts
		local total = 0
		for _, part in ipairs(parts) do total = total + (part.value or 0) end

		-- On réutilise les textures : une barre redessinée à chaque
		-- rafraîchissement ne doit pas fabriquer de nouveaux objets.
		for _, segment in ipairs(self.segments) do segment:Hide() end

		if total <= 0 then return end

		local width = self:GetWidth()
		if not width or width <= 0 then return end

		local offset = 0
		for index, part in ipairs(parts) do
			local value = part.value or 0
			if value > 0 then
				local segment = self.segments[index]
				if not segment then
					segment = self:CreateTexture(nil, "ARTWORK")
					self.segments[index] = segment
				end
				local span = (value / total) * width
				segment:ClearAllPoints()
				segment:SetPoint("TOPLEFT", offset, 0)
				segment:SetPoint("BOTTOMLEFT", offset, 0)
				segment:SetWidth(math.max(1, span))
				local c = part.color
				segment:SetColorTexture(c[1], c[2], c[3], 1)
				segment:Show()
				offset = offset + span
			end
		end
	end

	return frame
end

--------------------------------------------------------------------------------
-- Ligne de graphe en barres horizontales
--
--   Ulduar          ████████░░░░░░  12/31
--------------------------------------------------------------------------------

function Theme.BarRow(parent, labelWidth, valueWidth)
	local row = CreateFrame("Frame", nil, parent)

	row.Label = Theme.Text(row, "GameFontHighlightSmall", Theme.colors.text)
	row.Label:SetPoint("LEFT", 0, 0)
	row.Label:SetWidth(labelWidth or 130)
	row.Label:SetWordWrap(false)

	row.Value = Theme.Text(row, "GameFontHighlightSmall", Theme.colors.muted, "RIGHT")
	row.Value:SetPoint("RIGHT", 0, 0)
	row.Value:SetWidth(valueWidth or 64)

	row.Bar = Theme.Bar(row, Theme.colors.accent)
	row.Bar:SetPoint("LEFT", row.Label, "RIGHT", 8, 0)
	row.Bar:SetPoint("RIGHT", row.Value, "LEFT", -8, 0)
	row.Bar:SetHeight(10)

	function row:Set(label, value, total, color)
		self.Label:SetText(label)
		self.Value:SetText(string.format("%d/%d", value, total))
		local ratio = self.Bar:SetRatio(value, total)
		local c = color
		if not c then
			-- Le vert n'est pas gratuit : il récompense une collection bien
			-- avancée. Une extension à peine entamée reste bleue, neutre.
			c = ratio >= 0.999 and Theme.colors.green or Theme.colors.accent
		end
		self.Bar:SetStatusBarColor(c[1], c[2], c[3])
	end

	return row
end

--------------------------------------------------------------------------------
-- Ligne de répartition
--
-- Une BarRow classique dessine un pourcentage : toutes les barres ont la même
-- longueur, seule la part remplie change. C'est ce qu'il faut pour comparer des
-- avancements, et c'est exactement ce qu'il ne faut pas pour montrer une
-- répartition — trois montures possédées sur trois y font une barre pleine, plus
-- longue que cent-vingt sur deux-cents.
--
-- Ici la longueur dessinée porte l'EFFECTIF de la catégorie (rapporté à la plus
-- grosse), et la part remplie porte les possédées. Une seule ligne répond donc à
-- « combien y en a-t-il ? » et « où j'en suis ? ».
--
--   Butin      ██████████░░░░░░░░░░░░   128/312
--   Vendeur    ████░░░░                  21/54
--------------------------------------------------------------------------------

function Theme.ShareRow(parent, labelWidth, valueWidth)
	local row = CreateFrame("Frame", nil, parent)

	row.Label = Theme.Text(row, "GameFontHighlightSmall", Theme.colors.text)
	row.Label:SetPoint("LEFT", 0, 0)
	row.Label:SetWidth(labelWidth or 130)
	row.Label:SetWordWrap(false)

	row.Value = Theme.Text(row, "GameFontHighlightSmall", Theme.colors.muted, "RIGHT")
	row.Value:SetPoint("RIGHT", 0, 0)
	row.Value:SetWidth(valueWidth or 64)

	-- Zone de tracé : c'est elle qui donne la largeur disponible en pixels.
	local plot = CreateFrame("Frame", nil, row)
	plot:SetPoint("LEFT", row.Label, "RIGHT", 8, 0)
	plot:SetPoint("RIGHT", row.Value, "LEFT", -8, 0)
	plot:SetHeight(10)
	row.Plot = plot

	-- Effectif de la catégorie : l'aplat pâle.
	row.Track = plot:CreateTexture(nil, "ARTWORK")
	row.Track:SetPoint("LEFT")
	row.Track:SetHeight(10)

	-- Possédées : l'aplat plein, par-dessus, aligné à gauche.
	row.Fill = plot:CreateTexture(nil, "OVERLAY")
	row.Fill:SetPoint("LEFT")
	row.Fill:SetHeight(10)

	-- La largeur du tracé vaut zéro au premier rafraîchissement, tant que le
	-- client n'a pas résolu les ancrages : sans ce rappel, les barres restent
	-- invisibles jusqu'au prochain événement.
	plot:SetScript("OnSizeChanged", function()
		if row.lastValues then
			row:Set(row.lastValues[1], row.lastValues[2], row.lastValues[3], row.lastValues[4])
		end
	end)

	--- @param owned  possédées dans cette catégorie
	--  @param total  effectif de la catégorie
	--  @param max    plus gros effectif du graphe, pour l'échelle
	function row:Set(label, owned, total, max)
		self.lastValues = { label, owned, total, max }
		self.Label:SetText(label)
		self.Value:SetText(string.format("%d/%d", owned, total))

		local width = self.Plot:GetWidth() or 0
		if width <= 0 then
			self.Track:Hide()
			self.Fill:Hide()
			return
		end

		max = (max and max > 0) and max or math.max(1, total)
		-- Un minimum de deux pixels : une catégorie à une seule monture doit
		-- rester visible à côté d'une catégorie à trois cents.
		local span = math.max(2, (total / max) * width)
		local ratio = total > 0 and (owned / total) or 0

		local c = ratio >= 0.999 and Theme.colors.green or Theme.colors.accent
		self.Track:SetWidth(span)
		self.Track:SetColorTexture(c[1], c[2], c[3], 0.22)
		self.Track:Show()

		if owned > 0 then
			self.Fill:SetWidth(math.max(1, span * ratio))
			self.Fill:SetColorTexture(c[1], c[2], c[3], 1)
			self.Fill:Show()
		else
			self.Fill:Hide()
		end
	end

	return row
end

--------------------------------------------------------------------------------
-- Sélecteur segmenté
--
-- Deux ou trois choix exclusifs, collés, l'actif en évidence. Une liste
-- déroulante pour deux entrées demande un clic de plus pour rien.
--------------------------------------------------------------------------------

--- @param choices  liste { key, label }
--  @param onSelect fonction(key) appelée au clic
function Theme.Segmented(parent, choices, onSelect)
	local frame = CreateFrame("Frame", nil, parent)
	frame:SetHeight(18)
	frame.buttons = {}

	local offset = 0
	for index, choice in ipairs(choices) do
		local button = CreateFrame("Button", nil, frame)
		button:SetHeight(18)
		button.key = choice.key

		button.Background = button:CreateTexture(nil, "BACKGROUND")
		button.Background:SetAllPoints()
		Theme.Border(button, Theme.colors.border)

		button.Text = Theme.Text(button, "GameFontHighlightSmall", Theme.colors.muted, "CENTER")
		button.Text:SetPoint("CENTER")
		button.Text:SetText(choice.label)
		button:SetWidth(button.Text:GetStringWidth() + 20)
		button:SetPoint("LEFT", offset, 0)
		-- Un pixel de recouvrement : les bordures voisines se confondent en un
		-- seul trait, sinon le groupe se lit comme des boutons épars.
		offset = offset + button:GetWidth() - 1

		button:SetScript("OnClick", function(self_)
			frame:SetValue(self_.key)
			if onSelect then onSelect(self_.key) end
		end)
		button:SetScript("OnEnter", function(self_)
			if not self_.active then
				local c = Theme.colors.text
				self_.Text:SetTextColor(c[1], c[2], c[3])
			end
		end)
		button:SetScript("OnLeave", function(self_)
			if not self_.active then
				local c = Theme.colors.muted
				self_.Text:SetTextColor(c[1], c[2], c[3])
			end
		end)

		frame.buttons[index] = button
	end
	frame:SetWidth(math.max(1, offset + 1))

	function frame:SetValue(key)
		self.value = key
		for _, button in ipairs(self.buttons) do
			button.active = (button.key == key)
			local background = button.active and Theme.colors.cardHi or Theme.colors.panel
			button.Background:SetColorTexture(background[1], background[2], background[3], 1)
			local text = button.active and Theme.colors.accent or Theme.colors.muted
			button.Text:SetTextColor(text[1], text[2], text[3])
		end
	end

	return frame
end

--------------------------------------------------------------------------------
-- Pastille de statut
--
-- Un aplat translucide de la couleur du statut, avec le texte dedans. C'est ce
-- qui remplace la colonne « disponible / verrouillé » en texte coloré.
--------------------------------------------------------------------------------

function Theme.Pill(parent)
	local pill = CreateFrame("Frame", nil, parent)
	pill:SetHeight(16)

	pill.Background = pill:CreateTexture(nil, "BACKGROUND")
	pill.Background:SetAllPoints()

	pill.Text = Theme.Text(pill, "GameFontHighlightSmall", Theme.colors.text, "CENTER")
	pill.Text:SetPoint("CENTER")

	function pill:Set(text, color)
		self.Text:SetText(text)
		self.Text:SetTextColor(color[1], color[2], color[3])
		self.Background:SetColorTexture(color[1], color[2], color[3], 0.16)
		self:SetWidth(math.max(48, self.Text:GetStringWidth() + 16))
	end

	return pill
end

--------------------------------------------------------------------------------
-- Bouton plat
--------------------------------------------------------------------------------

function Theme.Button(parent, label, width, height)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(width or 110, height or 22)

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetAllPoints()
	local c = Theme.colors.card
	background:SetColorTexture(c[1], c[2], c[3], 1)
	button.Background = background

	Theme.Border(button, Theme.colors.border)

	button.Text = Theme.Text(button, "GameFontHighlightSmall", Theme.colors.text, "CENTER")
	button.Text:SetPoint("CENTER")
	button.Text:SetText(label)

	button:SetScript("OnEnter", function(self_)
		local hi = Theme.colors.cardHi
		self_.Background:SetColorTexture(hi[1], hi[2], hi[3], 1)
	end)
	button:SetScript("OnLeave", function(self_)
		local base = Theme.colors.card
		self_.Background:SetColorTexture(base[1], base[2], base[3], 1)
	end)

	return button
end
