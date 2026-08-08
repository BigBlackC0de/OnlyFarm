#!/usr/bin/env python3
"""Interroge l'API officielle Blizzard et produit le CSV de curation.

    export BLIZZARD_CLIENT_ID=...
    export BLIZZARD_CLIENT_SECRET=...
    Build/fetch_blizzard.py --region eu --locale fr_FR -o Build/overlay/mounts.csv

CE QUE L'API OFFICIELLE DONNE — ET CE QU'ELLE NE DONNE PAS
----------------------------------------------------------
https://develop.battle.net/documentation/world-of-warcraft/game-data-apis

Elle donne, de façon canonique et versionnée :

  * la liste complète des montures (/data/wow/mount/index), avec le mountID —
    LE MÊME identifiant que C_MountJournal côté client. C'est ce qui rend la
    jointure exacte au lieu d'être approximative ;
  * le nom de chaque monture DANS TOUTES LES LOCALES. C'est le point le plus
    utile et le moins évident : il permet de rapprocher n'importe quelle liste
    extérieure écrite en anglais du client français d'un joueur, en passant par
    le mountID. Sans ça, toute source communautaire est inutilisable hors des
    clients anglais ;
  * la source déclarée par Blizzard (`source.type` : DROP, VENDOR, QUEST,
    ACHIEVEMENT, PROFESSION…), plus fiable que le `sourceType` numérique du
    client ;
  * la faction et les prérequis.

Elle NE donne PAS l'extension d'une monture. Aucun champ, sur aucun endpoint
de l'API des montures. Le chemin officiel n'existe que pour les instances
(/data/wow/journal-expansion -> journal-instance -> journal-encounter), et
c'est justement le seul cas que l'addon sait déjà résoudre tout seul, côté
client, sans réseau.

Autrement dit : l'API règle le problème de l'IDENTITÉ et de la LANGUE, pas
celui de l'extension des montures hors instance. Pour celles-là, la colonne
`expansion` du CSV reste à remplir — par une source communautaire, ou à la
main. Le script la laisse vide plutôt que d'inventer.

Ce script n'a JAMAIS été exécuté contre l'API réelle depuis ce dépôt : l'accès
réseau y est bloqué. Il est écrit d'après la documentation ; le premier
lancement demande donc un œil sur la sortie.

PRÉREQUIS
---------
Un client OAuth gratuit à créer sur https://develop.battle.net/access/clients
(identifiant + secret). Aucune bibliothèque tierce : uniquement la librairie
standard.
"""

from __future__ import annotations

import argparse
import base64
import csv
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO_ROOT / "Build" / "overlay" / "mounts.csv"

OAUTH_URL = "https://oauth.battle.net/token"
USER_AGENT = "OnlyFarm-build/1.0 (+https://github.com/BigBlackC0de/OnlyFarm)"

# La documentation ne garantit aucun quota précis ; on reste poli.
REQUEST_DELAY = 0.05
MAX_RETRIES = 4

# Correspondance entre les types de source de l'API et le vocabulaire de
# Data.SOURCE_KINDS. Tout ce qui n'est pas listé retombe sur « unknown », qui
# est un aveu honnête plutôt qu'une catégorie fourre-tout déguisée.
SOURCE_TYPE_TO_KIND = {
    "DROP": "boss",
    "VENDOR": "vendor",
    "QUEST": "quest",
    "ACHIEVEMENT": "achievement",
    "PROFESSION": "profession",
    "WORLD_EVENT": "event",
    "PVP": "pvp",
    "TRADING_CARD_GAME": "unknown",
    "PROMOTION": "unknown",
    "IN_GAME_STORE": "unknown",
    "DISCOVERY": "unknown",
}


