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
| `/of scan` | forcer un rescan : collection, verrous et cartographie |
| `/of chars` | lister les personnages connus et leurs verrous |
| `/of deepscan` | passe approfondie : butin boss par boss (lent, facultatif) |
| `/of debug` | activer les traces |
| `/of reset` | effacer la base sauvegardée (confirmation requise) |

### La cartographie des montures

L'addon connaît les montures qui te manquent dès l'installation. Savoir à
quelle extension elles appartiennent et dans quelle instance elles tombent
demande une passe supplémentaire : c'est la **cartographie**.

**Tu n'as rien à lancer.** Elle part toute seule quelques secondes après la
première connexion, puis **elle est gardée sur le disque** (SavedVariables).
Elle ne se refait que dans deux cas : le build du client a changé (un patch), ou
le client expose plus de montures qu'au dernier passage. Le bouton
« Rescanner » du tableau de bord la force à la main.

Elle se fait en deux temps :

1. **l'index des instances** — les paliers du Journal des rencontres donnent la
   liste des instances et leur extension ;
2. **le texte de source** — chaque monture expose déjà
   `Butin : Le roi-liche|nCitadelle de la Couronne de glace`. On le découpe, et
   on rapproche le lieu de l'index.

Une troisième passe, **`/of deepscan`** (bouton « Scan approfondi »), parcourt
le butin boss par boss pour affiner les cas que le texte de source décrit mal.
Elle est lente et facultative : la version 0.1.0 en dépendait entièrement, et
c'est ce qui laissait l'addon muet quand l'API de butin ne répondait pas.

Le résultat brut part aussi dans `OnlyFarmScanDB`, qui alimentera le générateur
de données de la phase 2.

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
