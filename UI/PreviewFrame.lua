--[[---------------------------------------------------------------------------
	OnlyFarm — UI/PreviewFrame.lua

	Aperçu 3D d'une monture, ouvert par un clic gauche sur une ligne.

	Choix technique : une frame `PlayerModel` avec `SetDisplayInfo`, et non le
	`ModelScene` du Journal des montures de Blizzard. Le ModelScene donne un
	rendu plus riche (monture + joueur, animations, caméra scriptée) mais
	demande un template XML, des acteurs nommés et des constantes de caméra —
	beaucoup de surface non testable hors du jeu. `PlayerModel:SetDisplayInfo`
	est une API stable depuis des années et tient en dix lignes.

	À rebasculer vers ModelScene en phase 4 si l'aperçu mérite mieux.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Preview = ns:NewModule("Preview", 82)

local WIDTH, HEIGHT = 280, 360

function Preview:OnEnable()
	-- Une monture obtenue en cours de route n'a plus à être prévisualisée.
	self:RegisterMessage("OF_COLLECTION_UPDATED", "OnCollectionUpdated")
end

function Preview:OnCollectionUpdated()
	if self.frame and self.frame:IsShown() and self.mountID then
		if ns.Collection:IsOwned(self.mountID) then self:Hide() end
	end
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

function Preview:Create()
	if self.frame then return self.frame end

	local Theme = ns.Theme

	local frame = CreateFrame("Frame", "OnlyFarmPreviewFrame", UIParent)
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetFrameStrata("HIGH")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetClampedToScreen(true)
	frame:Hide()

	Theme.Fill(frame, Theme.colors.bg)
	Theme.Border(frame, Theme.colors.border)

	local titleBar = CreateFrame("Frame", nil, frame)
	titleBar:SetPoint("TOPLEFT")
	titleBar:SetPoint("TOPRIGHT")
	titleBar:SetHeight(28)
	Theme.Fill(titleBar, Theme.colors.panel)

	local rule = Theme.Separator(titleBar)
	rule:SetPoint("BOTTOMLEFT")
	rule:SetPoint("BOTTOMRIGHT")

	local title = Theme.Text(titleBar, "GameFontNormal", Theme.colors.text)
	title:SetPoint("LEFT", 10, 0)
	title:SetPoint("RIGHT", -28, 0)
	title:SetWordWrap(false)
	frame.Title = title

	local close = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
	close:SetSize(24, 24)
	close:SetPoint("RIGHT", -2, 0)
	close:SetScript("OnClick", function() Preview:Hide() end)

	local parent = frame

	local model = CreateFrame("PlayerModel", nil, parent)
	model:SetPoint("TOPLEFT", 6, -34)
	model:SetPoint("BOTTOMRIGHT", -6, 58)
	model:EnableMouse(true)
	model:EnableMouseWheel(true)

	-- Rotation à la souris : on suit le déplacement horizontal du curseur.
	model:SetScript("OnMouseDown", function(self_, button)
		if button ~= "LeftButton" then return end
		self_.rotating = true
		self_.cursorStart = select(1, GetCursorPosition())
		self_.facingStart = self_:GetFacing() or 0
	end)
	model:SetScript("OnMouseUp", function(self_) self_.rotating = false end)
	model:SetScript("OnUpdate", function(self_)
		if not self_.rotating then return end
		local cursorX = select(1, GetCursorPosition())
		self_:SetFacing((self_.facingStart or 0)
			+ (cursorX - (self_.cursorStart or cursorX)) * 0.012)
	end)
	model:SetScript("OnMouseWheel", function(self_, delta)
		local scale = (self_.zoom or 1) - delta * 0.1
		scale = math.max(0.4, math.min(3, scale))
		self_.zoom = scale
		if self_.SetCamDistanceScale then pcall(self_.SetCamDistanceScale, self_, scale) end
	end)
	frame.Model = model

	local sourceText = Theme.Text(parent, "GameFontHighlightSmall", Theme.colors.muted)
	sourceText:SetPoint("BOTTOMLEFT", 10, 30)
	sourceText:SetPoint("BOTTOMRIGHT", -10, 30)
	sourceText:SetHeight(36)
	frame.SourceText = sourceText

	local hint = Theme.Text(parent, "GameFontHighlightSmall", Theme.colors.faint)
	hint:SetPoint("BOTTOMLEFT", 10, 9)
	hint:SetText(ns.L.PREVIEW_HINT)
	frame.Hint = hint

	self.frame = frame
	return frame
end

--------------------------------------------------------------------------------
-- Affichage
--------------------------------------------------------------------------------

--- Identifiant d'affichage de la créature, avec repli.
--  GetMountInfoExtraByID le renvoie en premier, mais il est marqué Nilable :
--  certaines montures n'en ont pas et il faut passer par la liste complète.
local function ResolveDisplayID(mountID)
	local displayID = C_MountJournal.GetMountInfoExtraByID(mountID)
	if type(displayID) == "number" and displayID > 0 then return displayID end

	if C_MountJournal.GetMountAllCreatureDisplayInfoByID then
		local ok, all = pcall(C_MountJournal.GetMountAllCreatureDisplayInfoByID, mountID)
		if ok and type(all) == "table" then
			for _, info in ipairs(all) do
				if info.creatureDisplayID and info.creatureDisplayID > 0 then
					return info.creatureDisplayID
				end
			end
		end
	end
	return nil
end

function Preview:Show(mountID)
	local entry = ns.Collection:GetEntry(mountID)
	if not entry then return end

	local frame = self:Create()
	self.mountID = mountID

	frame.Title:SetText(entry.name)

	frame:ClearAllPoints()
	local anchor = ns.UI.frame
	if anchor and anchor:IsShown() then
		frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, 0)
	else
		frame:SetPoint("CENTER")
	end

	local model = frame.Model
	model.zoom = 1
	model:ClearModel()

	local displayID = ResolveDisplayID(mountID)
	if displayID then
		pcall(model.SetDisplayInfo, model, displayID)
		model:SetFacing(0.4)
		model:Show()
		frame.SourceText:SetText(ns.Collection:GetSourceSummary(mountID) or "")
	else
		-- Pas de modèle disponible : on le dit, plutôt que d'afficher un carré
		-- noir qui ressemble à un bug.
		model:Hide()
		frame.SourceText:SetText(ns.Theme.Colorize(ns.Theme.colors.faint, ns.L.PREVIEW_NONE))
	end

	frame:Show()
end

function Preview:Hide()
	if self.frame then self.frame:Hide() end
	self.mountID = nil
end

--- Clic gauche sur la ligne déjà affichée : on referme.
function Preview:Toggle(mountID)
	if self.frame and self.frame:IsShown() and self.mountID == mountID then
		self:Hide()
	else
		self:Show(mountID)
	end
end
