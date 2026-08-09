#!/usr/bin/env python3
"""Résout l'extension de CHAQUE monture à partir des tables DB2 du client.

    python3 Build/fetch_db2.py --inspect          # voir les colonnes réelles
    python3 Build/fetch_db2.py                    # produit Build/overlay/mounts.csv
    python3 Build/generate_data.py Build/overlay/mounts.csv

POURQUOI CE CHEMIN-LÀ
---------------------
Aucune API — ni le client, ni l'API web officielle — ne donne l'extension d'une
monture. C'est vérifié et documenté dans docs/API-NOTES.md. Le client expose en
revanche l'extension d'un OBJET (`C_Item.GetItemInfo` -> `expansionID`), et
c'est le même champ que `ItemSparse.ExpansionID` côté données.

Tout le problème est donc de relier une monture à son objet. Le client ne sait
le faire que dans un sens (`GetMountFromItem`), et seulement pour les objets
qu'on lui présente. Les tables DB2 publiées sur wago.tools, elles, contiennent
la chaîne complète :

    Mount.SourceSpellID
      -> ItemEffect.SpellID / ItemEffect.ID
        -> ItemXItemEffect.ItemEffectID / ItemXItemEffect.ItemID
          -> ItemSparse.ExpansionID          <- l'extension, faisant autorité

Ça couvre TOUTES les montures, y compris les vendeurs, métiers, événements et
PvP — exactement le trou que la cartographie en jeu ne peut pas combler.

CE QUE CE SCRIPT NE FAIT PAS
----------------------------
Il ne devine rien. Une monture dont la chaîne casse quelque part sort SANS
extension, et l'addon l'affichera « inconnue ». Il n'y a volontairement aucun
repli par intervalle de mountID : voir docs/API-NOTES.md pour le raisonnement.

wago.tools est un service communautaire. Le créditer dans le README.

Aucune bibliothèque tierce : librairie standard uniquement. Ce script tourne
chez le MAINTENEUR, une fois par patch ; le joueur n'installe rien.
"""

from __future__ import annotations

import argparse
import csv
import io
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO_ROOT / "Build" / "overlay" / "mounts.csv"

BASE_URL = "https://wago.tools/db2/{table}/csv"
USER_AGENT = "OnlyFarm-build/1.0 (+https://github.com/BigBlackC0de/OnlyFarm)"

# ItemSparse pèse plusieurs dizaines de mégaoctets : on la lit en flux et on ne
# retient que les objets dont on a besoin.
STREAM_TABLES = {"ItemSparse"}


def fetch(table: str, branch: str) -> io.StringIO | urllib.request.addinfourl:
    """Télécharge une table DB2 en CSV."""
    url = BASE_URL.format(table=table) + "?" + urllib.parse.urlencode({"branch": branch})
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        return urllib.request.urlopen(request, timeout=180)
    except urllib.error.HTTPError as error:
        raise SystemExit(f"{url} : HTTP {error.code}") from error
    except urllib.error.URLError as error:
        raise SystemExit(f"{url} : {error.reason}") from error


def reader_for(table: str, branch: str) -> csv.DictReader:
    response = fetch(table, branch)
    stream = io.TextIOWrapper(response, encoding="utf-8", newline="")
    return csv.DictReader(stream)


def pick_column(fieldnames: list[str], *candidates: str) -> str:
    """Trouve une colonne, insensible à la casse.

    Les noms de colonnes DB2 changent d'un build à l'autre — `SourceSpellID`
    devient `SourceSpellId`, un suffixe apparaît. Échouer bruyamment ici vaut
    infiniment mieux que produire une table vide en silence : c'est le mode
    d'échec qui a coûté le plus cher sur ce projet.
    """
    lowered = {name.lower(): name for name in fieldnames if name}
    for candidate in candidates:
        found = lowered.get(candidate.lower())
        if found:
            return found
    raise SystemExit(
        f"colonne introuvable parmi {candidates}.\n"
        f"Colonnes disponibles : {', '.join(fieldnames)}\n"
        "Relance avec --inspect et envoie la sortie : les noms DB2 bougent "
        "entre builds."
    )


def inspect(branch: str) -> int:
    """Affiche l'en-tête de chaque table. À lancer en premier."""
    for table in ("Mount", "ItemEffect", "ItemXItemEffect", "ItemSparse"):
        reader = reader_for(table, branch)
        print(f"--- {table} ---")
        print(", ".join(reader.fieldnames or ["(aucune colonne)"]))
        first = next(reader, None)
        if first:
            preview = {k: v for i, (k, v) in enumerate(first.items()) if i < 8}
            print(f"    exemple : {preview}")
        print()
    return 0


