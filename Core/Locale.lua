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
	TAB_DASHBOARD = "Dashboard",
	TAB_COLLECTION = "Collection",
	TAB_ROUTE = "Route",
	TAB_EDITOR = "Editor",
	ROUTE_PLACEHOLDER = "Route planning arrives in phase 3.",
	EDITOR_PLACEHOLDER = "Custom routes arrive in phase 5.",

	-- Colonnes
	COL_MOUNT = "Mount",
	COL_SOURCE = "Source",
	COL_CATEGORY = "Category",
	COL_TYPE = "Type",
	COL_TRIES = "Tries",
	COL_OWNED = "Owned",
	YES = "yes",
	NO = "no",
	SORT_HINT = "Click a column header to sort it",

	-- Tableau de bord
	KPI_OWNED = "collected",
	KPI_MISSING = "missing",
	KPI_OBTAINED = "obtained",
	KPI_OBTAINED_DETAIL = "in the last %s",
	KPI_LOCKS = "active lockouts",
	KPI_INSTANCES = "%d/h · %d/day",
	DASH_BREAKDOWN = "How your collection breaks down",
	DASH_BREAKDOWN_HINT = "bar length = how many exist · filled = collected",
	DASH_BREAKDOWN_MORE = "+%d more — enlarge the window",
	DASH_AXIS_SOURCE = "By source",
	DASH_AXIS_MOVEMENT = "By type",
	DASH_TARGETS = "Start with these",
	DASH_NO_TARGET = "Nothing available right now — everything is locked or unmapped.",
	DASH_LOCKOUTS = "Done this week",
	DASH_NO_LOCKOUT = "No lockout on this character — the week is untouched.",

	-- Modes de déplacement (mountTypeID)
	MOVE_GROUND = "Ground",
	MOVE_FLYING = "Flying",
	MOVE_SKYRIDING = "Skyriding",
	MOVE_AQUATIC = "Aquatic",
	MOVE_OTHER = "Other",
	SOURCE_UNKNOWN = "Other",

	-- Statuts
	STATUS_AVAILABLE = "available",
	STATUS_LOCKED = "locked",
	STATUS_UNKNOWN = "unknown",
	STATUS_NO_SOURCE = "source not mapped",
	STATUS_NO_SOURCE_SHORT = "unmapped",
	STATUS_INELIGIBLE = "not eligible",

	-- Résumés
	SUMMARY = "%d/%d collected — %d missing",
	SUMMARY_FILTERED = "%d shown",
	INSTANCE_COUNTER = "Instances: %d/%d this hour · %d/%d today",
	JOURNAL_NOT_READY = "Mount Journal not populated yet, retrying…",
	NO_RESULT = "Nothing matches the current filters.",

	-- Filtres
	FILTER_SEARCH = "Search",
	FILTER_SHOW_OWNED = "Show collected",
	FILTER_HIDE_EXCLUDED = "Hide excluded",
	FILTER_SOURCE = "Source",
	FILTER_ALL = "All",
	FILTER_NONE = "None",
	TYPE_RAID = "Raid",
	TYPE_DUNGEON = "Dungeon",

	-- Aperçu
	PREVIEW_HINT = "Drag to rotate · wheel to zoom",
	PREVIEW_NONE = "No model available for this mount.",
	HINT_PREVIEW = "Left-click: preview the mount",
	HINT_MENU = "Right-click: more actions",

	-- Actions du menu contextuel
	ACTION_PREVIEW = "Preview the mount",
	ACTION_COPY_NAME = "Copy the name",
	ACTION_ROUTE = "Route to it",
	ACTION_ROUTE_IMPOSSIBLE = "No mapped entrance for this mount yet.",
	ACTION_EXCLUDE = "Exclude from the list",
	ACTION_INCLUDE = "Put back in the list",
	TAG_EXCLUDED = "excluded",
	TOOLTIP_BOSS = "Boss",
	TOOLTIP_MOVEMENT = "Mount type",
	TOOLTIP_DIFFICULTY = "Locked in",
	MINIMAP_LEFT = "Left-click: open OnlyFarm",
	MINIMAP_RIGHT = "Right-click: rescan collection and lockouts",
	MINIMAP_RESCANNED = "rescan requested.",

	-- Tentatives
	ATTEMPTS = "%d tries",
	ATTEMPTS_ONE = "1 try",
	ATTEMPTS_NONE = "no try yet",
	ATTEMPTS_LAST = "last try %s ago",
	ATTEMPTS_DRY = "%.0f%% chance of still having nothing",
	ATTEMPTS_TOTAL = "%d tries on %d mounts",
	HINT_ATTEMPT_ADD = "Shift-click: +1 try (if the automatic count missed it)",
	HINT_ATTEMPT_SUB = "Ctrl-click: -1 try",

	-- Verrous
	LOCK_RESETS_IN = "resets in %s",
	LOCK_CHARS = "%d character(s) available",
	LOCK_STALE = "not seen for %s",

	-- Commandes
	CMD_HELP_HEADER = "OnlyFarm commands:",
	CMD_HELP_SHOW = "  /of           — open the window",
	CMD_HELP_SCAN = "  /of scan      — rescan collection and lockouts",
	CMD_HELP_CHARS = "  /of chars     — list known characters",
	CMD_HELP_DEEPSCAN = "  /of deepscan  — deep pass: walk every boss's loot table (slow, optional)",
	CMD_HELP_DIAG = "  /of diag      — why the mapping came back empty (copyable report)",
	CMD_HELP_EXPORT = "  /of export    — CSV of mounts still lacking an expansion (add 'all' for every mount)",
	CMD_HELP_DEBUG = "  /of debug     — toggle debug traces",
	CMD_HELP_RESET = "  /of reset     — wipe the saved database (asks twice)",

	-- Cartographie
	SCAN_START = "Mapping your mounts…",
	SCAN_AUTO_START = "First-run mapping of your mounts — expansions, instances and bosses.",
	SCAN_DEEP_START = "Full mapping: walking every boss's loot table. A few minutes, once. The UI may stutter.",
	SCAN_DONE = "Mapping done: %d of %d mounts tied to an instance, across %d instances.",
	SCAN_AUTO_DONE = "Kept on disc — it only runs again after a patch or when new mounts appear.",
	SCAN_SUMMARY = "%d/%d mapped · %s ago",
	SCAN_RUNNING = "mapping…",
	SCAN_BUTTON = "Rescan mounts",
	SCAN_NEVER = "never mapped",
	SCAN_BREAKDOWN = "detail: %d by place, %d by achievement (%d achievements indexed, %d/%d categories tied to an expansion).",
	SCAN_EMPTY_DETAIL = "nothing tied: %d mounts had source text, %d yielded a place, index holds %d instances. |cff7ac1ff/of diag|r for the detail.",
	SCAN_BUSY = "A scan is already running.",
	SCAN_NEEDS_EJ = "Encounter Journal unavailable — open it once, then retry.",

	-- Diagnostic
	DIAG_TITLE = "OnlyFarm — mapping diagnostic",
	DIAG_SUMMARY = "diagnostic opened: %d of %d mounts tied to an instance. Ctrl+C to copy.",
	COPY_TITLE = "OnlyFarm",
	COPY_HINT = "Ctrl+C to copy · Escape to close",
	EXPORT_TITLE = "OnlyFarm — curation worksheet (CSV)",
	EXPORT_DONE = "%d mounts exported. Ctrl+C to copy.",

	-- Voyage
	NODE_PLAYER = "Your position",

	-- Onglet Route
	ROUTE_MISSION = "Next target",
	ROUTE_WHERE = "Where it is",
	ROUTE_TARGET = "Target",
	ROUTE_ZONE = "Zone",
	ROUTE_COORDS = "Coordinates",
	ROUTE_START = "Start",
	ROUTE_UNPIN = "Let go",
	ROUTE_PINNED = "pinned by you",
	ROUTE_VIA_CLIENT = "Start plants the game's own waypoint and tracks it.",
	ROUTE_VIA_TOMTOM = "TomTom detected: Start hands it the waypoint.",
	ROUTE_STARTED = "waypoint set: %s. Follow the arrow.",
	ROUTE_FAILED = "could not set the waypoint (%s).",
	ROUTE_NONE = "No routable mount: none of the missing ones has a mapped entrance.",
	ROUTE_NEEDS_SCAN = "The mapping has not run yet — it is what ties a mount to an instance entrance.",
	ROUTE_NO_MAP = "No map art for this place.",
	TYPE_OUTDOOR_LABEL = "Out in the world",
	COL_STATUS_SHORT = "Status",

	-- Divers
	RESET_CONFIRM = "Type |cffff5555/of reset confirm|r to wipe OnlyFarm's database.",
	RESET_DONE = "Database wiped. Reload the interface (/reload).",
}

