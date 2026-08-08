--[[---------------------------------------------------------------------------
	OnlyFarm — UI/MinimapButton.lua

	Bouton sur l'anneau de la minicarte, déplaçable.

	Écrit à la main plutôt qu'avec LibDBIcon-1.0 : la phase 1 n'embarque aucune
	bibliothèque, et le besoin tient en un angle sauvegardé et un peu de
	trigonométrie. La bascule vers LibDBIcon reste possible plus tard sans rien
	casser — c'est le même modèle (un angle en degrés dans les réglages).
-----------------------------------------------------------------------------]]

local _, ns = ...

local MinimapButton = ns:NewModule("MinimapButton", 85)

local BUTTON_SIZE = 31

-- Écart entre le bord VISIBLE de l'icône et le bord de la minicarte.
--
-- Deux pièges empilés ici, et le second a survécu à la première correction :
--
-- 1. Ne pas coder le rayon en dur. La minicarte de retail fait 198 px de côté
--    (Blizzard_Minimap/Mainline/Minimap.xml), pas les 140 px de l'époque où le
--    « rayon 80 » de LibDBIcon a été écrit.
-- 2. Le rayon positionne le CENTRE du bouton, pas son bord. Poser ce centre à
--    « bord de la minicarte + 10 » laisse encore la moitié de l'icône (15 px)
--    à l'intérieur du cadre — c'est le placement classique de LibDBIcon, où le
--    bouton chevauche l'anneau. Pour qu'il soit franchement dehors, il faut
--    décaler du rayon de l'icône EN PLUS de l'écart voulu.
local RING_GAP = 3

function MinimapButton:OnEnable()
	if not Minimap then
		self:Debug("pas de minicarte, bouton ignoré")
		return
	end
	self:Create()
	self:UpdatePosition()
	self:RegisterMessage("OF_COLLECTION_UPDATED", "RefreshTooltip")
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

function MinimapButton:Create()
	if self.button then return self.button end

	local button = CreateFrame("Button", "OnlyFarmMinimapButton", Minimap)
	button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(Minimap:GetFrameLevel() + 8)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetMovable(true)

	-- Icône, découpée en rond pour tenir dans la bordure Blizzard.
	local icon = button:CreateTexture(nil, "BACKGROUND")
	icon:SetSize(20, 20)
	icon:SetPoint("CENTER", -1, 1)
	icon:SetTexture(ns.MINIMAP_TEXTURE)
	icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
	button.Icon = icon

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	button.Border = border

	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	button:SetScript("OnDragStart", function(self_)
		self_.isDragging = true
		self_:SetScript("OnUpdate", function() MinimapButton:FollowCursor() end)
	end)
	button:SetScript("OnDragStop", function(self_)
		self_.isDragging = false
		self_:SetScript("OnUpdate", nil)
	end)

	button:SetScript("OnClick", function(_, mouseButton)
		if mouseButton == "RightButton" then
			ns.Collection:Scan()
			ns.Lockouts.lastRequest = 0
			ns.Lockouts:RequestScan()
			ns:Print(ns.L.MINIMAP_RESCANNED)
		else
			ns.UI:Toggle()
		end
	end)

	button:SetScript("OnEnter", function(self_) MinimapButton:ShowTooltip(self_) end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)

	self.button = button
	return button
end

--------------------------------------------------------------------------------
-- Position sur l'anneau
--------------------------------------------------------------------------------

--- Rayon de l'anneau, recalculé à chaque positionnement : un addon qui
--  redimensionne la minicarte est ainsi suivi sans réglage.
local function RingRadius()
	local width = Minimap:GetWidth()
	if not width or width <= 0 then width = 198 end   -- taille de retail 12.x
	return (width / 2) + (BUTTON_SIZE / 2) + RING_GAP
end

function MinimapButton:UpdatePosition()
	local button = self.button
	if not button or not ns.db then return end

	local config = ns.db.profile.minimap
	button:SetShown(not config.hide)

	local radius = RingRadius()
	local angle = math.rad(config.angle or 205)
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER",
		math.cos(angle) * radius,
		math.sin(angle) * radius)
end

--- Recalcule l'angle depuis la position du curseur pendant un glisser.
function MinimapButton:FollowCursor()
	local centerX, centerY = Minimap:GetCenter()
	if not centerX then return end

	local scale = Minimap:GetEffectiveScale()
	local cursorX, cursorY = GetCursorPosition()
	cursorX, cursorY = cursorX / scale, cursorY / scale

	local angle = math.deg(math.atan2(cursorY - centerY, cursorX - centerX))
	ns.db.profile.minimap.angle = angle
	self:UpdatePosition()
end

function MinimapButton:SetHidden(hidden)
	if not ns.db then return end
	ns.db.profile.minimap.hide = hidden and true or false
	self:UpdatePosition()
end

--------------------------------------------------------------------------------
-- Infobulle
--------------------------------------------------------------------------------

function MinimapButton:ShowTooltip(owner)
	local L = ns.L
	GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
	GameTooltip:AddLine("OnlyFarm", 1, 1, 1)

	if ns.Collection.ready then
		local counts = ns.Collection.counts
		GameTooltip:AddLine(L.SUMMARY:format(counts.owned, counts.total, counts.missing),
			0.8, 0.8, 0.8)
	else
		GameTooltip:AddLine(L.JOURNAL_NOT_READY, 0.8, 0.8, 0.8)
	end

	local hour, day = ns.Lockouts:GetInstanceCounts()
	GameTooltip:AddLine(L.INSTANCE_COUNTER:format(hour, 10, day, 30), 0.6, 0.8, 1)

	GameTooltip:AddLine(" ")
	GameTooltip:AddLine(L.MINIMAP_LEFT, 0.6, 0.6, 0.6)
	GameTooltip:AddLine(L.MINIMAP_RIGHT, 0.6, 0.6, 0.6)
	GameTooltip:Show()
end

function MinimapButton:RefreshTooltip()
	if self.button and GameTooltip:IsOwned(self.button) then
		self:ShowTooltip(self.button)
	end
end
