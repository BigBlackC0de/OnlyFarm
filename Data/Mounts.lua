--[[---------------------------------------------------------------------------
	OnlyFarm — Data/Mounts.lua

	Table curée des montures, GÉNÉRÉE par Build/generate_data.py.
	Ne pas éditer à la main : le prochain build écrasera tout.

	>>> ÉTAT : VIDE. Elle attend sa source de données. <<<

	POURQUOI ELLE EXISTE

	La cartographie dérivée du client (Modules/Mapping.lua) rattache environ une
	monture sur dix à une extension. Le reste — vendeurs, métiers, événements
	saisonniers, PvP, quêtes, butins de zone — n'est rattachable par AUCUNE API :
	le texte de source ne cite qu'un PNJ ou une zone, et le client n'expose pas
	l'extension d'une zone. Ce n'est pas une heuristique à améliorer, c'est un
	mur.

	Cette table est le seul moyen de passer le mur, et c'est ce que prévoit la
	phase 2 de la spécification.

	POURQUOI LA CLÉ EST LE mountID

	Surtout PAS le nom. Les noms de montures sont localisés, et n'importe quelle
	liste extérieure est écrite dans UNE langue. Un rapprochement par nom
	marcherait sur un client anglais et échouerait partout ailleurs — la pire
	des situations, parce qu'elle passe les tests de celui qui l'écrit.

	Le mountID est l'identifiant qu'utilisent À LA FOIS le client
	(C_MountJournal) et l'API officielle de Blizzard (/data/wow/mount/{id}).
	C'est donc la jointure naturelle. Le spellID est accepté en clé secondaire,
	pour les sources qui ne connaissent que lui.

	SOURCE DES DONNÉES

	Aucune requête réseau n'est possible depuis un addon : la table doit être
	compilée au build. `/of export` produit le fichier de travail (un CSV de
	toutes les montures avec leur spellID et ce que l'addon sait déjà), qui sert
	de base à la curation.

	Les valeurs communautaires (Wowhead, warcraftmounts) sont des estimations
	maintenues par des joueurs. Elles doivent être créditées dans le README et
	présentées comme des estimations, jamais comme des vérités du client.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Data = ns.Data

--[[
	Forme d'une entrée :

	Data.Mounts[264] = {
		spellID    = 40192,          -- facultatif, clé secondaire
		expansion  = 1,              -- niveau d'extension (0 = Vanilla)
		kind       = "boss",         -- cf. Data.SOURCE_KINDS
		instance   = "Tempest Keep", -- nom NON localisé, indicatif seulement
		dropRate   = 0.02,           -- estimation communautaire, jamais exacte
	}

	`instance` ne sert PAS au rapprochement des verrous : celui-ci passe par le
	nom localisé fourni par le client. C'est une indication d'affichage.
--]]
Data.Mounts = {}

--- Index secondaire spellID -> entrée, construit à la demande.
local bySpell

--- Entrée curée d'une monture.
--  @param mountID identifiant du Journal des montures
--  @param spellID identifiant de sort, utilisé en repli
function Data.GetCuratedMount(mountID, spellID)
	local entry = type(mountID) == "number" and Data.Mounts[mountID] or nil
	if entry then return entry end

	if type(spellID) ~= "number" then return nil end
	if not bySpell then
		bySpell = {}
		for _, candidate in pairs(Data.Mounts) do
			if candidate.spellID then bySpell[candidate.spellID] = candidate end
		end
	end
	return bySpell[spellID]
end

--- Nombre d'entrées curées, pour le diagnostic.
function Data.CountCuratedMounts()
	return ns.Util.Count(Data.Mounts)
end