def build(branch: str, output: Path) -> int:
    # 1. Montures : ID et sort source.
    reader = reader_for("Mount", branch)
    fields = reader.fieldnames or []
    mount_id_col = pick_column(fields, "ID")
    spell_col = pick_column(fields, "SourceSpellID", "SourceSpellId")
    name_col = None
    try:
        name_col = pick_column(fields, "Name_lang", "Name")
    except SystemExit:
        pass  # le nom n'est qu'un confort de relecture

    mounts: dict[int, dict] = {}
    spell_to_mounts: dict[int, list[int]] = {}
    for row in reader:
        try:
            mount_id = int(row[mount_id_col])
            spell_id = int(row[spell_col] or 0)
        except (TypeError, ValueError):
            continue
        mounts[mount_id] = {
            "mountID": mount_id,
            "spellID": spell_id or None,
            "name": (row.get(name_col) or "").strip() if name_col else "",
        }
        if spell_id:
            spell_to_mounts.setdefault(spell_id, []).append(mount_id)
    print(f"Mount : {len(mounts)} montures, {len(spell_to_mounts)} sorts source")

    # 2. Effets d'objet : sort -> identifiants d'effet.
    reader = reader_for("ItemEffect", branch)
    fields = reader.fieldnames or []
    effect_id_col = pick_column(fields, "ID")
    effect_spell_col = pick_column(fields, "SpellID", "SpellId")

    effect_to_spell: dict[int, int] = {}
    for row in reader:
        try:
            effect_id = int(row[effect_id_col])
            spell_id = int(row[effect_spell_col] or 0)
        except (TypeError, ValueError):
            continue
        if spell_id in spell_to_mounts:
            effect_to_spell[effect_id] = spell_id
    print(f"ItemEffect : {len(effect_to_spell)} effets rattachés à une monture")

    # 3. Effet -> objet.
    reader = reader_for("ItemXItemEffect", branch)
    fields = reader.fieldnames or []
    x_effect_col = pick_column(fields, "ItemEffectID", "ItemEffectId")
    x_item_col = pick_column(fields, "ItemID", "ItemId")

    item_to_spell: dict[int, int] = {}
    for row in reader:
        try:
            effect_id = int(row[x_effect_col])
            item_id = int(row[x_item_col])
        except (TypeError, ValueError):
            continue
        spell_id = effect_to_spell.get(effect_id)
        if spell_id:
            # Le plus petit itemID gagne : c'est l'objet d'origine, et non une
            # réédition ultérieure qui porterait une extension plus récente.
            existing = item_to_spell.get(item_id)
            if existing is None:
                item_to_spell[item_id] = spell_id
    print(f"ItemXItemEffect : {len(item_to_spell)} objets rattachés")

    # 4. Objet -> extension. Table volumineuse, lue en flux.
    reader = reader_for("ItemSparse", branch)
    fields = reader.fieldnames or []
    sparse_id_col = pick_column(fields, "ID")
    sparse_expansion_col = pick_column(fields, "ExpansionID", "ExpansionId")

    spell_expansion: dict[int, int] = {}
    seen_items = 0
    for row in reader:
        try:
            item_id = int(row[sparse_id_col])
        except (TypeError, ValueError):
            continue
        spell_id = item_to_spell.get(item_id)
        if spell_id is None:
            continue
        try:
            expansion = int(row[sparse_expansion_col])
        except (TypeError, ValueError):
            continue
        seen_items += 1
        # Sur plusieurs objets pour un même sort, on garde la PLUS ANCIENNE
        # extension : c'est celle de l'objet d'origine.
        previous = spell_expansion.get(spell_id)
        if previous is None or expansion < previous:
            spell_expansion[spell_id] = expansion
    print(f"ItemSparse : {seen_items} objets de monture, "
          f"{len(spell_expansion)} sorts datés")

    # 5. Assemblage.
    resolved = 0
    for mount in mounts.values():
        spell_id = mount["spellID"]
        expansion = spell_expansion.get(spell_id) if spell_id else None
        mount["expansion"] = expansion
        if expansion is not None:
            resolved += 1

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["mountID", "spellID", "name", "expansion", "kind",
                        "instance", "dropRate"],
            extrasaction="ignore",
        )
        writer.writeheader()
        for mount_id in sorted(mounts):
            mount = mounts[mount_id]
            writer.writerow({
                "mountID": mount["mountID"],
                "spellID": mount["spellID"] or "",
                "name": mount["name"],
                "expansion": "" if mount["expansion"] is None else mount["expansion"],
                "kind": "",
                "instance": "",
                "dropRate": "",
            })

    missing = len(mounts) - resolved
    print()
    print(f"écrit : {output}")
    print(f"{resolved}/{len(mounts)} montures datées ({missing} sans extension)")
    if missing:
        print("Les non résolues resteront « inconnue » dans l'addon : "
              "aucune extension n'est devinée.", file=sys.stderr)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--branch", default="wow",
                        help="branche wago.tools (wow, wow_classic_era…)")
    parser.add_argument("-o", "--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--inspect", action="store_true",
                        help="afficher les colonnes réelles et s'arrêter")
    args = parser.parse_args()

    if args.inspect:
        return inspect(args.branch)
    return build(args.branch, args.output)


if __name__ == "__main__":
    raise SystemExit(main())