if GetLocale and GetLocale() == "frFR" then
	L.UNIT_DAY = "j"
	L.UNIT_MIN = "min"

	L.TAB_DASHBOARD = "Tableau de bord"
	L.TAB_COLLECTION = "Collection"
	L.TAB_ROUTE = "Route"
	L.TAB_EDITOR = "Éditeur"
	L.ROUTE_PLACEHOLDER = "La planification de route arrive en phase 3."
	L.EDITOR_PLACEHOLDER = "Les routes maison arrivent en phase 5."

	L.COL_MOUNT = "Monture"
	L.COL_SOURCE = "Source"
	L.COL_CATEGORY = "Catégorie"
	L.COL_TYPE = "Type"
	L.COL_TRIES = "Essais"
	L.COL_OWNED = "Possédée"
	L.YES = "oui"
	L.NO = "non"
	L.SORT_HINT = "Clique un titre de colonne pour trier dessus"

	L.KPI_OWNED = "possédées"
	L.KPI_MISSING = "manquantes"
	L.KPI_OBTAINED = "obtenues"
	L.KPI_OBTAINED_DETAIL = "en %s"
	L.KPI_LOCKS = "verrous actifs"
	L.KPI_INSTANCES = "%d/h · %d/jour"
	L.DASH_BREAKDOWN = "Comment se répartit ta collection"
	L.DASH_BREAKDOWN_HINT = "longueur = effectif · rempli = possédées"
	L.DASH_BREAKDOWN_MORE = "+%d autres — agrandis la fenêtre"
	L.DASH_AXIS_SOURCE = "Par source"
	L.DASH_AXIS_MOVEMENT = "Par type"
	L.DASH_TARGETS = "Commence par là"
	L.DASH_NO_TARGET = "Rien de disponible maintenant — tout est verrouillé ou non cartographié."
	L.DASH_LOCKOUTS = "Déjà fait cette semaine"
	L.DASH_NO_LOCKOUT = "Aucun verrou sur ce personnage — la semaine est intacte."

	L.MOVE_GROUND = "Terrestre"
	L.MOVE_FLYING = "Volante"
	L.MOVE_SKYRIDING = "Skyriding"
	L.MOVE_AQUATIC = "Aquatique"
	L.MOVE_OTHER = "Autre"
	L.SOURCE_UNKNOWN = "Autres"

	L.STATUS_AVAILABLE = "disponible"
	L.STATUS_LOCKED = "verrouillé"
	L.STATUS_UNKNOWN = "incertain"
	L.STATUS_NO_SOURCE = "source non cartographiée"
	L.STATUS_NO_SOURCE_SHORT = "non cartographiée"
	L.STATUS_INELIGIBLE = "non éligible"

	L.SUMMARY = "%d/%d possédées — %d manquantes"
	L.INSTANCE_COUNTER = "Instances : %d/%d cette heure · %d/%d aujourd'hui"
	L.SUMMARY_FILTERED = "%d affichées"
	L.JOURNAL_NOT_READY = "Journal des montures pas encore peuplé, nouvelle tentative…"
	L.NO_RESULT = "Aucun résultat pour ces filtres."

	L.FILTER_SEARCH = "Rechercher"
	L.FILTER_SHOW_OWNED = "Afficher les possédées"
	L.FILTER_HIDE_EXCLUDED = "Masquer les exclues"
	L.FILTER_SOURCE = "Source"
	L.FILTER_ALL = "Tout"
	L.FILTER_NONE = "Rien"
	L.TYPE_RAID = "Raid"
	L.TYPE_DUNGEON = "Donjon"

	L.PREVIEW_HINT = "Glisser pour tourner · molette pour zoomer"
	L.PREVIEW_NONE = "Aucun modèle disponible pour cette monture."
	L.HINT_PREVIEW = "Clic gauche : aperçu de la monture"
	L.HINT_MENU = "Clic droit : plus d'actions"

	L.ACTION_PREVIEW = "Aperçu de la monture"
	L.ACTION_COPY_NAME = "Copier le nom"
	L.ACTION_ROUTE = "Tracer la route"
	L.ACTION_ROUTE_IMPOSSIBLE = "Aucune entrée cartographiée pour cette monture."
	L.ACTION_EXCLUDE = "Exclure de la liste"
	L.ACTION_INCLUDE = "Remettre dans la liste"
	L.TAG_EXCLUDED = "exclue"
	L.TOOLTIP_BOSS = "Boss"
	L.TOOLTIP_MOVEMENT = "Type de monture"
	L.TOOLTIP_DIFFICULTY = "Verrou posé en"
	L.MINIMAP_LEFT = "Clic gauche : ouvrir OnlyFarm"
	L.MINIMAP_RIGHT = "Clic droit : rescanner collection et verrous"
	L.MINIMAP_RESCANNED = "rescan demandé."

	L.ATTEMPTS = "%d essais"
	L.ATTEMPTS_ONE = "1 essai"
	L.ATTEMPTS_NONE = "aucun essai"
	L.ATTEMPTS_LAST = "dernier essai il y a %s"
	L.ATTEMPTS_DRY = "%.0f%% de chances de n'avoir toujours rien"
	L.ATTEMPTS_TOTAL = "%d essais sur %d montures"
	L.HINT_ATTEMPT_ADD = "Maj+clic : +1 essai (si le comptage automatique a raté)"
	L.HINT_ATTEMPT_SUB = "Ctrl+clic : -1 essai"

	L.LOCK_RESETS_IN = "reset dans %s"
	L.LOCK_CHARS = "%d perso(s) disponible(s)"
	L.LOCK_STALE = "vu il y a %s"

	L.CMD_HELP_HEADER = "Commandes OnlyFarm :"
	L.CMD_HELP_SHOW = "  /of           — ouvrir la fenêtre"
	L.CMD_HELP_SCAN = "  /of scan      — rescanner collection et verrous"
	L.CMD_HELP_CHARS = "  /of chars     — lister les personnages connus"
	L.CMD_HELP_DEEPSCAN = "  /of deepscan  — passe approfondie : butin boss par boss (lent, facultatif)"
	L.CMD_HELP_DIAG = "  /of diag      — pourquoi la cartographie est revenue vide (rapport copiable)"
	L.CMD_HELP_EXPORT = "  /of export    — CSV des montures sans extension (« all » pour toutes)"
	L.CMD_HELP_DEBUG = "  /of debug     — activer/couper les traces"
	L.CMD_HELP_RESET = "  /of reset     — effacer la base sauvegardée (demande confirmation)"

	L.SCAN_START = "Cartographie de tes montures en cours…"
	L.SCAN_AUTO_START = "Première cartographie de tes montures — extensions, instances et boss."
	L.SCAN_DEEP_START = "Cartographie complète : butin boss par boss. Quelques minutes, une seule fois. L'interface peut saccader."
	L.SCAN_DONE = "Cartographie terminée : %d montures sur %d rattachées à une instance, sur %d instances."
	L.SCAN_AUTO_DONE = "C'est gardé sur le disque — ça ne se refait qu'après un patch ou à l'arrivée de nouvelles montures."
	L.SCAN_SUMMARY = "%d/%d cartographiées · il y a %s"
	L.SCAN_RUNNING = "cartographie…"
	L.SCAN_BUTTON = "Rescanner"
	L.SCAN_NEVER = "jamais cartographié"
	L.SCAN_BREAKDOWN = "détail : %d par le lieu, %d par haut fait (%d hauts faits indexés, %d/%d catégories rattachées à une extension)."
	L.SCAN_EMPTY_DETAIL = "rien de rattaché : %d montures avec un texte de source, %d avec un lieu extrait, %d instances dans l'index. |cff7ac1ff/of diag|r pour le détail."
	L.SCAN_BUSY = "Un scan est déjà en cours."
	L.SCAN_NEEDS_EJ = "Journal des rencontres indisponible — ouvre-le une fois, puis réessaie."

	L.DIAG_TITLE = "OnlyFarm — diagnostic de cartographie"
	L.DIAG_SUMMARY = "diagnostic ouvert : %d montures sur %d rattachées à une instance. Ctrl+C pour copier."
	L.COPY_TITLE = "OnlyFarm"
	L.COPY_HINT = "Ctrl+C pour copier · Échap pour fermer"
	L.EXPORT_TITLE = "OnlyFarm — fichier de curation (CSV)"
	L.EXPORT_DONE = "%d montures exportées. Ctrl+C pour copier."

	L.NODE_PLAYER = "Ta position"

	L.ROUTE_MISSION = "Prochaine cible"
	L.ROUTE_WHERE = "Où c'est"
	L.ROUTE_TARGET = "Objectif"
	L.ROUTE_ZONE = "Zone"
	L.ROUTE_COORDS = "Coordonnées"
	L.ROUTE_START = "Start"
	L.ROUTE_UNPIN = "Laisser choisir"
	L.ROUTE_PINNED = "épinglée par toi"
	L.ROUTE_VIA_CLIENT = "Start pose le point de passage du jeu et le suit."
	L.ROUTE_VIA_TOMTOM = "TomTom détecté : Start lui confie le point de passage."
	L.ROUTE_STARTED = "point de passage posé : %s. Suis la flèche."
	L.ROUTE_FAILED = "impossible de poser le point de passage (%s)."
	L.ROUTE_NONE = "Aucune monture routable : aucune des manquantes n'a d'entrée cartographiée."
	L.ROUTE_NEEDS_SCAN = "La cartographie n'a pas encore tourné — c'est elle qui relie une monture à une entrée d'instance."
	L.ROUTE_NO_MAP = "Pas d'art de carte pour ce lieu."
	L.TYPE_OUTDOOR_LABEL = "En extérieur"
	L.COL_STATUS_SHORT = "Statut"

	L.RESET_CONFIRM = "Tape |cffff5555/of reset confirm|r pour effacer la base d'OnlyFarm."
	L.RESET_DONE = "Base effacée. Recharge l'interface (/reload)."
end

ns.L = L
