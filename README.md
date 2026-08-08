# OnlyFarm

Addon World of Warcraft (Retail) qui répond à une question : **qu'est-ce que je
fais cette semaine pour choper des montures, et dans quel ordre ?**

État : **phase 1 (socle)**. Diff de collection, verrous et disponibilité
multi-personnage fonctionnent. Les routes arrivent en phase 3.

## Ce que ça fait aujourd'hui

* Liste des montures qui te manquent **et que ce personnage peut obtenir** —
  les montures d'une autre faction ou d'une autre classe sont écartées, pas
  comptées comme « manquantes ».
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

### À faire une fois : `/of ejscan`

L'addon connaît les montures qui te manquent dès l'installation, mais pas
encore quel boss les lâche. `/of ejscan` parcourt le Journal des rencontres et
construit cette correspondance depuis **ton** client, donc pour le patch
courant. Quelques secondes, à relancer après chaque patch majeur.

C'est aussi ce scan qui alimentera le générateur de données de la phase 2 : il
écrit son résultat brut dans `OnlyFarmScanDB` (SavedVariables).

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
