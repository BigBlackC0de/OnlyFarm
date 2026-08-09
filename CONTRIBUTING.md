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

### Recette du tableau de bord

Le harnais ne charge pas `UI/` : ces points ne se vérifient qu'en jeu, et ils se
vérifient à chaque fois qu'on touche au tableau de bord.

- [ ] **Sans aucun scan** (base neuve, ou `/of reset` puis `/reload`) : le graphe
      de répartition est rempli dès l'ouverture. C'est le point le plus
      important : aucun de ses deux axes ne dépend de la cartographie. S'il est
      vide, c'est une régression, pas une attente.
- [ ] **Bascule d'axe** : « Par source » ↔ « Par type ». Le bouton actif
      se voit, le graphe change, et le choix survit à un `/reload`.
- [ ] **Somme par source** = nombre de montures obtenables (tuile « possédées » +
      tuile « manquantes »). Les montures d'une autre faction ou classe ne
      doivent apparaître dans aucune barre.
- [ ] **Somme par type** = la même. Une barre « Autre » non vide n'est pas
      un bug : c'est un `mountTypeID` que `Data/MountTypes.lua` ne classe pas
      encore. Relever la valeur — infobulle de la monture, ou `/of debug` — et
      compléter la table.
- [ ] **Échelle des barres** : la catégorie la plus fournie occupe toute la
      largeur, les autres sont proportionnelles. Une catégorie complétée est
      verte, pleine.
- [ ] **Redimensionnement** : rétrécir la fenêtre jusqu'à la hauteur minimale.
      Aucune barre ne doit déborder de la carte ; les catégories retirées sont
      comptées en pied (« +N autres »).
- [ ] **Acquisition** : apprendre une monture (ou `/of scan`) met à jour la barre
      de sa catégorie sans réordonner les lignes.
- [ ] **Échelle de couleur** : elle suit les qualités d'objet du jeu, et les
      bornes sont exactes — gris sous 30 %, vert de 30 à 50, violet de 50 à 70,
      orange de 70 à 99, doré à 100. Une catégorie à 29 % ne doit pas être verte.
- [ ] **Bouton Rescanner** (pied du graphe) : lance la cartographie, le bouton se
      coupe pendant, le libellé affiche l'avancement, puis le résumé.
- [ ] **Tuile « obtenues »** : à 0 sur une base neuve, même avec 400 montures
      déjà possédées — elle compte ce qui arrive APRÈS l'installation. Elle passe
      à 1 à la première monture apprise, et le détail dit depuis quand.
- [ ] **Tuile « obtenues », changement de personnage** : le chiffre ne bouge pas
      d'un perso à l'autre, y compris entre factions. Le repère porte sur le
      compte, pas sur le personnage.
- [ ] **Journal lent** : sur un `/reload` en zone chargée, la carte affiche
      « Journal des montures pas encore peuplé » au lieu de rester vide.

### Recette de l'onglet Collection

- [ ] **Le menu « Source » liste EXACTEMENT les catégories du graphe du tableau
      de bord**, dans le même ordre et avec les mêmes noms. Une catégorie qui
      manque d'un côté est le symptôme du bug corrigé en schéma 3 : un filtre
      indexé sur `kind` au lieu de `sourceType`, qui écrasait promotion, JCC,
      boutique, découverte et comptoir en une seule entrée. Les EFFECTIFS, eux,
      diffèrent légitimement : le menu compte ce qu'il va montrer (les
      manquantes), le graphe compte possédées et manquantes.
- [ ] **Aucune cellule vide**, sur aucune ligne, filtres au maximum. « Catégorie »
      et « Type » viennent du client : elles répondent même sans cartographie.
      Une cellule vide est un bug, pas une donnée manquante.
- [ ] **Tri par colonne** : un clic sur un titre trie dessus, un second inverse.
      Le titre actif est en bleu, avec la flèche dans le bon sens.
- [ ] **Tri stable** : sur une colonne où beaucoup de lignes sont à égalité
      (« Type », par exemple), l'ordre des ex æquo ne bouge pas d'un
      rafraîchissement à l'autre — le départage se fait toujours par le nom.
- [ ] **Réglage hérité** : un profil qui triait par « extension », « statut » ou
      « possédée » retombe sur le nom sans erreur au premier affichage.
- [ ] **Possédées** : cocher « Afficher les possédées » les fait apparaître, nom
      en doré. Le reste de leur ligne reste lisible.
- [ ] **Infobulle** : « Boss » n'apparaît QUE sur une monture de butin. Sur un
      vendeur, la ligne ne doit pas exister — c'était le nom du vendeur.
- [ ] **Infobulle multi-perso** : le bloc « N perso(s) disponible(s) » n'apparaît
      que si au moins un personnage a un état mesuré. Sur une monture non
      cartographiée, pas de tableau d'« incertain ».
- [ ] **Clic droit** : le menu s'ouvre, « Copier le nom » remplit la fenêtre de
      copie, « Tracer la route » basculent sur l'onglet Route avec la bonne
      monture. L'item est grisé — et explique pourquoi — si la monture n'a pas
      d'entrée cartographiée.
- [ ] **Bouton exclure** (la croix en fin de ligne) : exclut, et devient un `+`
      qui réintègre. Il ne doit pas déclencher l'aperçu du clic gauche.

### Recette de l'onglet Route

- [ ] **Sans cartographie** : la page dit que le scan n'a pas tourné, elle ne
      reste pas vide.
- [ ] **Après cartographie** : une mission apparaît, raid en priorité, avec
      instance, boss, zone et coordonnées.
