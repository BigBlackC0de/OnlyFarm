--[[---------------------------------------------------------------------------
	OnlyFarm — Core/Init.lua

	Espace de noms, bus d'événements/messages, système de modules.

	Aucune bibliothèque externe en phase 1 (cf. CONTRIBUTING.md, « Décision : pas
	d'Ace3 pour l'instant »). La surface exposée ici imite volontairement
	AceEvent-3.0 / AceAddon-3.0 pour que la bascule reste mécanique le jour où
	AceConfig / AceGUI deviennent utiles (phase 3+).
-----------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

ns.ADDON_NAME = ADDON_NAME
ns.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata
	and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")) or "dev"

ns.modules = {}      -- [nom] = module
ns.moduleOrder = {}  -- ordre d'initialisation (trié par priorité)
ns.Data = ns.Data or {}

--------------------------------------------------------------------------------
-- Journalisation
--------------------------------------------------------------------------------

local CHAT_PREFIX = "|cff7ac1ffOnlyFarm|r: "

function ns:Print(fmt, ...)
	local msg = select("#", ...) > 0 and fmt:format(...) or fmt
	DEFAULT_CHAT_FRAME:AddMessage(CHAT_PREFIX .. msg)
end

--- Trace de debug. Silencieuse tant que `/onlyfarm debug` n'a pas été activé.
function ns:Debug(fmt, ...)
	if not ns.debugEnabled then return end
	local msg = select("#", ...) > 0 and fmt:format(...) or fmt
	DEFAULT_CHAT_FRAME:AddMessage("|cff888888OF|r " .. msg)
end

-- On ne laisse jamais une erreur de handler casser la boucle de dispatch :
-- elle part dans le gestionnaire d'erreurs du client (BugSack l'attrape).
-- Note : `xpcall` de WoW accepte des arguments supplémentaires, mais pas celui
-- de Lua 5.1 standard utilisé par les tests headless — d'où `pcall`.
local function SafeCall(func, ...)
	local ok, err = pcall(func, ...)
	if not ok then
		local handler = geterrorhandler and geterrorhandler()
		if handler then handler(err) else print(err) end
	end
	return ok
end
ns.SafeCall = SafeCall

--------------------------------------------------------------------------------
-- Bus d'événements et de messages
--------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
ns.eventFrame = eventFrame

local eventSubs = {}    -- [event]   = { {owner=, method=}, ... }
local messageSubs = {}  -- [message] = { {owner=, method=}, ... }

local function Dispatch(subs, key, ...)
	local list = subs[key]
	if not list then return end
	-- Copie défensive : un handler peut se désabonner pendant le dispatch.
	local n = #list
	for i = 1, n do
		local sub = list[i]
		if sub then
			local func = sub.owner[sub.method]
			if func then
				SafeCall(func, sub.owner, key, ...)
			end
		end
	end
end

local function Subscribe(subs, key, owner, method)
	local list = subs[key]
	if not list then
		list = {}
		subs[key] = list
	end
	for i = 1, #list do
		if list[i].owner == owner then
			list[i].method = method
			return list
		end
	end
	list[#list + 1] = { owner = owner, method = method }
	return list
end

local function Unsubscribe(subs, key, owner)
	local list = subs[key]
	if not list then return false end
	for i = #list, 1, -1 do
		if list[i].owner == owner then
			table.remove(list, i)
		end
	end
	return #list == 0
end

--- Abonne `owner` à un événement du client.
--  Un nom d'événement inconnu (retiré par un patch) est ignoré proprement au
--  lieu de faire exploser le chargement de l'addon.
--  @return true si l'abonnement est effectif.
function ns:RegisterEvent(event, owner, method)
	local isNew = eventSubs[event] == nil
	if isNew and not pcall(eventFrame.RegisterEvent, eventFrame, event) then
		ns:Debug("événement inconnu, ignoré : %s", event)
		return false
	end
	Subscribe(eventSubs, event, owner, method or event)
	return true
end

function ns:UnregisterEvent(event, owner)
	if Unsubscribe(eventSubs, event, owner) then
		eventSubs[event] = nil
		pcall(eventFrame.UnregisterEvent, eventFrame, event)
	end
end

--- Messages internes à l'addon (préfixe « OF_ » par convention).
function ns:RegisterMessage(message, owner, method)
	Subscribe(messageSubs, message, owner, method or message)
	return true
end

function ns:UnregisterMessage(message, owner)
	if Unsubscribe(messageSubs, message, owner) then
		messageSubs[message] = nil
	end
end

function ns:SendMessage(message, ...)
	ns:Debug("message %s", message)
	Dispatch(messageSubs, message, ...)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
	Dispatch(eventSubs, event, ...)
end)

--------------------------------------------------------------------------------
-- Modules
--------------------------------------------------------------------------------

local moduleProto = {}
moduleProto.__index = moduleProto

function moduleProto:RegisterEvent(event, method)
	return ns:RegisterEvent(event, self, method or event)
end

function moduleProto:UnregisterEvent(event)
	return ns:UnregisterEvent(event, self)
end

function moduleProto:RegisterMessage(message, method)
	return ns:RegisterMessage(message, self, method or message)
end

function moduleProto:UnregisterMessage(message)
	return ns:UnregisterMessage(message, self)
end

function moduleProto:SendMessage(message, ...)
	return ns:SendMessage(message, ...)
end

function moduleProto:Print(...) return ns:Print(...) end
function moduleProto:Debug(...) return ns:Debug(...) end

--- Déclare un module.
--  @param name      nom unique, accessible ensuite via `ns.Collection` etc.
--  @param priority  ordre d'initialisation croissant (défaut 50).
function ns:NewModule(name, priority)
	assert(not ns.modules[name], "module déjà déclaré : " .. tostring(name))
	local module = setmetatable({
		moduleName = name,
		priority = priority or 50,
	}, moduleProto)
	ns.modules[name] = module
	ns.moduleOrder[#ns.moduleOrder + 1] = module
	ns[name] = module
	return module
end

local function SortedModules()
	table.sort(ns.moduleOrder, function(a, b)
		if a.priority ~= b.priority then return a.priority < b.priority end
		return a.moduleName < b.moduleName
	end)
	return ns.moduleOrder
end

--------------------------------------------------------------------------------
-- Séquence de démarrage
--
-- ADDON_LOADED       -> OnInitialize (les SavedVariables existent)
-- PLAYER_LOGIN       -> OnEnable     (les API du joueur répondent)
-- PLAYER_ENTERING_WORLD -> message OF_ENTERING_WORLD
--
-- Attention : le Mount Journal n'est PAS garanti peuplé à PLAYER_LOGIN. Les
-- modules qui en dépendent doivent réagir à OF_ENTERING_WORLD et retenter.
--------------------------------------------------------------------------------

local bootstrap = {}
ns.bootstrap = bootstrap

function bootstrap:ADDON_LOADED(_, name)
	if name ~= ADDON_NAME then return end
	ns.initialized = true
	for _, module in ipairs(SortedModules()) do
		if module.OnInitialize then
			SafeCall(module.OnInitialize, module)
		end
	end
	ns:UnregisterEvent("ADDON_LOADED", self)
end

function bootstrap:PLAYER_LOGIN()
	ns.enabled = true
	for _, module in ipairs(SortedModules()) do
		if module.OnEnable then
			SafeCall(module.OnEnable, module)
		end
	end
	ns:SendMessage("OF_ENABLED")
end

function bootstrap:PLAYER_ENTERING_WORLD(_, isInitialLogin, isReloadingUi)
	ns:SendMessage("OF_ENTERING_WORLD", isInitialLogin, isReloadingUi)
end

ns:RegisterEvent("ADDON_LOADED", bootstrap, "ADDON_LOADED")
ns:RegisterEvent("PLAYER_LOGIN", bootstrap, "PLAYER_LOGIN")
ns:RegisterEvent("PLAYER_ENTERING_WORLD", bootstrap, "PLAYER_ENTERING_WORLD")

-- Exposé pour le débogage en jeu et pour les tests headless.
-- Textures de l'addon. Chemins sans extension : le client choisit entre .tga
-- et .blp tout seul. Un chemin invalide s'affiche en carré vert, pas en erreur,
-- donc c'est un point à vérifier à l'œil et pas en test.
ns.LOGO_TEXTURE = "Interface\\AddOns\\OnlyFarm\\Media\\logo"
ns.MINIMAP_TEXTURE = "Interface\\AddOns\\OnlyFarm\\Media\\minimap"
ns.BANNER_TEXTURE = "Interface\\AddOns\\OnlyFarm\\Media\\banner"

_G.OnlyFarm = ns
