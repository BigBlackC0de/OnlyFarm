# Media

Textures d'OnlyFarm.

| Fichier | Rôle |
|---|---|
| `source/` | logo source haute résolution — **le fichier de référence** |
| `logo.tga` | 128 × 128 — portrait de la fenêtre et icône du `.toc` |
| `minimap.tga` | 64 × 64 — bouton minimap (phase 4) |
| `logo.png` | bandeau du README, généré depuis la source |

> ⚠️ Les `.tga` actuellement présents sont un **bouche-trou** : ils viennent
> d'un dessin provisoire, pas du vrai logo. Ils évitent seulement le carré vert
> en jeu. Ils sont écrasés dès le premier passage du script ci-dessous.

## Mettre le vrai logo

```bash
cp ~/mon-logo.png Media/source/onlyfarm-logo.png
./scripts/make-textures.sh Media/source/onlyfarm-logo.png
```

Le script détoure le fond, isole le symbole, et écrit les deux `.tga` plus le
bandeau du README. Les chemins référencés par `OnlyFarm.toc` et
`Core/Init.lua` ne changent jamais : il n'y a rien d'autre à modifier.

### Si le rendu 64 px ne va pas

Regarde `Media/preview-minimap.png`, que le script produit exprès : c'est
l'icône minimap agrandie, donc ce que tu verras vraiment en jeu. Si le symbole
est trop petit ou mal centré, donne un recadrage explicite en second argument :

```bash
./scripts/make-textures.sh Media/source/onlyfarm-logo.png 620x560+390+40
```

Le format est `LARGEURxHAUTEUR+X+Y`, en pixels de l'image source. Par défaut le
script garde les 68 % supérieurs, ce qui coupe le wordmark — voulu : à 64
pixels un texte est illisible, seul le symbole doit rester.

## Les trois pièges du format

1. **WoW ne lit pas les PNG.** Seulement `.tga` et `.blp`. Un `.png` posé ici
   ne s'affichera pas.
2. **Un chemin de texture invalide ne lève pas d'erreur Lua** : ça s'affiche en
   carré vert. C'est à vérifier à l'œil, pas en test.
3. **Puissances de deux, 32 bits, non compressé.** Le script s'en charge
   (`-type TrueColorAlpha -compress none`), mais si tu convertis à la main :
   des dimensions hors 32/64/128/256 sont ignorées ou déformées, un TGA 24 bits
   perd la transparence, et la compression RLE de certains encodeurs passe mal.

## Détourage du fond blanc

Le script part des quatre coins par remplissage de proche en proche
(`-floodfill`), et surtout **pas** d'un `-transparent white` global : celui-ci
percerait aussi les blancs internes du dessin — les reflets du dragon, par
exemple, deviendraient des trous.

Si ton logo a déjà un fond transparent, l'étape ne fait rien de nuisible.
