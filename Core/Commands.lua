--[[---------------------------------------------------------------------------
	OnlyFarm — Core/Commands.lua

	Commandes slash. Chargé en dernier : tous les modules existent.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Commands = ns:NewModule("Commands", 90)

local handlers = {}

function Commands:OnEnable()
	SLASH_ONLYFARM1 = "/onlyfarm"
	SLASH_ONLYFARM2 = "/of"
	SlashCmdList["ONLYFARM"] = function(input)
		Commands:Dispatch(input or "")
	end
end

function Commands:Dispatch(input)
	local command, rest = input:match("^%s*(%S*)%s*(.-)%s*$")
	command = (command or ""):lower()
	local handler = handlers[command]
	if handler then
		ns.SafeCall(handler, self, rest)
	else
		handlers.help(self)
	end
end

--------------------------------------------------------------------------------

function handlers.help()
	local L = ns.L
	ns:Print(L.CMD_HELP_HEADER)
	for _, line in ipairs({
		L.CMD_HELP_SHOW, L.CMD_HELP_SCAN, L.CMD_HELP_CHARS,
		L.CMD_HELP_EJSCAN, L.CMD_HELP_DEBUG, L.CMD_HELP_RESET,
	}) do
		DEFAULT_CHAT_FRAME:AddMessage(line)
	end
end

handlers[""] = function()
	ns.UI:Toggle()
end

handlers["show"] = handlers[""]
handlers["toggle"] = handlers[""]

function handlers.scan()
	ns.Collection:Scan()
	ns.Lockouts:PurgeExpired()
	ns.Lockouts.lastRequest = 0   -- on force, la commande est explicite
	ns.Lockouts:RequestScan()
	ns:Print("scan lancé.")
end

function handlers.ejscan()
	ns.DevScan:Start()
end

function handlers.chars()
	local keys = ns.Database:GetCharKeys()
	if #keys == 0 then
		ns:Print("aucun personnage enregistré.")
		return
	end
	ns:Print("%d personnage(s) connus :", #keys)
	for _, charKey in ipairs(keys) do
		local charEntry = ns.Database:GetChar(charKey)
		local lockCount = ns.Util.Count(charEntry.lockouts or {})
		local stale = ns.Database:IsStale(charEntry)
		local age = ns.Util.FormatAge(charEntry.lastSeen)
		DEFAULT_CHAT_FRAME:AddMessage(string.format(
			"  %s — %d verrou(s) — vu il y a %s%s",
			charKey, lockCount, age,
			stale and " |cffbbbb55(incertain)|r" or ""))
	end
end

function handlers.debug()
	ns.debugEnabled = not ns.debugEnabled
	ns:Print("traces de debug : %s", ns.debugEnabled and "activées" or "coupées")
end

function handlers.reset(_, rest)
	if rest ~= "confirm" then
		ns:Print(ns.L.RESET_CONFIRM)
		return
	end
	ns.Database:Wipe()
	ns:Print(ns.L.RESET_DONE)
end

Commands.handlers = handlers
