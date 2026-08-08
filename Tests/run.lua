#!/usr/bin/env lua5.1
--[[---------------------------------------------------------------------------
	OnlyFarm — Tests/run.lua

	Lancement :  lua5.1 Tests/run.lua      (depuis la racine du dépôt)
-----------------------------------------------------------------------------]]

package.path = "Tests/?.lua;" .. package.path

local stub = require("wow_stub")
local harness = require("harness")

--------------------------------------------------------------------------------
-- Mini-framework
--------------------------------------------------------------------------------

local passed, failed = 0, 0
local failures = {}
local currentSuite = "?"

local function suite(name) currentSuite = name end

local function check(condition, description, detail)
	if condition then
		passed = passed + 1
	else
		failed = failed + 1
		table.insert(failures, string.format("%s :: %s%s",
			currentSuite, description, detail and ("  [" .. detail .. "]") or ""))
	end
end

local function eq(actual, expected, description)
	check(actual == expected, description,
		string.format("attendu %s, obtenu %s", tostring(expected), tostring(actual)))
end

local function test(name, func)
	suite(name)
	local ok, err = pcall(func)
	if not ok then
		failed = failed + 1
		table.insert(failures, string.format("%s :: ERREUR LUA — %s", name, tostring(err)))
	end
end

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

local function StandardMounts()
	return {
		-- possédée
		{ mountID = 100, name = "Cheval alezan", sourceType = 3, isCollected = true },
		-- manquante, butin de raid
		{ mountID = 201, name = "Proto-drake fumeronde", sourceType = 1,
		  itemID = 32458, source = "Butin : Yogg-Saron\nUlduar" },
		-- manquante, vendeur
		{ mountID = 202, name = "Brutosaure gigantesque", sourceType = 3,
		  source = "Vendeur : Talutu" },
		-- manquante, mais masquée sur ce personnage (faction adverse)
		{ mountID = 203, name = "Loup de guerre", sourceType = 1,
		  shouldHideOnChar = true, faction = 0 },
		-- manquante, butin de donjon
		{ mountID = 204, name = "Cheval en flammes", sourceType = 1,
		  source = "Butin : Attumen\nÉcurie" },
	}
end

--------------------------------------------------------------------------------
-- Util
--------------------------------------------------------------------------------

test("Util — formatage de durée", function()
	stub.Reset()
	local ns = harness.Load(stub)
	local Util = ns.Util
	eq(Util.FormatDuration(0), "—", "durée nulle")
	eq(Util.FormatDuration(-5), "—", "durée négative")
	eq(Util.FormatDuration(45), "45s", "secondes")
	eq(Util.FormatDuration(120), "2m", "minutes")
	eq(Util.FormatDuration(3600 + 720), "1h 12m", "heures et minutes")
	eq(Util.FormatDuration(3 * 86400 + 4 * 3600), "3d 4h", "jours et heures")
end)

test("Util — ApplyDefaults ne détruit rien", function()
	stub.Reset()
	local ns = harness.Load(stub)
	local target = { a = 1, nested = { keep = "oui" } }
	ns.Util.ApplyDefaults(target, { a = 99, b = 2, nested = { keep = "non", added = true } })
	eq(target.a, 1, "valeur existante préservée")
	eq(target.b, 2, "valeur manquante ajoutée")
	eq(target.nested.keep, "oui", "valeur imbriquée préservée")
	eq(target.nested.added, true, "valeur imbriquée ajoutée")
end)

test("Util — frontière de reset quotidien", function()
	stub.Reset()
	local ns = harness.Load(stub)
	stub.dailyResetAt = stub.now + 3600         -- reset dans 1 h
	local boundary = ns.Util.LastDailyReset()   -- donc il y a 23 h
	eq(boundary, stub.now + 3600 - 86400, "dernière frontière calculée")
	eq(ns.Util.IsSinceDailyReset(stub.now - 3600), true, "il y a 1 h : après le reset")
	eq(ns.Util.IsSinceDailyReset(stub.now - 90000), false, "il y a 25 h : avant le reset")

	-- API muette : pas de roulement, le décompte reste à zéro.
	stub.dailyResetPeriod = nil
	stub.dailyResetAt = stub.now
	eq(ns.Util.IsSinceDailyReset(stub.now), nil, "frontière inconnue -> nil, pas false")
end)

