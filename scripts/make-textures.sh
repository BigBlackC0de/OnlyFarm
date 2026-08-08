#!/usr/bin/env bash
#
# Fabrique les textures du jeu à partir du logo source.
#
#   scripts/make-textures.sh Media/source/onlyfarm-logo.png
#   scripts/make-textures.sh Media/source/onlyfarm-logo.png 620x560+390+40
#
# Le second argument est un recadrage facultatif (LxH+X+Y) pour isoler le
# symbole. Sans lui, le script garde les 68 % supérieurs de l'image : sur un
# logo « symbole au-dessus, texte en dessous », ça coupe le texte, ce qui est
# exactement ce qu'on veut — à 64 pixels un wordmark est illisible.
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
if [ -n "$CROP" ]; then
	convert "$TMP/cut.png" -crop "$CROP" +repage "$TMP/mark.png"
else
	convert "$TMP/cut.png" -gravity North -crop "100%x68%+0+0" +repage "$TMP/mark.png"
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

# 4. Bandeau du README : le logo complet, texte compris, fond conservé.
convert "$SRC" -resize 1280x -strip Media/logo.png
echo "Bandeau README :"
echo "  Media/logo.png ($(identify -format '%wx%h' Media/logo.png))"

# 5. Aperçu de ce que donnera l'icône minimap, agrandi pour être jugeable.
convert Media/minimap.tga -scale 256x256 "$TMP/preview64.png"
cp "$TMP/preview64.png" Media/preview-minimap.png
echo "Aperçu 64 px agrandi :"
echo "  Media/preview-minimap.png"

echo
echo "Regarde Media/preview-minimap.png : si le symbole est trop petit ou"
echo "décentré, relance avec un recadrage explicite en second argument."