class BlizzardAPI:
    def __init__(self, client_id: str, client_secret: str, region: str, locale: str):
        self.region = region
        self.locale = locale
        self.host = f"https://{region}.api.blizzard.com"
        self.namespace = f"static-{region}"
        self._token = self._authenticate(client_id, client_secret)

    def _authenticate(self, client_id: str, client_secret: str) -> str:
        credentials = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
        request = urllib.request.Request(
            OAUTH_URL,
            data=urllib.parse.urlencode({"grant_type": "client_credentials"}).encode(),
            headers={
                "Authorization": f"Basic {credentials}",
                "User-Agent": USER_AGENT,
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.load(response)
        except urllib.error.HTTPError as error:
            raise SystemExit(
                f"authentification refusée ({error.code}). "
                "Vérifie BLIZZARD_CLIENT_ID et BLIZZARD_CLIENT_SECRET."
            ) from error
        except urllib.error.URLError as error:
            raise SystemExit(f"réseau injoignable : {error.reason}") from error

        token = payload.get("access_token")
        if not token:
            raise SystemExit("réponse OAuth sans access_token")
        return token

    def get(self, path: str) -> dict | None:
        """Un GET, avec reprise sur erreur transitoire.

        Renvoie None sur 404 : une monture retirée du jeu est un cas normal, pas
        une raison d'interrompre une collecte de mille appels."""
        query = urllib.parse.urlencode({"namespace": self.namespace, "locale": self.locale})
        url = f"{self.host}{path}?{query}"
        request = urllib.request.Request(
            url,
            headers={
                "Authorization": f"Bearer {self._token}",
                "User-Agent": USER_AGENT,
            },
        )

        for attempt in range(1, MAX_RETRIES + 1):
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    return json.load(response)
            except urllib.error.HTTPError as error:
                if error.code == 404:
                    return None
                if error.code in (429, 500, 502, 503, 504) and attempt < MAX_RETRIES:
                    time.sleep(2**attempt)
                    continue
                raise SystemExit(f"{url} : HTTP {error.code}") from error
            except urllib.error.URLError as error:
                if attempt < MAX_RETRIES:
                    time.sleep(2**attempt)
                    continue
                raise SystemExit(f"{url} : {error.reason}") from error
        return None


def fetch_mounts(api: BlizzardAPI, limit: int | None) -> list[dict]:
    index = api.get("/data/wow/mount/index")
    if not index or "mounts" not in index:
        raise SystemExit("index des montures illisible")

    listing = index["mounts"]
    if limit:
        listing = listing[:limit]

    total = len(listing)
    print(f"{total} montures à récupérer…", file=sys.stderr)

    rows = []
    for position, item in enumerate(listing, start=1):
        mount_id = item.get("id")
        if mount_id is None:
            continue

        detail = api.get(f"/data/wow/mount/{mount_id}")
        time.sleep(REQUEST_DELAY)
        if detail is None:
            continue

        source = detail.get("source") or {}
        source_type = source.get("type")

        rows.append(
            {
                "mountID": mount_id,
                # Le nom localisé sert à VÉRIFIER la jointure avec le client,
                # pas à la faire : c'est le mountID qui joint.
                "name": detail.get("name") or item.get("name") or "",
                "apiSource": source.get("name") or "",
                "kind": SOURCE_TYPE_TO_KIND.get(source_type, "unknown"),
                # Volontairement vide : l'API ne donne pas l'extension. La
                # remplir au jugé serait exactement le genre de donnée
                # plausible et fausse que ce dépôt refuse.
                "expansion": "",
                "spellID": "",
                "instance": "",
                "dropRate": "",
            }
        )

        if position % 100 == 0:
            print(f"  {position}/{total}", file=sys.stderr)

    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--region", default="eu", choices=["us", "eu", "kr", "tw"])
    parser.add_argument(
        "--locale",
        default="fr_FR",
        help="locale des noms, à faire correspondre au client (fr_FR, en_US…)",
    )
    parser.add_argument("-o", "--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--limit", type=int, help="s'arrêter après N montures (essai)")
    args = parser.parse_args()

    client_id = os.environ.get("BLIZZARD_CLIENT_ID")
    client_secret = os.environ.get("BLIZZARD_CLIENT_SECRET")
    if not client_id or not client_secret:
        raise SystemExit(
            "BLIZZARD_CLIENT_ID et BLIZZARD_CLIENT_SECRET doivent être définis.\n"
            "Client gratuit à créer sur https://develop.battle.net/access/clients"
        )

    api = BlizzardAPI(client_id, client_secret, args.region, args.locale)
    rows = fetch_mounts(api, args.limit)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "mountID",
                "spellID",
                "name",
                "apiSource",
                "kind",
                "expansion",
                "instance",
                "dropRate",
            ],
        )
        writer.writeheader()
        writer.writerows(rows)

    print(f"écrit : {args.output} ({len(rows)} montures)")
    print(
        "La colonne « expansion » est VIDE : l'API ne la fournit pas. "
        "À compléter avant Build/generate_data.py.",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
