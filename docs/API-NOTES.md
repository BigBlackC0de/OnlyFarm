# Notes d'API — vérifiées contre le client

Toutes les signatures ci-dessous ont été relevées dans le dump officiel de
l'interface Blizzard, **build 12.0.7 (68974)** :
<https://github.com/Gethe/wow-ui-source>, dossiers
`Interface/AddOns/Blizzard_APIDocumentationGenerated/` (documentation générée)
et le code des addons Blizzard pour les fonctions globales historiques, qui
n'apparaissent pas dans la documentation générée.

À refaire à chaque patch majeur : c'est la moitié des erreurs de premier
chargement qui disparaît.

---

## Confirmé conforme à la spécification

| Appel | Détail |
|---|---|
| `C_MountJournal.GetMountIDs()` | renvoie une table de `mountID` |
| `C_MountJournal.GetMountInfoByID(mountID)` | 13 retours, `isCollected` en **11e** position, `shouldHideOnChar` en 10e. Marquée `MayReturnNothing` : `name` peut être `nil` |
| `C_MountJournal.GetMountInfoExtraByID(mountID)` | 3e retour = `source`, le texte affiché dans le Journal |
| `C_MountJournal.GetMountFromItem(itemID)` | `mountID` ou `nil` |
| `C_MountJournal.GetMountFromSpell(spellID)` | `mountID` ou `nil` |
| `GetNumSavedInstances()` / `GetSavedInstanceInfo(i)` | globales, toujours présentes (utilisées par `Blizzard_RaidFrame`) |
| `RequestRaidInfo()` | asynchrone, réponse sur `UPDATE_INSTANCE_INFO` |
| `GetInstanceInfo()` / `IsInInstance()` | globales ; `instanceID` est le **8e** retour de `GetInstanceInfo` |
| `C_Item.GetItemInfoInstant(itemID)` | 6e = `classID`, 7e = `subClassID` |
| `C_QuestLog.IsQuestFlaggedCompleted(questID)` | conforme |
| `C_Reputation.GetFactionDataByID` / `C_MajorFactions.GetMajorFactionRenownInfo` | renvoient une **table**, pas des valeurs multiples |
| `PlayerHasToy(itemID)` / `C_ToyBox.GetToyInfo(itemID)` | conformes |
| `C_Map.SetUserWaypoint` / `C_SuperTrack.SetSuperTrackedUserWaypoint` | conformes ; penser à `C_Map.CanSetUserWaypointOnMap(uiMapID)` avant |
| `C_TaxiMap.GetAllTaxiNodes(uiMapID)` | ne renvoie que les nœuds **du maître de vol courant** |
| `EJ_SelectTier` / `EJ_GetInstanceByIndex` / `EJ_SelectInstance` / `EJ_GetEncounterInfoByIndex` / `EJ_SelectEncounter` | globales, toujours utilisées par `Blizzard_EncounterJournal/Mainline` |
| `NEW_MOUNT_ADDED` | existe toujours (`MountJournalDocumentation.lua`) |

---

## Divergences trouvées — la spécification est à corriger

### 1. `C_EncounterJournal.GetLootInfoByIndex` renvoie une table sans `classID`

La spécification propose de filtrer le butin sur `classID == 15 and subClassID == 5`.
Impossible tel quel : la structure `EncounterJournalItemInfo` retournée contient
`itemID`, `encounterID`, `name`, `itemQuality`, `filterType`, `icon`, `slot`,
`armorType`, `link`… mais **ni `classID` ni `subClassID`**.

Deux options :

* appeler `C_Item.GetItemInfoInstant(itemID)` pour récupérer les deux champs ;
* **ou** appeler directement `C_MountJournal.GetMountFromItem(itemID)` — plus
  court, plus fiable, et c'est le test qui compte vraiment.

`Modules/Mapping.lua` retient la seconde, en passe approfondie.

### 2. `C_Spell.GetSpellCooldown` renvoie une table, pas 4 valeurs

```lua
local info = C_Spell.GetSpellCooldown(spellID)
-- info.startTime, info.duration, info.isEnabled, info.isActive, info.modRate
```

Elle est en plus marquée `SecretWhenCooldownsRestricted` : dans les contextes
où le client restreint les cooldowns, `startTime` et `duration` peuvent être des
**valeurs secrètes** inutilisables en arithmétique. `isEnabled` et `isActive`
sont marqués `NeverSecret` — ce sont les seuls champs sur lesquels s'appuyer
sans précaution. À prendre en compte au moment du bouton de téléport (phase 4).

### 3. `IsPlayerSpell` et `IsSpellKnownOrOverridesKnown` sont des rétro-compatibilités

Elles ne sont définies que si la CVar `loadDeprecationFallbacks` est active
(`Blizzard_DeprecatedSpellBook/Deprecated_SpellBook.lua`). Ne pas s'y fier.
Les vraies API :

```lua
C_SpellBook.IsSpellKnown(spellID, Enum.SpellBookSpellBank.Player)
C_SpellBook.IsSpellInSpellBook(spellID, bank, includeOverrides)
```

À corriger dans `TravelGraph:Build()` (phase 3), qui utilise `IsPlayerSpell`
dans la spécification.

### 4. `GetSavedInstanceEncounterInfo` n'est documentée nulle part — mais elle existe

Elle n'apparaît ni dans la documentation générée, ni dans le code de
l'interface Blizzard de la 12.0.7. **Vérifié en jeu sur un client 12.0.7 :
`type(GetSavedInstanceEncounterInfo) == "function"`.** Elle est donc bien
présente, simplement plus utilisée par Blizzard.