test("Util — normalisation de nom d'instance", function()
	stub.Reset()
	local ns = harness.Load(stub)
	eq(ns.Util.NormalizeName("  Ulduar  "), "ulduar", "espaces et casse")
	eq(ns.Util.NormalizeName("Le  Sanctum   de la Foudre"), "le sanctum de la foudre",
		"espaces multiples réduits")
	eq(ns.Util.NormalizeName(nil), nil, "entrée nil")
end)

--------------------------------------------------------------------------------
-- Database
--------------------------------------------------------------------------------

test("Database — création et estampille de schéma", function()
	stub.Reset()
	local ns = harness.Load(stub)
	eq(_G.OnlyFarmDB.schema, 2, "schéma estampillé à la version courante")
	eq(ns.db.charKey, "Krayne-Hyjal", "clé de personnage")
	eq(type(ns.db.global.chars["Krayne-Hyjal"]), "table", "entrée de personnage créée")
	eq(ns.db.char.faction, "Alliance", "instantané écrit à PLAYER_LOGIN")
	eq(ns.db.char.level, 80, "niveau enregistré")
end)

test("Database — base existante préservée", function()
	stub.Reset()
	_G.OnlyFarmDB = {
		schema = 1,
		global = { chars = { ["Zaltus-Hyjal"] = { name = "Zaltus", lastSeen = 1 } },
			excluded = { [777] = true } },
		profiles = {},
	}
	local ns = harness.Load(stub)
	eq(ns.db.global.excluded[777], true, "exclusions conservées")
	eq(ns.db.global.chars["Zaltus-Hyjal"].name, "Zaltus", "autre personnage conservé")
	eq(#ns.Database:GetCharKeys(), 2, "deux personnages connus")
end)

test("Database — fraîcheur d'un personnage", function()
	stub.Reset()
	local ns = harness.Load(stub)
	eq(ns.Database:IsStale({ lastSeen = stub.now }), false, "vu à l'instant")
	eq(ns.Database:IsStale({ lastSeen = stub.now - 8 * 86400 }), true, "vu il y a 8 jours")
	eq(ns.Database:IsStale({}), true, "jamais vu")
end)

--------------------------------------------------------------------------------
-- Collection
--------------------------------------------------------------------------------

test("Collection — diff possédées / manquantes", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = harness.Load(stub)

	eq(ns.Collection.ready, true, "scan abouti")
	eq(ns.Collection.counts.owned, 1, "une monture possédée")
	eq(ns.Collection.counts.missing, 3, "trois manquantes obtenables")
	eq(ns.Collection.counts.hidden, 1, "une masquée sur ce personnage")
	eq(ns.Collection.counts.total, 4, "total obtenable sur ce personnage")
	eq(ns.Collection:IsOwned(100), true, "monture possédée reconnue")
	eq(ns.Collection:IsOwned(201), false, "monture manquante non possédée")
	eq(ns.Collection:GetEntry(203), nil, "monture masquée absente de la liste")
end)

test("Collection — Journal vide puis peuplé", function()
	stub.Reset()
	stub.mounts = {}
	local ns = harness.Load(stub)
	eq(ns.Collection.ready, false, "Journal vide : pas prêt")

	stub.mounts = StandardMounts()
	stub.Advance(3)
	stub.FlushTimers()
	eq(ns.Collection.ready, true, "réessai automatique abouti")
	eq(ns.Collection.counts.missing, 3, "manquantes comptées après réessai")
end)

test("Collection — texte de source en cache", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = harness.Load(stub)
	eq(ns.Collection:GetSourceText(201), "Butin : Yogg-Saron\nUlduar", "texte brut")
	eq(ns.Collection:GetSourceSummary(201), "Butin : Yogg-Saron — Ulduar", "résumé sur une ligne")
	eq(ns.Collection:GetSourceText(999), nil, "monture inconnue")
end)

test("Collection — exclusions", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = harness.Load(stub)
	eq(ns.Collection:IsExcluded(202), false, "non exclue au départ")
	ns.Collection:SetExcluded(202, true)
	eq(ns.Collection:IsExcluded(202), true, "exclusion posée")
	eq(ns.db.global.excluded[202], true, "exclusion persistée")
	ns.Collection:SetExcluded(202, false)
	eq(ns.db.global.excluded[202], nil, "exclusion retirée, pas mise à false")
end)

test("Collection — NEW_MOUNT_ADDED déclenche un rescan", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = harness.Load(stub)
	eq(ns.Collection.counts.owned, 1, "état initial")

	stub.mounts[2].isCollected = true      -- le proto-drake tombe enfin
	stub.Fire("NEW_MOUNT_ADDED", 201)
	stub.Advance(2)
	stub.FlushTimers()

	eq(ns.Collection.counts.owned, 2, "collection remise à jour")
	eq(ns.Collection:IsOwned(201), true, "nouvelle monture possédée")
end)

--------------------------------------------------------------------------------
-- Lockouts
--------------------------------------------------------------------------------

test("Lockouts — lecture des verrous sauvegardés", function()
	stub.Reset()
	stub.savedInstances = {
		{ name = "Ulduar", instanceID = 759, difficultyID = 14, reset = 3 * 86400,
		  isRaid = true, numEncounters = 2, encounterProgress = 1,
		  bosses = { { name = "Flame Leviathan", isKilled = true },
					 { name = "Yogg-Saron", isKilled = false } } },
		{ name = "Naxxramas", instanceID = 533, difficultyID = 14, reset = 2 * 86400,
		  isRaid = true, numEncounters = 0 },
	}
	local ns = harness.Load(stub)

	local lockouts = ns.db.char.lockouts
	eq(ns.Util.Count(lockouts), 2, "deux verrous enregistrés")

	local ulduar = lockouts["759:14"]
	eq(type(ulduar), "table", "clé instanceID:difficultyID")
	eq(ulduar.expires, stub.now + 3 * 86400, "expiration calculée")
	eq(ulduar.bosses["Flame Leviathan"], true, "boss tué")
	eq(ulduar.bosses["Yogg-Saron"], false, "boss vivant")
	eq(ns.Lockouts:GetInstanceIDByName("ulduar"), 759, "pont nom -> instanceID appris")
end)

test("Lockouts — verrou expiré ignoré et purgé", function()
	stub.Reset()
	stub.savedInstances = {
		{ name = "Ulduar", instanceID = 759, difficultyID = 14, reset = 3 * 86400,
		  isRaid = true },
	}
	local ns = harness.Load(stub)
	eq(ns.Lockouts:GetLock("Krayne-Hyjal", 759) ~= nil, true, "verrou actif trouvé")

	stub.Advance(4 * 86400)
	eq(ns.Lockouts:GetLock("Krayne-Hyjal", 759), nil, "verrou périmé non retourné")
	eq(ns.Lockouts:PurgeExpired(), 1, "un verrou purgé")
	eq(ns.Util.Count(ns.db.char.lockouts), 0, "base nettoyée")
end)

test("Lockouts — verrou non verrouillé et non prolongé ignoré", function()
	stub.Reset()
	stub.savedInstances = {
		{ name = "Ulduar", instanceID = 759, difficultyID = 14, reset = 0,
		  locked = false, extended = false, isRaid = true },
	}
	local ns = harness.Load(stub)
	eq(ns.Util.Count(ns.db.char.lockouts), 0, "verrou mort non enregistré")
end)

test("Lockouts — entrée en instance enregistrée", function()
	stub.Reset()
	local ns = harness.Load(stub)

	stub.currentInstance = { name = "Karazhan", instanceType = "party",
		difficultyID = 1, instanceID = 532 }
	stub.Fire("PLAYER_ENTERING_WORLD", false, false)

	local entry = ns.db.char.dungeonEntries[532]
	eq(type(entry), "table", "entrée enregistrée")
	eq(entry.name, "Karazhan", "nom retenu")
	eq(ns.Lockouts:GetInstanceIDByName("karazhan"), 532, "pont appris depuis l'entrée")
	eq(ns.Lockouts:HasEnteredToday("Krayne-Hyjal", 532), true, "entré aujourd'hui")

	-- Réentrer dans la même instance ne doit pas gonfler le compteur de cap.
	stub.Fire("PLAYER_ENTERING_WORLD", false, false)
	local hour = ns.Lockouts:GetInstanceCounts()
	eq(hour, 1, "une seule entrée comptée")
end)

test("Lockouts — compteur du cap d'instances", function()
	stub.Reset()
	local ns = harness.Load(stub)
	for i = 1, 4 do
		stub.currentInstance = { name = "Donjon " .. i, instanceType = "party",
			difficultyID = 1, instanceID = 1000 + i }
		stub.Fire("PLAYER_ENTERING_WORLD", false, false)
		stub.Advance(60)
	end
	local hour, day = ns.Lockouts:GetInstanceCounts()
	eq(hour, 4, "quatre entrées dans l'heure")
	eq(day, 4, "quatre entrées dans la journée")

	stub.Advance(3600)
	hour, day = ns.Lockouts:GetInstanceCounts()
	eq(hour, 0, "fenêtre glissante d'une heure vidée")
	eq(day, 4, "fenêtre journalière encore pleine")
end)

--------------------------------------------------------------------------------
-- Eligibility
--------------------------------------------------------------------------------

local function LoadWithSources(sourceCache)
	local ns = harness.Load(stub)
	ns.db.global.sourceCache = sourceCache
	ns.Eligibility:Invalidate()
	return ns
end

test("Eligibility — source non cartographiée", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = harness.Load(stub)
	local status = ns.Eligibility:GetStatus(201)
	eq(status.state, ns.Eligibility.STATE.UNMAPPED, "aucune source connue")
end)

test("Eligibility — raid hebdomadaire disponible puis verrouillé", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	stub.savedInstances = {}
	local ns = LoadWithSources({
		[201] = { instanceName = "Ulduar", isRaid = true, kind = "boss" },
	})

	-- Aucun verrou enregistré : l'absence vaut disponibilité, mais encore
	-- faut-il savoir de quelle instance moteur on parle.
	ns.db.global.instanceIDsByName["ulduar"] = 759
	local status = ns.Eligibility:GetStatus(201)
	eq(status.state, ns.Eligibility.STATE.AVAILABLE, "pas de verrou -> disponible")

	-- Le joueur tue le boss : le verrou apparaît.
	stub.savedInstances = {
		{ name = "Ulduar", instanceID = 759, difficultyID = 14,
		  reset = 3 * 86400, isRaid = true },
	}
	stub.Fire("UPDATE_INSTANCE_INFO")
	status = ns.Eligibility:GetStatus(201)
	eq(status.state, ns.Eligibility.STATE.LOCKED, "verrou détecté")
	eq(status.resetIn, 3 * 86400, "temps avant reset")
end)

test("Eligibility — instance jamais rapprochée d'un instanceID", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = LoadWithSources({
		[201] = { instanceName = "Ulduar", isRaid = true, kind = "boss" },
	})
	local status = ns.Eligibility:GetStatus(201)
	eq(status.state, ns.Eligibility.STATE.UNKNOWN, "identifiant moteur inconnu")
	eq(status.detail, "instance_unresolved", "raison explicite")
end)

test("Eligibility — donjon quotidien", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = LoadWithSources({
		[204] = { instanceName = "Karazhan", isRaid = false, kind = "boss" },
	})
	ns.db.global.instanceIDsByName["karazhan"] = 532

	eq(ns.Eligibility:GetStatus(204).state, ns.Eligibility.STATE.AVAILABLE,
		"jamais entré aujourd'hui -> disponible")

	stub.currentInstance = { name = "Karazhan", instanceType = "party",
		difficultyID = 1, instanceID = 532 }
	stub.Fire("PLAYER_ENTERING_WORLD", false, false)

	local status = ns.Eligibility:GetStatus(204)
	eq(status.state, ns.Eligibility.STATE.LOCKED, "entré aujourd'hui -> verrouillé")
	eq(status.detail, "entered_today", "raison explicite")

	-- Passage du reset quotidien : la porte se rouvre.
	stub.Advance(3601)
	eq(ns.Eligibility:GetStatus(204).state, ns.Eligibility.STATE.AVAILABLE,
		"après le reset quotidien -> disponible")
end)

test("Eligibility — faction bloquante", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = LoadWithSources({
		[202] = { instanceName = "Orgrimmar", faction = "Horde", lockout = "none" },
	})
	local status = ns.Eligibility:GetStatus(202)
	eq(status.state, ns.Eligibility.STATE.INELIGIBLE, "faction adverse")
	eq(status.detail, "faction", "raison explicite")
end)

test("Eligibility — source sans verrou", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = LoadWithSources({
		[202] = { kind = "vendor", lockout = "none" },
	})
	eq(ns.Eligibility:GetStatus(202).state, ns.Eligibility.STATE.AVAILABLE,
		"vendeur toujours disponible")
end)

test("Eligibility — vue multi-personnage", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	stub.savedInstances = {
		{ name = "Ulduar", instanceID = 759, difficultyID = 14,
		  reset = 3 * 86400, isRaid = true },
	}
	local ns = harness.Load(stub)

	-- Un alt connu, sans verrou, vu récemment.
	ns.db.global.chars["Zaltus-Hyjal"] = {
		name = "Zaltus", faction = "Alliance", level = 80,
		lastSeen = stub.now, lockouts = {}, dungeonEntries = {},
	}
	-- Un alt oublié depuis trois semaines.
	ns.db.global.chars["Morvani-Hyjal"] = {
		name = "Morvani", faction = "Alliance", level = 80,
		lastSeen = stub.now - 21 * 86400, lockouts = {}, dungeonEntries = {},
	}
	ns.db.global.sourceCache = { [201] = { instanceName = "Ulduar", isRaid = true } }
	ns.Eligibility:Invalidate()

	local rows, available = ns.Eligibility:GetCharacterAvailability(201)
	eq(#rows, 3, "trois personnages listés")
	eq(available, 2, "deux personnages disponibles")

	local byName = {}
	for _, row in ipairs(rows) do byName[row.name] = row end
	eq(byName.Krayne.state, ns.Eligibility.STATE.LOCKED, "le main est verrouillé")
	eq(byName.Zaltus.state, ns.Eligibility.STATE.AVAILABLE, "l'alt est disponible")
	eq(byName.Morvani.stale, true, "l'alt oublié est marqué incertain")
end)

--------------------------------------------------------------------------------
-- Attempts
--------------------------------------------------------------------------------

test("Attempts — un kill compte une tentative par monture manquante", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = LoadWithSources({
		[201] = { instanceName = "Ulduar", encounterName = "Yogg-Saron", isRaid = true },
	})
	ns.Attempts:Invalidate()

	eq(ns.Attempts:GetCount(201), 0, "aucune tentative au départ")

	stub.Fire("ENCOUNTER_END", 1143, "Yogg-Saron", 14, 1, 1)
	eq(ns.Attempts:GetCount(201), 1, "kill réussi compté")

	-- Un échec ne compte pas : on n'a pas vu la table de butin.
	stub.Advance(120)
	stub.Fire("ENCOUNTER_END", 1143, "Yogg-Saron", 14, 1, 0)
	eq(ns.Attempts:GetCount(201), 1, "wipe non compté")
end)

test("Attempts — ENCOUNTER_END et BOSS_KILL ne comptent pas deux fois", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = LoadWithSources({
		[201] = { instanceName = "Ulduar", encounterName = "Yogg-Saron", isRaid = true },
	})
	ns.Attempts:Invalidate()

	stub.Fire("ENCOUNTER_END", 1143, "Yogg-Saron", 14, 1, 1)
	stub.Fire("BOSS_KILL", 1143, "Yogg-Saron")
	eq(ns.Attempts:GetCount(201), 1, "le doublon est absorbé")

	-- Passé la fenêtre d'anti-doublon, c'est une vraie seconde tentative.
	stub.Advance(120)
	stub.Fire("BOSS_KILL", 1143, "Yogg-Saron")
	eq(ns.Attempts:GetCount(201), 2, "kill suivant compté")
end)

test("Attempts — le nom de rencontre fait le pont, pas l'encounterID", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	-- Le nom est stocké avec une casse et des espaces différents : le pont doit
	-- tenir, c'est tout l'intérêt de passer par NormalizeName.
	local ns = LoadWithSources({
		[201] = { instanceName = "Ulduar", encounterName = "  YOGG-SARON  ", isRaid = true },
	})
	ns.Attempts:Invalidate()

	stub.Fire("ENCOUNTER_END", 999999, "Yogg-Saron", 14, 1, 1)
	eq(ns.Attempts:GetCount(201), 1, "rapprochement par nom insensible à la casse")
end)

test("Attempts — monture obtenue : le compteur se fige", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = LoadWithSources({
		[201] = { instanceName = "Ulduar", encounterName = "Yogg-Saron", isRaid = true },
	})
	ns.Attempts:Invalidate()

	stub.Fire("ENCOUNTER_END", 1143, "Yogg-Saron", 14, 1, 1)
	local total, mounts = ns.Attempts:GetTotals()
	eq(total, 1, "une tentative au total")
	eq(mounts, 1, "sur une monture")

	stub.mounts[2].isCollected = true
	stub.Fire("NEW_MOUNT_ADDED", 201)
	stub.AdvanceFrames(2)
	stub.FlushTimers()

	eq(ns.db.global.attempts[201].obtainedAt ~= nil, true, "date d'obtention posée")
	total, mounts = ns.Attempts:GetTotals()
	eq(total, 0, "la monture obtenue sort du total en cours")
end)

test("Attempts — proba cumulée seulement si le taux de drop est connu", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = LoadWithSources({
		[201] = { instanceName = "Ulduar", encounterName = "Yogg-Saron", isRaid = true },
	})
	ns.Attempts:Invalidate()
	stub.Fire("ENCOUNTER_END", 1143, "Yogg-Saron", 14, 1, 1)

	eq(ns.Attempts:GetDryChance(201), nil, "sans taux de drop : pas de probabilité inventée")

	ns.db.global.sourceCache[201].dropRate = 0.01
	ns.Eligibility:Invalidate()
	local dry = ns.Attempts:GetDryChance(201)
	eq(dry ~= nil and math.abs(dry - 0.99) < 1e-9, true, "1 essai à 1 % : 99 % de rien")
end)

test("Database — remise à zéro reconstruit une base utilisable", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = harness.Load(stub)
	ns.Collection:SetExcluded(202, true)
	eq(ns.db.global.excluded[202], true, "exclusion posée")

	ns.Database:Wipe()
	eq(type(ns.db), "table", "ns.db toujours exploitable après effacement")
	eq(ns.db.global.excluded[202], nil, "exclusion effacée")
	eq(ns.db.charKey, "Krayne-Hyjal", "personnage courant recréé")
end)

test("Database — migration 1 -> 2 : les exclues redeviennent visibles", function()
	stub.Reset()
	_G.OnlyFarmDB = {
		schema = 1,
		global = { chars = {}, excluded = {} },
		profiles = {
			["Krayne-Hyjal"] = { filters = { hideExcluded = true, search = "loup" } },
			["Zaltus-Hyjal"] = { filters = { hideExcluded = false } },
		},
	}
	local ns = harness.Load(stub)

	eq(_G.OnlyFarmDB.schema, 2, "schéma migré")
	eq(ns.db.profile.filters.hideExcluded, false, "profil courant corrigé")
	eq(_G.OnlyFarmDB.profiles["Zaltus-Hyjal"].filters.hideExcluded, false,
		"autre profil laissé cohérent")
	eq(ns.db.profile.filters.search, "loup", "le reste du profil est intact")
end)

test("Database — une base neuve n'affiche pas les exclues masquées", function()
	stub.Reset()
	local ns = harness.Load(stub)
	eq(ns.db.profile.filters.hideExcluded, false, "défaut : exclues visibles, grisées")
	eq(type(ns.db.profile.minimap), "table", "réglages du bouton minicarte présents")
	eq(ns.db.profile.minimap.hide, false, "bouton minicarte affiché par défaut")
end)

--------------------------------------------------------------------------------
-- Bus d'événements
--------------------------------------------------------------------------------

test("Bus — événement inconnu ignoré sans casser le chargement", function()
	stub.Reset()
	local ns = harness.Load(stub)
	local received = false
	local owner = { Handler = function() received = true end }
	eq(ns:RegisterEvent("UN_EVENEMENT_QUI_NEXISTE_PAS", owner, "Handler"), false,
		"abonnement refusé proprement")
	eq(received, false, "aucun appel")
end)

test("Bus — erreur dans un handler n'interrompt pas les suivants", function()
	stub.Reset()
	local ns = harness.Load(stub)
	local secondCalled = false
	ns:RegisterMessage("OF_TEST", { Boom = function() error("boum") end }, "Boom")
	ns:RegisterMessage("OF_TEST", { Ok = function() secondCalled = true end }, "Ok")
	ns:SendMessage("OF_TEST")
	eq(secondCalled, true, "le second handler a bien tourné")
	eq(#stub.errors >= 1, true, "l'erreur est partie dans le gestionnaire du client")
end)

--------------------------------------------------------------------------------
-- Bilan
--------------------------------------------------------------------------------

print(string.format("\n%d assertions réussies, %d échecs\n", passed, failed))
if failed > 0 then
	for _, failure in ipairs(failures) do
		print("  ÉCHEC  " .. failure)
	end
	os.exit(1)
end
print("Tout est vert.")
os.exit(0)
