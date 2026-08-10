# OnlyFarm — Spécification technique

**Addon World of Warcraft (Retail) — planificateur de farm de montures**
Version 1.0 · Cible : Retail (The War Within / Midnight, API 11.x+)

> Document d'origine, rédigé sous le nom de travail « MountRoute ». Le projet
> s'appelle **OnlyFarm**. Le texte est conservé tel quel ; les corrections
> apportées après vérification contre le client réel sont dans
> [`API-NOTES.md`](API-NOTES.md), et l'état d'avancement dans
> [`../CONTRIBUTING.md`](../CONTRIBUTING.md).

---

## 1. Objectif

Un addon qui répond à une seule question, bien : **« qu'est-ce que je fais cette semaine pour choper des montures, et dans quel ordre ? »**

Trois fonctions :

1. **Diff collection** — croiser les montures possédées avec la base des montures farmables → liste des cibles manquantes.
2. **État des verrous** — pour chaque cible, dire si elle est disponible *maintenant*, sur *quel personnage*, et quand ça reset.
3. **Route** — ordonner les cibles disponibles en un parcours minimisant le temps de trajet réel (téléports, portails, vols), avec possibilité d'éditer/créer sa propre route.

**Principe directeur :** l'addon ne joue pas à ta place. Il calcule, affiche, pose des waypoints et met le bon sort de téléportation sous un bouton. Le clic reste humain.

---

## 2. Contraintes techniques (le cadre imposé par Blizzard)

À poser d'entrée, parce que ça détermine l'architecture entière.

### Ce qui est possible

| Besoin | API |
|---|---|
| Montures possédées | `C_MountJournal.GetMountIDs()` + `C_MountJournal.GetMountInfoByID(mountID)` → champ `isCollected` |
| Item → monture | `C_MountJournal.GetMountFromItem(itemID)` |
| Sort → monture | `C_MountJournal.GetMountFromSpell(spellID)` |
| Verrous d'instance | `RequestRaidInfo()` puis `GetNumSavedInstances()` / `GetSavedInstanceInfo(i)` |
| Verrou par boss | `GetSavedInstanceEncounterInfo(instanceIndex, encounterIndex)` → `isKilled` |
| Loot par boss (bootstrap DB) | `EJ_SelectInstance()`, `EJ_SelectEncounter()`, `C_EncounterJournal.GetLootInfoByIndex()` |
| Classe d'objet (détecter une monture) | `C_Item.GetItemInfoInstant(itemID)` → `classID == 15`, `subClassID == 5` |
| Quêtes hebdo (world bosses, trackers cachés) | `C_QuestLog.IsQuestFlaggedCompleted(questID)` |
| Réputation classique | `C_Reputation.GetFactionDataByID(factionID)` |
| Renom (factions majeures) | `C_MajorFactions.GetMajorFactionRenownInfo(id)` |
| Jouets possédés | `PlayerHasToy(itemID)`, `C_ToyBox.GetToyInfo(itemID)` |
| Sorts connus | `IsPlayerSpell(spellID)`, `IsSpellKnownOrOverridesKnown(spellID)` |
| Cooldowns | `C_Spell.GetSpellCooldown(spellID)`, `C_Container.GetItemCooldown(itemID)` |
| Position / carte | `C_Map.GetBestMapForUnit("player")`, `C_Map.GetPlayerMapPosition()` |
| Waypoint natif | `C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(...))` + `C_SuperTrack.SetSuperTrackedUserWaypoint(true)` |
| Vols | `C_TaxiMap.GetAllTaxiNodes(uiMapID)` |
| Lancer un sort au clic utilisateur | `SecureActionButtonTemplate` avec attributs `type="spell"` / `type="item"` |

### Ce qui est impossible (et qu'il ne faut pas promettre)

