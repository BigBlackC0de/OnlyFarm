--[[---------------------------------------------------------------------------
	OnlyFarm — Tests/harness.lua

	Charge l'addon dans l'environnement simulé et rejoue la séquence de
	démarrage du client (ADDON_LOADED -> PLAYER_LOGIN -> PLAYER_ENTERING_WORLD).

	Les fichiers d'interface ne sont pas chargés : ils dépendent de templates
	XML de Blizzard qu'on ne peut pas simuler honnêtement. Le harnais couvre la
	logique, pas le rendu.
-----------------------------------------------------------------------------]]

local harness = {}

-- Ordre de chargement identique à OnlyFarm.toc, sans UI/.
harness.FILES = {
	"Core/Init.lua",
	"Core/Util.lua",
	"Core/Locale.lua",
	"Core/Database.lua",
	"Data/Sources.lua",
	"Data/Nodes.lua",
	"Data/Travel.lua",
	"Modules/Collection.lua",
	"Modules/Lockouts.lua",
	"Modules/Nodes.lua",
	"Modules/Teleports.lua",
	"Modules/Attempts.lua",
	"Modules/Eligibility.lua",
	"Modules/DevScan.lua",
	"Core/Commands.lua",
}

local root = (...) and "" or ""

--- Charge l'addon à neuf et renvoie son espace de noms.
--  @param stub    module wow_stub, déjà remis à zéro
--  @param options { skipLogin = true } pour s'arrêter après ADDON_LOADED
function harness.Load(stub, options)
	options = options or {}

	-- Nouvel espace de noms à chaque chargement : pas d'état résiduel entre tests.
	local ns = {}
	_G.OnlyFarm = nil

	for _, path in ipairs(harness.FILES) do
		local chunk, err = loadfile(root .. path)
		if not chunk then
			error("échec de chargement de " .. path .. " : " .. tostring(err))
		end
		chunk("OnlyFarm", ns)
	end

	stub.Fire("ADDON_LOADED", "OnlyFarm")
	if options.skipLogin then return ns end

	stub.Fire("PLAYER_LOGIN")
	stub.Fire("PLAYER_ENTERING_WORLD", true, false)

	-- Les scans initiaux passent par un anti-rebond d'une seconde. On avance
	-- l'horloge des frames seulement : la date serveur ne doit pas bouger,
	-- sinon les expirations de verrou calculées ici deviendraient fausses.
	stub.AdvanceFrames(2)
	stub.FlushTimers()

	return ns
end

return harness
