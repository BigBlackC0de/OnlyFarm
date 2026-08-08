#!/usr/bin/env bash
# Vérification locale d'OptiFarm : syntaxe Lua 5.1 (la version du client WoW)
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
done < <(grep -E '\.lua$' OptiFarm.toc || true)
[ "$missing" -eq 0 ] && echo "  ok"

echo
echo "== Tests =="
lua5.1 Tests/run.lua

exit $(( fail || missing ))
