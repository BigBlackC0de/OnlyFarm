# Media

Identité visuelle d'OnlyFarm.

| Fichier | Rôle |
|---|---|
| `mark.svg` | symbole seul — **source vectorielle**, c'est le fichier à éditer |
| `logo.svg` | logo complet (symbole + wordmark + accroche) |
| `mark.png` | rendu 512 × 512 du symbole |
| `logo.png` | rendu 1280 × 440 du logo complet, pour le README |
| `logo.tga` | 128 × 128 — portrait de la fenêtre et icône du `.toc` |
| `minimap.tga` | 64 × 64 — bouton minimap (phase 4) |

Les deux `.tga` sont déjà en place et référencés par `OnlyFarm.toc` et
`Core/Init.lua`. Rien à faire pour les utiliser.

## L'idée

Un cadenas dont l'anse est un fer à cheval, posé sur un disque radar traversé
par une route.

Le fer à cheval dit « monture », le cadenas dit « contenu verrouillé » — et ça
tombe bien, parce que **les verrous d'instance sont littéralement le sujet de
l'addon**. Le clin d'œil au nom passe par là plutôt que par un pastiche de la
charte de qui que ce soit : le dessin est original, aucune marque existante
n'est reprise. Utile si tu publies un jour sur CurseForge, où une imitation
trop littérale d'un logo connu se fait retirer.

## Contrainte : WoW ne lit pas les PNG

Le client n'accepte que `.tga` et `.blp`. Un `.png` posé ici ne s'affichera
pas — c'est l'erreur classique. Et un chemin de texture invalide ne produit pas
d'erreur Lua : ça s'affiche en **carré vert**. À vérifier à l'œil.

## Régénérer après une modification du SVG

```bash
# Rendus PNG
rsvg-convert -w 512  -h 512 Media/mark.svg -o Media/mark.png
rsvg-convert -w 1280 -h 440 -b '#071624' Media/logo.svg -o Media/logo.png

# Textures du jeu
for size in 128 64; do rsvg-convert -w $size -h $size Media/mark.svg -o /tmp/mark$size.png; done
convert /tmp/mark128.png -background none -alpha on -type TrueColorAlpha -depth 8 \
        -compress none -define tga:image-origin=TopLeft Media/logo.tga
convert /tmp/mark64.png  -background none -alpha on -type TrueColorAlpha -depth 8 \
        -compress none -define tga:image-origin=TopLeft Media/minimap.tga
```

Trois règles à ne pas casser :

* **dimensions en puissance de deux** (32, 64, 128, 256…), sinon la texture est
  ignorée ou déformée ;
* **32 bits avec canal alpha** (`-type TrueColorAlpha`), sinon plus de
  transparence autour du badge ;
* **non compressé** (`-compress none`) : le client gère mal la compression RLE
  de certains encodeurs TGA.

## Polices

Les rendus ci-dessus utilisent DejaVu Sans, qui est ce que la machine de build
avait sous la main. Une police plus ronde (Nunito, Quicksand, Baloo…) collerait
mieux au ton. Si tu en installes une, remplace `font-family` dans `logo.svg` et
régénère — ou convertis le texte en tracés pour que le fichier soit autonome.
