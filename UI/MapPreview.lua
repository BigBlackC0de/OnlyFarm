--[[---------------------------------------------------------------------------
	OnlyFarm — UI/MapPreview.lua

	Un aperçu de carte de zone, avec une épingle. « Où est cette entrée ? »,
	répondu en montrant l'endroit plutôt qu'en donnant deux nombres.

	POURQUOI PAS LA CARTE DU MONDE DE BLIZZARD

	`WorldMapFrame` est un MapCanvas complet : couches de pins, zoom, panoramique,
	et un seul exemplaire à l'écran. En embarquer un second dans notre fenêtre
	demande de reprendre tout son cycle de vie, et casse à chaque refonte de la
	carte par Blizzard.

	On dessine donc la carte nous-mêmes, avec les mêmes textures qu'elle :

	  C_Map.GetMapArtLayers(uiMapID)        -> les couches, avec leur pavage
	  C_Map.GetMapArtLayerTextures(id, 1)   -> les fileID des pavés, en ligne

	Les pavés se posent en grille. Le dernier de chaque ligne et de chaque colonne
	est ROGNÉ : la couche ne fait presque jamais un multiple entier de la taille
	de pavé, et l'afficher entier étirerait la carte. C'est le seul piège de la
	méthode, et c'est celui que ce fichier traite avec le plus de soin.

	Une carte non disponible n'est pas une erreur : les cartes d'intérieur
	d'instance n'en ont pas. L'aperçu affiche alors le nom du lieu, ce qui reste
	une réponse.
-----------------------------------------------------------------------------]]

local _, ns = ...

local MapPreview = {}
ns.MapPreview = MapPreview

local PIN_SIZE = 16

--- Crée un aperçu. Le frame renvoyé porte `:SetTarget(uiMapID, x, y, label)`.
function MapPreview.Create(parent)
	local Theme = ns.Theme

	local frame = CreateFrame("Frame", nil, parent)
	frame:SetClipsChildren(true)

	-- Fond sombre : il se voit sur les bords, une carte ne remplissant jamais
	-- exactement un cadre dont on ne choisit pas les proportions.
	Theme.Fill(frame, Theme.colors.bg)

	-- Zone de dessin de la carte, centrée et aux proportions de la couche.
	local canvas = CreateFrame("Frame", nil, frame)
	canvas:SetPoint("CENTER")
	canvas:SetSize(1, 1)
	frame.Canvas = canvas

	frame.tiles = {}

	-- Épingle : un losange plein bordé de blanc, dessiné par-dessus les pavés.
	-- La texture de repère de Blizzard est une pièce d'or qui jurerait ici.
	local pin = CreateFrame("Frame", nil, canvas)
	pin:SetSize(PIN_SIZE, PIN_SIZE)
	pin:SetFrameLevel(canvas:GetFrameLevel() + 10)
	pin.Halo = pin:CreateTexture(nil, "OVERLAY")
	pin.Halo:SetAllPoints()
	pin.Halo:SetColorTexture(1, 1, 1, 0.35)
	pin.Dot = pin:CreateTexture(nil, "OVERLAY")
	pin.Dot:SetPoint("CENTER")
	pin.Dot:SetSize(PIN_SIZE - 6, PIN_SIZE - 6)
	local accent = Theme.colors.red
	pin.Dot:SetColorTexture(accent[1], accent[2], accent[3], 1)
	pin:Hide()
	frame.Pin = pin

	frame.Label = Theme.Text(frame, "GameFontHighlightSmall", Theme.colors.muted, "CENTER")
	frame.Label:SetPoint("BOTTOM", 0, 6)
	frame.Label:SetPoint("LEFT", 6, 0)
	frame.Label:SetPoint("RIGHT", -6, 0)
	frame.Label:SetWordWrap(false)

	frame.Fallback = Theme.Text(frame, "GameFontHighlightSmall", Theme.colors.faint, "CENTER")
	frame.Fallback:SetPoint("CENTER")
	frame.Fallback:SetPoint("LEFT", 12, 0)
	frame.Fallback:SetPoint("RIGHT", -12, 0)
	frame.Fallback:Hide()

	-- La taille du cadre vaut zéro à la construction : tout le placement dépend
	-- d'elle, donc on redessine dès qu'elle change.
	frame:SetScript("OnSizeChanged", function(self_)
		if self_.target then
			self_:SetTarget(self_.target.uiMapID, self_.target.x, self_.target.y,
				self_.target.label)
		end
	end)

	frame.SetTarget = MapPreview.SetTarget
	frame.Clear = MapPreview.Clear
	return frame
end