- [ ] **La cible est bien du BUTIN d'instance.** Ouvrir l'aperçu de la monture et
      lire son texte de source : s'il dit « Vendeur », « Métier » ou « Haut
      fait », c'est une régression de la règle n°5 du domaine — la cible ne
      devrait pas avoir d'instance du tout. C'est ce qui proposait un raid de
      Cataclysm pour une monture achetée chez les Kyrians.
- [ ] **La carte s'affiche** et l'épingle tombe au bon endroit — comparer avec la
      carte du monde du jeu, l'icône d'entrée de donjon doit être au même point.
- [ ] **Pavé de bord** : la carte n'est ni compressée ni étirée sur son bord
      droit ou bas. C'est le symptôme d'un `SetTexCoord` manquant.
- [ ] **Bouton Start** : la flèche d'OnlyFarm apparaît, déplaçable à la souris,
      et son point suit le cap quand on tourne sur soi-même. C'est le point le
      plus important : elle ne dépend d'aucun autre addon, donc elle doit venir
      dans TOUS les cas.
- [ ] **Cap juste** : se placer au sud de la cible, regarder au nord — le point
      doit être en HAUT de l'anneau. Si la flèche pointe à l'opposé ou en miroir,
      c'est une convention d'axe inversée dans Route:GetBearing ; les trois
      conventions en jeu y sont écrites en commentaire.
- [ ] **Le point de passage du jeu est posé aussi** (épingle sur la carte,
      distance dans le suivi de quêtes), même quand TomTom est là. C'est
      volontaire : si la flèche de TomTom ne vient pas, il reste un guidage.
- [ ] **Étapes** : la liste montre le chemin AVANT de cliquer Start. Avec un
      téléport dont le nom correspond à la destination, il doit apparaître comme
      première étape (« Utilise … »).
- [ ] **Avancement** : arriver près d'une étape la passe en grisé, la suivante
      passe en bleu, et la flèche change de cible. À la dernière, la flèche
      disparaît et le chat dit « Tu y es ».
- [ ] **Bouton Arrêter** : pendant un trajet, le bouton Start devient Arrêter et
      retire la flèche et le point de passage.
- [ ] **Épinglage** : après Start, la mission est marquée « épinglée par toi » et
      ne change plus. « Laisser choisir » rend la main à l'addon.
- [ ] **Monture obtenue** : la cible épinglée obtenue laisse la place à une autre
      mission au lieu de rester affichée.

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

Ces cinq points sont la raison d'être de l'addon. Une régression dessus est
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
5. **Seul un BUTIN peut être rattaché à une instance.** Le `sourceType` du
   client tranche, et il ne se trompe pas : une monture de vendeur se tient là
   où se tient son PNJ — une zone, jamais une instance verrouillée. Rapprocher
   le lieu d'une monture de vendeur, de métier ou de haut fait d'un nom
   d'instance a déjà envoyé un vendeur de Bastion (Shadowlands) vers le bastion
   du Crépuscule (Cataclysm), avec le verrou hebdomadaire qui va avec.
   Corollaire : **un fragment de nom ne désigne pas ce nom.** Un rapprochement
   partiel ne va que dans un sens — le texte de lieu contient le nom
   d'instance — et refuse l'ambiguïté au lieu de trancher au hasard.

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
construit sans toucher au butin.

**Une coroutine à budget de frame ne rend PAS la main au client.** Le pilote
enchaîne plusieurs reprises tant qu'il lui reste du budget : un
`coroutine.yield()` nu revient au pilote, pas au jeu. La passe de butin
sélectionnait donc un boss et lisait son butin dans la même frame, avant que le
client ait pu charger quoi que ce soit — d'où une récolte quasi nulle.
`coroutine.yield(WAIT_FRAME)` termine la frame pour de bon. À utiliser partout
où l'on attend une réponse asynchrone du client.

**Un seul bouton de scan, et c'est délibéré.** « Scan » et « scan approfondi »
demandaient au joueur de trancher une question technique — faut-il parcourir le
butin ? — dont il n'a pas les éléments. L'addon sait y répondre
(`Mapping:NeedsDeepPass`), donc il y répond. `/of deepscan` subsiste pour
forcer, sans figurer dans l'aide.

**Les outils de `Build/` ne concernent JAMAIS le joueur.** Un addon WoW ne peut
émettre aucune requête réseau : toute donnée extérieure est compilée en `.lua`
au build, committée, et livrée dans le dossier de l'addon comme une texture.
`fetch_blizzard.py` et son client OAuth sont l'équivalent d'un compilateur —
indispensables pour produire la release, invisibles pour qui l'installe. Toute
formulation qui laisserait croire qu'un joueur doit configurer quelque chose est
un bug de documentation : la question a réellement été posée.

**Le scan doit précéder le pipeline Python.** `Data/Mounts.lua` ne peut pas être
produit hors du jeu : il faut d'abord une cartographie en jeu sur un client à
jour, puis `Build/generate_data.py` lit `OnlyFarmScanDB` dans les
SavedVariables. Ordre non négociable.

## État par phase

| Phase | Contenu | État |
|---|---|---|
| 1 — Socle | collection, verrous, éligibilité, tableau de bord, tentatives | **fait** |
| 2 — Données | `Build/generate_data.py`, taux de drop, coordonnées | cartographie en jeu prête et persistée, pipeline à écrire |
| 3 — Route auto | NodeDB, TravelDB, Dijkstra, TSP | géographie moissonnée, onglet Route à une cible en place ; enchaînement multi-étapes à faire |
| 4 — En jeu | HUD, auto-avance, waypoints, bouton de téléport | à faire |
| 5 — Routes maison | éditeur, épinglage, import/export | à faire |
| 6 — Élargissement | rares, world bosses, réputations, métiers, PvP | à faire |

Ne pas ouvrir une phase avant que la précédente tourne en jeu.
