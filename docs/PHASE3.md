# Phase 3 — De la cible unique à la tournée

Document d'implémentation. Il complète `docs/SPEC.md` §6 : la spécification dit
*quoi*, celui-ci dit *contre quel code*, *avec quelles signatures* et *quels
pièges ont déjà coûté cher*. Lire `CONTRIBUTING.md` avant, en particulier les
règles du domaine.

**La moitié de la phase 3 est déjà en place.** Ce document ne décrit que ce qui
reste, et il commence par un inventaire précis de l'existant — c'est la partie
qu'il ne faut pas réécrire par accident.

---

## 1. Où on en est

L'addon sait déjà :

* quelles montures manquent, et lesquelles sont ouvertes cette semaine sur ce
  personnage ;
* **où se trouve une cible** — `Modules/Route.lua` choisit une monture (raid en
  priorité), résout son entrée d'instance, pose un point de passage ;
* **comment y aller** — `Route:BuildSteps` lance Dijkstra sur le graphe des
  téléports que ce personnage possède réellement, et découpe le trajet en
  étapes ;
* **où regarder** — `UI/ArrowHUD.lua` pointe l'étape en cours, pas la
  destination finale.

Il ne sait pas **dans quel ordre enchaîner plusieurs cibles dans une même
sortie**. C'est tout le reste de la phase 3, et c'est un problème de nature
différente : jusqu'ici on résolvait un plus court chemin (Dijkstra, exact,
résolu) ; à partir de maintenant on résout une tournée (TSP, heuristique,
plein de pièges).

---

## 2. État d'entrée : l'inventaire

### Ce qui tourne en jeu

| Fichier | Ce qu'il fait déjà |
|---|---|
| `Modules/Route.lua` (prio 50) | `GetMission()` / `GetMissionFor(mountID)` / `PickAuto()` — **une** cible ; `BuildSteps(mission)` → étapes via Dijkstra ; `Start` / `Advance` / `Stop` ; `GetBearing(node)` ; point de passage natif + TomTom |
| `Modules/Nodes.lua` (32) | registre fusionné (statique + `nodeCache` + `customNodes`), `GetPlayerNode()`, `GetForSource(source)`, `Distance()`, `FlightCost()` |
| `Modules/Teleports.lua` (33) | découverte des téléports dans le grimoire et le coffre à jouets, `GetEdges()`, `IsReady(edge)`, `GetCooldownRemaining(edge)`, apprentissage des durées (`NoteTravel`) |
| `Modules/TravelGraph.lua` (34) | `BuildUniverse()`, `EdgesFrom()`, `ShortestPaths()`, `Path()`, `BuildMatrix()`, `IsReachable()` |
| `UI/RoutePage.lua`, `UI/MapPreview.lua`, `UI/ArrowHUD.lua` | onglet Route, carte avec épingle, flèche déplaçable |

Douze tests `Route — …` couvrent déjà la cible unique dans `Tests/run.lua`. Ils
ne doivent pas régresser.

### Ce qui existe mais n'a jamais servi

**`TravelGraph:BuildMatrix(nodeIDs)`.** `Route:BuildSteps` appelle
`ShortestPaths` + `Path` en direct pour un seul couple. La matrice complète —
`matrix, paths, universe, sources` — n'a jamais tourné, ni en jeu ni en test.
C'est la première brique de la tournée et c'est la moins vérifiée du dépôt :
la tester avant de bâtir dessus.

`Data/Nodes.lua` et `Data/Travel.lua` restent volontairement vides. `Data.COST`
(forfaits en secondes) et `Data.DEFAULT_FLY_SPEED = 75` y vivent.

### Les réglages déjà déclarés

`db.profile.routing` porte déjà `target`, `flySpeed`, `budgetMinutes` (0 = pas
de budget) et `respectInstanceCap` (`true`). Les deux derniers ne sont lus par
personne : c'est ici qu'ils prennent leur sens.

