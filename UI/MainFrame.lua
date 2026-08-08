--[[---------------------------------------------------------------------------
	OptiFarm — UI/MainFrame.lua

	Fenêtre principale. Trois onglets prévus par la spécification ; seul
	« Collection » a du contenu en phase 1, les deux autres annoncent
	honnêtement ce qui arrive plus tard.

	La liste est virtualisée (ScrollBox + ScrollBoxListLinearView) : on
	n'instancie jamais 300 lignes, seulement celles visibles. Les lignes sont
	construites en Lua pur — SetElementInitializer accepte un type de frame et
	pas seulement un template XML, ce qui évite d'avoir à écrire du XML.
-----------------------------------------------------------------------------]]

local _, ns = ...

local UI = ns:NewModule("UI", 80)

local ROW_HEIGHT = 24
local FRAME_WIDTH, FRAME_HEIGHT = 720, 520

function UI:OnEnable()
	self:RegisterMessage("OF_COLLECTION_UPDATED", "Refresh")
	self:RegisterMessage("OF_LOCKOUTS_UPDATED", "Refresh")
	self:RegisterMessage("OF_SCAN_COMPLETE", "Refresh")
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function SetFrameTitle(frame, title)
	-- Le chemin d'accès au titre a changé plusieurs fois entre extensions.
	if frame.SetTitle then
		frame:SetTitle(title)
	elseif frame.TitleContainer and frame.TitleContainer.TitleText then
		frame.TitleContainer.TitleText:SetText(title)
	elseif frame.TitleText then
		frame.TitleText:SetText(title)
	end
end

function UI:CreateFrame()
	if self.frame then return self.frame end
	local L = ns.L

	local frame = CreateFrame("Frame", "OptiFarmFrame", UIParent, "ButtonFrameTemplate")
	frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(f)
		f:StopMovingOrSizing()
		self:SavePosition()
	end)
	frame:SetClampedToScreen(true)
	frame:Hide()
	SetFrameTitle(frame, L.TITLE .. " " .. ns.VERSION)

	if ButtonFrameTemplate_HideButtonBar then
		pcall(ButtonFrameTemplate_HideButtonBar, frame)
	end
	if frame.SetPortraitToAsset then
		pcall(frame.SetPortraitToAsset, frame, "Interface\\ICONS\\Ability_Mount_Drake_Proto")
	end

	-- Fermeture par Échap.
	tinsert(UISpecialFrames, "OptiFarmFrame")

	self.frame = frame
	self:CreateHeader(frame)
	self:CreateTabs(frame)
	self:CreateList(frame)
	self:RestorePosition()
	return frame
end

function UI:CreateHeader(frame)
	local L = ns.L
	local parent = frame.Inset or frame

	local summary = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	summary:SetPoint("TOPLEFT", 12, -10)
	summary:SetJustifyH("LEFT")
	frame.Summary = summary

	local search = CreateFrame("EditBox", "OptiFarmSearchBox", parent, "SearchBoxTemplate")
	search:SetSize(200, 20)
	search:SetPoint("TOPRIGHT", -12, -8)
	search:SetScript("OnTextChanged", function(box, userInput)
		if SearchBoxTemplate_OnTextChanged then
			pcall(SearchBoxTemplate_OnTextChanged, box)
		end
		if not userInput then return end
		ns.db.profile.filters.search = box:GetText() or ""
		self:Refresh()
	end)
	frame.SearchBox = search

	local availableOnly = CreateFrame("CheckButton", "OptiFarmAvailableOnly", parent, "UICheckButtonTemplate")
	availableOnly:SetSize(22, 22)
	availableOnly:SetPoint("TOPLEFT", 10, -32)
	availableOnly.text = availableOnly.text or availableOnly.Text
	if availableOnly.text then availableOnly.text:SetText(L.FILTER_AVAILABLE_ONLY) end
	availableOnly:SetScript("OnClick", function(button)
		ns.db.profile.filters.availableOnly = button:GetChecked() and true or false
		self:Refresh()
	end)
	frame.AvailableOnly = availableOnly

	local hideUnmapped = CreateFrame("CheckButton", "OptiFarmHideUnmapped", parent, "UICheckButtonTemplate")
	hideUnmapped:SetSize(22, 22)
	hideUnmapped:SetPoint("LEFT", availableOnly, "LEFT", 250, 0)
	hideUnmapped.text = hideUnmapped.text or hideUnmapped.Text
	if hideUnmapped.text then hideUnmapped.text:SetText(L.FILTER_HIDE_UNMAPPED) end
	hideUnmapped:SetScript("OnClick", function(button)
		ns.db.profile.filters.hideUnmapped = button:GetChecked() and true or false
		self:Refresh()
	end)
	frame.HideUnmapped = hideUnmapped
