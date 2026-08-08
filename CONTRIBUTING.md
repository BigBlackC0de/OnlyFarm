# OnlyFarm — consignes de développement

Addon World of Warcraft Retail (Lua 5.1, API 12.x). Planificateur de farm de
montures : diff de collection, état des verrous, puis routes.

La spécification fonctionnelle complète est dans `docs/SPEC.md`. Ce fichier-ci
ne la répète pas : il dit comment travailler sur ce dépôt.

---

## Avant d'écrire du code

**Vérifier chaque appel d'API contre le dump officiel de l'interface**, pas
contre la mémoire. Blizzard renomme et migre vers les namespaces `C_` à chaque
extension.

Source de vérité : <https://github.com/Gethe/wow-ui-source>

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/Gethe/wow-ui-source /tmp/wow-ui
cd /tmp/wow-ui
git sparse-checkout set Interface/AddOns/Blizzard_APIDocumentationGenerated
```

* Les signatures des API `C_*` sont dans `Blizzard_APIDocumentationGenerated/`.
* Les **globales historiques** (`GetSavedInstanceInfo`, `EJ_SelectInstance`,
  `IsInInstance`…) n'y figurent pas : les vérifier dans le code des addons
  Blizzard (`git sparse-checkout add Interface/AddOns/Blizzard_RaidFrame` etc.).
* Une fonction absente de la doc n'est pas forcément absente du client — mais
  elle mérite un `type(f) == "function"` et un `pcall`.

Les divergences déjà trouvées entre la spécification et le client réel sont
consignées dans **`docs/API-NOTES.md`**. Le lire avant de toucher à un module,
et le mettre à jour à chaque nouvelle trouvaille.

## Vérifier son travail

```bash
./scripts/check.sh
```

Contrôle la syntaxe avec `luac5.1 -p` (Lua 5.1, exactement la version du
client), vérifie que tout fichier déclaré dans le `.toc` existe, et lance la
suite de tests headless.

`Tests/wow_stub.lua` simule assez de client pour exécuter la logique pure hors
du jeu : montures, verrous, entrées d'instance, horloges de reset, timers,
frames et bus d'événements. **Tout nouveau module de logique doit être
testable là.** Ce que le harnais n'attrape pas : le rendu, les templates XML,
les frames sécurisées, et le comportement réel des API.

### La boucle de test réelle reste le jeu

Rien ici ne remplace un chargement en jeu :

1. lien symbolique du dépôt vers `_retail_/Interface/AddOns/OnlyFarm` ;
2. installer **BugSack + BugGrabber**, sans quoi les erreurs sont invisibles ;
3. `/reload`, puis `/of` ;
4. recoller les erreurs de BugSack ici.

Un module « écrit et syntaxiquement valide » n'est pas un module qui marche.

## Conventions

* **Langue** : commentaires et messages de commit en français, comme la
  spécification. Les chaînes affichées passent par `ns.L` (`Core/Locale.lua`),
  base enUS + surcharge frFR.
* **Indentation** : tabulations, comme le code de Blizzard.
* **Un module = un fichier** dans `Modules/`, déclaré par
  `ns:NewModule(nom, priorité)`. Priorité croissante = initialisé plus tôt
  (Database 10, Collection 20, Lockouts 30, Nodes 32, Teleports 33,
  TravelGraph 34, Attempts 35, Eligibility 40, Stats 45, Mapping 60, UI 80,
  Dashboard 82, Preview 82, MinimapButton 85, Commands 90).
* **Rien ne se dessine hors de `UI/Theme.lua`.** Couleurs, cartes, barres et
  pastilles viennent toutes de là. Un `|cffxxxxxx` écrit en dur dans un module
  est un bug de style : la couleur d'un statut est décidée une seule fois.
* **Les agrégats se calculent dans un module, pas dans une frame.**
  `Modules/Stats.lua` produit les chiffres du tableau de bord ; `UI/Dashboard.lua`
  ne fait que les poser. C'est ce qui les rend testables hors du jeu.
* **Pas de variable globale** hors `_G.OnlyFarm`, `OnlyFarmDB`, `OnlyFarmScanDB`
  et les frames nommées.
* **Messages internes** préfixés `OF_` (`OF_COLLECTION_UPDATED`, …), via
  `self:SendMessage` / `self:RegisterMessage`.
* **Jamais d'`OnUpdate` permanent** : anti-rebond (`ns.Util.Debounce`) pour les
  rescans, coroutine à budget de frame pour les calculs longs.

## Règles du domaine à ne pas casser

Ces quatre points sont la raison d'être de l'addon. Une régression dessus est
un bug grave même si rien ne plante :

1. **L'absence de verrou vaut disponibilité.** Une instance jamais entrée cette
   semaine n'apparaît pas dans `GetSavedInstanceInfo`. Ne jamais traiter
   « absent » comme « inconnu ».
2. **Deux horloges.** Raids legacy : reset hebdomadaire. Donjons legacy : reset
   quotidien. Confondre les deux rend l'addon inutile.
3. **Montures account-wide, verrous par personnage.** Le gain de temps réel est
   là. Un raid fait sur le main reste disponible sur les alts.
4. **On n'invente jamais une donnée.** Pas d'identifiant écrit au jugé, pas de
   taux de drop présenté comme exact. Un statut inconnu s'affiche « incertain »
   avec sa raison.

## Ce que l'addon ne fera jamais

Contraintes Blizzard, pas choix de conception — ne pas les promettre dans
l'interface :

* aucune automatisation de déplacement ou de clic ; `SetUserWaypoint` +
  navigation manuelle est le maximum ;
* pas de modification d'attribut de frame sécurisée en combat (file d'attente,
  vidée sur `PLAYER_REGEN_ENABLED`) ;
* aucune requête réseau : toute donnée externe est compilée dans le `.lua` ;
* pas de lecture des verrous des autres personnages sans s'y être connecté.

## Décisions prises (et pourquoi)

**Pas d'Ace3 pour l'instant.** `Core/Init.lua` et `Core/Database.lua` couvrent
ce dont la phase 1 a besoin (bus d'événements, modules, profils, migrations) en
~350 lignes, et l'addon se charge sans dépendance à télécharger. La surface
imite volontairement AceAddon/AceEvent/AceDB pour que la bascule reste
mécanique le jour où AceConfig et AceGUI deviennent utiles (phase 3+).

**`Data/Sources.lua` est vide, et c'est voulu.** Un `mountID` ou un `instanceID`
écrit de mémoire produit un addon qui ment sans le dire. La table sera générée
en phase 2 à partir du dump de la cartographie. En attendant, la liste des
montures manquantes vient entièrement du client, donc elle est exacte.

**La cartographie a deux sources d'extension, et c'est voulu.** Le parcours par
paliers du Journal (`EJ_GetNumTiers` / `EJ_SelectTier`) s'est révélé muet en
jeu : selon l'état du client, `EJ_GetNumTiers` renvoie 0 tant que la fenêtre du
Journal n'a jamais été ouverte, et l'index sort vide sans la moindre erreur.
`GetLFGDungeonInfo` est une globale toujours présente qui porte directement le
niveau d'extension (`_G["EXPANSION_NAME"..n]` pour le libellé). Les deux sont
construits et fusionnés ; le Journal gagne quand il répond, parce qu'il apporte
le `journalInstanceID`. Ne jamais revenir à une source unique ici.

**La cartographie ne repose PAS sur l'API de butin.** La version 0.1.0 en
dépendait entièrement (`EJ_SelectEncounter` + `GetLootInfoByIndex`) et remontait
zéro monture en jeu : le butin n'est pas prêt à la frame suivante, il dépend de
la difficulté sélectionnée, et une liste vide est indiscernable d'une fin de
liste. `Modules/Mapping.lua` part maintenant du texte de source déjà exposé par
`C_MountJournal.GetMountInfoExtraByID`, rapproché d'un index des instances
construit sans toucher au butin. La passe de butin subsiste en `/of deepscan`,
hors du chemin critique.

**Le scan doit précéder le pipeline Python.** `Data/Mounts.lua` ne peut pas être
produit hors du jeu : il faut d'abord une cartographie en jeu sur un client à
jour, puis `Build/generate_data.py` lit `OnlyFarmScanDB` dans les
SavedVariables. Ordre non négociable.

## État par phase

| Phase | Contenu | État |
|---|---|---|
| 1 — Socle | collection, verrous, éligibilité, tableau de bord, tentatives | **fait** |
| 2 — Données | `Build/generate_data.py`, taux de drop, coordonnées | cartographie en jeu prête et persistée, pipeline à écrire |
| 3 — Route auto | NodeDB, TravelDB, Dijkstra, TSP | à faire |
| 4 — En jeu | HUD, auto-avance, waypoints, bouton de téléport | à faire |
| 5 — Routes maison | éditeur, épinglage, import/export | à faire |
| 6 — Élargissement | rares, world bosses, réputations, métiers, PvP | à faire |

Ne pas ouvrir une phase avant que la précédente tourne en jeu.
