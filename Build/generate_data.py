#!/usr/bin/env python3
"""Génère Data/Mounts.lua à partir d'un fichier de curation.

    Build/generate_data.py Build/overlay/mounts.csv

POURQUOI CE SCRIPT EXISTE
-------------------------
Un addon WoW ne peut faire AUCUNE requête réseau : c'est une contrainte du
client, pas un choix. Toute donnée extérieure doit donc être compilée dans un
fichier `.lua` au moment du build. C'est le rôle de ce script.

La cartographie dérivée du client (Modules/Mapping.lua) rattache ce qu'elle
peut — instances, hauts faits — et suit les patchs toute seule. Elle bute sur
les vendeurs, métiers, événements, PvP et butins de zone, dont le client
n'expose pas l'extension. Ce script comble ce trou-là, et rien d'autre.

LA CLÉ EST LE spellID
---------------------
Surtout pas le nom : les noms de montures sont localisés, une liste extérieure
est écrite dans une seule langue, et un rapprochement par nom marcherait chez
celui qui teste puis échouerait chez tous les autres. Le spellID est stable et
le client le donne pour chaque monture.

FORMAT D'ENTRÉE
---------------
CSV avec en-tête. Une seule colonne est obligatoire : `spellID`.

    spellID,expansion,kind,instance,dropRate
    40192,1,boss,Tempest Keep,0.02
    32458,1,boss,Tempest Keep,0.01

  expansion  niveau d'extension du client, 0 = Vanilla … 11 = Midnight
  kind       boss | rare | vendor | profession | event | pvp | quest |
             achievement | unknown
  instance   nom indicatif, NON localisé, affichage seulement
  dropRate   estimation communautaire entre 0 et 1

`/of export` en jeu produit un CSV de départ avec les spellID et ce que l'addon
sait déjà. Les colonnes vides sont celles à remplir.

Les lignes sans `expansion` exploitable sont ignorées avec un avertissement :
une entrée vide dans la table serait pire qu'une absence, parce qu'elle
empêcherait la cartographie dérivée du client de retenter sa chance.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO_ROOT / "Data" / "Mounts.lua"

MAX_EXPANSION_LEVEL = 11

VALID_KINDS = {
    "boss",
    "rare",
    "vendor",
    "profession",
    "event",
    "pvp",
    "quest",
    "achievement",
    "unknown",
}

HEADER = """\
--[[---------------------------------------------------------------------------
	OnlyFarm — Data/Mounts.lua

	FICHIER GÉNÉRÉ — ne pas éditer à la main.
	Produit par Build/generate_data.py le {generated}.

	Source : {source}
	Empreinte des données : {digest}
	{count} monture(s) curée(s).

	Les taux de drop sont des ESTIMATIONS communautaires. Ils doivent être
	affichés comme tels, jamais comme une donnée du client.
-----------------------------------------------------------------------------]]

local _, ns = ...

local Data = ns.Data

Data.MountsBuild = {{
	generated = "{generated}",
	digest = "{digest}",
	count = {count},
}}

