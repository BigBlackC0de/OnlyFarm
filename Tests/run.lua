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
		{ mountID = 100, name = "Cheval alezan", sourceType = 3, isCollected = true,
		  mountTypeID = 230 },
		-- manquante, butin de raid
		{ mountID = 201, name = "Proto-drake fumeronde", sourceType = 1,
		  itemID = 32458, source = "Butin : Yogg-Saron\nUlduar", mountTypeID = 248 },
		-- manquante, vendeur
		{ mountID = 202, name = "Brutosaure gigantesque", sourceType = 3,
		  source = "Vendeur : Talutu", mountTypeID = 230 },
		-- manquante, mais masquée sur ce personnage (faction adverse)
		{ mountID = 203, name = "Loup de guerre", sourceType = 1,
		  shouldHideOnChar = true, faction = 0, mountTypeID = 230 },
		-- manquante, butin de donjon. Son mountTypeID est volontairement
		-- inconnu : c'est le cas d'un type ajouté par un patch, qui doit tomber
		-- dans « autre » sans rien inventer.
		{ mountID = 204, name = "Cheval en flammes", sourceType = 1,
		  source = "Butin : Attumen\nÉcurie", mountTypeID = 991 },
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
	-- L'espace insécable du client français doit se comparer comme un espace.
	eq(ns.Util.NormalizeName("Région\194\160: Ulduar"), "région : ulduar",
		"espace insécable ramené à un espace ordinaire")
end)

--------------------------------------------------------------------------------
-- Database
--------------------------------------------------------------------------------