---

## 3. Ce qu'il faut écrire

| Fichier | Priorité | Rôle |
|---|---|---|
| `Modules/RunTimes.lua` | 36 | durée d'une visite : forfait, puis mesure réelle |
| `Modules/Targets.lua` | 46 | montures → visites regroupées par nœud |
| `Modules/Router.lua` | 48 | matrice, TSP, post-passes, route finale |

Priorités existantes pour situer : Database 10, Collection 20, Lockouts 30,
Nodes 32, Teleports 33, TravelGraph 34, Attempts 35, Eligibility 40, Stats 45,
Route 50, Mapping 60, UI 80+, Commands 90.

**`Router` passe avant `Route` (48 < 50), et c'est voulu** : `Route` reste le
module qui parle à l'interface — mission courante, plan, flèche, point de
passage — et il consomme la tournée que `Router` produit. Ne pas dupliquer la
sélection de cible : `Route:PickAuto()` devient un cas particulier de la
tournée (le premier élément), pas un algorithme concurrent.

### Messages

Déjà émis par `Route`, à ne pas redéfinir : `OF_ROUTE_UPDATED` (la route
courante est invalidée), `OF_ROUTE_STARTED`, `OF_ROUTE_STEP`,
`OF_ROUTE_ARRIVED`, `OF_ROUTE_STOPPED`.

Un seul message nouveau : **`OF_ROUTE_PROGRESS`**, émis par le solveur avec une
`fraction` entre 0 et 1, pour la barre de progression.

`Route` écoute déjà `OF_COLLECTION_UPDATED`, `OF_LOCKOUTS_UPDATED`,
`OF_SCAN_COMPLETE`, `OF_ATTEMPTS_UPDATED`, `OF_NODES_UPDATED` et **invalide**
sans recalculer. Garder cette règle pour la tournée : un recalcul automatique
en boucle sur un joueur qui tue des boss est une régression de performance ET
d'ergonomie — la route bouge sous ses yeux. On marque « périmée », on propose
un bouton.

---

## 4. Pipeline

```
montures manquantes du perso courant     (Collection)
   ↓ filtre d'éligibilité                (Eligibility:GetStatus)
cibles retenues
   ↓ résolution de nœud                  (Nodes:GetForSource)
   ↓ regroupement par nodeID             (Targets)
visites  { nodeID, targets[], runTime, ev }
   ↓ Dijkstra de chacune vers chacune    (TravelGraph:BuildMatrix)
matrice C[i][j] en secondes  — ASYMÉTRIQUE
   ↓ TSP ouvert : NN + Or-opt + 2-opt    (Router, coroutine)
ordre
   ↓ retarification des téléports réutilisés
   ↓ cap d'instances → étapes de pause
   ↓ budget temps → troncature par efficacité
tournée : liste d'étapes
   ↓                                     (Route)
plan guidé, flèche, point de passage
```

### 4.1 Sélection des cibles

```lua
--- @return liste de { mountID, name, icon, source, node, status, weight }
function Targets:Collect(options)
```

`Route:GetMissionFor(mountID)` fait déjà l'essentiel du travail par monture —
entrée de collection, source, nœud, statut, tentatives, nom de zone. **La
réutiliser** plutôt que de réécrire cette résolution : elle porte déjà deux
décisions non évidentes (le vendeur n'est pas annoncé comme un boss ; la
difficulté n'est jamais devinée, seulement lue d'un verrou mesuré), et les
tests correspondants existent.

Règles de filtrage, dans cet ordre :

1. monture possédée → écartée ;
2. monture exclue (`Collection:IsExcluded`) → écartée ;
3. `status.state == INELIGIBLE` → écartée (faction, niveau) ;
4. `status.state == LOCKED` → écartée **par défaut**, et c'est le cœur de
   l'addon : la tournée ne propose jamais un raid déjà fait cette semaine.
   `options.includeLocked` les garde pour la vue « et la semaine prochaine ? »,
   alors marquées `deferred = true` et jamais mêlées aux étapes actives ;
