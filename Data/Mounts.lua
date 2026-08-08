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

	POURQUOI LA CLÉ EST LE spellID

	Surtout PAS le nom. Les noms de montures sont localisés : « Invincible » en
	anglais, « Invincible » en français, mais « 冰龙 » ailleurs — et n'importe
	quelle liste extérieure sera dans UNE langue. Un rapprochement par nom
	marcherait sur un client anglais et échouerait partout ailleurs, ce qui est
	la pire des situations : ça marche chez celui qui teste.

	Le spellID est stable, unique, et le client le donne pour chaque monture
	(2e retour de C_MountJournal.GetMountInfoByID). C'est la seule jointure
	honnête entre une donnée extérieure et le client du joueur.

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

	Data.Mounts[40192] = {
		expansion  = 1,              -- niveau d'extension (0 = Vanilla)
		kind       = "boss",         -- cf. Data.SOURCE_KINDS
		instance   = "Tempest Keep", -- nom NON localisé, indicatif seulement
		dropRate   = 0.02,           -- estimation communautaire, jamais exacte
	}

	`instance` ne sert PAS au rapprochement des verrous : celui-ci passe par le
	nom localisé fourni par le client. C'est une indication d'affichage.
--]]
Data.Mounts = {}

--- Entrée curée d'une monture, par son identifiant de sort.
function Data.GetCuratedMount(spellID)
	if type(spellID) ~= "number" then return nil end
	return Data.Mounts[spellID]
end

--- Nombre d'entrées curées, pour le diagnostic.
function Data.CountCuratedMounts()
	return ns.Util.Count(Data.Mounts)
end
