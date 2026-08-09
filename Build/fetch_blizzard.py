#!/usr/bin/env python3
"""Interroge l'API officielle Blizzard et produit le CSV de curation.

    python3 Build/fetch_blizzard.py --region eu --locale fr_FR --raw 3

Les identifiants sont lus dans Build/blizzard-credentials.txt (deux lignes
CLÉ=VALEUR), ou dans les variables d'environnement BLIZZARD_CLIENT_ID et
BLIZZARD_CLIENT_SECRET si elles sont définies.

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

Elle NE donne PAS l'extension d'une monture. VÉRIFIÉ contre l'API réelle le
2026-08-09, build 12.0.7_67808, région eu : la réponse de /data/wow/mount/{id}
contient id, name, creature_displays, description, source, faction,
requirements et should_exclude_if_uncollected. Aucun champ d'extension, ni
direct ni indirect.

Le chemin officiel vers une extension n'existe que pour les instances
(/data/wow/journal-expansion -> journal-instance -> journal-encounter), et il
ne rejoint jamais les montures : aucun endpoint ne relie un objet de butin à
une monture. C'est de toute façon le seul cas que l'addon résout déjà tout
seul, côté client, sans réseau.

Autrement dit : l'API règle le problème de l'IDENTITÉ et de la LANGUE, pas
celui de l'extension des montures hors instance. Pour celles-là, la colonne
`expansion` du CSV reste à remplir — par une source communautaire, ou à la
main. Le script la laisse vide plutôt que d'inventer.

Exécuté contre l'API réelle le 2026-08-09 (1627 montures dans l'index). Le
dépôt lui-même n'a pas d'accès réseau : les corrections viennent de sorties
collées à la main.

PRÉREQUIS — POUR LE MAINTENEUR, PAS POUR LE JOUEUR
--------------------------------------------------
Un client OAuth gratuit à créer sur https://develop.battle.net/access/clients
(identifiant + secret). Aucune bibliothèque tierce : uniquement la librairie
standard.

Ce script tourne UNE FOIS PAR PATCH, chez le mainteneur. Son résultat est
compilé par generate_data.py en Data/Mounts.lua, qui est committé et livré dans
le dossier de l'addon. Personne d'autre n'exécute ceci : l'addon lui-même est
incapable d'appeler une API, et le joueur n'a ni identifiants, ni Python, ni
quoi que ce soit à installer.
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

# Fichier d'identifiants, cherché quand les variables d'environnement sont
# absentes. Les définir demande une syntaxe différente selon le système
# (« export » sur Linux et macOS, « $env: » sous PowerShell), ce qui est une
# source d'erreur inutile pour une opération qu'on fait une fois. Un fichier
# texte de deux lignes marche partout, et .gitignore le couvre.
CREDENTIALS_FILE = REPO_ROOT / "Build" / "blizzard-credentials.txt"

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


def read_credentials() -> tuple[str | None, str | None]:
    """Identifiants, depuis l'environnement ou le fichier local."""
    client_id = os.environ.get("BLIZZARD_CLIENT_ID")
    client_secret = os.environ.get("BLIZZARD_CLIENT_SECRET")
    if client_id and client_secret:
        return client_id, client_secret

    if not CREDENTIALS_FILE.is_file():
        return client_id, client_secret

    for line in CREDENTIALS_FILE.read_text(encoding="utf-8-sig").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip().upper()
        # Les guillemets copiés depuis une page web sont fréquents.
        value = value.strip().strip("\"'")
        if key == "BLIZZARD_CLIENT_ID" and not client_id:
            client_id = value
        elif key == "BLIZZARD_CLIENT_SECRET" and not client_secret:
            client_secret = value

    return client_id, client_secret


def dump_raw(api: BlizzardAPI, count: int) -> None:
    """Affiche les réponses BRUTES de l'API pour quelques montures.

    C'est le premier geste à faire, avant toute planification : ce script est
    écrit d'après la documentation, sans avoir jamais été confronté à l'API
    réelle. Voir les champs effectivement renvoyés répond en une fois à des
    questions qu'on ne peut que supposer autrement — à commencer par « existe-t-il
    un champ d'extension quelque part ? »."""
    index = api.get("/data/wow/mount/index")
    if not index or "mounts" not in index:
        raise SystemExit("index des montures illisible")

    print(f"index : {len(index['mounts'])} montures")
    print(json.dumps(index["mounts"][:3], ensure_ascii=False, indent=2))
    print()

    for item in index["mounts"][:count]:
        mount_id = item.get("id")
        detail = api.get(f"/data/wow/mount/{mount_id}")
        time.sleep(REQUEST_DELAY)
        print(f"--- /data/wow/mount/{mount_id} ---")
        print(json.dumps(detail, ensure_ascii=False, indent=2))
        print()


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

        # Champ absent de la documentation mais bien présent dans les réponses :
        # Blizzard s'en sert pour ne PAS afficher une monture non possédée dans
        # l'armurerie. Il désigne en pratique les montures hors d'atteinte
        # (retirées, doublons, réservées à l'autre faction). On le conserve : il
        # vaut mieux que l'addon sache les écarter plutôt que de les compter
        # comme « manquantes ».
        excluded = bool(detail.get("should_exclude_if_uncollected"))

        faction = (detail.get("faction") or {}).get("type") or ""

        rows.append(
            {
                "mountID": mount_id,
                "apiType": source_type or "",
                "faction": faction,
                "excludeIfUncollected": "1" if excluded else "",
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
    parser.add_argument(
        "--raw",
        type=int,
        metavar="N",
        help="afficher la réponse BRUTE de l'API pour N montures, sans rien écrire",
    )
    args = parser.parse_args()

    client_id, client_secret = read_credentials()
    if not client_id or not client_secret:
        raise SystemExit(
            "Identifiants Blizzard introuvables.\n"
            "\n"
            f"Le plus simple : créer le fichier {CREDENTIALS_FILE}\n"
            "avec ces deux lignes (en remplaçant par tes valeurs) :\n"
            "\n"
            "    BLIZZARD_CLIENT_ID=ton_client_id\n"
            "    BLIZZARD_CLIENT_SECRET=ton_client_secret\n"
            "\n"
            "Ce fichier est ignoré par git, il ne partira jamais sur GitHub.\n"
            "Client gratuit à créer sur https://develop.battle.net/access/clients"
        )

    api = BlizzardAPI(client_id, client_secret, args.region, args.locale)

    if args.raw:
        dump_raw(api, args.raw)
        return 0

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
                "apiType",
                "faction",
                "excludeIfUncollected",
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