5. `status.state == UNMAPPED` → écartée : sans source, pas de nœud ;
6. `status.state == UNKNOWN` → **retenue**, marquée `uncertain = true`.
   L'interface doit le dire. On n'écarte pas une cible parce qu'on ignore son
   horloge : ce serait masquer une monture farmable derrière une lacune de
   l'addon ;
7. `GetMissionFor` renvoie `nil` (pas de nœud exploitable) → écartée, comptée
   dans `stats.noNode`. **Ce compteur doit être affiché** : c'est lui qui mesure
   le trou de géographie, et le seul moyen de savoir si le moissonnage des
   entrées d'instance a marché.

### 4.2 Regroupement

```lua
--- @return liste de visites, statistiques
function Targets:BuildVisits(targets)
```

Une visite = un `nodeID` + toutes les cibles qui s'y trouvent. Trois montures
dans Ulduar font **une** visite, pas trois. C'est le gain principal de la phase
et il est purement combinatoire : rien à mesurer, rien à deviner.

```lua
{
    nodeID   = "ej:187",
    node     = <nœud>,
    name     = "Ulduar",            -- nom localisé, indicatif
    targets  = { <mission>, … },
    runTime  = 420,                 -- secondes, cf. §5
    ev       = 0.031,               -- cf. §7
    evIsEstimated = true,           -- au moins un dropRate manquant
    instanceID = 759,               -- pour le cap d'instances
    isRaid   = true,
}
```

### 4.3 Matrice de coûts

`TravelGraph:BuildMatrix(nodeIDs)` renvoie `matrix, paths, universe, sources`,
et ajoute en tête le nœud virtuel `TravelGraph.PLAYER_NODE` (`"player"`) quand
la position du joueur est connue.

**La matrice est asymétrique.** Une arête de téléport a `from = "*"` : elle
coûte pareil depuis n'importe où, donc `C[A][B] ≠ C[B][A]` dès qu'un des deux
nœuds a un téléport et pas l'autre. Toute la suite doit en tenir compte — c'est
le piège n°1 de cette phase, détaillé au §6.2.