- **Aucune automatisation de déplacement.** Pas de `MoveForward()` scripté, pas de clic auto, pas de pathing exécuté. `SetUserWaypoint` + navigation manuelle, c'est le maximum.
- **Impossible de changer les attributs d'un bouton sécurisé en combat.** Le bouton « téléport de l'étape courante » ne se met à jour qu'hors combat (`PLAYER_REGEN_ENABLED` → flush d'une file d'attente).
- **Pas d'API « taux de drop ».** Les drop rates viennent d'une table statique embarquée (source : Wowhead / datamining), pas du client.
- **Pas d'API « quels boss j'ai loot cette semaine »** au sens loot ; seulement `isKilled` par boss, ce qui suffit pour les lockouts.
- **Le verrou n'existe pas avant le premier kill.** Une instance jamais entrée cette semaine ne figure pas dans `GetSavedInstanceInfo` → absence = disponible.
- **Pas de lecture des lockouts des autres persos.** Il faut se connecter au moins une fois par perso pour que l'addon écrive son état dans les SavedVariables (account-wide).
- **Aucun accès aux serveurs Blizzard.** Pas d'appel HTTP. Toute donnée externe doit être compilée dans le `.lua` au build.

### Règles de jeu à modéliser (souvent oubliées)

- **Donjons legacy : reset quotidien.** Raids legacy : reset hebdomadaire (mardi ou mercredi selon la région). Deux horloges différentes → deux logiques de disponibilité.
- **Cap d'instances : 10 par heure, 30 par jour.** Une route de farm legacy sature ce cap très vite. C'est une contrainte dure du routeur, pas un détail.
- **Les montures sont account-wide, les lockouts sont par personnage.** Un raid déjà fait sur le main reste dispo sur 4 alts. C'est là que se trouve le vrai gain de temps, et peu d'addons le gèrent.
- **Certaines montures sont faction-locked ou classe-locked** (`isFactionSpecific`, `shouldHideOnChar`) → à filtrer par perso.

---

## 3. Architecture

```
OnlyFarm/
├─ OnlyFarm.toc
├─ libs/                    Ace3, LibDeflate, LibSerialize, HereBeDragons, LibDBIcon
├─ Core/
│  ├─ Init.lua              bootstrap AceAddon, namespace, event bus
│  ├─ Database.lua          AceDB, profils, migrations de schéma
│  └─ Util.lua              helpers, throttle, coroutine scheduler
├─ Data/                    ── généré au build, jamais édité à la main ──
│  ├─ Mounts.lua            MountDB
│  ├─ Sources.lua           SourceDB (boss, rare, vendeur, métier…)
│  ├─ Nodes.lua             NodeDB (entrées d'instance, hubs, coords)
│  ├─ Travel.lua            TravelDB (téléports, portails, vols)
│  └─ Version.lua           hash + patch de build
├─ Modules/
│  ├─ Collection.lua        scan du Mount Journal → set possédé
│  ├─ Lockouts.lua          scan des verrous, agrégation multi-perso
│  ├─ Eligibility.lua       cible dispo ? filtres, faction, niveau, prérequis
│  ├─ TravelGraph.lua       construction du graphe pondéré selon TES accès
│  ├─ Router.lua            Dijkstra + TSP ouvert (coroutine)
│  ├─ RouteStore.lua        routes auto / maison, import-export
│  └─ Tracker.lua           progression en jeu, auto-avance, waypoints
├─ UI/
│  ├─ MainFrame.lua         onglets Collection / Route / Éditeur
│  ├─ RouteEditor.lua       drag & drop, verrouillage d'étapes
│  ├─ HUD.lua               mini-tracker flottant en jeu
│  └─ TeleportButton.lua    SecureActionButton de l'étape courante
└─ Build/
   └─ generate_data.py      pipeline de génération de Data/
```

**Dépendances** : Ace3 (AceAddon-3.0, AceDB-3.0, AceEvent-3.0, AceTimer-3.0, AceConfig-3.0), HereBeDragons-2.0 (coordonnées monde unifiées), LibSerialize + LibDeflate (partage de routes), LibDBIcon-1.0.

---

## 4. Modèle de données

### 4.1 MountDB — une entrée par monture farmable

```lua
[mountID] = {
    name       = "Reins de proto-drake fumeronde",
    itemID     = 32458,
    spellID    = 40192,
    sources    = { "srcSSC_Kael", "srcTK_Kael" },  -- clés vers SourceDB
    tags       = { "raid", "tbc", "legacy" },
    faction    = nil,        -- "Alliance" | "Horde" | nil
    classOnly  = nil,        -- classID si monture de classe
}
```