Data.Mounts = {{
"""

FOOTER = """}

--- Entrée curée d'une monture, par son identifiant de sort.
function Data.GetCuratedMount(spellID)
	if type(spellID) ~= "number" then return nil end
	return Data.Mounts[spellID]
end

--- Nombre d'entrées curées, pour le diagnostic.
function Data.CountCuratedMounts()
	return ns.Util.Count(Data.Mounts)
end
"""


def lua_string(value: str) -> str:
    """Échappe une chaîne pour Lua. Les noms d'instance contiennent des
    apostrophes et parfois des guillemets."""
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    escaped = escaped.replace("\n", "\\n").replace("\r", "")
    return f'"{escaped}"'


def parse_rows(path: Path) -> tuple[list[dict], list[str]]:
    """Lit le CSV et renvoie (entrées valides, avertissements)."""
    entries: dict[int, dict] = {}
    warnings: list[str] = []

    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None or "spellID" not in reader.fieldnames:
            raise SystemExit(
                f"{path}: colonne « spellID » absente. "
                "C'est la clé de jointure, elle est obligatoire."
            )

        for line_number, row in enumerate(reader, start=2):
            raw_spell = (row.get("spellID") or "").strip()
            if not raw_spell:
                continue
            try:
                spell_id = int(raw_spell)
            except ValueError:
                warnings.append(f"ligne {line_number} : spellID « {raw_spell} » illisible")
                continue

            expansion_raw = (row.get("expansion") or "").strip()
            expansion = None
            if expansion_raw:
                try:
                    expansion = int(expansion_raw)
                except ValueError:
                    warnings.append(
                        f"ligne {line_number} : expansion « {expansion_raw} » illisible"
                    )
                    continue
                if not 0 <= expansion <= MAX_EXPANSION_LEVEL:
                    warnings.append(
                        f"ligne {line_number} : expansion {expansion} hors bornes"
                    )
                    continue

            kind = (row.get("kind") or "").strip().lower() or None
            if kind and kind not in VALID_KINDS:
                warnings.append(f"ligne {line_number} : nature « {kind} » inconnue")
                kind = None

            drop_rate = None
            raw_drop = (row.get("dropRate") or "").strip()
            if raw_drop:
                try:
                    drop_rate = float(raw_drop.replace(",", "."))
                except ValueError:
                    warnings.append(f"ligne {line_number} : dropRate « {raw_drop} » illisible")
                if drop_rate is not None and not 0 < drop_rate <= 1:
                    warnings.append(
                        f"ligne {line_number} : dropRate {drop_rate} hors ]0,1]"
                    )
                    drop_rate = None

            instance = (row.get("instance") or "").strip() or None

            # Une entrée qui n'apporte rien ne doit PAS être écrite : elle
            # masquerait la cartographie dérivée du client, qui a toutes ses
            # chances de faire mieux au prochain patch.
            if expansion is None and kind is None and drop_rate is None:
                continue

            if spell_id in entries:
                warnings.append(f"ligne {line_number} : spellID {spell_id} en double, ignoré")
                continue

            entries[spell_id] = {
                "spellID": spell_id,
                "expansion": expansion,
                "kind": kind,
                "instance": instance,
                "dropRate": drop_rate,
            }

    return [entries[key] for key in sorted(entries)], warnings


def render(entries: list[dict], source: str, digest: str) -> str:
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    out = [
        HEADER.format(
            generated=generated,
            source=source,
            digest=digest,
            count=len(entries),
        )
    ]

    for entry in entries:
        fields = []
        if entry["expansion"] is not None:
            fields.append(f'expansion = {entry["expansion"]}')
        if entry["kind"]:
            fields.append(f'kind = {lua_string(entry["kind"])}')
        if entry["instance"]:
            fields.append(f'instance = {lua_string(entry["instance"])}')
        if entry["dropRate"] is not None:
            fields.append(f'dropRate = {entry["dropRate"]:g}')
        out.append(f'\t[{entry["spellID"]}] = {{ {", ".join(fields)} }},\n')

    out.append(FOOTER)
    return "".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="CSV de curation")
    parser.add_argument(
        "-o", "--output", type=Path, default=DEFAULT_OUTPUT, help="fichier Lua produit"
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="valide l'entrée sans rien écrire",
    )
    args = parser.parse_args()

    if not args.source.is_file():
        raise SystemExit(f"source introuvable : {args.source}")

    raw = args.source.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()[:16]

    entries, warnings = parse_rows(args.source)

    for warning in warnings:
        print(f"  attention : {warning}", file=sys.stderr)

    print(f"{len(entries)} monture(s) retenue(s) sur {args.source}")
    if warnings:
        print(f"{len(warnings)} avertissement(s)", file=sys.stderr)

    if args.check:
        return 0

    try:
        relative_source = args.source.relative_to(REPO_ROOT)
    except ValueError:
        relative_source = args.source

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(render(entries, str(relative_source), digest), encoding="utf-8")
    print(f"écrit : {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
