# Media

Textures de l'addon. **Ce dossier attend le logo OptiFarm.**

## Contrainte : WoW ne lit pas les PNG

Le client n'accepte que `.tga` et `.blp` pour les textures d'addon. Un `.png`
posé ici ne s'affichera pas — c'est l'erreur classique.

## Fichiers attendus

| Fichier | Dimensions | Usage |
|---|---|---|
| `logo.tga` | 128 × 128 | portrait de la fenêtre principale, icône du `.toc` |
| `minimap.tga` | 64 × 64 | bouton minimap (phase 4, LibDBIcon) |

## Export

Depuis le PNG du logo, avec ImageMagick :

```bash
magick logo.png -resize 128x128 -background none -gravity center -extent 128x128 \
       -define tga:image-origin=TopLeft logo.tga
magick logo.png -resize 64x64 -background none -gravity center -extent 64x64 \
       -define tga:image-origin=TopLeft minimap.tga
```

Points de vigilance :

* **dimensions en puissance de deux** (32, 64, 128, 256…), sinon la texture est
  ignorée ou déformée ;
* **32 bits avec canal alpha** pour garder la transparence autour du logo ;
* le logo étant plus large que haut, le carré 128 × 128 laissera des marges —
  d'où le `-extent` centré plutôt qu'un étirement.

## Une fois les fichiers en place

Décommenter dans `OptiFarm.toc` :

```
## IconTexture: Interface\AddOns\OptiFarm\Media\logo
```

(sans extension), et dans `UI/MainFrame.lua`, remplacer l'icône Blizzard par
`Interface\\AddOns\\OptiFarm\\Media\\logo` dans l'appel à `SetPortraitToAsset`.

Tant que les fichiers sont absents, l'addon utilise une icône du jeu : un
chemin de texture invalide s'affiche en carré vert, ce qui est pire que pas de
logo.