end

function UI:CreateTabs(frame)
	local L = ns.L
	local labels = { L.TAB_COLLECTION, L.TAB_ROUTE, L.TAB_EDITOR }
	frame.Tabs = {}

	for i, label in ipairs(labels) do
		local tab = CreateFrame("Button", "OptiFarmTab" .. i, frame, "PanelTabButtonTemplate")
		tab:SetText(label)
		tab:SetID(i)
		if i == 1 then
			tab:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 12, 2)
		else
			tab:SetPoint("LEFT", frame.Tabs[i - 1], "RIGHT", -14, 0)
		end
		tab:SetScript("OnClick", function(button)
			self:SelectTab(button:GetID())
		end)
		frame.Tabs[i] = tab
	end

	local placeholder = (frame.Inset or frame):CreateFontString(nil, "ARTWORK", "GameFontDisableLarge")
	placeholder:SetPoint("CENTER")
	placeholder:Hide()
	frame.Placeholder = placeholder
end

function UI:CreateList(frame)
	local parent = frame.Inset or frame

	local scrollBox = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
	scrollBox:SetPoint("TOPLEFT", 8, -58)
	scrollBox:SetPoint("BOTTOMRIGHT", -28, 8)
	frame.ScrollBox = scrollBox

	local scrollBar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
	scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, 0)
	scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 0)
	frame.ScrollBar = scrollBar

	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(ROW_HEIGHT)
	view:SetElementInitializer("Button", function(button, elementData)
		self:InitRow(button, elementData)
	end)
	ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

	local empty = parent:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	empty:SetPoint("CENTER", scrollBox, "CENTER")
	empty:SetText(ns.L.NO_RESULT)
	empty:Hide()
	frame.EmptyLabel = empty
end

--------------------------------------------------------------------------------
-- Lignes
--------------------------------------------------------------------------------

--- Construit les widgets d'une ligne la première fois qu'elle est acquise,
--  puis se contente de les remplir. Le pool de ScrollBox recycle les frames.
function UI:InitRow(button, elementData)
	if not button.mrBuilt then
		button.mrBuilt = true
		button:SetHeight(ROW_HEIGHT)

		button.Icon = button:CreateTexture(nil, "ARTWORK")
		button.Icon:SetSize(18, 18)
		button.Icon:SetPoint("LEFT", 2, 0)

		button.Name = button:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		button.Name:SetPoint("LEFT", button.Icon, "RIGHT", 6, 0)
		button.Name:SetWidth(220)
		button.Name:SetJustifyH("LEFT")
		button.Name:SetWordWrap(false)

		button.Source = button:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		button.Source:SetPoint("LEFT", button.Name, "RIGHT", 8, 0)
		button.Source:SetWidth(240)
		button.Source:SetJustifyH("LEFT")
		button.Source:SetWordWrap(false)

		button.Status = button:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		button.Status:SetPoint("LEFT", button.Source, "RIGHT", 8, 0)
		button.Status:SetJustifyH("LEFT")
		button.Status:SetWordWrap(false)

		button.Highlight = button:CreateTexture(nil, "HIGHLIGHT")
		button.Highlight:SetAllPoints()
		button.Highlight:SetColorTexture(1, 1, 1, 0.08)

		button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		button:SetScript("OnEnter", function(row) UI:ShowRowTooltip(row) end)
		button:SetScript("OnLeave", function() GameTooltip:Hide() end)
		button:SetScript("OnClick", function(row, mouseButton)
			if mouseButton == "RightButton" and row.mountID then
				local excluded = not ns.Collection:IsExcluded(row.mountID)
				ns.Collection:SetExcluded(row.mountID, excluded)
			end
		end)
	end

	button.mountID = elementData.mountID
	button.Icon:SetTexture(elementData.icon)

	local nameText = elementData.name
	if elementData.excluded then
		nameText = "|cff666666" .. nameText .. "|r"
	end
	button.Name:SetText(nameText)
	button.Source:SetText(elementData.sourceSummary or "")
	button.Status:SetText(elementData.statusText or "")
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
	GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- Rafraîchissement
