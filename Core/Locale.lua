--[[---------------------------------------------------------------------------
	OnlyFarm — Core/Locale.lua

	Table de chaînes. Base enUS, surcharge par locale.
	Toute chaîne affichée passe par `ns.L`.
-----------------------------------------------------------------------------]]

local _, ns = ...

local L = {
	-- Unités de durée (collées au nombre : « 3j 4h »)
	UNIT_DAY = "d",
	UNIT_HOUR = "h",
	UNIT_MIN = "m",
	UNIT_SEC = "s",

	-- Fenêtre principale
	TITLE = "OnlyFarm",
	TAB_COLLECTION = "Collection",
	TAB_ROUTE = "Route",
	TAB_EDITOR = "Editor",
	ROUTE_PLACEHOLDER = "Route planning arrives in phase 3.",
	EDITOR_PLACEHOLDER = "Custom routes arrive in phase 5.",

	-- Colonnes
	COL_MOUNT = "Mount",
	COL_SOURCE = "Source",
	COL_STATUS = "Availability",

	-- Statuts
	STATUS_AVAILABLE = "available",
	STATUS_LOCKED = "locked",
	STATUS_UNKNOWN = "unknown",
	STATUS_NO_SOURCE = "source not mapped",
	STATUS_INELIGIBLE = "not eligible",

	-- Résumés
	SUMMARY = "%d/%d collected — %d missing",
	SUMMARY_HIDDEN = "%d unavailable to this character",
	SUMMARY_FILTERED = "%d shown",
	INSTANCE_COUNTER = "Instances: %d/%d this hour · %d/%d today",
	JOURNAL_NOT_READY = "Mount Journal not populated yet, retrying…",
	NO_RESULT = "Nothing matches the current filters.",

	-- Filtres
	FILTER_SEARCH = "Search",
	FILTER_AVAILABLE_ONLY = "Available now only",
	FILTER_HIDE_UNMAPPED = "Hide unmapped sources",
	FILTER_HIDE_EXCLUDED = "Hide excluded",
	FILTER_EXPANSION = "Expansion",
	FILTER_EXPANSION_ALL = "All",
	FILTER_EXPANSION_NONE = "None",
	EXPANSION_UNKNOWN = "Unknown (unmapped source)",
	EXPANSION_NEEDS_SCAN = "Run /of ejscan to fill this list.",

	-- Aperçu
	PREVIEW_HINT = "Drag to rotate · wheel to zoom",
	PREVIEW_NONE = "No model available for this mount.",
	HINT_PREVIEW = "Left-click: preview the mount",
	HINT_EXCLUDE = "Right-click: exclude from the list",
	HINT_INCLUDE = "Right-click: put back in the list",
	TAG_EXCLUDED = "excluded",
	MINIMAP_LEFT = "Left-click: open OnlyFarm",
	MINIMAP_RIGHT = "Right-click: rescan collection and lockouts",
	MINIMAP_RESCANNED = "rescan requested.",

	-- Verrous
	LOCK_RESETS_IN = "resets in %s",
	LOCK_CHARS = "%d character(s) available",
	LOCK_STALE = "not seen for %s",

	-- Commandes
	CMD_HELP_HEADER = "OnlyFarm commands:",
	CMD_HELP_SHOW = "  /of           — open the window",
	CMD_HELP_SCAN = "  /of scan      — rescan collection and lockouts",
	CMD_HELP_CHARS = "  /of chars     — list known characters",
	CMD_HELP_EJSCAN = "  /of ejscan    — dev: harvest mount sources from the Encounter Journal",
	CMD_HELP_DEBUG = "  /of debug     — toggle debug traces",
	CMD_HELP_RESET = "  /of reset     — wipe the saved database (asks twice)",

	-- DevScan
	SCAN_START = "Encounter Journal scan started (a few seconds, the UI may stutter).",
	SCAN_DONE = "Scan finished: %d mounts mapped across %d instances.",
	SCAN_BUSY = "A scan is already running.",
	SCAN_NEEDS_EJ = "Encounter Journal unavailable — open it once, then retry.",

	-- Divers
	RESET_CONFIRM = "Type |cffff5555/of reset confirm|r to wipe OnlyFarm's database.",
	RESET_DONE = "Database wiped. Reload the interface (/reload).",
}