`TravelGraph:IsReachable(cost)` distingue un coût réel d'un `math.huge`. Un
nœud inatteignable **ne se retire pas silencieusement de la tournée** : il sort
dans une section « inatteignable depuis ici », avec sa raison. `Route:BuildSteps`
applique déjà cette règle pour la cible unique (`path == nil` → `nil`, et
l'interface le dit) ; la tournée ne doit pas être moins honnête.

---

## 5. La durée d'une visite : `Modules/RunTimes.lua`

Aucune API ne donne le temps de nettoyage d'une instance. Deux niveaux, dans
l'esprit de `Teleports:CostOf` — forfait d'abord, mesure ensuite :

```lua
--- @return secondes, source ∈ { "measured", "default" }
function RunTimes:Get(instanceID, difficultyID)

--- Enregistre la durée réelle d'un passage.
function RunTimes:Note(instanceID, difficultyID, seconds)
```

Forfaits de départ, à poser dans `Data/Travel.lua` à côté de `Data.COST` :

```lua
Data.RUN_TIME = {
    RAID_LEGACY    = 420,   -- raid d'extension ancienne, solo au niveau max
    DUNGEON_LEGACY = 240,
    OUTDOOR        = 120,   -- rare, vendeur, nœud de métier
}
```

Mesure : `Lockouts:RecordInstanceEntry` connaît déjà l'entrée en instance et
émet `OF_INSTANCE_ENTERED` — s'y abonner plutôt que de réécouter
`PLAYER_ENTERING_WORLD`. La sortie (ou un `PLAYER_LOGOUT`) ferme la mesure.
Mêmes garde-fous que `Teleports.NoteTravel` : échantillon rejeté sous 30 s ou
au-dessus de 3600 s, moyenne glissante sur 10 échantillons, stockage dans
`db.global.runTimings["<instanceID>:<difficultyID>"]`.

Ces forfaits sont des **estimations** et l'interface doit les présenter comme
telles tant qu'aucune mesure ne les a remplacés (`source == "default"`).

---

## 6. Le solveur

### 6.1 Construction — plus proche voisin

Départ imposé : `PLAYER_NODE`. À chaque pas, la visite non visitée dont
`C[courant][candidat]` est minimal. Si la position du joueur est inconnue
(`GetPlayerNode()` renvoie `nil` — carte non projetable, ça arrive en
instance), partir de la visite dont la somme des coûts sortants est la plus
faible, et **le dire** dans l'interface.

### 6.2 Amélioration — Or-opt d'abord, 2-opt ensuite

**Or-opt** déplace un segment de 1 à 3 visites consécutives ailleurs dans la
tournée, **sans l'inverser**. Il préserve le sens de parcours, donc son delta de
coût est exact sur une matrice asymétrique et se calcule en O(1). C'est
l'opérateur principal.

**2-opt** inverse un segment. Sur une matrice asymétrique, **le delta à deux
arêtes est faux** : toutes les arêtes intérieures au segment changent de sens.
Il faut donc réévaluer le coût du segment inversé en entier — O(n) par
mouvement, O(n³) par passe. Avec n ≤ 40 c'est ~64 000 additions, rien du tout.
Écrire ce commentaire dans le code : quelqu'un « optimisera » ce recalcul un
jour, et la tournée deviendra silencieusement moins bonne, sans erreur, sans
test rouge.

Arrêt : aucune amélioration sur une passe complète, ou budget de calcul épuisé.

### 6.3 Cadence

Coroutine avec budget de frame, comme `Modules/Mapping.lua` :

```lua
local FRAME_BUDGET = 0.004   -- ms via debugprofilestop()
```

**Différence importante avec Mapping :** le solveur ne fait aucun appel
asynchrone au client. Il n'a donc **pas** besoin du motif `WAIT_FRAME` — un
`coroutine.yield()` nu suffit, le pilote peut enchaîner plusieurs reprises dans
la même frame et c'est même souhaitable. `WAIT_FRAME` existe uniquement pour
attendre que le client charge quelque chose, et son absence a coûté une passe
de butin quasi muette (cf. l'en-tête de `Mapping.lua`, version 8). Ne pas
copier-coller ce pilote sans savoir dans lequel des deux cas on se trouve.

Émettre `OF_ROUTE_PROGRESS` à chaque yield.

### 6.4 Téléports à cooldown

`TravelGraph:EdgesFrom(fromID, universe, options)` accepte déjà
`options.spent[edge.key]` : une arête consommée n'est plus proposée. Mais
`BuildMatrix` calcule la matrice **sans** cette contrainte — chaque paire est
optimisée isolément, donc deux tronçons peuvent « utiliser » la même pierre de
foyer.

Passe de retarification, après le TSP :

1. parcourir la tournée dans l'ordre, tenir un ensemble `spent` ;
2. pour chaque tronçon, reprendre `paths[from][to]` et regarder les arêtes de
   `kind == TELEPORT` ;
3. une arête déjà dans `spent` → recalculer ce tronçon seul avec
   `ShortestPaths(from, universe, { spent = spent })` et remplacer le chemin ET
   le coût ;
4. sinon, ajouter la clé à `spent`.

L'en-tête de `TravelGraph.lua` documente déjà cet écart assumé avec la
spécification (§6.3 propose une affectation gloutonne réoptimisée jusqu'à
stabilité). Garder l'approche simple, garder le commentaire.

Une arête dont `Teleports:IsReady(edge)` est faux au moment du calcul est
retirée de l'univers dès le départ : proposer un téléport en recharge est pire
que de proposer un vol.

### 6.5 Cap d'instances

10 entrées par heure, 30 par jour, et ça compte **les instances, pas les
boss**. `Lockouts:GetInstanceCounts()` donne l'état courant.

Simuler l'avancement du compteur le long de la tournée : quand la visite *k*
franchirait le cap horaire, insérer une étape

```lua
{ kind = "pause", reason = "instance_cap", waitFor = <secondes>, until_ = <ts> }
```

et reprendre. Une tournée de 15 donjons est physiquement impossible d'un trait :
mieux vaut l'afficher avec ses pauses que produire un plan qui ne tient pas.
Piloté par `db.profile.routing.respectInstanceCap`, déjà déclaré à `true`.

### 6.6 Budget temps

`db.profile.routing.budgetMinutes` (0 = pas de budget) est déjà déclaré. Quand
il est posé, garder le sous-ensemble de visites qui maximise l'EV cumulée sous
la contrainte de durée totale.

Glouton par efficacité décroissante, puis **une** passe de remplacement : tenter
d'échanger la dernière visite retenue contre une visite écartée moins chère et
plus rentable. Pas de programmation dynamique — la matrice de coûts dépend de
l'ordre, donc le « poids » d'une visite n'est pas fixe et le sac à dos exact de
la spécification résout un problème qu'on n'a pas.

Le résultat n'est pas optimal, et l'interface ne doit pas prétendre le
contraire. « Ce qui tient dans 45 minutes », pas « la meilleure tournée de 45
minutes ».

---

## 7. Score d'efficacité, sans inventer de chiffre

```
EV(visite)         = Σ poids(monture)
efficacité(visite) = EV / (coût_trajet + runTime)
```

`poids(monture) = dropRate` quand il est connu. **Il ne l'est presque jamais** :
`Data/Mounts.lua` est vide et le restera tant que personne n'aura curé les taux.
Donc :

* `dropRate` inconnu → `poids = Data.DEFAULT_WEIGHT` (constante déclarée, pas un
  nombre en dur au milieu du solveur), et la visite porte
  `evIsEstimated = true` ;
* dès qu'une visite d'une tournée est estimée, la tournée entière porte
  `evIsEstimated = true` et l'interface affiche l'avertissement ;
* on n'affiche **jamais** un pourcentage de chance dérivé d'un poids par défaut.
  Le classement est indicatif ; le chiffre serait un mensonge.

C'est la règle « ne jamais inventer de donnée » appliquée au routeur. Le tri par
efficacité reste utile même avec des poids uniformes : il devient « le plus de
montures par minute », ce qui est déjà une bonne réponse.

---

## 8. Contrat de sortie

```lua
route = {
    computedAt = 1754000000,
    charKey    = "Nom-Royaume",
    totalTime  = 3480,          -- secondes, trajets + visites + pauses
    evIsEstimated = true,
    stats = { targets = 12, visits = 7, noNode = 3, unreachable = 1 },
    steps = {
        { kind = "travel", from = "player", to = "ej:187",
          legs = { { edgeKind = "teleport", spellID = 373274,
                     label = "Téléport : Ulduar", cost = 18 } },
          cost = 18 },
        { kind = "visit", nodeID = "ej:187", name = "Ulduar",
          targets = { { mountID = 264, name = "…", dropRate = nil } },
          runTime = 420, runTimeSource = "default", cost = 420 },
        { kind = "pause", reason = "instance_cap", waitFor = 1260 },
    },
    deferred = { … },           -- cibles verrouillées, pour information
    unreachable = { … },        -- nœuds sans trajet connu, avec la raison
}
```

Une étape `travel` porte **toutes** ses jambes : c'est ce qui permet d'afficher
« Téléport Ulduar, puis 40 s de vol » au lieu d'un coût opaque. C'est aussi ce
que `Route:BuildSteps` produit déjà pour la cible unique — garder la même forme
d'étape (`kind`, `nodeID`, `node`, `name`, `spellName`, `spellID`, `itemID`,
`cost`) pour que `ArrowHUD` et `RoutePage` n'aient rien à réapprendre.

### Persistance

`Route.plan` vit aujourd'hui **en mémoire seule** : un `/reload` en plein farm
perd le plan. Acceptable pour une cible unique qu'on recalcule en une frame ; ça
ne l'est plus pour une tournée de 7 visites calculée en 200 ms et entamée depuis
20 minutes. Persister dans `db.char.route` — la tournée appartient au
personnage — avec `stale = true` dès qu'un message d'invalidation passe.

Schéma de base : `CURRENT_SCHEMA` vaut **3** (migrations `1` et `2` sont
publiées, ne jamais réutiliser leurs numéros). Ajouter `runTimings = {}` à
`GLOBAL_DEFAULTS`, `route = nil` à `CHAR_DEFAULTS`, puis **passer à 4** avec
`migrations[3]`. `ApplyDefaults` ne touche pas aux valeurs existantes : sans
migration, les bases déjà écrites n'auront pas les nouveaux champs.

Profiter du passage pour combler un trou existant : **`entryHistory` est écrit
par `Lockouts:RecordInstanceEntry` et lu par `GetInstanceCounts`, mais il n'est
pas déclaré dans `CHAR_DEFAULTS`**. Les deux se protègent par un `or {}`, donc
rien ne casse aujourd'hui — mais le compteur de cap devient une entrée de
premier ordre au §6.5, et un champ non déclaré est un champ qu'une migration
future oubliera.

---

## 9. Interface

`UI/RoutePage.lua` affiche aujourd'hui **une** mission : instance, boss, zone,
carte, étapes, bouton Start. La tournée s'y ajoute sans casser ça — la mission
courante reste la première visite.

* **Rien ne se dessine hors de `UI/Theme.lua`.** Couleurs, cartes, barres,
  pastilles viennent de là. Si un widget manque (chronologie verticale, jauge de
  budget), on l'ajoute *dans Theme*.
* **Les agrégats se calculent dans un module.** `Router` produit les nombres,
  `RoutePage` les pose. Sinon rien n'est testable hors du jeu.
* En-tête : durée totale, nombre de montures visées, bouton « Calculer », état
  « périmée » quand une invalidation est passée.
* Corps : la liste d'étapes en chronologie. Trajets discrets, visites mises en
  avant avec leurs montures et le compteur de tentatives (`ns.Attempts`).
* Pied : budget, vitesse de vol, case « respecter le cap d'instances ».
* Trois blocs honnêtes, repliés par défaut : cibles sans nœud, nœuds
  inatteignables, cibles verrouillées jusqu'au reset. Ce sont eux qui rendent
  l'addon crédible — masquer les trous les fait passer pour des bugs.

Commandes : `/of route` calcule la tournée et ouvre l'onglet ; `/of route 45`
pose un budget de 45 minutes pour ce calcul.

---

## 10. Ce que la phase 3 ne fait pas

Contraintes Blizzard, pas choix de conception :

* **aucun déplacement automatique, aucun clic simulé.** Le maximum autorisé est
  ce que `Route:PointAtCurrentStep` fait déjà : poser un point de passage ;
* **le bouton de téléport est une frame sécurisée** — c'est la phase 4. Une
  étape affiche le nom du sort, elle ne le lance pas ;
* pas de modification d'attribut sécurisé en combat : toute action de ce type se
  met en file et se vide sur `PLAYER_REGEN_ENABLED` ;
* aucune requête réseau.

---

## 11. Tests

`Tests/wow_stub.lua` a déjà tout ce qu'il faut, et c'est important de le savoir
avant d'aller l'étendre :

* `stub.maps[uiMapID] = { continentID, originX, originY, spanX, spanY }` et
  `GetWorldPosFromMapPos` projette dessus — **deux continents distincts se
  simulent en posant deux `continentID` différents** ;
* `stub.currentInstance = { name, instanceType, difficultyID, instanceID }`
  alimente `IsInInstance` et `GetInstanceInfo`, donc l'entrée en instance dont
  `RunTimes` a besoin ;
* `stub.spells`, `stub.toys`, `stub.cooldowns` pour les arêtes ;
  `stub.savedInstances` pour les verrous ; `stub.Advance(seconds)` pour le cap
  horaire.

**Rien à ajouter au stub pour les cas ci-dessous.** Si une fixture semble
manquer, relire le stub avant de l'étendre.

Cas à couvrir, du plus important au moins :

1. **`BuildMatrix` renvoie une matrice cohérente** — jamais exécuté à ce jour,
   c'est le test à écrire en premier ;
2. **deux montures du même raid font une seule visite** — le regroupement est le
   gain principal, il ne doit jamais régresser ;
3. **une monture verrouillée n'entre pas dans la tournée** — testée par un
   `savedInstances` non vide ;
4. **deux nœuds sur des continents différents sans téléport sont
   inatteignables** — et sortent dans `unreachable`, ils ne disparaissent pas ;
5. **le même téléport n'est pas facturé deux fois** : tournée à trois visites,
   une seule pierre de foyer, vérifier que le second usage coûte le prix du vol ;
6. **matrice asymétrique** : un nœud avec téléport, un sans, vérifier que
   `C[A][B] ≠ C[B][A]` et qu'un Or-opt n'améliore pas une tournée en la cassant ;
7. **le cap d'instances insère une pause** après 10 entrées dans l'heure ;
8. **le budget tronque** : 3 visites, budget qui n'en autorise que 2, vérifier
   que c'est la moins efficace qui saute ;
9. **une cible sans nœud est comptée, pas perdue** (`stats.noNode`) ;
10. **le solveur rend la main** : la coroutine yield au moins une fois sur 40
    visites, et `stub.RunFrames` la mène à terme.

Et la boucle réelle reste le jeu : lien symbolique, BugSack + BugGrabber,
`/reload`, `/of route`.

---

## 12. Ordre de travail conseillé

1. **Un test sur `BuildMatrix`**, avant toute chose. C'est la seule fonction de
   `TravelGraph` que personne n'a jamais exécutée, et tout le reste s'empile
   dessus ;
2. `RunTimes` — petit, isolé, testable seul ;
3. `Targets` — pure logique, aucun rendu, entièrement couvrable par le harnais,
   et bâti sur `Route:GetMissionFor` qui est déjà testé ;
4. `Router` sans post-passes : NN seulement, sortie texte dans `/of route` ;
5. Or-opt, puis 2-opt ;
6. retarification des téléports, cap d'instances, budget ;
7. `RoutePage` en tournée, et `Route` qui consomme `Router` au lieu de
   `PickAuto`.

Ne pas ouvrir la phase 4 avant que `/of route` donne un ordre défendable sur un
vrai personnage, sur au moins deux continents.

---

## 13. Critères d'acceptation

* `./scripts/check.sh` vert, les douze tests `Route — …` existants toujours
  verts, ceux du §11 en plus ;
* `/of route` sur un personnage réel produit une tournée dont chaque étape est
  vérifiable à la main : le téléport existe dans le grimoire, l'instance n'est
  pas déjà verrouillée, l'ordre n'oblige pas à traverser deux fois le même
  continent ;
* les trois blocs d'honnêteté (sans nœud, inatteignable, verrouillé) sont
  remplis et non vides sur un compte normal — s'ils sont vides, c'est qu'ils
  mentent ;
* aucun freeze perceptible sur 40 visites ;
* aucun taux de drop affiché qui ne vienne pas d'une donnée réelle.
