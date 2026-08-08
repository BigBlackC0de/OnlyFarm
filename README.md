<p align="center">
  <img src="Media/logo.png" alt="OnlyFarm" width="640">
</p>

# OnlyFarm

Addon World of Warcraft (Retail) qui répond à une question : **qu'est-ce que je
fais cette semaine pour choper des montures, et dans quel ordre ?**

État : **phase 1 (socle)**. Diff de collection, verrous et disponibilité
multi-personnage fonctionnent. Les routes arrivent en phase 3.

## Ce que ça fait aujourd'hui

* **Tableau de bord** : compteurs, progression par extension (les moins
  avancées en tête), répartition de ce qui est ouvert / verrouillé / inconnu,
  cibles à lancer maintenant, et la liste des raids déjà faits cette semaine
  avec leur temps avant reset.
* Liste des montures qui te manquent **et que ce personnage peut obtenir** —
  les montures d'une autre faction ou d'une autre classe sont écartées, pas
  comptées comme « manquantes ».
* **Compteur de tentatives** par monture : tuer un boss incrémente les montures
  qu'il peut lâcher. Maj+clic sur une ligne ajoute une tentative à la main,
  Ctrl+clic en retire une.
* Pour chaque monture, sa source telle que le jeu la décrit, et son statut :
  disponible, verrouillée avec le temps avant reset, ou honnêtement
  « incertain » quand l'addon ne sait pas encore.
* Vue multi-personnage en infobulle : sur quels persos la cible est encore
  ouverte cette semaine. Un perso pas connecté depuis plus de 7 jours est
  marqué incertain plutôt que présenté comme fiable.
* Suivi des entrées d'instance, avec le compteur du cap 10/heure — 30/jour.

## Installation

Cloner (ou copier) le dépôt dans le dossier des addons, sous le nom `OnlyFarm` :

```
World of Warcraft/_retail_/Interface/AddOns/OnlyFarm/
```

Le nom du dossier doit correspondre à `OnlyFarm.toc`, sinon le client ignore
l'addon.

## Commandes

| Commande | Effet |
|---|---|
| `/of` | ouvrir la fenêtre |
| `/of scan` | forcer un rescan collection + verrous |
| `/of chars` | lister les personnages connus et leurs verrous |
| `/of ejscan` | moissonner les sources de montures dans le Journal des rencontres |
| `/of debug` | activer les traces |
| `/of reset` | effacer la base sauvegardée (confirmation requise) |

### Le scan du Journal des rencontres

L'addon connaît les montures qui te manquent dès l'installation, mais pas
encore quel boss les lâche, ni à quelle extension elles appartiennent, ni où se
trouve l'entrée de l'instance. Ces trois choses viennent du Journal des
rencontres.

**Tu n'as rien à lancer** : le scan part tout seul une dizaine de secondes
après la première connexion, et se relance de lui-même après chaque patch
(l'addon compare le build du client à celui du dernier scan). Il tourne en
coroutine avec un budget de 6 ms par frame — pas de gel. `/of ejscan` reste là
pour le forcer.

Le scan attend si tu es en combat ou si le Journal des rencontres est ouvert :
il déplace la sélection de cette fenêtre, et le faire sous ton nez passerait
pour un bug.

Il écrit aussi son résultat brut dans `OnlyFarmScanDB` (SavedVariables), qui
alimente le générateur de données de la phase 2.

## Développement

```bash
./scripts/check.sh     # syntaxe Lua 5.1 + tests headless
```

* [`CONTRIBUTING.md`](CONTRIBUTING.md) — conventions, règles du domaine, décisions prises.
* [`docs/SPEC.md`](docs/SPEC.md) — spécification fonctionnelle complète.
* [`docs/API-NOTES.md`](docs/API-NOTES.md) — signatures d'API vérifiées contre
  le client 12.0.7, et les endroits où la spécification est fausse.

Les tests tournent hors du jeu grâce à un client simulé
(`Tests/wow_stub.lua`) : ils couvrent la logique, pas le rendu. Pour l'interface
il n'y a pas de raccourci — charger l'addon en jeu avec **BugSack + BugGrabber**
et lire les erreurs.
