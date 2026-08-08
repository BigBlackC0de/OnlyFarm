#!/usr/bin/env bash
#
# Fabrique les textures du jeu à partir du logo source.
#
#   scripts/make-textures.sh Media/source/OnlyFarm-Logo.png
#   scripts/make-textures.sh Media/source/OnlyFarm-Logo.png 620x560+390+40
#
# Le second argument est un recadrage facultatif (LxH+X+Y) pour isoler le
# symbole. Sans lui, le script CHERCHE la coupure : sur un logo « symbole
# au-dessus, texte en dessous », il repère la bande horizontale vide qui sépare
# les deux et coupe là. Un pourcentage fixe se dérègle au premier logo qui ne
# tombe pas pile aux mêmes proportions — et à 64 pixels, un wordmark est de
# toute façon illisible.
#
# Prérequis : ImageMagick (paquet « imagemagick »).
set -euo pipefail

cd "$(dirname "$0")/.."

SRC=${1:-Media/source/onlyfarm-logo.png}
CROP=${2:-}

if [ ! -f "$SRC" ]; then
	echo "Source introuvable : $SRC" >&2
	echo "Dépose le logo dans Media/source/ puis relance." >&2
	exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Source : $SRC"

# 1. Détourage du fond blanc.
#    On part des quatre coins par remplissage de proche en proche, et surtout
#    PAS d'un « -transparent white » global : ça percerait aussi les blancs
#    internes du dessin (les reflets du dragon, par exemple).
SRC_W=$(identify -format '%w' "$SRC[0]")
SRC_H=$(identify -format '%h' "$SRC[0]")

convert "$SRC" -alpha set -fuzz 12% -fill none \
	-floodfill "+0+0" white \
	-floodfill "+$((SRC_W - 1))+0" white \
	-floodfill "+0+$((SRC_H - 1))" white \
	-floodfill "+$((SRC_W - 1))+$((SRC_H - 1))" white \
	"$TMP/cut.png"

# 2. Isolement du symbole.
#
#    Sans recadrage explicite, on réduit l'image à une colonne d'un pixel de
#    large (la moyenne de chaque ligne), on repère les lignes qui contiennent
#    quelque chose, et on coupe à la fin de la PREMIÈRE bande de contenu.
#    Une bande se termine quand au moins GAP lignes vides se suivent : ça
#    encaisse l'anticrénelage sans couper un symbole en deux.
GAP=12

first_band_end() {
	convert "$1" -colorspace gray -resize "1x${SRC_H}!" -depth 8 txt:- \
		| awk -F'[,:() ]+' 'NR > 1 && $4 < 253 { print $2 }' \
		| awk -v gap="$GAP" '
			NR == 1 { prev = $1; next }
			{ if ($1 > prev + gap) { print prev; found = 1; exit } prev = $1 }
			END { if (!found) print prev }'
}

if [ -n "$CROP" ]; then
	convert "$TMP/cut.png" -crop "$CROP" +repage "$TMP/mark.png"
else
	BAND_END=$(first_band_end "$SRC")
	if [ -z "$BAND_END" ] || [ "$BAND_END" -le 0 ]; then
		echo "Impossible de repérer le symbole automatiquement." >&2
		echo "Relance avec un recadrage explicite en second argument." >&2
		exit 1
	fi
	echo "Symbole détecté : lignes 0 à $BAND_END sur $SRC_H"
	# Largeur en PIXELS et pas en pourcentage : dès qu'un « % » apparaît dans
	# une géométrie, ImageMagick l'applique aux deux dimensions. « 100%x481 »
	# vaut donc 481 % de hauteur, c'est-à-dire l'image entière — le recadrage
	# passe inaperçu et le wordmark se retrouve dans l'icône 64 px.
	convert "$TMP/cut.png" -gravity North \
		-crop "${SRC_W}x$((BAND_END + 1))+0+0" +repage "$TMP/mark.png"
fi

# 3. Carré transparent, sans étirement : le symbole est centré dans le plus
#    grand côté. Les dimensions finales doivent être des puissances de deux,
#    sinon le client ignore ou déforme la texture.
convert "$TMP/mark.png" -trim +repage "$TMP/trimmed.png"
TRIM_W=$(identify -format '%w' "$TMP/trimmed.png")
TRIM_H=$(identify -format '%h' "$TMP/trimmed.png")
SIDE=$(( TRIM_W > TRIM_H ? TRIM_W : TRIM_H ))
convert "$TMP/trimmed.png" -background none -gravity center \
	-extent "${SIDE}x${SIDE}" "$TMP/square.png"

emit_tga() {
	local size=$1 out=$2
	convert "$TMP/square.png" -resize "${size}x${size}" \
		-background none -gravity center -extent "${size}x${size}" \
		-alpha on -type TrueColorAlpha -depth 8 \
		-compress none -define tga:image-origin=TopLeft "$out"
	echo "  $out ($(identify -format '%wx%h, %B octets' "$out"))"
}

echo "Textures du jeu :"
emit_tga 128 Media/logo.tga
emit_tga 64 Media/minimap.tga

# 4. Bandeau du jeu : le logo complet, texte compris, détouré, dans une texture
#    aux dimensions puissances de deux. C'est ce qui s'affiche en page de garde
#    de la fenêtre de l'addon.
convert "$TMP/cut.png" -trim +repage \
	-background none -gravity center \
	-resize "512x256" -extent "512x256" \
	-alpha on -type TrueColorAlpha -depth 8 \
	-compress none -define tga:image-origin=TopLeft Media/banner.tga
echo "Bandeau du jeu :"
echo "  Media/banner.tga ($(identify -format '%wx%h, %B octets' Media/banner.tga))"

# 5. Bandeau du README : le logo complet, texte compris, fond conservé.
convert "$SRC" -resize 1280x -strip Media/logo.png
echo "Bandeau README :"
echo "  Media/logo.png ($(identify -format '%wx%h' Media/logo.png))"

# 6. Aperçu de ce que donnera l'icône minimap, agrandi pour être jugeable.
convert Media/minimap.tga -scale 256x256 "$TMP/preview64.png"
cp "$TMP/preview64.png" Media/preview-minimap.png
echo "Aperçu 64 px agrandi :"
echo "  Media/preview-minimap.png"

echo
echo "Regarde Media/preview-minimap.png : si le symbole est trop petit ou"
echo "décentré, relance avec un recadrage explicite en second argument."