if GetLocale and GetLocale() == "frFR" then
	L.UNIT_DAY = "j"
	L.UNIT_MIN = "min"

	L.TAB_COLLECTION = "Collection"
	L.TAB_ROUTE = "Route"
	L.TAB_EDITOR = "Éditeur"
	L.ROUTE_PLACEHOLDER = "La planification de route arrive en phase 3."
	L.EDITOR_PLACEHOLDER = "Les routes maison arrivent en phase 5."

	L.COL_MOUNT = "Monture"
	L.COL_SOURCE = "Source"
	L.COL_STATUS = "Disponibilité"

	L.STATUS_AVAILABLE = "disponible"
	L.STATUS_LOCKED = "verrouillé"
	L.STATUS_UNKNOWN = "incertain"
	L.STATUS_NO_SOURCE = "source non cartographiée"
	L.STATUS_INELIGIBLE = "non éligible"

	L.SUMMARY = "%d/%d possédées — %d manquantes"
	L.SUMMARY_HIDDEN = "%d hors de portée sur ce perso"
	L.INSTANCE_COUNTER = "Instances : %d/%d cette heure · %d/%d aujourd'hui"
	L.SUMMARY_FILTERED = "%d affichées"
	L.JOURNAL_NOT_READY = "Journal des montures pas encore peuplé, nouvelle tentative…"
	L.NO_RESULT = "Aucun résultat pour ces filtres."

	L.FILTER_SEARCH = "Rechercher"
	L.FILTER_AVAILABLE_ONLY = "Dispo maintenant uniquement"
	L.FILTER_HIDE_UNMAPPED = "Masquer les sources non cartographiées"
	L.FILTER_HIDE_EXCLUDED = "Masquer les exclues"
	L.FILTER_EXPANSION = "Extension"
	L.FILTER_EXPANSION_ALL = "Tout"
	L.FILTER_EXPANSION_NONE = "Rien"
	L.EXPANSION_UNKNOWN = "Inconnue (source non cartographiée)"
	L.EXPANSION_NEEDS_SCAN = "Lance /of ejscan pour remplir cette liste."

	L.PREVIEW_HINT = "Glisser pour tourner · molette pour zoomer"
	L.PREVIEW_NONE = "Aucun modèle disponible pour cette monture."
	L.HINT_PREVIEW = "Clic gauche : aperçu de la monture"
	L.HINT_EXCLUDE = "Clic droit : exclure de la liste"
	L.HINT_INCLUDE = "Clic droit : remettre dans la liste"
	L.TAG_EXCLUDED = "exclue"
	L.MINIMAP_LEFT = "Clic gauche : ouvrir OnlyFarm"
	L.MINIMAP_RIGHT = "Clic droit : rescanner collection et verrous"
	L.MINIMAP_RESCANNED = "rescan demandé."

	L.LOCK_RESETS_IN = "reset dans %s"
	L.LOCK_CHARS = "%d perso(s) disponible(s)"
	L.LOCK_STALE = "vu il y a %s"

	L.CMD_HELP_HEADER = "Commandes OnlyFarm :"
	L.CMD_HELP_SHOW = "  /of           — ouvrir la fenêtre"
	L.CMD_HELP_SCAN = "  /of scan      — rescanner collection et verrous"
	L.CMD_HELP_CHARS = "  /of chars     — lister les personnages connus"
	L.CMD_HELP_EJSCAN = "  /of ejscan    — dev : moissonner les sources via le Journal des rencontres"
	L.CMD_HELP_DEBUG = "  /of debug     — activer/couper les traces"
	L.CMD_HELP_RESET = "  /of reset     — effacer la base sauvegardée (demande confirmation)"

	L.SCAN_START = "Scan du Journal des rencontres lancé (quelques secondes, l'interface peut saccader)."
	L.SCAN_DONE = "Scan terminé : %d montures cartographiées sur %d instances."
	L.SCAN_BUSY = "Un scan est déjà en cours."
	L.SCAN_NEEDS_EJ = "Journal des rencontres indisponible — ouvre-le une fois, puis réessaie."

	L.RESET_CONFIRM = "Tape |cffff5555/of reset confirm|r pour effacer la base d'OnlyFarm."
	L.RESET_DONE = "Base effacée. Recharge l'interface (/reload)."
end

ns.L = L
