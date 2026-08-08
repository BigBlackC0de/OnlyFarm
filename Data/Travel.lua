--[[---------------------------------------------------------------------------
	OnlyFarm — Data/Travel.lua

	Schéma des arêtes du graphe de voyage + constantes de coût.

	>>> La table `Travel` est VOLONTAIREMENT VIDE. <<<

	Écrire à la main « sort 445414 = téléportation vers Ulduar » est exactement
	le genre de donnée qui pourrit en silence : un identifiant recopié de
	travers produit un bouton qui lance le mauvais sort, et personne ne le voit
	avant d'être au mauvais bout d'Azeroth.

	Les arêtes sont donc découvertes en jeu (`Modules/Teleports.lua`) :
	  * les sorts de téléportation sont lus dans le grimoire du joueur et
	    rapprochés des noms d'instance du Journal des rencontres — les deux
	    viennent du même client, donc de la même locale ;
	  * les arêtes de vol sont calculées à partir des coordonnées monde des
	    nœuds, pas listées ;
	  * les durées réelles sont apprises à l'usage (db.global.travelTimings).

	Cette table reste là pour les arêtes qu'aucune API n'expose (portails fixes
	entre capitales, par exemple), à remplir par Build/generate_data.py depuis
	un fichier de curation du dépôt.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Data = ns.Data

--------------------------------------------------------------------------------
-- Vocabulaire
--------------------------------------------------------------------------------

Data.EDGE_KINDS = {
	TELEPORT = "teleport",  -- sort ou jouet, depuis n'importe où
	PORTAL = "portal",      -- portail fixe, d'un nœud vers un autre
	TAXI = "taxi",          -- maître de vol
	FLY = "fly",            -- vol libre, coût calculé depuis la distance
	WALK = "walk",          -- déplacement au sol dans la même zone
}

--------------------------------------------------------------------------------
-- Constantes de coût (secondes)
--
-- Ce sont des ESTIMATIONS, et l'interface doit les présenter comme telles.
-- Elles servent de valeur de départ : `Modules/Teleports.lua` chronomètre les
-- trajets réels du joueur et remplace progressivement ces forfaits par des
-- moyennes mesurées sur CE joueur (db.global.travelTimings).
--------------------------------------------------------------------------------

Data.COST = {
	-- Tout changement d'instance ou de continent paie un écran de chargement.
	LOADING_SCREEN = 8,
	-- Incantation d'un sort de téléportation (10 s pour la famille « Téléport »).
	TELEPORT_CAST = 10,
	-- Pierre de foyer et jouets équivalents.
	HEARTHSTONE_CAST = 10,
	-- Décollage, atterrissage, contournement du décor : le vol à vol d'oiseau
	-- n'existe pas, ce forfait empêche le routeur de sous-estimer les sauts courts.
	FLIGHT_OVERHEAD = 15,
	-- Coût d'un vol en maître de vol quand aucune mesure n'a encore été faite.
	-- Volontairement pessimiste : une route trop optimiste se remarque en jeu,
	-- une route trop prudente se corrige toute seule à la première mesure.
	TAXI_DEFAULT = 120,
	-- Marche entre deux points de la même zone, hors calcul de distance.
	WALK_OVERHEAD = 5,
}

--- Vitesse de vol par défaut, en yards/seconde. Le vol dynamique tient entre
--  65 et 90 sur longue distance ; 75 est le milieu, et le joueur l'ajuste dans
--  `db.profile.routing.flySpeed`.
Data.DEFAULT_FLY_SPEED = 75

--------------------------------------------------------------------------------
-- Table statique
--------------------------------------------------------------------------------

--[[
	Forme d'une entrée :

	{
		kind     = "teleport",
		spellID  = 445414,
		from     = "*",              -- "*" = depuis n'importe quel nœud
		to       = "ej:1301",
		cost     = 18,               -- incantation + écran de chargement
		cooldown = 900,              -- secondes ; nil = pas de cooldown
		source   = "spell",          -- "spell" | "toy:<itemID>" | "item:<itemID>"
	}

	Pour un portail, `from` et `to` sont deux nodeID et `source` vaut nil : un
	portail fixe est toujours disponible.
--]]
Data.Travel = {}