--------------------------------------------------------------------------------

local function MatchesSearch(entry, needle)
	if needle == "" then return true end
	return entry.name:lower():find(needle, 1, true) ~= nil
end

function UI:BuildDataProvider()
	local filters = ns.db.profile.filters
	local needle = (filters.search or ""):lower()
	local provider = CreateDataProvider()
	local shown = 0

	for _, entry in ipairs(ns.Collection:GetMissing()) do
		local keep = true

		if filters.hideExcluded and entry.excluded then keep = false end
		if keep and not MatchesSearch(entry, needle) then keep = false end

		local status
		if keep then
			status = ns.Eligibility:GetStatus(entry.mountID)
			if filters.availableOnly and status.state ~= ns.Eligibility.STATE.AVAILABLE then
				keep = false
			end
			if keep and filters.hideUnmapped and status.state == ns.Eligibility.STATE.UNMAPPED then
				keep = false
			end
		end

		if keep then
			shown = shown + 1
			provider:Insert({
				mountID = entry.mountID,
				name = entry.name,
				icon = entry.icon,
				excluded = entry.excluded,
				sourceSummary = ns.Collection:GetSourceSummary(entry.mountID),
				statusText = ns.Eligibility:FormatStatus(status),
			})
		end
	end

	return provider, shown
end

function UI:Refresh()
	local frame = self.frame
	if not frame or not frame:IsShown() then return end

	local L = ns.L
	if not ns.Collection.ready then
		frame.Summary:SetText(L.JOURNAL_NOT_READY)
		return
	end

	local counts = ns.Collection.counts
	local provider, shown = self:BuildDataProvider()
	frame.Summary:SetText(L.SUMMARY:format(counts.owned, counts.total, counts.missing)
		.. "  |cff888888(" .. L.SUMMARY_FILTERED:format(shown) .. ")|r")

	frame.ScrollBox:SetDataProvider(provider, ScrollBoxConstants.RetainScrollPosition)
	frame.EmptyLabel:SetShown(shown == 0)
end

--------------------------------------------------------------------------------
-- Onglets, position, visibilité
--------------------------------------------------------------------------------

function UI:SelectTab(index)
	local frame = self.frame
	if not frame then return end
	ns.db.profile.ui.activeTab = index

	for i, tab in ipairs(frame.Tabs) do
		if PanelTemplates_SelectTab and i == index then
			pcall(PanelTemplates_SelectTab, tab)
		elseif PanelTemplates_DeselectTab and i ~= index then
			pcall(PanelTemplates_DeselectTab, tab)
		end
	end

	local isCollection = (index == 1)
	frame.ScrollBox:SetShown(isCollection)
	frame.ScrollBar:SetShown(isCollection)
	frame.SearchBox:SetShown(isCollection)
	frame.AvailableOnly:SetShown(isCollection)
	frame.HideUnmapped:SetShown(isCollection)
	frame.EmptyLabel:Hide()

	if isCollection then
		frame.Placeholder:Hide()
		self:Refresh()
	else
		frame.Summary:SetText("")
		frame.Placeholder:SetText(index == 2 and ns.L.ROUTE_PLACEHOLDER or ns.L.EDITOR_PLACEHOLDER)
		frame.Placeholder:Show()
	end
end

function UI:SavePosition()
	if not self.frame or not ns.db then return end
	local point, _, _, x, y = self.frame:GetPoint()
	local uiConfig = ns.db.profile.ui
	uiConfig.point, uiConfig.x, uiConfig.y = point, x, y
end

function UI:RestorePosition()
	if not self.frame or not ns.db then return end
	local uiConfig = ns.db.profile.ui
	self.frame:ClearAllPoints()
	self.frame:SetPoint(uiConfig.point or "CENTER", UIParent, uiConfig.point or "CENTER",
		uiConfig.x or 0, uiConfig.y or 0)
	self.frame:SetScale(uiConfig.scale or 1)
end

function UI:Show()
	local frame = self:CreateFrame()
	frame:Show()
	-- Les filtres persistés doivent se refléter dans les widgets.
	local filters = ns.db.profile.filters
	frame.SearchBox:SetText(filters.search or "")
	frame.AvailableOnly:SetChecked(filters.availableOnly)
	frame.HideUnmapped:SetChecked(filters.hideUnmapped)
	self:SelectTab(ns.db.profile.ui.activeTab or 1)
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