function MapPreview.Clear(frame)
	frame.target = nil
	for _, tile in ipairs(frame.tiles) do tile:Hide() end
	frame.Pin:Hide()
	frame.Label:SetText("")
	frame.Fallback:Hide()
end

--- Affiche la carte `uiMapID` avec une épingle en (x, y) normalisés.
function MapPreview.SetTarget(frame, uiMapID, x, y, label)
	frame.target = { uiMapID = uiMapID, x = x, y = y, label = label }
	frame.Label:SetText(label or "")

	for _, tile in ipairs(frame.tiles) do tile:Hide() end
	frame.Pin:Hide()

	local layer, textures = MapPreview.GetArt(uiMapID)
	local width, height = frame:GetWidth() or 0, frame:GetHeight() or 0

	if not layer or not textures or width <= 1 or height <= 1 then
		-- Sans art de carte, on dit où c'est avec des mots. Une zone vide et
		-- muette se lirait comme une panne.
		frame.Fallback:SetText(label or ns.L.ROUTE_NO_MAP)
		frame.Fallback:Show()
		frame.Label:SetText("")
		return
	end
	frame.Fallback:Hide()

	-- Réserve la place du libellé en bas : la carte ne doit pas passer dessous.
	local usableHeight = math.max(1, height - 20)
	local scale = math.min(width / layer.layerWidth, usableHeight / layer.layerHeight)

	local canvas = frame.Canvas
	canvas:SetSize(layer.layerWidth * scale, layer.layerHeight * scale)
	-- Décalé vers le haut de la moitié de la bande du libellé, pour que la carte
	-- reste centrée dans ce qui lui revient.
	canvas:ClearAllPoints()
	canvas:SetPoint("CENTER", frame, "CENTER", 0, 10)

	local columns = math.ceil(layer.layerWidth / layer.tileWidth)
	local rows = math.ceil(layer.layerHeight / layer.tileHeight)

	-- Reste de la dernière colonne et de la dernière ligne. Zéro veut dire que la
	-- couche tombe pile, donc que le pavé est entier.
	local lastColumnWidth = layer.layerWidth - (columns - 1) * layer.tileWidth
	local lastRowHeight = layer.layerHeight - (rows - 1) * layer.tileHeight

	for index, fileID in ipairs(textures) do
		local column = (index - 1) % columns + 1
		local row = math.floor((index - 1) / columns) + 1
		if row <= rows then
			local tile = frame.tiles[index]
			if not tile then
				tile = canvas:CreateTexture(nil, "ARTWORK")
				frame.tiles[index] = tile
			end

			local tileWidth = (column == columns) and lastColumnWidth or layer.tileWidth
			local tileHeight = (row == rows) and lastRowHeight or layer.tileHeight

			-- Le pavé rogné n'affiche qu'une fraction de sa texture : sans ces
			-- coordonnées, la dernière colonne écraserait toute l'image dans un
			-- espace plus étroit qu'elle.
			tile:SetTexture(fileID)
			tile:SetTexCoord(0, tileWidth / layer.tileWidth, 0, tileHeight / layer.tileHeight)
			tile:SetSize(tileWidth * scale, tileHeight * scale)
			tile:ClearAllPoints()
			tile:SetPoint("TOPLEFT", canvas, "TOPLEFT",
				(column - 1) * layer.tileWidth * scale,
				-(row - 1) * layer.tileHeight * scale)
			tile:Show()
		end
	end

	if type(x) == "number" and type(y) == "number" then
		frame.Pin:ClearAllPoints()
		frame.Pin:SetPoint("CENTER", canvas, "TOPLEFT",
			x * canvas:GetWidth(), -y * canvas:GetHeight())
		frame.Pin:Show()
	end
end

--- Première couche d'art d'une carte et ses pavés.
--  @return layerInfo, liste de fileID — ou nil si la carte n'a pas d'art
function MapPreview.GetArt(uiMapID)
	if type(uiMapID) ~= "number" then return nil end
	if not C_Map or type(C_Map.GetMapArtLayers) ~= "function" then return nil end

	local ok, layers = pcall(C_Map.GetMapArtLayers, uiMapID)
	if not ok or type(layers) ~= "table" or not layers[1] then return nil end

	local layer = layers[1]
	if type(layer.layerWidth) ~= "number" or type(layer.tileWidth) ~= "number"
		or layer.tileWidth <= 0 or layer.tileHeight <= 0
	then
		return nil
	end

	local okTextures, textures = pcall(C_Map.GetMapArtLayerTextures, uiMapID, 1)
	if not okTextures or type(textures) ~= "table" or #textures == 0 then return nil end

	return layer, textures
end