### 4.2 SourceDB — le cœur : « où et à quelle fréquence »

```lua
srcULD_Yogg = {
    kind        = "boss",          -- boss | rare | vendor | profession | event | pvp | quest
    instanceID  = 759,             -- instanceID moteur (GetSavedInstanceInfo)
    journalID   = 187,             -- journalInstanceID (Encounter Journal)
    encounterID = 1143,
    difficulty  = { 14, 15, 16 },  -- difficultyID acceptés
    nodeID      = "node_ulduar",   -- point d'entrée dans NodeDB
    lockout     = "weekly",        -- weekly | daily | none | respawn
    dropRate    = 0.01,
    runTime     = 420,             -- secondes, estimation solo au niveau max
    requires    = { minLevel = 80 },
}

srcRare_TLPD = {
    kind      = "rare",
    npcID     = 32491,
    nodeID    = "node_stormpeaks_tlpd",
    lockout   = "respawn",         -- pas de verrou, respawn 6-24h
    dropRate  = 1.00,
    runTime   = 60,
    note      = "spawn aléatoire, faible priorité en route",
}

srcVendor_Brutosaur = {
    kind      = "vendor",
    currency  = { type = "gold", amount = 5000000 },
    nodeID    = "node_blackrocktrade",
    lockout   = "none",
}
```

Le champ `lockout` pilote quelle horloge appliquer. Le champ `runTime` est la durée estimée *dans* l'instance, distincte du coût de trajet — les deux se somment dans le score final.

### 4.3 NodeDB — la géographie

```lua
node_ulduar = {
    uiMapID  = 492,
    x, y     = 0.415, 0.185,        -- coords normalisées de la carte
    wx, wy   = ...,                 -- coords monde (via HereBeDragons) pour le calcul de distance
    continent = "northrend",
    hub      = "hub_dalaran_wlk",   -- ancre de voyage la plus proche
    indoor   = false,
}
```

### 4.4 TravelDB — les arêtes du graphe

```lua
{ kind="teleport", spellID=373274, from="*",              to="node_dalaran_wlk", cost=12, cooldown=1800, source="toy:140192" },
{ kind="teleport", spellID=445414, from="*",              to="node_ulduar",      cost=12, cooldown=900,  source="spell" },  -- téléport M+
{ kind="portal",   from="hub_dornogal", to="hub_dalaran_wlk", cost=35 },
{ kind="taxi",     from="node_dalaran_wlk", to="node_ulduar", cost=95 },
{ kind="fly",      -- arête implicite, coût calculé : distance monde / vitesse
```

`cost` en secondes, incluant temps d'incantation **et** écran de chargement (~8 s forfaitaires pour tout changement d'instance/continent).

### 4.5 Génération de la base (`Build/generate_data.py`)

Écrire 300 entrées à la main n'est ni tenable ni maintenable entre patchs. Le pipeline :