Le garde-fou reste en place dans `Modules/Lockouts.lua` (`type(...) ==
"function"` puis `pcall`, avec repli sur `encounterProgress`) : une fonction
qu'aucun code de Blizzard n'appelle plus est exactement le genre de chose qui
disparaît sans préavis à une extension.

### 5. Positions 11 et 12 de `GetSavedInstanceInfo` non confirmées

Le code de Blizzard ne lit que les retours 1 à 10, 13 et 14 :

```lua
-- Blizzard_RaidFrame/Mainline/RaidFrame.lua
local name, instanceID, reset, difficulty, locked, extended,
      instanceIDMostSig, isRaid, maxPlayers, difficultyName = GetSavedInstanceInfo(index)
local _, _, _, _, locked, extended, _, _, _, _, _, _, extendDisabled, _ = GetSavedInstanceInfo(...)
```

`numEncounters` (11) et `encounterProgress` (12) viennent de la documentation
communautaire. `Modules/Lockouts.lua` valide leur type avant usage et retombe
sur `0` sinon. Attention aussi : le 2e retour s'appelle `lockoutID` dans la
spécification et `instanceID` dans le code de Blizzard — ce n'est **pas**
l'`instanceID` moteur, qui est le 14e.

### 6. Le libellé de catégorie de source vient du client

Pas besoin de traduire soi-même : `_G["BATTLE_PET_SOURCE_"..sourceType]` donne
le libellé localisé, exactement ce qu'affiche l'interface Blizzard (mêmes
constantes pour montures, mascottes, jouets et objets hérités).

---

## Le pont manquant : journalInstanceID ↔ instanceID moteur

Le Journal des rencontres parle en `journalInstanceID`, les verrous en
`instanceID` moteur, et **aucune API n'expose la correspondance**.

Contournement retenu (`Modules/Lockouts.lua`) : apprentissage par le nom
localisé. `GetSavedInstanceInfo` et `EJ_GetInstanceByIndex` viennent du même
client, donc de la même locale. La table `db.global.instanceIDsByName` se
remplit à chaque lecture de verrou et à chaque entrée en instance, et se
corrige d'elle-même à l'usage.

Conséquence assumée : une instance jamais visitée et jamais verrouillée n'a pas
encore d'`instanceID` connu. Son statut est alors « incertain » et le dit
(`detail = "instance_unresolved"`) — jamais « disponible » par défaut.

---

---

## L'extension d'une monture : ce que le client donne vraiment

Question ouverte pendant plusieurs itérations, tranchée sur le dump officiel du
build 12.0.7 et sur l'API web réelle.

**Aucune API ne donne l'extension d'une MONTURE.** Ni `C_MountJournal`
(vérifié : `MountInfo` et `MountInfoExtra` ne contiennent aucun champ
d'extension), ni l'API web `/data/wow/mount/{id}` (vérifié en jeu le
2026-08-09 : `id`, `name`, `creature_displays`, `description`, `source`,
`faction`, `requirements`, `should_exclude_if_uncollected`). Le Journal des
montures de Blizzard lui-même n'a pas de filtre par extension — son code ne
mentionne le mot nulle part.

**En revanche `C_Item.GetItemInfo(itemID)` donne un `expansionID`**, en 15e
position (`ItemDocumentation.lua`, structure `ItemInfoResult`). C'est
l'extension de l'OBJET, donc celle de la monture qu'il enseigne : exacte, non
localisée, fournie par le client.

Le chaînon manquant est l'itemID : `C_MountJournal.GetMountFromItem` va de
l'objet vers la monture, jamais l'inverse. La seule source d'itemID est le
butin du Journal des rencontres (`GetLootInfoByIndex`, champ `itemID`), donc la
passe approfondie.

D'où le montage retenu dans `Modules/Mapping.lua` : la passe approfondie
récolte les itemID, ils sont **mémorisés dans le cache**, et chaque scan rapide
ultérieur en tire l'extension exacte sans avoir à la refaire. L'objet écrase
toutes les heuristiques ; l'instance, elle, reste celle du rapprochement de
lieu, puisque c'est elle qui sert aux verrous et que l'objet ne la donne pas.

Restent hors d'atteinte les montures qui ne viennent d'aucune table de butin
d'instance : vendeurs, métiers, événements, PvP. Pour celles-là, seule une
table curée peut répondre (`Data/Mounts.lua`).

### `C_MountJournal.SetSourceFilter` : à ne pas utiliser

`SetSourceFilter(filterIndex, isChecked)` pilote les cases « source » du
Journal des montures et change ce que renvoient `GetNumDisplayedMounts` et
`GetDisplayedMountInfo`. Deux raisons de s'en passer :

* elle modifie les **réglages du joueur**. Un addon qui les change en douce
  laisse le Journal filtré autrement qu'il ne l'avait laissé ;
* elle n'apporte rien : `sourceType` est déjà le 6e retour de
  `GetMountInfoByID`, monture par monture, sans effet de bord.

Elle ne donne pas non plus accès à l'extension, qui est le seul manque réel.

## Points à vérifier au prochain patch

* `GetSavedInstanceEncounterInfo` existe-t-elle encore ?
* Les positions 11/12 de `GetSavedInstanceInfo` sont-elles toujours celles-là ?
* Les « valeurs secrètes » de la 12.0 s'étendent-elles à d'autres API utilisées
  ici (aucune pour l'instant : montures, verrous et carte sont tous
  `AllowedWhenUntainted`) ?
