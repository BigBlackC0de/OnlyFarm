#!/usr/bin/env bash
# Vérification locale d'OnlyFarm : syntaxe Lua 5.1 (la version du client WoW)
# puis suite de tests headless.
#
# Prérequis : lua5.1 (paquet « lua5.1 » sur Debian/Ubuntu).
set -euo pipefail

cd "$(dirname "$0")/.."

echo "== Syntaxe (luac5.1 -p) =="
fail=0
while IFS= read -r file; do
	if ! luac5.1 -p "$file"; then
		echo "  ÉCHEC : $file"
		fail=1
	fi
done < <(find Core Data Modules UI Tests -name '*.lua' | sort)
[ "$fail" -eq 0 ] && echo "  ok"

echo
echo "== Fichiers déclarés dans le .toc =="
missing=0
while IFS= read -r declared; do
	path="${declared//\\//}"
	if [ ! -f "$path" ]; then
		echo "  MANQUANT : $path"
		missing=1
	fi
done < <(grep -E '\.lua$' OnlyFarm.toc || true)
[ "$missing" -eq 0 ] && echo "  ok"

echo
echo "== Fichiers non déclarés dans le .toc =="
# Le contrôle inverse du précédent. Sans lui, un module peut exister, compiler,
# passer la revue — et n'être chargé nulle part. C'est arrivé à TravelGraph.lua,
# resté mort pendant plusieurs versions.
#
# Le .toc écrit ses chemins avec des antislashs : on les normalise avant de
# comparer, sinon le contrôle ne trouve jamais rien et rassure à tort.
orphan=0
grep -E '\.lua$' OnlyFarm.toc | tr -d '\r' | tr '\\' '/' | sort > /tmp/of-declared.txt
find Core Data Modules UI -name '*.lua' | sed 's|^\./||' | sort > /tmp/of-present.txt
while IFS= read -r file; do
	echo "  NON CHARGÉ : $file"
	orphan=1
done < <(comm -13 /tmp/of-declared.txt /tmp/of-present.txt)
rm -f /tmp/of-declared.txt /tmp/of-present.txt
[ "$orphan" -eq 0 ] && echo "  ok"

echo
echo "== Générateur de données =="
if [ -f Build/overlay/mounts.csv ]; then
	python3 Build/generate_data.py Build/overlay/mounts.csv --check
else
	echo "  pas de Build/overlay/mounts.csv, rien à valider"
fi

echo
echo "== Tests =="
lua5.1 Tests/run.lua

exit $(( fail || missing || orphan ))