1. **Scan in-game** (mode dev de l'addon) : boucler sur tous les `journalInstanceID` via `EJ_GetInstanceByIndex`, pour chaque boss lire `C_EncounterJournal.GetLootInfoByIndex`, filtrer `classID == 15 and subClassID == 5`, résoudre via `C_MountJournal.GetMountFromItem` → dump JSON dans les SavedVariables.
2. **Enrichissement offline** : le script Python fusionne ce dump avec une table de drop rates et de coordonnées d'entrée maintenue dans le repo.
3. **Émission** de `Data/*.lua` + un hash de version.

Résultat : les montures d'instance sont ~90 % auto-générées et se régénèrent en une commande à chaque patch. Seuls rares, vendeurs, métiers, événements et PvP restent curés à la main (~80 entrées, stables dans le temps).

---

## 5. Détection : collection, verrous, éligibilité

### 5.1 Collection

```lua
function Collection:Scan()
    local owned = {}
    for _, mountID in ipairs(C_MountJournal.GetMountIDs()) do
        local _, _, _, _, _, _, _, _, _, _, isCollected = C_MountJournal.GetMountInfoByID(mountID)
        if isCollected then owned[mountID] = true end
    end
    self.owned = owned
end
```

Rescan sur `NEW_MOUNT_ADDED` et `COMPANION_LEARNED`. Coût négligeable (~500 itérations).

⚠️ Le Mount Journal n'est pas garanti peuplé à `PLAYER_LOGIN`. Attendre `PLAYER_ENTERING_WORLD` + un `C_Timer.After(2, ...)` de sécurité, et invalider le cache si `GetNumMounts()` renvoie 0.

### 5.2 Verrous

```lua
function Lockouts:Scan()
    RequestRaidInfo()          -- asynchrone
end

-- puis, sur UPDATE_INSTANCE_INFO :
for i = 1, GetNumSavedInstances() do
    local name, lockoutID, reset, difficultyID, locked, _, _, isRaid,
          _, _, numEncounters, encounterProgress, _, instanceID = GetSavedInstanceInfo(i)
    if locked then
        local bosses = {}
        for e = 1, numEncounters do
            local bossName, _, isKilled = GetSavedInstanceEncounterInfo(i, e)
            bosses[bossName] = isKilled
        end
        store[instanceID .. ":" .. difficultyID] = {
            expires = time() + reset,
            bosses  = bosses,
        }
    end
end
```

Écrit dans `OnlyFarmDB.global.chars[realm-name]`, avec `lastSeen`. Un raid absent du store et non expiré = **disponible**.

Les donjons legacy n'apparaissent quasiment jamais dans les saved instances (reset quotidien, verrou court) : pour eux, l'addon suit ses propres entrées via `PLAYER_ENTERING_WORLD` + `IsInInstance()` et compare à la frontière de reset quotidien du royaume.

### 5.3 Vue multi-personnage

L'écran le plus utile de l'addon :

```
Invincible (ICC 25 HM)
  ✅ Krayne    disponible
  ❌ Zaltus    verrouillé — reset mercredi 09:00
  ✅ Morvani   disponible
  → 2 tentatives cette semaine
```

Implémentation : agrégation du store par `sourceID`, avec un indicateur de fraîcheur (perso non connecté depuis > 7 j → état grisé « incertain »).

### 5.4 Compteur du cap d'instances

Buffer glissant des timestamps d'entrée (`PLAYER_ENTERING_WORLD` où `IsInInstance()` passe à vrai), plus parsing de `CHAT_MSG_SYSTEM` pour le message « trop d'instances » qui recale le compteur en cas de désync. Affiché en permanence : `Instances : 6/10 cette heure · 14/30 aujourd'hui`. Le routeur insère une pause quand la route dépasse le cap.

---

## 6. Moteur de route

### 6.1 Pipeline

```
Cibles manquantes
   ↓ filtre éligibilité (faction, niveau, verrou, prérequis, activation utilisateur)
Cibles retenues
   ↓ regroupement par nœud (plusieurs boss = une seule visite d'instance)
Visites
   ↓ Dijkstra sur le graphe de voyage → matrice de coûts C[i][j]
Matrice
   ↓ TSP ouvert (nearest neighbor + 2-opt + Or-opt)
Ordre
   ↓ post-passes : cap d'instances, cooldowns de téléport, budget temps
Route finale
```

### 6.2 Graphe de voyage — personnalisé par personnage

C'est ce qui fait la différence entre un ordre correct et un ordre juste. Le graphe se reconstruit à la connexion, en ne gardant que les arêtes réellement disponibles :

```lua
function TravelGraph:Build()
    for _, edge in ipairs(TravelDB) do
        local ok
        if edge.source == "spell" then ok = IsPlayerSpell(edge.spellID)
        elseif edge.source:match("^toy:") then ok = PlayerHasToy(tonumber(edge.source:sub(5)))
        elseif edge.source:match("^item:") then ok = C_Item.GetItemCount(id, true) > 0
        else ok = true end
        if ok then self:AddEdge(edge) end
    end
    self:AddFlightEdges()   -- distance monde / vitesse effective
end
```

Les téléports de donjon Mythique+ (obtenus via les hauts faits de clé) transforment une route Legion/BfA/DF. Il faut donc les détecter, pas les supposer.

**Coût d'une arête `fly`** :

```
cost = distance_monde(A, B) / vitesse_effective + pénalité_verticale
```

`vitesse_effective` dépend du mode : vol dynamique (Skyriding) ≈ 65–90 yd/s en moyenne sur longue distance, vol stationnaire ≈ 27 yd/s. À prendre depuis les réglages du joueur, avec un facteur de calibration ajustable dans les options.

**Coût d'une arête `taxi`** : les durées réelles de vol ne sont pas exposées. Deux options — (a) table pré-mesurée pour les trajets fréquents, (b) auto-apprentissage : l'addon chronomètre les vols du joueur (`TAXIMAP_OPENED` → départ → arrivée) et alimente une table locale qui s'affine à l'usage. L'option (b) coûte 40 lignes et rend le modèle progressivement exact pour *ce* joueur.

### 6.3 Ressources rares : les téléports à cooldown

Une pierre de foyer, un jouet Dalaran, un Anneau de portail — chacun n'est utilisable qu'une fois par route. C'est un problème de tournée sous contrainte de ressources, NP-difficile en général, mais avec n ≤ 40 une heuristique gloutonne suffit :

1. Résoudre le TSP **sans** les arêtes à cooldown (baseline).
2. Pour chaque téléport à cooldown, calculer le gain marginal de son insertion à chaque position.
3. Affecter gloutonnement chaque téléport à sa meilleure position, recalculer, itérer jusqu'à stabilité (converge en 2–3 passes).

### 6.4 Solveur TSP

`n` est petit (typiquement 8–35 visites), donc pas besoin d'artillerie :

```lua
-- Construction : nearest neighbor depuis la position du joueur
-- Amélioration : 2-opt (inversion de segment) + Or-opt (déplacement de 1-3 nœuds)
-- Arrêt : pas d'amélioration sur un passage complet, ou 200 ms de budget écoulé
```

Le tout dans une **coroutine** cadencée par `OnUpdate` avec un budget de ~4 ms par frame. Aucun freeze perceptible, même à n = 60. Le solveur est *open-ended* : il part de la position du joueur et ne revient pas au départ (une route de farm ne boucle pas).

### 6.5 Score d'efficacité — savoir où couper

Chaque visite reçoit :

```
EV = Σ (dropRate × poids_priorité)   sur les montures manquantes du nœud
efficacité = EV / (coût_trajet + runTime)
```

Trié par efficacité décroissante, ça permet le mode **« j'ai 45 minutes »** : le routeur prend le préfixe de visites qui tient dans le budget en maximisant l'EV cumulée — un sac à dos glouton, résolu exactement par programmation dynamique si besoin puisque les temps s'arrondissent à la minute.

### 6.6 Sortie

```lua
route = {
  { type="travel",  action="spell", id=373274, label="Jouet : Pierre de foyer de Dalaran", eta=12 },
  { type="visit",   nodeID="node_ulduar", instance="Ulduar",
      targets = { { mount="Rênes de proto-drake fumeronde", boss="Yogg-Saron", drop=0.01 } },
      eta = 420 },
  { type="travel",  action="taxi", to="node_icecrown", eta=95 },
  { type="visit",   nodeID="node_icc", ... },
  { type="pause",   reason="instance_cap", until_=1754...  },
}
```

---

## 7. Interface

### 7.1 Fenêtre principale — trois onglets

**Collection** — liste des montures manquantes, groupées par source (Raids / Donjons / Rares / Réputations / Métiers / Événements / PvP). Colonnes : monture, source, taux de drop, disponibilité, nb de persos éligibles. Filtres : expansion, type de source, drop rate mini, « uniquement le dispo maintenant ». Recherche texte. Case à cocher par ligne : *inclure dans les routes*.

**Route** — la route courante en étapes numérotées. Chaque étape : icône (téléport / vol / instance), libellé, ETA, montures visées. En tête : total estimé, EV cumulée, compteur d'instances. Boutons : `Générer`, `Recalculer depuis ma position`, `Sauver comme route maison`.

**Éditeur** — construction manuelle (voir §8).

### 7.2 HUD en jeu

Petite fenêtre déplaçable, ancrable, masquable en combat :

```
┌────────────────────────────────┐
│ 3/11 · Ulduar                  │
│ ▸ Yogg-Saron — Proto fumeronde │
│   [ Poser un waypoint ]        │
│ Suivant : ICC (vol, ~95 s)     │
└────────────────────────────────┘
```

**Auto-avance** : `ENCOUNTER_END` (succès) coche le boss ; `ZONE_CHANGED_NEW_AREA` détecte l'arrivée à un nœud et avance l'étape de trajet. `NEW_MOUNT_ADDED` déclenche une célébration et retire définitivement la cible de toutes les routes.

### 7.3 Bouton de téléport sécurisé

Un `SecureActionButtonTemplate` unique dont les attributs sont réécrits à chaque changement d'étape :

```lua
btn:SetAttribute("type", "spell")
btn:SetAttribute("spell", currentStep.spellID)
```

Réécriture bloquée en combat → mise en file et flush sur `PLAYER_REGEN_ENABLED`. Le bouton affiche le cooldown via `CooldownFrame_Set` et se grise si indisponible.

### 7.4 Waypoints

Priorité à TomTom s'il est chargé (`TomTom:AddWaypoint`), sinon fallback natif :

```lua
C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(uiMapID, x, y))
C_SuperTrack.SetSuperTrackedUserWaypoint(true)
```

Plus des pins sur la carte du monde pour toutes les étapes de la route (data provider natif ou HereBeDragons-Pins).

### 7.5 Bouton minimap

LibDBIcon. Clic gauche : ouvrir/fermer. Clic droit : générer une route. Infobulle : prochaine étape + compteur d'instances.

---

## 8. Routes maison

Le point sur lequel la plupart des addons de ce type déçoivent. Le cahier des charges :

- **Ajouter n'importe quelle cible** : depuis la liste Collection (clic droit → ajouter), depuis la carte, ou une étape libre (« Bijoutier de Valdrakken », note perso).
- **Réordonner** par drag & drop.
- **Verrouiller une étape** (📌) : le ré-optimiseur ne la déplace pas. Ça permet le mélange manuel/auto — « je commence toujours par ICC, optimise le reste ».
- **Optimiser l'ordre** : bouton qui lance le routeur sur les seules étapes non verrouillées, en gardant les positions figées.
- **Conditions par étape** : `si monture manquante` (par défaut, l'étape disparaît une fois obtenue), `toujours`, `si perso = X`.
- **Plusieurs routes nommées**, avec une route active. Cas d'usage typiques : « Reset mardi complet », « Legacy rapide 30 min », « Rares Draenor quotidien ».
- **Templates** fournis : *Legacy raids complet*, *Donjons quotidiens*, *Rares hebdo TWW*, *Débutant — meilleurs ratios drop/temps*.
- **Import/export** : `LibSerialize` → `LibDeflate:CompressDeflate` → `EncodeForPrint`. Chaîne collable, avec version de schéma et migration à l'import.

Schéma de stockage :

```lua
OnlyFarmDB.global.routes["Legacy mardi"] = {
    version = 2,
    steps = {
        { sourceID="srcICC_LK", pinned=true,  condition="missing" },
        { sourceID="srcULD_Yogg", pinned=false, condition="missing" },
        { custom={ label="Vendeur Brutosaure", uiMapID=32, x=.51, y=.29 }, condition="always" },
    },
}
```

---

## 9. Persistance

```
OnlyFarmDB
├─ global
│  ├─ chars["Krayne-Hyjal"] = { lockouts={}, quests={}, teleports={}, lastSeen=… }
│  ├─ routes[name]          = { steps={}, version=… }
│  ├─ excluded[mountID]     = true          -- montures que le joueur ne veut pas
│  └─ travelTimings[edge]   = { samples={}, avg=… }   -- auto-apprentissage
└─ profile   (AceDB, par perso par défaut)
   ├─ ui       = { position, scale, hudEnabled, autoAdvance }
   ├─ filters  = { minDropRate, expansions={}, sourceKinds={} }
   └─ routing  = { flySpeed, budgetMinutes, respectInstanceCap }
```

Migrations gérées par un numéro de schéma + une chaîne de fonctions `migrate[v] -> v+1`, jouée au chargement.

---

## 10. Performance

| Point | Approche |
|---|---|
| Scan collection | ~500 itérations, une fois au login + sur événement. Négligeable. |
| Scan lockouts | Asynchrone via `RequestRaidInfo`, débouncé à 1 appel / 10 s. |
| Construction du graphe | Une fois au login, invalidée sur `SPELLS_CHANGED` / `TOYS_UPDATED` (débouncé 2 s). |
| Matrice de coûts | Dijkstra depuis chaque nœud cible uniquement (n ≤ 40), mémoïsée, invalidée avec le graphe. |
| Solveur TSP | Coroutine, budget 4 ms/frame, cible < 300 ms total. |
| Listes UI | Scroll virtualisé (`ScrollBoxListLinearView`), jamais 300 frames instanciées. |
| Table de données | ~250 Ko en Lua. Chargement à la demande via `## LoadOnDemand` pour les tables de voyage lourdes. |

Aucun `OnUpdate` permanent hors calcul actif. Zéro requête réseau (impossible de toute façon).

---

## 11. Roadmap suggérée

| Phase | Contenu | Effort |
|---|---|---|
| **1 — Socle** | TOC, Ace3, scan collection, scan lockouts, liste des montures manquantes avec disponibilité. Aucune route. | ~1 semaine |
| **2 — Données** | Pipeline `generate_data.py`, scan Encounter Journal, drop rates, coordonnées d'entrée. | ~1 semaine |
| **3 — Route auto** | NodeDB, TravelDB, graphe, Dijkstra, TSP, onglet Route. Plan détaillé : [`docs/PHASE3.md`](PHASE3.md). | ~2 semaines |
| **4 — En jeu** | HUD, auto-avance, waypoints, bouton de téléport sécurisé, compteur d'instances. | ~1 semaine |
| **5 — Routes maison** | Éditeur drag & drop, épinglage, conditions, import/export, templates. | ~1 semaine |
| **6 — Élargissement** | Rares, world bosses, réputations, métiers, événements, PvP. Vue multi-perso complète. | ~1–2 semaines |

La phase 1 seule est déjà utilisable au quotidien — c'est le bon point d'arrêt si l'envie retombe.

---

## 12. Risques et limites

- **Maintenance des données.** Chaque patch ajoute des montures et déplace des entrées d'instance. Le pipeline automatique couvre les instances ; le reste demande une passe manuelle par patch majeur. C'est le vrai coût de possession de cet addon.
- **Drop rates approximatifs.** Les valeurs communautaires (Wowhead) sont des estimations. Les afficher comme telles, ne pas prétendre à l'exactitude.
- **Estimations de trajet imparfaites** au premier lancement. L'auto-apprentissage corrige à l'usage, mais la première route sera un peu optimiste.
- **Les rares à respawn** (Proto-drake perdu dans le temps, Aeonaxx…) ne s'intègrent pas proprement à une route : pas de verrou, spawn aléatoire. Les traiter comme des *détours opportunistes* affichés le long du trajet, pas comme des étapes obligatoires.
- **Cap d'instances** : sur une route legacy agressive, c'est lui et non la distance qui devient le facteur limitant. Le routeur doit le dire clairement plutôt que de proposer un plan infaisable.
- **Fiabilité de `ENCOUNTER_END`** en instance solo legacy : l'événement se déclenche correctement, mais prévoir un fallback manuel (clic pour cocher) plutôt qu'un blocage si l'auto-avance rate.

---

## 13. Idées optionnelles

- **Mode « meilleur perso »** : pour chaque cible, indiquer sur quel personnage la lancer, et proposer une route par perso ordonnée pour minimiser les allers-retours.
- **Journal de tentatives** : compter les runs par monture, afficher la probabilité cumulée de ne toujours rien avoir (`1 - (1-p)^n`). Utile, et un peu cruel.
- **Estimation de fin** : « à ce rythme, Invincible tombe statistiquement autour de la semaine 47 ». Purement indicatif, mais motivant.
- **Intégration Rarity** : si l'addon Rarity est présent, lire ses compteurs de tentatives plutôt que de dupliquer le suivi.
- **Alerte de reset** : notification le jour du reset avec le nombre de tentatives disponibles.
- **Détection de groupe** : si des membres du groupe ont aussi OnlyFarm, afficher les cibles communes pour organiser un tour de farm collectif.
