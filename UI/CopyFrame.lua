--[[---------------------------------------------------------------------------
	OnlyFarm — UI/CopyFrame.lua

	Fenêtre de texte sélectionnable.

	Le client n'a pas de presse-papiers accessible aux addons : impossible de
	copier quoi que ce soit par script. Le seul chemin est une zone de saisie
	remplie par nos soins, que le joueur sélectionne et copie lui-même.

	Ça sert d'abord au diagnostic : recopier vingt lignes de chat à la main pour
	les envoyer à quelqu'un est un travail idiot, et un screenshot ne se lit pas
	à la machine. Ça resservira en phase 5 pour l'import/export de routes, qui a
	exactement le même besoin.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Copy = ns:NewModule("Copy", 84)

local WIDTH, HEIGHT = 620, 420

function Copy:Create()
	if self.frame then return self.frame end
	local Theme = ns.Theme

	local frame = CreateFrame("Frame", "OnlyFarmCopyFrame", UIParent)
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:SetClampedToScreen(true)
	frame:Hide()

	Theme.Fill(frame, Theme.colors.bg)
	Theme.Border(frame, Theme.colors.border)

	tinsert(UISpecialFrames, "OnlyFarmCopyFrame")

	local titleBar = CreateFrame("Frame", nil, frame)
	titleBar:SetPoint("TOPLEFT")
	titleBar:SetPoint("TOPRIGHT")
	titleBar:SetHeight(30)
	titleBar:EnableMouse(true)
	titleBar:RegisterForDrag("LeftButton")
	titleBar:SetScript("OnDragStart", function() frame:StartMoving() end)
	titleBar:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
	Theme.Fill(titleBar, Theme.colors.panel)

	local rule = Theme.Separator(titleBar)
	rule:SetPoint("BOTTOMLEFT")
	rule:SetPoint("BOTTOMRIGHT")

	local title = Theme.Text(titleBar, "GameFontNormal", Theme.colors.text)
	title:SetPoint("LEFT", 10, 0)
	frame.Title = title

	local close = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
	close:SetPoint("RIGHT", -2, 0)
	close:SetScript("OnClick", function() frame:Hide() end)

	local hint = Theme.Text(frame, "GameFontHighlightSmall", Theme.colors.faint, "CENTER")
	hint:SetPoint("BOTTOMLEFT", 10, 8)
	hint:SetPoint("BOTTOMRIGHT", -10, 8)
	hint:SetText(ns.L.COPY_HINT)

	-- Zone de texte défilante. L'EditBox doit être l'enfant défilant, pas un
	-- enfant du cadre : sinon le contenu long est coupé au lieu de défiler.
	local scroll = CreateFrame("ScrollFrame", "OnlyFarmCopyScroll", frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 10, -38)
	scroll:SetPoint("BOTTOMRIGHT", -30, 28)

	local editBox = CreateFrame("EditBox", nil, scroll)
	editBox:SetMultiLine(true)
	editBox:SetAutoFocus(false)
	editBox:SetFontObject("ChatFontNormal")
	editBox:SetWidth(WIDTH - 56)
	editBox:SetScript("OnEscapePressed", function() frame:Hide() end)
	-- Le texte ne doit pas pouvoir être modifié par mégarde : on annule toute
	-- frappe en restaurant le contenu d'origine.
	editBox:SetScript("OnTextChanged", function(box, userInput)
		if userInput and box.originalText then
			box:SetText(box.originalText)
			box:HighlightText()
		end
	end)
	scroll:SetScrollChild(editBox)
	frame.EditBox = editBox

	self.frame = frame
	return frame
end

--- Ouvre la fenêtre sur un texte donné, déjà sélectionné.
function Copy:Show(title, text)
	local frame = self:Create()
	frame.Title:SetText(title or ns.L.COPY_TITLE)
	frame:ClearAllPoints()
	frame:SetPoint("CENTER")

	local editBox = frame.EditBox
	editBox.originalText = text or ""
	editBox:SetText(editBox.originalText)
	frame:Show()

	-- La sélection immédiate évite au joueur d'avoir à viser : Ctrl+C suffit.
	editBox:SetFocus()
	editBox:HighlightText()
end

--- Ouvre la fenêtre sur une liste de lignes.
function Copy:ShowLines(title, lines)
	self:Show(title, table.concat(lines, "\n"))
end
