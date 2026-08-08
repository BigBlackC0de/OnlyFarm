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

`Modules/DevScan.lua` retient la seconde.

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

### 4. `GetSavedInstanceEncounterInfo` n'est documentée nulle part

Elle n'apparaît ni dans la documentation générée, ni dans le code de
l'interface Blizzard de la 12.0.7. Elle existe probablement toujours, mais rien
ne le garantit. `Modules/Lockouts.lua` la teste (`type(...) == "function"`) et
l'appelle en `pcall`, avec repli sur `encounterProgress`.

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

## Points à vérifier au prochain patch

* `GetSavedInstanceEncounterInfo` existe-t-elle encore ?
* Les positions 11/12 de `GetSavedInstanceInfo` sont-elles toujours celles-là ?
* Les « valeurs secrètes » de la 12.0 s'étendent-elles à d'autres API utilisées
  ici (aucune pour l'instant : montures, verrous et carte sont tous
  `AllowedWhenUntainted`) ?