test("Database — création et estampille de schéma", function()
	stub.Reset()
	local ns = harness.Load(stub)
	eq(_G.OnlyFarmDB.schema, 3, "schéma estampillé à la version courante")
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

test("Collection — catégories de source, celles du client et pas les nôtres", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = harness.Load(stub)

	local sources = ns.Collection:GetSourceTypes()
	-- Deux butins (201, 204) et deux vendeurs (100 possédée, 202) ; la monture
	-- masquée sur ce personnage ne compte nulle part.
	eq(#sources, 2, "deux catégories présentes")
	eq(sources[1].label, "Drop", "libellé fourni par le client")
	eq(sources[1].sourceType, 1, "indexé par le sourceType, pas par notre kind")
	eq(sources[1].total, 2, "effectif complet")
	eq(sources[1].missing, 2, "dont deux manquantes")
	eq(sources[2].label, "Vendor", "puis les vendeurs")
	eq(sources[2].total, 2, "effectif complet")
	eq(sources[2].missing, 1, "dont une seule manquante")
	eq(sources[2].owned, 1, "et une possédée")

	-- On ne liste QUE ce qui existe : un menu plein d'entrées à zéro résultat
	-- se lit comme un menu cassé.
	for _, entry in ipairs(sources) do
		eq(entry.total > 0, true, "aucune catégorie vide dans la liste")
	end
end)

test("Collection — promotion, JCC, boutique et comptoir ne fusionnent plus", function()
	stub.Reset()
	-- Ces cinq sourceType partagent le même `kind` interne (« unknown ») parce
	-- qu'aucun ne porte de verrou. Les afficher par `kind` produisait UN seau de
	-- cinq catégories, étiqueté du libellé de la première monture croisée : le
	-- menu annonçait « Promotion (5) » pour cinq choses différentes.
	stub.mounts = {
		{ mountID = 301, name = "Promo", sourceType = 8 },
		{ mountID = 302, name = "JCC", sourceType = 9 },
		{ mountID = 303, name = "Boutique", sourceType = 10 },
		{ mountID = 304, name = "Découverte", sourceType = 11 },
		{ mountID = 305, name = "Comptoir", sourceType = 12 },
	}
	local ns = harness.Load(stub)

	eq(ns.Data.GetSourceKind(8), ns.Data.GetSourceKind(9),
		"les cinq partagent bien le même kind interne")

	local sources = ns.Collection:GetSourceTypes()
	eq(#sources, 5, "cinq catégories distinctes à l'affichage")
	for _, entry in ipairs(sources) do
		eq(entry.total, 1, "chacune avec son unique monture")
	end
	-- Et chacune porte SON libellé, pas celui de sa voisine.
	eq(sources[1].label, "Discovery", "libellés distincts, ordonnés")
	eq(sources[5].label, "Trading Post", "jusqu'au dernier")

	-- Et le graphe du tableau de bord voit exactement la même chose : c'est la
	-- même fonction de seau et le même comparateur.
	local breakdown = ns.Stats:GetBreakdown("source")
	eq(#breakdown, #sources, "le graphe liste autant de catégories que le filtre")
	for index, bucket in ipairs(breakdown) do
		eq(bucket.label, sources[index].label, "mêmes libellés, dans le même ordre")
	end
end)

test("Collection — les possédées sont listées aussi", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = harness.Load(stub)

	local collected = ns.Collection:GetCollected()
	eq(#collected, 1, "une monture possédée listée")
	eq(collected[1].mountID, 100, "la bonne")
	eq(collected[1].owned, true, "marquée comme possédée")

	-- Une entrée existe pour les possédées : la liste doit pouvoir les
	-- afficher, et l'aperçu 3D en a besoin.
	eq(ns.Collection:GetEntry(100) ~= nil, true, "entrée disponible pour une possédée")
	eq(ns.Collection:GetEntry(201).owned, false, "une manquante ne l'est pas")

	-- Les manquantes ne bougent pas.
	eq(#ns.Collection:GetMissing(), 3, "trois manquantes")
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

-- Régression : le tableau de bord affichait « Citadelle de la Couronne de
-- glace, 11/12, reset dans 3j » pendant que la monture qui en tombe restait
-- « incertain ». Le verrou est un fait mesuré ; il doit être consulté AVANT
-- toute question d'horloge, et même quand la cartographie n'a pas abouti.
test("Eligibility — le verrou prime, même sur une source non cartographiée", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	stub.savedInstances = {
		{ name = "Citadelle de la Couronne de glace", instanceID = 631,
		  difficultyID = 5, difficultyName = "25 joueurs (héroïque)",
		  reset = 3 * 86400, isRaid = true, numEncounters = 12, encounterProgress = 11 },
	}
	-- La cartographie a échoué : pas d'instanceName, seulement le lieu brut du
	-- texte de source, avec son étiquette « Région : » et un espace insécable.
	local ns = LoadWithSources({
		[201] = {
			kind = "boss",
			encounterName = "Le roi-liche",
			placeName = "Région\194\160: Citadelle de la Couronne de glace",
		},
	})

	local status = ns.Eligibility:GetStatus(201)
	eq(status.state, ns.Eligibility.STATE.LOCKED, "verrou trouvé malgré l'étiquette")
	eq(status.resetIn, 3 * 86400, "temps avant reset")
	eq(status.detail, "25 joueurs (héroïque)", "difficulté du verrou remontée")
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

	eq(_G.OnlyFarmDB.schema, 3, "schéma migré jusqu'à la version courante")
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

-- Régression : le client écrit tantôt un vrai saut de ligne, tantôt « |n ».
-- N'en gérer qu'un donnait un texte d'une seule ligne, donc aucun lieu, donc
-- « 0 sur 1619 rattachées » — sans la moindre erreur pour le signaler.
test("Mapping — les deux séparateurs de ligne sont acceptés", function()
	stub.Reset()
	local ns = harness.Load(stub)
	local Parse = ns.Mapping.ParseSourceText

	local boss, place = Parse("Butin : Le roi-liche|nCitadelle de la Couronne de glace")
	eq(boss, "Le roi-liche", "séquence |n : boss")
	eq(place, "Citadelle de la Couronne de glace", "séquence |n : lieu")

	boss, place = Parse("Butin : Le roi-liche\nCitadelle de la Couronne de glace")
	eq(boss, "Le roi-liche", "vrai saut de ligne : boss")
	eq(place, "Citadelle de la Couronne de glace", "vrai saut de ligne : lieu")

	boss, place = Parse("Butin : Le roi-liche\r\nCitadelle de la Couronne de glace")
	eq(place, "Citadelle de la Couronne de glace", "retour chariot Windows")

	-- Régression, vue sur les données DB2 réelles : le lieu n'est pas toujours
	-- la DERNIÈRE ligne. « Vendeur … |n Zone … |n Coût … » en a trois, et la
	-- dernière est le prix.
	local _, first, all = Parse("Vendeur : Unger Statforth|nZone : Wetlands|nCoût : 1 or")
	eq(#all, 2, "deux lignes candidates après le sujet")
	eq(all[1], "Zone : Wetlands", "le lieu est la deuxième ligne")
	eq(all[2], "Coût : 1 or", "le prix reste candidat, il ne correspondra à rien")
	eq(first, all[1], "la première candidate est renvoyée par commodité")
end)

-- Et le rapprochement doit trouver le lieu même quand il est suivi d'un prix.
test("Mapping — le lieu est trouvé au milieu des lignes", function()
	stub.Reset()
	stub.lfgDungeons = {
		[100] = { name = "Gnomeregan", subtypeID = 1, expansionLevel = 0 },
	}
	-- Trois lignes, et le lieu est celle du MILIEU : prendre la dernière donnait
	-- la ligne de coût, prendre la première donnait le nom du boss.
	--
	-- La monture est un BUTIN (sourceType 1). C'était un vendeur avant, et le
	-- test passait parce que l'addon rattachait alors n'importe quel lieu à
	-- n'importe quelle instance — c'est précisément ce qui est corrigé.
	stub.mounts = {
		{ mountID = 6, spellID = 458, name = "Cheval bai", sourceType = 1,
		  source = "Butin : Mekgineer Thermaplugg|nZone : Gnomeregan|nHéroïque" },
	}
	local ns = harness.Load(stub)

	ns.Mapping:Run(false)
	stub.RunFrames(80)

	local entry = ns.db.global.sourceCache[6]
	eq(entry.tierName, "Vanilla", "extension trouvée malgré la troisième ligne")
	eq(entry.instanceName, "Gnomeregan", "lieu rapproché sur la bonne ligne")
end)

test("Mapping — replis de rapprochement des noms d'instance", function()
	stub.Reset()
	local ns = harness.Load(stub)
	local index = {
		["citadelle de la couronne de glace"] = { name = "Citadelle de la Couronne de glace" },
		["karazhan"] = { name = "Karazhan" },
	}

	local match, how = ns.Mapping.MatchPlace(index, "Citadelle de la Couronne de glace")
	eq(how, "exact", "correspondance directe")

	-- Le Recherche de groupe nomme ses ailes ; le Journal des montures non.
	match, how = ns.Mapping.MatchPlace(index,
		"Citadelle de la Couronne de glace : Le Bastion inférieur")
	eq(match and match.name, "Citadelle de la Couronne de glace", "suffixe d'aile ignoré")
	eq(how, "prefix", "repli par préfixe")

	-- Régression : la seconde ligne du texte de source est souvent ÉTIQUETÉE
	-- (« Région : Libération de Terremine »). Sans savoir enlever l'étiquette,
	-- aucune de ces montures ne se rattachait.
	local labelled = {
		["libération de terremine"] = { name = "Libération de Terremine" },
	}
	-- Avec un espace insécable devant le deux-points, comme le client français.
	match, how = ns.Mapping.MatchPlace(labelled, "Région\194\160: Libération de Terremine")
	eq(match and match.name, "Libération de Terremine", "étiquette « Région : » retirée")
	eq(how, "labelled", "repli par étiquette")

	-- Un nom trop court ne doit rien attraper au hasard.
	eq(ns.Mapping.MatchPlace(index, "Kara"), nil, "nom trop court, aucun rapprochement")
	eq(ns.Mapping.MatchPlace(index, "Uldaman"), nil, "instance absente de l'index")
end)

test("Mapping — un fragment de nom ne désigne pas une instance", function()
	stub.Reset()
	local ns = harness.Load(stub)

	-- Le bug réel : « Le Bastion », la zone de Shadowlands où se tient un vendeur
	-- de montures, est un sous-mot de « Le bastion du Crépuscule », un raid de
	-- Cataclysm. L'addon envoyait chercher en raid une monture qui s'achète chez
	-- un PNJ.
	local index = {
		["le bastion du crépuscule"] = { name = "Le bastion du Crépuscule", isRaid = true },
	}
	eq(ns.Mapping.MatchPlace(index, "Le Bastion"), nil,
		"une zone dont le nom est un fragment d'instance ne se rattache pas")
	eq(ns.Mapping.MatchPlace(index, "Région : Le Bastion"), nil,
		"même étiquetée")

	-- Le sens inverse reste légitime : le texte de lieu CONTIENT le nom exact de
	-- l'instance. C'est le cas des ailes du Recherche de groupe.
	local match, how = ns.Mapping.MatchPlace(index,
		"Le bastion du Crépuscule — aile supérieure")
	eq(match and match.name, "Le bastion du Crépuscule", "le sens utile est conservé")
	eq(how, "partial", "par correspondance partielle")
end)

test("Mapping — deux instances également plausibles : on refuse", function()
	stub.Reset()
	local ns = harness.Load(stub)
	-- Deux noms de même longueur contenus dans le même texte. L'ordre de parcours
	-- d'une table Lua n'étant pas défini, « la première trouvée » donnerait deux
	-- réponses différentes à deux joueurs.
	local index = {
		["donjon de gauche"] = { name = "Donjon de gauche" },
		["donjon de droite"] = { name = "Donjon de droite" },
	}
	eq(ns.Mapping.MatchPlace(index, "Donjon de gauche et Donjon de droite"), nil,
		"ambiguïté : aucune réponse plutôt qu'une réponse au hasard")
end)

test("Mapping — une monture de vendeur ne se rattache à aucune instance", function()
	stub.Reset()
	-- Le nom de la zone du vendeur est volontairement un fragment du nom du raid,
	-- comme dans le cas réel. Même si le rapprochement de texte laissait passer
	-- quelque chose, le sourceType du client interdit la recherche.
	stub.tiers = {
		{ name = "Cataclysm", instances = {
			{ id = 73, name = "Le bastion du Crépuscule", isRaid = true },
		} },
	}
	stub.mounts = {
		-- sourceType 3 = Vendeur.
		{ mountID = 401, name = "Aquilon", sourceType = 3,
		  source = "Vendeur : Adjudant Galos|nRégion : Le Bastion|nCoût : 7500" },
		-- sourceType 1 = Butin : celle-là a le droit de se rattacher.
		{ mountID = 402, name = "Drake", sourceType = 1,
		  source = "Butin : Cho'gall|nLe bastion du Crépuscule" },
	}
	local ns = harness.Load(stub)

	ns.Mapping:Run(false)
	stub.RunFrames(400)
	stub.FlushTimers()

	local cache = ns.db.global.sourceCache
	eq(cache[401] ~= nil, true, "la monture de vendeur est bien dans le cache")
	eq(cache[401].instanceName, nil, "mais sans instance")
	eq(cache[401].isRaid, nil, "et sans verrou de raid")
	-- Le lieu est conservé BRUT, étiquette comprise. La découper demanderait de
	-- reconnaître « Région : » dans treize langues, et le texte du client reste
	-- la donnée la plus sûre qu'on ait.
	eq(cache[401].placeName, "Région : Le Bastion", "son lieu est conservé tel quel")

	eq(cache[402].instanceName, "Le bastion du Crépuscule", "le butin, lui, se rattache")
	eq(cache[402].isRaid, true, "et c'est bien un raid")
end)

test("Mapping — l'extension originale s'appelle Vanilla", function()
	stub.Reset()
	local ns = harness.Load(stub)
	ns.Data.ResetExpansionIndex()

	-- Le client la nomme « World of Warcraft », ce qui ne distingue rien dans
	-- une liste où tout est une extension de World of Warcraft.
	eq(_G.EXPANSION_NAME0, "Classic", "le client dit autre chose")
	eq(ns.Data.ExpansionName(0), "Vanilla", "l'addon affiche Vanilla")
	eq(ns.Data.ExpansionName(2), "Wrath of the Lich King", "les autres gardent le nom du client")

	-- Journal et client comptent différemment : palier 1 = niveau 0.
	eq(ns.Data.TierToExpansionLevel(1), 0, "palier 1 -> niveau 0")
	eq(ns.Data.TierToExpansionLevel(3), 2, "palier 3 -> niveau 2")

	-- Et un nom de palier doit retrouver son niveau, pour que les deux sources
	-- convergent sur une seule barre.
	eq(ns.Data.ExpansionLevelFromName("Wrath of the Lich King"), 2, "nom -> niveau")
	eq(ns.Data.ExpansionLevelFromName("Vanilla"), 0, "l'alias marche aussi")
end)

test("Mapping — les deux sources convergent sur un seul nom d'extension", function()
	stub.Reset()
	-- Le Journal appelle le palier « Wrath of the Lich King », le Recherche de
	-- groupe donne le niveau 2. Les deux doivent produire la même barre.
	stub.tiers = {
		{ name = "Classic", instances = { { id = 1, name = "Coeur du Magma", isRaid = true } } },
		{ name = "The Burning Crusade", instances = {} },
		{ name = "Wrath of the Lich King", instances = {
			{ id = 186, name = "Citadelle de la Couronne de glace", isRaid = true },
		} },
	}
	stub.lfgDungeons = {
		[100] = { name = "Ulduar", subtypeID = 3, expansionLevel = 2 },
	}
	stub.mounts = {
		{ mountID = 201, name = "Invincible", sourceType = 1,
		  source = "Butin : Le roi-liche\nCitadelle de la Couronne de glace" },
		{ mountID = 202, name = "Fumeronde", sourceType = 1,
		  source = "Butin : Yogg-Saron\nUlduar" },
		{ mountID = 203, name = "Coursier", sourceType = 1,
		  source = "Butin : Ragnaros\nCoeur du Magma" },
	}
	local ns = harness.Load(stub)

	ns.Mapping:Run(false)
	stub.RunFrames(80)

	local cache = ns.db.global.sourceCache
	eq(cache[201].tierName, cache[202].tierName,
		"Journal et Recherche de groupe donnent le même libellé")
	eq(cache[201].tierName, "Wrath of the Lich King", "et c'est le bon")
	eq(cache[203].tierName, "Vanilla", "le palier 1 du Journal devient Vanilla")
	eq(ns.db.global.scanMeta.mapped, 3, "les trois montures rattachées")
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

	-- L'extension reste dans le cache : elle n'alimente plus de filtre, mais
	-- c'est elle que `/of export` met dans le fichier de curation.
	eq(ns.Eligibility:GetExpansion(201), "Wrath of the Lich King",
		"l'extension reste lisible monture par monture")
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

-- Régression : un scan qui écrit 1600 entrées mais n'en rattache AUCUNE à une
-- instance passait pour frais. L'auto-scan ne se relançait donc jamais, et une
-- correction de la logique restait sans effet jusqu'au patch suivant.
test("Mapping — un scan qui ne rattache rien est à refaire", function()
	stub.Reset()
	stub.tiers = {}
	stub.lfgDungeons = {}
	stub.mounts = {
		{ mountID = 201, name = "Invincible", sourceType = 1,
		  source = "Butin : Le roi-liche|nCitadelle de la Couronne de glace" },
	}
	local ns = harness.Load(stub)

	ns.Mapping:Run(false)
	stub.RunFrames(80)

	eq(ns.db.global.scanMeta.mapped, 0, "rien de rattaché, comme attendu")
	eq(ns.db.global.scanMeta.emptyRuns, 1, "passage infructueux compté")
	eq(ns.Mapping:IsStale(), true, "donc à refaire")

	-- Mais pas indéfiniment : au bout de trois tentatives, on arrête d'insister.
	ns.db.global.scanMeta.emptyRuns = 3
	eq(ns.Mapping:IsStale(), false, "on n'insiste pas éternellement")

	-- Et dès qu'une passe rattache quelque chose, le compteur retombe.
	stub.lfgDungeons = {
		[100] = { name = "Citadelle de la Couronne de glace", subtypeID = 3, expansionLevel = 2 },
	}
	ns.Mapping:Run(false)
	stub.RunFrames(80)
	eq(ns.db.global.scanMeta.mapped, 1, "rattachée cette fois")
	eq(ns.db.global.scanMeta.emptyRuns, 0, "compteur remis à zéro")
	eq(ns.Mapping:IsStale(), false, "et le cache redevient frais")
end)

-- Le cache d'un joueur ne connaît pas les corrections apportées au code. Sans
-- ce garde-fou, une refonte de la cartographie reste invisible tant que le
-- client ne change pas de build.
test("Mapping — un changement d'algorithme périme les caches existants", function()
	stub.Reset()
	stub.lfgDungeons = {
		[100] = { name = "Ulduar", subtypeID = 3, expansionLevel = 2 },
	}
	stub.mounts = {
		{ mountID = 202, name = "Fumeronde", sourceType = 1,
		  source = "Butin : Yogg-Saron|nUlduar" },
	}
	local ns = harness.Load(stub)

	ns.Mapping:Run(false)
	stub.RunFrames(80)
	eq(ns.Mapping:IsStale(), false, "frais juste après")

	ns.db.global.scanMeta.mappingVersion = 1   -- cache d'une version précédente
	eq(ns.Mapping:IsStale(), true, "algorithme différent -> à refaire")
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

-- La table curée est le seul moyen de rattacher les montures que le client ne
-- sait pas situer : vendeurs, métiers, événements, PvP. Elle ne doit JAMAIS
-- primer sur une donnée dérivée du client, qui suit les patchs.
-- L'extension par l'objet est la seule source EXACTE : elle vient du client,
-- sans rapprochement de noms ni inférence. Elle doit donc écraser les
-- heuristiques, y compris un rapprochement de lieu réussi.
test("Mapping — l'extension de l'objet prime sur les heuristiques", function()
	stub.Reset()
	stub.lfgDungeons = {
		-- Volontairement faux : le lieu rattacherait la monture à Legion.
		[100] = { name = "Ulduar", subtypeID = 3, expansionLevel = 6 },
	}
	stub.items = { [45693] = { name = "Rênes", expansionID = 2 } }
	stub.mounts = {
		{ mountID = 201, spellID = 1001, name = "Fumeronde", sourceType = 1,
		  source = "Butin : Yogg-Saron\nUlduar" },
	}
	local ns = harness.Load(stub)
	-- itemID connu d'une passe approfondie précédente, conservé dans le cache.
	ns.db.global.sourceCache = { [201] = { itemID = 45693 } }

	ns.Mapping:Run(false)
	stub.RunFrames(120)

	local entry = ns.db.global.sourceCache[201]
	eq(entry.itemID, 45693, "l'itemID connu est repris du cache")
	eq(entry.matchedBy, "item", "c'est l'objet qui a tranché")
	eq(entry.tierName, "Wrath of the Lich King", "extension exacte de l'objet")
	-- L'instance reste celle du rapprochement de lieu : c'est elle qui sert
	-- aux verrous, et l'objet ne la donne pas.
	eq(entry.instanceName, "Ulduar", "l'instance du lieu est conservée")
end)

-- La table curée vient de ItemSparse.ExpansionID, c'est-à-dire du même champ
-- que le client expose sous le nom `expansionID`. C'est une donnée d'autorité,
-- pas une déduction : elle doit passer DEVANT le rapprochement de noms de
-- lieux, qui n'est qu'une heuristique.
test("Mapping — la table curée prime sur le rapprochement de lieu", function()
	stub.Reset()
	stub.lfgDungeons = {
		-- Le lieu rattacherait la monture à Legion. Il a tort.
		[100] = { name = "Ulduar", subtypeID = 3, expansionLevel = 6 },
	}
	stub.mounts = {
		{ mountID = 201, spellID = 1001, name = "Fumeronde", sourceType = 1,
		  source = "Butin : Yogg-Saron\nUlduar" },
		{ mountID = 202, spellID = 1002, name = "Brutosaure", sourceType = 3,
		  source = "Vendeur : Talutu" },
	}
	local ns = harness.Load(stub)
	ns.Data.Mounts = {
		[201] = { expansion = 2 },
		[202] = { expansion = 7, kind = "vendor", dropRate = 1 },
	}

	ns.Mapping:Run(false)
	stub.RunFrames(80)

	local cache = ns.db.global.sourceCache
	eq(cache[201].tierName, "Wrath of the Lich King", "la curation corrige le lieu")
	eq(cache[201].matchedBy, "curated", "et le dit")
	-- L'instance reste celle du lieu : la curation ne la donne pas dans la
	-- langue du client, et c'est ce nom-là qui sert aux verrous.
	eq(cache[201].instanceName, "Ulduar", "l'instance du lieu est conservée")

	-- Et elle comble ce qu'aucune heuristique n'atteint : un vendeur.
	eq(cache[202].tierName, "Battle for Azeroth", "la curation comble le trou")
	eq(cache[202].dropRate, 1, "taux de drop repris")

	-- Une source qui ne connaît que le spellID doit rester exploitable.
	ns.Data.Mounts = { [9999] = { spellID = 1002, expansion = 3 } }
	eq(ns.Data.GetCuratedMount(202, 1002).expansion, 3, "repli par spellID")
	eq(ns.Data.GetCuratedMount(202, nil), nil, "sans clé utilisable, rien")
end)

-- Une curation sans extension ne doit PAS masquer ce que le client sait : une
-- entrée qui n'apporte rien vaut mieux ignorée qu'appliquée.
test("Mapping — une curation muette laisse la main aux heuristiques", function()
	stub.Reset()
	stub.lfgDungeons = {
		[100] = { name = "Ulduar", subtypeID = 3, expansionLevel = 2 },
	}
	stub.mounts = {
		{ mountID = 201, spellID = 1001, name = "Fumeronde", sourceType = 1,
		  source = "Butin : Yogg-Saron\nUlduar" },
	}
	local ns = harness.Load(stub)
	ns.Data.Mounts = { [201] = { dropRate = 0.01 } }   -- pas d'extension

	ns.Mapping:Run(false)
	stub.RunFrames(80)

	local entry = ns.db.global.sourceCache[201]
	eq(entry.tierName, "Wrath of the Lich King", "le lieu garde la main")
	eq(entry.dropRate, 0.01, "mais le taux de drop curé est repris")
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

test("Stats — répartition par nature de source", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = harness.Load(stub)

	-- Deux butins (201, 204) et deux vendeurs (100 possédée, 202). La monture
	-- masquée sur ce personnage ne compte nulle part : elle ne tombera jamais.
	local breakdown = ns.Stats:GetBreakdown("source")
	eq(#breakdown, 2, "deux natures de source présentes")
	eq(breakdown.max, 2, "le plus gros effectif sert d'échelle")

	-- À effectif égal, l'ordre suit le libellé : il ne bouge donc pas d'un
	-- rafraîchissement à l'autre.
	eq(breakdown[1].label, "Drop", "le libellé vient du client")
	eq(breakdown[1].owned, 0, "aucun butin possédé")
	eq(breakdown[1].total, 2, "deux butins obtenables")
	eq(breakdown[2].label, "Vendor", "puis les vendeurs")
	eq(breakdown[2].owned, 1, "la possédée compte dans sa catégorie")
	eq(breakdown[2].total, 2, "dénominateur complet")
end)

test("Stats — répartition par mode de déplacement", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = harness.Load(stub)

	local breakdown = ns.Stats:GetBreakdown("movement")
	eq(#breakdown, 3, "terrestre, volante, autre")

	-- L'ordre est celui de Data.MOVEMENT_ORDER, pas l'effectif : il se lit comme
	-- une légende, et « autre » ferme la marche.
	eq(breakdown[1].key, ns.Data.MOVEMENT.GROUND, "terrestre d'abord")
	eq(breakdown[1].owned, 1, "la possédée est terrestre")
	eq(breakdown[1].total, 2, "deux terrestres obtenables")
	eq(breakdown[2].key, ns.Data.MOVEMENT.FLYING, "puis volante")
	eq(breakdown[3].key, ns.Data.MOVEMENT.OTHER,
		"un mountTypeID inconnu tombe dans « autre », sans supposition")
	eq(breakdown[3].label, ns.L.MOVE_OTHER, "et il est étiqueté comme tel")
end)

test("Stats — montures obtenues depuis l'installation", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = harness.Load(stub)

	-- Le repère est posé au premier scan : rien n'a encore été obtenu DEPUIS.
	eq(ns.db.global.baseline.owned, 1, "repère posé sur le total du compte")
	eq(ns.Stats:Get().obtained.count, 0, "aucune acquisition au départ")

	stub.mounts[3].isCollected = true
	stub.Fire("NEW_MOUNT_ADDED", 202)
	stub.AdvanceFrames(2)
	stub.FlushTimers()

	eq(ns.db.global.baseline.owned, 1, "le repère ne bouge plus")
	eq(ns.Stats:Get().obtained.count, 1, "une monture obtenue depuis")
end)

test("Stats — les montures hors de portée comptent dans le repère", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	-- La monture 203 est masquée sur ce personnage (faction adverse), mais la
	-- collection est liée au COMPTE : la posséder compte. Sinon changer de perso
	-- ferait varier « obtenues depuis l'installation », qui n'a rien à voir avec
	-- le personnage connecté.
	stub.mounts[4].isCollected = true
	local ns = harness.Load(stub)

	eq(ns.Collection.counts.ownedAll, 2, "les deux possédées comptent")
	eq(ns.Collection.counts.owned, 1, "une seule est obtenable ici")
	eq(ns.Stats:Get().obtained.count, 0, "et le compteur part bien de zéro")
end)

test("Stats — un retrait de monture ne rend pas le compteur négatif", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = harness.Load(stub)

	-- Blizzard retire ou fusionne parfois une monture : le total passe alors
	-- sous le repère. « -1 obtenue » serait un non-sens à l'écran.
	ns.db.global.baseline.owned = 5
	ns.Collection:Scan()
	ns.Stats:Invalidate()
	eq(ns.Stats:Get().obtained.count, 0, "borné à zéro")
end)

test("Stats — un axe inconnu retombe sur celui par défaut", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = harness.Load(stub)

	eq(ns.Stats:IsValidAxis("expansion"), false, "l'axe des extensions n'existe plus")
	eq(ns.Stats:ResolveAxis("expansion"), ns.Stats.DEFAULT_AXIS,
		"un réglage sauvegardé obsolète ne casse pas le graphe")
	eq(#ns.Stats:GetBreakdown(nil), #ns.Stats:GetBreakdown("source"),
		"sans axe, la répartition par source")
end)

test("Stats — la répartition retombe après un changement de collection", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = harness.Load(stub)
	eq(ns.Stats:GetBreakdown("source")[2].owned, 1, "une possédée au départ")

	-- Nouvelle monture apprise : le cache de répartition doit tomber avec le
	-- reste, sinon le graphe reste sur la photo d'avant.
	stub.mounts[3].isCollected = true
	stub.Fire("NEW_MOUNT_ADDED", 202)
	stub.AdvanceFrames(2)
	stub.FlushTimers()

	eq(ns.Stats:GetBreakdown("source")[2].owned, 2, "le graphe suit la collection")
end)

test("Collection — mode de déplacement lu et mis en cache", function()
	stub.Reset()
	stub.mounts = StandardMounts()
	local ns = harness.Load(stub)

	eq(ns.Collection:GetMovement(201), ns.Data.MOVEMENT.FLYING, "248 = volante")
	eq(ns.Collection:GetMovement(204), ns.Data.MOVEMENT.OTHER, "type inconnu = autre")
	eq(ns.Collection:GetEntry(201).mountTypeID, 248, "le mountTypeID est retenu")
	-- Le texte de source vient du même appel : le résoudre ne doit pas le
	-- redemander au client.
	eq(ns.Collection:GetSourceText(201), "Butin : Yogg-Saron\nUlduar",
		"un seul appel sert les deux données")
	eq(ns.Collection:GetMovement(999), ns.Data.MOVEMENT.OTHER, "monture inconnue")
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
-- Route
--------------------------------------------------------------------------------

--- Charge l'addon avec une géographie : une entrée d'instance cartographiée,
--  sur une carte projetable.
local function LoadWithRoute()
	stub.Reset()
	stub.mounts = StandardMounts()
	stub.maps[492] = {
		name = "Désolation des Dragons",
		continentID = 113, originX = 0, originY = 0, spanX = 1000, spanY = 1000,
	}

	local ns = harness.Load(stub)
	ns.db.global.sourceCache = {
		-- Monture de raid, avec boss et instance.
		[201] = {
			kind = "boss", instanceName = "Ulduar", journalInstanceID = 187,
			isRaid = true, encounterName = "Yogg-Saron",
		},
		-- Monture de vendeur : le « boss » extrait du texte est en réalité le
		-- vendeur, et l'entrée est la même instance pour les besoins du test.
		[202] = {
			kind = "vendor", instanceName = "Ulduar", journalInstanceID = 187,
			isRaid = false, encounterName = "Talutu",
		},
	}
	ns.db.global.nodeCache = {
		["ej:187"] = {
			nodeID = "ej:187", name = "Ulduar", kind = "instance",
			uiMapID = 492, x = 0.41, y = 0.18, journalInstanceID = 187,
			continentID = 113, wx = 410, wy = 180,
		},
	}
	ns.Eligibility:Invalidate()
	ns.Nodes:Invalidate()
	ns.Route:Invalidate()
	return ns
end

test("Route — mission construite depuis l'entrée cartographiée", function()
	local ns = LoadWithRoute()

	local mission = ns.Route:GetMissionFor(201)
	eq(mission ~= nil, true, "mission trouvée")
	eq(mission.instanceName, "Ulduar", "instance nommée")
	eq(mission.encounterName, "Yogg-Saron", "boss retenu")
	eq(mission.isRaid, true, "raid reconnu")
	eq(mission.node.uiMapID, 492, "carte de l'entrée")
	eq(mission.zoneName, "Désolation des Dragons", "zone nommée")
end)

test("Route — pas d'entrée cartographiée, pas de mission", function()
	local ns = LoadWithRoute()
	-- 204 n'a ni source ni nœud : l'addon ne sait pas où l'envoyer, et il le dit
	-- en ne proposant rien plutôt qu'en plantant une épingle au hasard.
	eq(ns.Route:GetMissionFor(204), nil, "aucune mission sans coordonnées")
	eq(ns.Route:GetMissionFor(nil), nil, "identifiant absent")
end)

test("Route — le vendeur n'est pas annoncé comme un boss", function()
	local ns = LoadWithRoute()
	local mission = ns.Route:GetMissionFor(202)
	eq(mission ~= nil, true, "mission trouvée quand même")
	eq(mission.encounterName, nil,
		"le sujet d'un texte de vendeur ne devient pas un boss")
end)

test("Route — le choix automatique met le raid devant", function()
	local ns = LoadWithRoute()
	-- 202 (donjon, vendeur) a plus d'essais, mais 201 est un raid : le raid
	-- passe devant, c'est le cas le plus net à router.
	ns.Attempts:Bump(202, nil, 20)
	ns.Route:Invalidate()

	local mission = ns.Route:GetMission()
	eq(mission ~= nil, true, "une mission est proposée")
	eq(mission.mountID, 201, "le raid d'abord")
end)

test("Route — la cible épinglée gagne, jusqu'à ce qu'elle tombe", function()
	local ns = LoadWithRoute()
	ns.Route:SetTarget(202)
	eq(ns.Route:GetMission().mountID, 202, "la cible épinglée est retenue")
	eq(ns.Route:GetMission().pinned, true, "et signalée comme telle")

	-- Monture obtenue : la cible ne tient plus, on repasse au choix
	-- automatique plutôt que d'afficher une mission périmée.
	stub.mounts[3].isCollected = true
	stub.Fire("NEW_MOUNT_ADDED", 202)
	stub.AdvanceFrames(2)
	stub.FlushTimers()

	eq(ns.Route:GetMission().mountID, 201, "retour au choix automatique")
end)

test("Route — Start construit un plan et pointe sur la première étape", function()
	local ns = LoadWithRoute()
	stub.playerMap = { uiMapID = 492, x = 0.10, y = 0.10 }
	ns.Route:SetTarget(201)

	eq(ns.Route:Start(), true, "le trajet démarre")
	local plan = ns.Route:GetPlan()
	eq(plan ~= nil, true, "un plan est retenu")
	eq(plan.current, 1, "on est à la première étape")
	eq(#plan.steps >= 1, true, "au moins une étape")

	-- Le point de passage va sur l'ÉTAPE, pas sur la destination finale. Ici les
	-- deux coïncident (un seul vol), mais c'est le nœud de l'étape qui est lu.
	local step = ns.Route:GetCurrentStep()
	eq(step.nodeID, "ej:187", "l'étape mène à l'entrée d'Ulduar")
	eq(stub.waypoint ~= nil, true, "le point du client est posé")
	eq(stub.waypoint.uiMapID, 492, "sur la bonne carte")
	eq(stub.superTracked, true, "et suivi à l'écran")
end)

test("Route — le plan passe par un téléport quand il en existe un", function()
	local ns = LoadWithRoute()
	-- Le joueur est sur un autre continent : sans téléport, Ulduar est
	-- inatteignable ; avec, le plan doit compter deux étapes.
	stub.maps[84] = { name = "Hurlevent", continentID = 13,
		originX = 0, originY = 0, spanX = 1000, spanY = 1000 }
	stub.playerMap = { uiMapID = 84, x = 0.5, y = 0.5 }
	ns.Nodes:Invalidate()

	eq(ns.Route:BuildSteps(ns.Route:GetMissionFor(201)), nil,
		"aucun chemin entre deux continents sans téléport")

	-- Un sort de téléportation qui porte le nom du nœud : c'est ainsi que
	-- Teleports rapproche un sort d'une destination.
	stub.spells = { { spellID = 3565, name = "Ulduar", castTime = 10000 } }
	ns.Teleports:Invalidate()
	ns.TravelGraph:Invalidate()

	local steps = ns.Route:BuildSteps(ns.Route:GetMissionFor(201))
	eq(steps ~= nil, true, "un chemin existe maintenant")
	eq(#steps, 1, "un seul saut : le téléport mène droit au nœud")
	eq(steps[1].kind, ns.Data.EDGE_KINDS.TELEPORT, "et c'est bien un téléport")
	eq(steps[1].spellName, "Ulduar", "avec le sort à lancer")
end)

test("Route — l'étape avance quand le joueur arrive", function()
	local ns = LoadWithRoute()
	stub.playerMap = { uiMapID = 492, x = 0.10, y = 0.10 }
	ns.Route:SetTarget(201)
	ns.Route:Start()

	eq(ns.Route:Advance(), false, "loin de l'étape : rien ne bouge")

	-- Le nœud est en (0.41, 0.18) sur une carte de 1000 yards de côté : on se
	-- pose juste à côté.
	stub.playerMap = { uiMapID = 492, x = 0.412, y = 0.181 }
	eq(ns.Route:Advance(), true, "arrivé : l'étape est franchie")
	eq(ns.Route:GetPlan().arrived, true, "et c'était la dernière")
	eq(ns.Route:GetCurrentStep(), nil, "plus d'étape courante")
end)

test("Route — cap et distance vers l'étape", function()
	local ns = LoadWithRoute()
	-- Joueur au sud-est du nœud, orienté au nord.
	stub.playerMap = { uiMapID = 492, x = 0.50, y = 0.50 }
	_G.GetPlayerFacing = function() return 0 end

	local node = ns.Nodes:Get("ej:187")
	local rotation, distance = ns.Route:GetBearing(node)
	eq(distance ~= nil, true, "une distance est calculée")

	-- Le nœud est au nord-ouest : cap entre nord (0) et ouest (pi/2), donc
	-- strictement dans le premier quadrant antihoraire.
	eq(rotation > 0 and rotation < math.pi / 2, true,
		"le cap pointe au nord-ouest, orientation nord")

	-- Même position, joueur tourné vers l'ouest : la cible est maintenant
	-- davantage sur sa droite, donc la rotation diminue.
	local before = rotation
	_G.GetPlayerFacing = function() return math.pi / 2 end
	local after = ns.Route:GetBearing(node)
	eq(after < before, true, "tourner change le cap relatif")
	_G.GetPlayerFacing = nil
end)

test("Route — une carte qui refuse le point de passage n'empêche pas la flèche", function()
	local ns = LoadWithRoute()
	stub.playerMap = { uiMapID = 492, x = 0.10, y = 0.10 }
	ns.Route:SetTarget(201)
	ns.Route:Start()

	-- Les cartes d'intérieur d'instance refusent le point de passage. Le trajet
	-- reste guidé : c'est notre flèche qui prend le relais, pas rien du tout.
	stub.waypoint = nil
	stub.maps[492] = nil
	local backend = ns.Route:PointAtCurrentStep()
	eq(backend, "arrow", "on retombe sur la flèche de l'addon")
	eq(stub.waypoint, nil, "et aucun point client n'est posé")
end)

test("Route — TomTom prend le point, et le client aussi", function()
	local ns = LoadWithRoute()
	stub.playerMap = { uiMapID = 492, x = 0.10, y = 0.10 }
	local received
	-- Forme moderne, celle qui ne change pas de sens d'une version à l'autre.
	_G.TomTom = {
		AddMFWaypoint = function(_, uiMapID, _, x, y, options)
			received = { uiMapID = uiMapID, x = x, y = y, options = options }
			return { uid = true }
		end,
	}

	eq(ns.Route:HasTomTom(), true, "TomTom détecté")
	ns.Route:SetTarget(201)
	ns.Route:Start()
	local backend = ns.Route:PointAtCurrentStep()
	_G.TomTom = nil

	eq(backend, "tomtom", "TomTom est annoncé comme le meilleur guidage")
	eq(received.uiMapID, 492, "avec la bonne carte")
	-- Les deux, volontairement : quand la flèche de TomTom ne vient pas — ce qui
	-- est exactement le bug d'origine — le point du client reste là pour donner
	-- la distance dans le suivi de quêtes.
	eq(stub.waypoint ~= nil, true, "le point du client est posé aussi")
end)

test("Route — TomTom d'une vieille version n'est pas appelé à l'aveugle", function()
	local ns = LoadWithRoute()
	stub.playerMap = { uiMapID = 492, x = 0.10, y = 0.10 }
	local args
	-- Vieille signature : AddWaypoint(x, y, description…) en centièmes, sur la
	-- carte courante. On l'appelle en dernier recours seulement, et jamais à la
	-- place du point client.
	_G.TomTom = {
		AddWaypoint = function(_, a, b, c) args = { a, b, c } end,
	}
	ns.Route:SetTarget(201)
	ns.Route:Start()
	_G.TomTom = nil

	eq(args ~= nil, true, "l'ancienne forme est tout de même tentée")
	eq(stub.waypoint ~= nil, true,
		"mais le point du client est posé, donc le joueur a un guidage")
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
