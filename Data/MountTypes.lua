--[[---------------------------------------------------------------------------
	OnlyFarm — Data/MountTypes.lua

	Mode de déplacement d'une monture : terrestre, volante, skyriding,
	aquatique.

	POURQUOI CE FICHIER EXISTE

	C'est le SEUL classement de montures, en dehors de la nature de la source,
	que le client fournisse monture par monture. `mountTypeID` est le 5e retour
	de `C_MountJournal.GetMountInfoExtraByID` (vérifié sur le dump 12.0.7) : un
	entier, exact, non localisé, disponible pour toutes les montures sans aucun
	scan.

	Ce que le client ne donne PAS, c'est le sens de cet entier. La table
	`MountType` du jeu (et ses capacités : marcher, voler, nager) vit dans les
	DB2, hors d'atteinte d'un addon. Il faut donc une table de correspondance,
	et la question devient : jusqu'où a-t-on le droit d'aller ?

	CE QU'ON TRANCHE, ET CE QU'ON NE TRANCHE PAS

	Les valeurs ci-dessous sont celles sur lesquelles les sources publiques
	concordent, et qui portent sur le gros de la collection : 230 (terrestre),
	248 (volante) et 402 (skyriding) couvrent à eux seuls la grande majorité des
	montures.

	Trois identifiants connus sont volontairement ABSENTS — 407, 408 et 412. Les
	sources publiques les classent différemment (volante pour l'une, aquatique
	pour l'autre) et aucune n'est le client. Une monture de type inconnu tombe
	dans « autre » : c'est une réponse honnête, contrairement à un rangement au
	hasard qui serait indiscernable d'un rangement juste.

	Même règle pour l'avenir : un patch qui introduit un nouveau type de monture
	le fera apparaître dans « autre », pas dans la mauvaise barre. La table se
	complète alors ici, en une ligne.

	Sources de la correspondance (aucune n'est Blizzard, d'où la prudence) :
	  * phanx-wow/MountMe — table `mountTypeInfo`, vitesses sol/vol/nage ;
	  * Usires/WoW_FlyCam — ensemble des types considérés volants ;
	  * documentation communautaire de `GetMountInfoExtraByID`.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Data = ns.Data

--- Modes de déplacement. `OTHER` n'est pas un mode, c'est un aveu.
Data.MOVEMENT = {
	GROUND = "ground",
	FLYING = "flying",
	SKYRIDING = "skyriding",
	AQUATIC = "aquatic",
	OTHER = "other",
}

local M = Data.MOVEMENT

--- mountTypeID (client) -> mode de déplacement.
Data.MOUNT_TYPE_MOVEMENT = {
	[230] = M.GROUND,     -- la grande majorité des montures terrestres
	[241] = M.GROUND,     -- chars de bataille qiraji (Ahn'Qiraj uniquement)
	[269] = M.GROUND,     -- arpenteurs des eaux : vitesse au sol, jamais de vol
	[284] = M.GROUND,     -- moto avec chauffeur

	[231] = M.AQUATIC,    -- tortues de mer
	[232] = M.AQUATIC,    -- hippocampe des abysses (Vashj'ir)
	[254] = M.AQUATIC,    -- hippocampe apprivoisé, Poséidus…

	[242] = M.FLYING,     -- griffon spectral rapide
	[247] = M.FLYING,     -- disque du nuage volant rouge
	[248] = M.FLYING,     -- la grande majorité des montures volantes
	[306] = M.FLYING,
	[398] = M.FLYING,     -- harnais de Kua'fon
	[436] = M.FLYING,
	[444] = M.FLYING,

	[402] = M.SKYRIDING,  -- vol dynamique (drakes)
	[424] = M.SKYRIDING,
}

--- Mode de déplacement d'un mountTypeID. Tout ce qui n'est pas dans la table
--  ci-dessus — y compris `nil` — répond `other`, jamais une supposition.
function Data.GetMovementKind(mountTypeID)
	if type(mountTypeID) ~= "number" then return M.OTHER end
	return Data.MOUNT_TYPE_MOVEMENT[mountTypeID] or M.OTHER
end

--- Ordre d'affichage et libellé localisé de chaque mode.
--  « autre » ferme la marche : c'est le panier des types non tranchés, il n'a
--  pas à squatter la première barre.
Data.MOVEMENT_ORDER = {
	{ kind = M.GROUND, label = "MOVE_GROUND" },
	{ kind = M.FLYING, label = "MOVE_FLYING" },
	{ kind = M.SKYRIDING, label = "MOVE_SKYRIDING" },
	{ kind = M.AQUATIC, label = "MOVE_AQUATIC" },
	{ kind = M.OTHER, label = "MOVE_OTHER" },
}

--- Rang d'un mode dans l'ordre d'affichage, pour trier sans réinventer la liste.
local movementRank
function Data.GetMovementRank(kind)
	if not movementRank then
		movementRank = {}
		for index, entry in ipairs(Data.MOVEMENT_ORDER) do
			movementRank[entry.kind] = index
		end
	end
	return movementRank[kind] or #Data.MOVEMENT_ORDER + 1
end

--- Libellé localisé d'un mode de déplacement.
function Data.GetMovementLabel(kind)
	for _, entry in ipairs(Data.MOVEMENT_ORDER) do
		if entry.kind == kind then return ns.L[entry.label] end
	end
	return ns.L.MOVE_OTHER
end
