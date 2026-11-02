# NecroMinions-CoA

Conquest Reborn / Ascension CoA Necromancer minion HUD for WoW 3.3.5a (Lua 5.1).

Maintainer: Uncle Bone. Original author: Smollett. Existing addon files and historical README remain preserved.

## Installation
Download the versioned ZIP from [Releases](https://github.com/uncle-bone/NecroMinions-CoA/releases) and extract the **NecroMinions** folder directly into `World of Warcraft/Interface/AddOns/`. Preserve your existing SavedVariables.

## v0.8.6 prerelease

This build does not change player nameplate CVars. Friendly plates stay off if the player configured them off. Existing minion HUD and combat-log estimates remain available. Per-minion right-click dismissal requires a verified client-supported operation and is not yet enabled.

## v0.8.5 prerelease

The options panel now provides two optional diagnostics buttons: **Recent summon events** and **Current minion status**. These show existing counters and history only on click; no new continuous scans or chat logging are introduced. The working combat, nameplate and Life Force code is unchanged.

## Research provenance
Reviewed [CoA-Research v2.0.1](https://github.com/uncle-bone/CoA-Research/releases/tag/shared-database-v2.0.1), especially `datasets/relationships/class-pet-summon-investigation-v1.json`. Its seven NPC candidates and four spell-attribution candidates are all quarantined and it reports **zero verified ownership edges**, so no speculative NPC or spell mappings are injected into gameplay. The addon's client-derived spell lists remain the baseline pending live tests.

See `RELEASE-NOTES.md`, `CHANGELOG.md`, and the original `NecroMinions/README.txt` for details.
