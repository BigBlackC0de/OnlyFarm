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

-- Régression : le Journal des montures sépare ses lignes par la séquence
-- « |n » du client, pas par un vrai retour à la ligne. En ne traitant que
-- « \n », la colonne affichait « Butin : Le roi-liche|... ».
test("Collection — séparateur |n et codes couleur retirés du résumé", function()
	stub.Reset()
	stub.mounts = {
		{ mountID = 301, name = "Invincible", sourceType = 1,
		  source = "Butin : Le roi-liche|nCitadelle de la Couronne de glace" },
		{ mountID = 302, name = "Autre", sourceType = 1,
		  source = "|cffffd200Butin|r : Sartharion|nL'Œil de l'éternité" },
	}
	local ns = harness.Load(stub)

	eq(ns.Collection:GetSourceSummary(301),
		"Butin : Le roi-liche — Citadelle de la Couronne de glace",
		"« |n » traité comme un saut de ligne")
	eq(ns.Collection:GetSourceSummary(302),
		"Butin : Sartharion — L'Œil de l'éternité",
		"codes couleur retirés")
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

test("Eligibility — sans identifiant moteur, le nom suffit", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = LoadWithSources({
		[201] = { instanceName = "Ulduar", isRaid = true, kind = "boss" },
	})
	-- Aucun instanceID appris, et c'est le cas courant : le joueur n'a jamais
	-- mis les pieds dans cette instance. Aucun verrou à ce nom non plus, donc
	-- elle est disponible — l'absence de verrou VAUT disponibilité.
	local status = ns.Eligibility:GetStatus(201)
	eq(status.state, ns.Eligibility.STATE.AVAILABLE, "pas de verrou à ce nom -> disponible")
end)

test("Eligibility — sans nom ni identifiant, on ne tranche pas", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = LoadWithSources({
		[201] = { isRaid = true, kind = "boss" },
	})
	local status = ns.Eligibility:GetStatus(201)
	eq(status.state, ns.Eligibility.STATE.UNKNOWN, "rien pour rapprocher un verrou")
	eq(status.detail, "instance_unresolved", "raison explicite")
end)

-- Régression : le 14e retour de GetSavedInstanceInfo n'est documenté nulle
-- part. Quand il manque, un rapprochement fondé sur lui seul échouait en
-- silence et l'addon annonçait « disponible » un raid tout juste terminé.
test("Eligibility — verrou lu même sans instanceID exposé (cas ICC)", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	stub.savedInstances = {
		{ name = "Citadelle de la Couronne de glace", instanceID = nil,
		  difficultyID = 5, reset = 4 * 86400, isRaid = true,
		  numEncounters = 12, encounterProgress = 12 },
	}
	local ns = LoadWithSources({
		[201] = { instanceName = "Citadelle de la Couronne de glace",
		          encounterName = "Le roi-liche", isRaid = true, kind = "boss" },
	})

	local status = ns.Eligibility:GetStatus(201)
	eq(status.state, ns.Eligibility.STATE.LOCKED, "verrou trouvé par le nom")
	eq(status.resetIn, 4 * 86400, "temps avant reset")

	-- Et il doit être visible dans la liste des verrous du tableau de bord,
	-- que la monture soit cartographiée ou non.
	local locks = ns.Lockouts:GetActiveLocks()
	eq(#locks, 1, "un verrou actif listé")
	eq(locks[1].encounterProgress, 12, "progression conservée")
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
-- Mapping
--------------------------------------------------------------------------------

test("Mapping — découpage du texte de source", function()
	stub.Reset()
	local ns = harness.Load(stub)
	local Parse = ns.Mapping.ParseSourceText

	local boss, place = Parse("Butin : Le roi-liche|nCitadelle de la Couronne de glace")
	eq(boss, "Le roi-liche", "boss extrait")
	eq(place, "Citadelle de la Couronne de glace", "lieu extrait")

	-- Codes couleur et espaces insécables : les deux traînent dans les
	-- libellés du client.
	boss, place = Parse("|cffffd200Butin|r :\194\160Sartharion|nL'Œil de l'éternité")
	eq(boss, "Sartharion", "codes couleur et espace insécable absorbés")
	eq(place, "L'Œil de l'éternité", "lieu extrait")

	-- Un nom de boss peut contenir un deux-points : on ne coupe qu'au premier.
	boss = Parse("Butin : Mimiron : phase 4|nUlduar")
	eq(boss, "Mimiron : phase 4", "seul le premier deux-points sépare")

	-- Une seule ligne : pas de lieu, et on ne l'invente pas.
	boss, place = Parse("Haut fait : Cavalier accompli")
	eq(boss, "Cavalier accompli", "sujet seul")
	eq(place, nil, "aucun lieu deviné")

	eq(Parse(nil), nil, "entrée nil")
	eq(Parse(""), nil, "entrée vide")
end)

test("Mapping — extension et instance déduites du texte de source", function()
	stub.Reset()
	stub.tiers = {
		{ name = "Wrath of the Lich King", instances = {
			{ id = 187, name = "Ulduar", isRaid = true },
			{ id = 186, name = "Citadelle de la Couronne de glace", isRaid = true },
		} },
		{ name = "Legion", instances = {
			{ id = 786, name = "Karazhan supérieur", isRaid = false },
		} },
	}
	stub.mounts = {
		{ mountID = 201, name = "Invincible", sourceType = 1,
		  source = "Butin : Le roi-liche|nCitadelle de la Couronne de glace" },
		{ mountID = 202, name = "Fumeronde", sourceType = 1,
		  source = "Butin : Yogg-Saron|nUlduar" },
		-- Lieu qui n'est pas une instance : on garde le texte sans prétendre
		-- que c'est un raid.
		{ mountID = 203, name = "Aeonaxx", sourceType = 1,
		  source = "Butin : Aeonaxx|nDéserts de Vashj'ir" },
	}
	local ns = harness.Load(stub)

	ns.Mapping:Run(false)
	stub.RunFrames(60)
	eq(ns.Mapping.running, false, "le scan se termine")

	local cache = ns.db.global.sourceCache
	eq(cache[201].instanceName, "Citadelle de la Couronne de glace", "instance rattachée")
	eq(cache[201].tierName, "Wrath of the Lich King", "extension déduite du palier")
	eq(cache[201].encounterName, "Le roi-liche", "boss retenu")
	eq(cache[201].isRaid, true, "raid reconnu")

	eq(cache[202].tierName, "Wrath of the Lich King", "seconde monture du même palier")

	eq(cache[203].instanceName, nil, "une zone n'est pas une instance")
	eq(cache[203].placeName, "Déserts de Vashj'ir", "le lieu est conservé tel quel")
	eq(cache[203].encounterName, "Aeonaxx", "le rare est retenu comme rencontre")

	-- Et c'est bien ça qui alimente le filtre par extension.
	local expansions = ns.Eligibility:GetKnownExpansions()
	eq(expansions[1].name, "Wrath of the Lich King", "l'extension apparaît dans le filtre")
end)

test("Mapping — la cartographie survit et ne se refait pas pour rien", function()
	stub.Reset()
	stub.tiers = {
		{ name = "Wrath", instances = { { id = 187, name = "Ulduar", isRaid = true } } },
	}
	stub.mounts = {
		{ mountID = 202, name = "Fumeronde", sourceType = 1,
		  source = "Butin : Yogg-Saron|nUlduar" },
	}
	local ns = harness.Load(stub)

	ns.Mapping:Run(false)
	stub.RunFrames(60)
	eq(ns.Mapping:IsStale(), false, "à jour juste après un scan")

	-- Un patch : le build change, il faut refaire.
	ns.db.global.scanMeta.build = "00000"
	eq(ns.Mapping:IsStale(), true, "build différent -> à refaire")

	-- Nouveau build mais surtout de nouvelles montures dans le client.
	ns.db.global.scanMeta.build = select(2, GetBuildInfo())
	eq(ns.Mapping:IsStale(), false, "rien de neuf")
	stub.mounts[#stub.mounts + 1] = { mountID = 999, name = "Nouvelle", sourceType = 1 }
	eq(ns.Mapping:IsStale(), true, "plus de montures qu'au dernier scan -> à refaire")
end)

-- Régression : en jeu, EJ_GetNumTiers renvoyait 0 et l'index restait vide, ce
-- qui donnait « 0/1619 cartographiées » sans la moindre erreur. La liste du
-- Recherche de groupe doit suffire à elle seule.
test("Mapping — le Journal muet, la liste du Recherche de groupe suffit", function()
	stub.Reset()
	stub.tiers = {}   -- EJ_GetNumTiers() = 0, exactement le cas observé
	stub.lfgDungeons = {
		[100] = { name = "Citadelle de la Couronne de glace", subtypeID = 3, expansionLevel = 2 },
		[101] = { name = "Karazhan supérieur", subtypeID = 1, expansionLevel = 6 },
	}
	stub.mounts = {
		{ mountID = 201, name = "Invincible", sourceType = 1,
		  source = "Butin : Le roi-liche|nCitadelle de la Couronne de glace" },
		{ mountID = 202, name = "Fauve", sourceType = 1,
		  source = "Butin : Attumen|nKarazhan supérieur" },
	}
	local ns = harness.Load(stub)

	ns.Mapping:Run(false)
	stub.RunFrames(80)
	eq(ns.Mapping.running, false, "le scan se termine")

	local cache = ns.db.global.sourceCache
	eq(cache[201].tierName, "Wrath of the Lich King", "extension via le Recherche de groupe")
	eq(cache[201].isRaid, true, "raid reconnu par le subtypeID")
	eq(cache[202].tierName, "Legion", "donjon d'une autre extension")
	eq(cache[202].isRaid, false, "donjon, pas raid")
	eq(ns.db.global.scanMeta.mapped, 2, "les deux montures rattachées")
	eq(ns.db.global.scanMeta.journalInstances, 0, "le Journal n'a rien donné, et on le dit")
end)

test("Mapping — le Journal prime quand les deux répondent", function()
	stub.Reset()
	stub.tiers = {
		{ name = "Wrath of the Lich King", instances = {
			{ id = 186, name = "Citadelle de la Couronne de glace", isRaid = true },
		} },
	}
	stub.lfgDungeons = {
		[100] = { name = "Citadelle de la Couronne de glace", subtypeID = 3, expansionLevel = 2 },
	}
	stub.mounts = {
		{ mountID = 201, name = "Invincible", sourceType = 1,
		  source = "Butin : Le roi-liche|nCitadelle de la Couronne de glace" },
	}
	local ns = harness.Load(stub)

	ns.Mapping:Run(false)
	stub.RunFrames(80)

	-- Le journalInstanceID ne vient que du Journal : c'est lui qui relie une
	-- instance à son entrée sur la carte, donc il doit gagner.
	eq(ns.db.global.sourceCache[201].journalInstanceID, 186, "identifiant du Journal retenu")
	eq(ns.db.global.sourceCache[201].tierName, "Wrath of the Lich King", "extension cohérente")
end)

test("Mapping — sans palier lisible, le scan n'invente rien", function()
	stub.Reset()
	stub.tiers = {}
	stub.mounts = {
		{ mountID = 201, name = "Invincible", sourceType = 1,
		  source = "Butin : Le roi-liche|nCitadelle de la Couronne de glace" },
	}
	local ns = harness.Load(stub)

	ns.Mapping:Run(false)
	stub.RunFrames(60)

	local entry = ns.db.global.sourceCache[201]
	eq(entry.encounterName, "Le roi-liche", "le boss reste lisible")
	eq(entry.tierName, nil, "aucune extension inventée")
	eq(ns.Eligibility:GetExpansion(201), ns.Eligibility.UNKNOWN_EXPANSION,
		"la monture tombe dans le panier « inconnue »")
end)

--------------------------------------------------------------------------------
-- Stats
--------------------------------------------------------------------------------

test("Stats — compteurs et ratio de collection", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = harness.Load(stub)

	local stats = ns.Stats:Get()
	eq(stats.owned, 1, "une possédée")
	eq(stats.missing, 3, "trois manquantes")
	eq(stats.total, 4, "total obtenable")
	eq(stats.hidden, 1, "une hors de portée")
	eq(math.abs(stats.ratio - 0.25) < 1e-9, true, "ratio de progression")
end)

test("Stats — répartition par statut", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = LoadWithSources({
		[201] = { instanceName = "Ulduar", isRaid = true },
		[202] = { kind = "vendor", lockout = "none" },
	})
	ns.db.global.instanceIDsByName["ulduar"] = 759
	ns.Stats:Invalidate()

	local STATE = ns.Eligibility.STATE
	local stats = ns.Stats:Get()
	eq(stats.byState[STATE.AVAILABLE], 2, "raid libre + vendeur")
	eq(stats.byState[STATE.UNMAPPED], 1, "la troisième n'a pas de source")
	eq(stats.availableCount, 2, "deux cibles ouvertes")
end)

test("Stats — progression par extension, les moins avancées d'abord", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = harness.Load(stub)
	-- La monture possédée et une manquante sur le même palier ; une manquante
	-- seule sur un autre. Le second palier est donc moins avancé.
	ns.db.global.sourceCache = {
		[100] = { tierName = "Wrath", tier = 3 },
		[201] = { tierName = "Wrath", tier = 3 },
		[202] = { tierName = "Legion", tier = 6 },
	}
	ns.Eligibility:Invalidate()
	ns.Stats:Invalidate()

	local stats = ns.Stats:Get()
	eq(stats.expansions[1].name, "Legion", "0/1 passe devant 1/2")
	eq(stats.expansions[1].owned, 0, "rien de possédé sur Legion")
	eq(stats.expansions[1].total, 1, "une monture sur Legion")

	-- Le panier « inconnue » est mécaniquement à 0 % : il doit rester dernier
	-- au lieu de squatter la première barre en permanence.
	eq(stats.expansions[#stats.expansions].name, ns.Eligibility.UNKNOWN_EXPANSION,
		"les sources non cartographiées ferment la marche")

	local wrath
	for _, bucket in ipairs(stats.expansions) do
		if bucket.name == "Wrath" then wrath = bucket end
	end
	eq(wrath and wrath.owned, 1, "la possédée compte dans son extension")
	eq(wrath and wrath.total, 2, "dénominateur complet")
end)

test("Stats — cibles du moment triées par tentatives", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = LoadWithSources({
		[201] = { kind = "vendor", lockout = "none" },
		[202] = { kind = "vendor", lockout = "none" },
	})
	ns.Attempts:Bump(202, nil, 5)
	ns.Stats:Invalidate()

	local stats = ns.Stats:Get()
	eq(#stats.topTargets, 2, "deux cibles disponibles")
	eq(stats.topTargets[1].mountID, 202, "la plus attendue en tête")
	eq(stats.topTargets[1].attempts, 5, "avec son compte")
end)

test("Stats — une monture exclue sort des agrégats", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = LoadWithSources({
		[201] = { kind = "vendor", lockout = "none" },
		[202] = { kind = "vendor", lockout = "none" },
	})
	eq(ns.Stats:Get().availableCount, 2, "deux cibles au départ")

	ns.Collection:SetExcluded(202, true)
	ns.Stats:Invalidate()
	eq(ns.Stats:Get().availableCount, 1, "l'exclue ne compte plus")
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
