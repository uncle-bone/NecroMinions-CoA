NecroMinions 0.8.3 - Driver-aware invisible minion nameplates

Built from 0.8.0, preserving its automatic-health summon/combat/drain pulses.
This supersedes 0.8.2's passive-only workaround.

The extracted client manager reparents UnitFrame to WorldFrame, then changes
its alpha in ReduceNamePlateLag/UpdateAlphaAndLevel during camera movement
and target changes. A periodic SetAlpha(0) races those callbacks.
This build uses secure post-hooks on each visible UnitFrame's SetAlpha,
Show and SetUnit methods to immediately reapply minion invisibility.
Each hook checks the CURRENT unit, so recycled enemy frames are restored.
Native base frames are not hidden/disabled; UnitHealth polling continues.
No tiny replacement bars are created. The startup enemy/combat-only toggle
is removed. Enemy and combat-only CVars are not written.

Install: close the game, replace Interface/AddOns/NecroMinions with the
NecroMinions folder in this ZIP, and keep your SavedVariables. Do not install
or replace the extracted Ascension driver; it was used for reference only.
Enable Automatic nearby health and Hide my minions' nameplates in /nm options.

Test: login with minions, wait at least 10 seconds, move/rotate the camera,
change targets, summon, enter/leave combat, then /reload. Minion world bars
should remain invisible. Damage/drain a minion during combat and verify the
HUD health changes without targeting or mousing over it. Enemy plates should
remain visible according to your settings. /nm plates should say hook-hidden
for minions while automatic-health pulses are active. Outside a pulse, guardian
health can still be cached, as in 0.8.0. Client combat-only mode also determines
whether nameplate tokens exist; this addon does not override that setting.

Validation: Lua 5.4 syntax and mocked driver/health tests (including the
extracted alpha callback); the game uses Lua 5.1. Native rendering requires
confirmation in Conquest Reborn. If an error occurs, report its full text.

Previous release notes (historical):

NecroMinions 0.8.0 - Tracking and display fixes
For Conquest Reborn / Conquest of Azeroth's modified WoW 3.3.5a client.
Interface: 30300.

New in 0.8.0
- At login or reload, nameplates are set to the game's "All Nameplates
  Turned On (Combat)" mode, as the nameplate toggle does: the client setting
  nameplateInCombatOnly is switched on, and enemy plates are switched off
  and back on half a second later. Option: "Turn on combat nameplates at
  login and reload" (on by default).

New in 0.7.9
- Found the cause of the full-size blue minion plates: the addon's own
  C_NamePlateManager.DisableBlizzPlate call. It switches off Ascension's
  nameplate and leaves the old-style blue plate underneath, until a
  nameplate toggle rebuilds the plates. It is no longer called. Minion
  plates keep the game's drawing and fade it out (the Ascension frame and
  each plate part), with the small see-through bar on top.
- Removed the 0.7.8 automatic nameplate off/on after loading and the
  repeated switch-off from 0.7.6/0.7.7. The 4-second wait after a loading
  screen stays.
- Removed the addon's own copy of Ascension's plate frame
  (NecroMinionsPlates.xml and its two Lua files); the game draws every
  plate that is not a minion again.

New in 0.7.8
- 0.7.7 did not stop the full-size blue minion plates at login or reload;
  only toggling nameplates by hand fixed them. Now, 4 seconds after a
  loading screen, the friendly nameplate settings that are on are switched
  off for half a second and back on, the same as toggling them. If the game
  is reloaded during that half second, they are switched back on at the next
  load.

New in 0.7.7
- After a login, reload or loading screen the minion plates came up as
  full-size blue plates until nameplates were toggled. The addon switched
  friendly plates on (a reading pulse) while the client was still setting
  its nameplates up. Nameplate settings are now left alone for 4 seconds
  after a loading screen, and plates are switched off again repeatedly for
  6 seconds after that.

New in 0.7.6
- The small minion plates showed at login but turned back into full-size
  blue plates after nameplates were toggled off and on. The game switches a
  plate's built-in drawing back on when plates are toggled, and the addon
  only switched each plate off once. Plates are now switched off again
  whenever they are hidden, emptied, removed or added, or a setting changes.

New in 0.7.5
- In game, 0.7.4 found every minion plate, took it over and faded the
  built-in frame, yet the full-size blue plates still showed:
  DisableBlizzPlate does not switch off the old-style plate drawing. Each
  part of a minion's plate (border, name, health bar, level...) is now faded
  on its own. The client resets the whole plate's alpha but not its parts',
  so this holds. The parts come back when the plate shows another unit.
  DisableBlizzPlate is also tried with the plate itself.
- /nm plates lists every part of each plate (type, shown, alpha; NecroMinions'
  own parts are marked *).

New in 0.7.4
- Minion nameplates are now really replaced. The client's built-in
  nameplate code puts its own frame on every plate, and 0.7.3 took that for
  another nameplate addon and left every plate alone. A minion's plate is
  now always taken over: its built-in drawing is switched off (again each
  time the plate shows a new minion), any frame on it is faded out, and the
  small bar is drawn. When the plate shows anything else, the faded frame
  comes back unchanged.
- /nm plates also shows each plate's role, whether it is taken over, the
  state of any frame on it, and whether the unit is one of your minions.

New in 0.7.3
- Your minions' nameplates are replaced, not hidden. The game's own plate is
  switched off (C_NamePlateManager.DisableBlizzPlate) and a tiny see-through
  bar in the HUD's bar colour is drawn instead: 40 px wide, 40% opacity by
  default (Options > Minion nameplates, or "Small minion nameplates" in the
  right-click menu). It never takes clicks. The old approach set the plate's
  alpha to 0, which the client kept resetting: that was the flicker, and
  why full-size blue plates still showed.
- The client cannot switch a plate's own drawing back on, and it reuses
  plates. A taken-over plate that later shows any other unit is drawn as
  Ascension's standard nameplate, built from the same template and client
  code as the built-in one (copied as NecroMinionsPlates.xml and its two
  Lua files), so enemies never lose their plate. Plates driven by another
  nameplate addon are left alone.
- During a pulse with friendly nameplates originally off, other friendly
  plates are taken over and drawn as nothing, instead of alpha 0.
- /nm plates lists each visible nameplate and how NecroMinions draws it.

New in 0.7.2
- Every summonable minion is tracked. Any summon in the 2 seconds after one
  of your Raise, Animate or Mass Raise casts becomes a row, even when its
  summon effect or creature name is not in the addon's lists; a new creature
  name is learned per character so nameplates and mouseover recognize it
  afterwards. Added by name: Frenzied Ghoul (Ghoul Mastery), Flesh Golem and
  Gurgling Horror (Summoning Mastery; no Life Force cost in CR's data, so
  they do not count toward Life Force), Rotting Frost Giant, and the
  Gravebound, Spellbound and Icebound Champions. Animate: Skeletal Smith is
  a repair helper and stays untracked. Every Animate summon is temporary.
  The cast itself also starts the nameplate pulse.
- Skeletons and Crypt Fiends no longer vanish until moused over. A minion's
  own attacks, casts and the damage it takes now count as proof it is alive:
  they bring back a row a Life Force/aura guess removed, and keep it from
  being removed again while it fights. A replacement check also stops when
  the native Life Force in use already covers every tracked minion.
- Automatic nearby health is ON by default (existing installs switch on once).
  It pulses friendly pet/guardian nameplates on so skeletons and fiends,
  which have no other unit to read, report live health: for 3 seconds after
  a summon, for the whole of combat (plus 2 seconds after), and for 4 seconds
  after your own spell hits, drains or applies an effect to a minion. The
  rest of the time your character's own nameplate settings are back in
  place, and rows keep their last reading (marked "~" as the log adjusts it).
  During a pulse your own minions' plates are invisible; every other friendly
  plate is hidden as well when friendly nameplates were off before. Turn it
  off with /nm autohealth off or the options checkbox; rows then update from
  targeting, mouseover, focus and combat-log estimates.
- Summon numbers reuse freed slots. A new minion takes the lowest number no
  current minion of its type has, so resummoning four Ghouls shows #1-#4
  instead of counting up (#7, #8, ...) for the whole session.

New in 0.7.1
- Temporary summons (Zombies, Rotlings, Animate: Crypt Fiend, etc.) no longer
  extend roster settling time or become the "newest summon". Rapid temporary
  summons can no longer push a pending Life Force replacement past its
  3-second deadline and leave replaced minions on the HUD.
- A Crypt Fiend found without its summon event (e.g. after /reload) may be the
  temporary Animate: version, so it is kept out of Life Force counts until its
  summon spell is seen. It never contributes to removing other rows.
- Temporary summons now expire from the HUD after 60 seconds with no live
  unit, combat-log activity or death event. A live unit restores the row.
- Up to 20 rows (was 10). Permanent minions always take the first rows;
  temporary summons follow, and any that do not fit show as "+N more".
- Move/preview mode no longer replaces the tracked army. Tracking, deaths and
  Sacrifice Undead continue during preview, and nothing is lost on exit.
  Preview can now be left during combat with /nm change or the options button.
- Life Force costs are now really per character (NecroMinionsCharDB). On each
  character's first login with 0.7.1 the previous account-wide costs are
  copied once; after that, changes affect only that character.
- The ownership tooltip is re-anchored before every scan. A hidden scan
  tooltip loses its owner and silently stops reading owner lines, which could
  stop nameplate/target discovery of your minions after a reload.
- Other Necromancers' identically named minions are no longer tooltip-scanned
  on every health event; a negative result is cached for 5 seconds per GUID.
- Hidden friendly nameplates (automatic nearby health) also have mouse input
  disabled, so invisible plates should not take clicks meant for enemies. This
  is skipped in combat and on protected plates; untested on the live client.
- Per-frame nameplate checks reuse one table instead of allocating each frame.
- Dead temporary summons keep only a minimal guard, and expired ones are
  dropped from ownership history, so long sessions do not grow memory.
- The HUD's screen clamp now covers its rows, not only the 20px header.
- The release no longer ships the pre-0.7 backup folder.
- Corner resize grip, like a Details! window: drag the grabber on the last
  row's corner (bottom-right, or top-right when rows grow up). Sideways sets
  row width; up/down sets row height. Available whenever Move is (outside
  combat, HUD visible). Targeting clicks pause while resizing and rebind after.
- March of the Dead zombies are not tracked. They walk to an enemy and
  explode, often with no death event, so they used to linger as rows. Zombie
  summons within 1.5 sec of casting March of the Dead (other than known
  Animate: Zombies / Lesser / Greater Zombie summon spells) are ignored and
  blocked from rediscovery through nameplates or combat activity.
- Every Zombie source lasts at most 15 sec, so other Zombie rows now leave
  shortly after that instead of waiting for the 60-second fallback.
- Temporary summons are no longer tracked by default: Zombies, March of the
  Dead, Animate: Skeletal Archer, Rotlings, Muckworms, Bone Construct, Putrid
  Thrall, Bone Wraith, Tomb King, Plaguefather, Frost Wyrm and Animate: Crypt
  Fiend. (Raise: Skeletal Archer is a permanent minion and is always tracked.)
  Turn on "Track temporary summons" under Options > Tracking, or use
  /nm temporary on|off. Turning it off also clears current temporary rows.
- Units the client reports as "Unknown" (not loaded yet, or a stale token
  left after a despawn) no longer count as living minions or name a row.
  They used to keep despawned summons at 100% health indefinitely.
- Automatic nearby health became opt-in (0.7.2 replaces it with a pulse).
- The managed nameplate backup is now saved per character. This client keeps
  nameplate settings per character (each config-cache.wtf), so the old
  account-wide backup could restore one character's preference on another.
  The first Necromancer to log in takes over the old backup; other characters
  no longer restore anything. Characters that were left with friendly plates
  on by an older version can be switched back with Shift-V.
- With automatic health off, health keeps updating without nameplates. NecroMinions remembers each
  minion type's maximum health (per character) from the last real read, so a
  new row starts at that value instead of "HP unknown", and combat-log damage
  and healing update it from there. Estimated values show "~"; any target,
  mouseover or focus read replaces them with exact health. Mouse over one
  minion of a type once to teach it; after that it persists across sessions.
- Fixed live minions disappearing after a new raise. The Life Force cap was
  read without the four capacity passives CR's Life Force bar adds (92123,
  504431, 807494, 680283), so a normal raise looked like going over the cap
  and the oldest minions without a visible unit were retired. With their
  rows gone, combat-log damage to them was ignored until a mouseover.
- Life Force costs now default to CR's own Raise costs: Greater Skeletal
  Warrior 2, Skeletal Mage 2 (1 with Grave Mages), Abomination 3, Crypt
  Fiend 2, Decaying Colossus 3, Skeletal Archer 1, Gargoyle 3, Banshee 2;
  Lesser Skeletal Warrior, Skeletal Rogue and Ghoul 1. Costs still at the old
  guessed defaults update once; costs you set by hand are kept.
- Raise: Skeletal Archer (500332) is tracked as a permanent minion.
- Dismiss Undead clears the HUD like Sacrifice Undead.
- Health is shown as a percentage by default (installs still on the old Auto
  default switch once; a format you chose is kept). Toggle it from the
  right-click menu ("Health as percentage") or pick any format in options.
  The tooltip still shows exact current / max health.
- NecroMinions works entirely on its own: it does not depend on, or talk to,
  any nameplate addon.
- Only active on a Necromancer (class token NECROMANCER). On any other
  character the HUD is hidden, nothing is tracked, and friendly-nameplate
  settings are never changed; a backup left by the Necromancer is restored,
  since those settings are shared by the whole account. Saved settings are
  kept, /nm options still opens, and other /nm commands report "inactive".
- Right-click the Move tab for a menu: Lock HUD, Preview mode, Track
  temporary summons, numbering, health colours, tooltips, grow direction,
  Rescan, Rebuild and All options. When locked the tab reads "Locked" and the
  HUD cannot be dragged or resized; right-click it again to unlock. Also
  /nm lock, /nm unlock, or the "Lock HUD position" option.
- The Move/Locked tab and resize grip only appear while the cursor is over
  the HUD (tab or rows), and stay visible during preview, drags, resizes and
  while the menu is open. Turn off "Show this tab only on mouseover" in the
  menu or options to keep it always visible.
- Fixed: a friendly plate hidden while still fading in recorded alpha 0, so a
  later enemy on that pooled plate was "restored" invisible. Plates are now
  never restored below full opacity from a zero reading.
- Row icons are the game's own spell icons for each minion (Raise: Ghoul,
  Raise: Abomination, Animate: Zombies, etc.), read with GetSpellInfo. The old
  generic icons are only used if the client cannot supply one.
- /nm summons lists the last 12 summon events with their spell IDs and
  whether each was tracked or ignored, to identify unrecognized summons.

Note: Automatic nearby health turns friendly nameplate settings on. They are
only restored by "/nm autohealth off" in a live game, never at logout. Run it
BEFORE uninstalling the addon, or friendly nameplates stay on (and visible).

New in 0.7
- Only recognized Necromancer combat summons enter the HUD. Player ownership
  and pet/guardian flags alone are no longer sufficient proof.
- Books of Conquest/Artisans, guide companions, repair bots, Skeletal Smith and
  other unrecognized utility companions are ignored during summons, combat-log
  discovery, targeting, mouseover, pet updates and nameplate scans.
- Utility summon events cannot change the newest combat minion, extend roster
  settling time or interfere with a genuine Life Force replacement decision.
- Added verified combat summon spell IDs from the local client data, including
  temporary Zombies, Putrid Thrall, Bone Construct, Rotlings, Muckworms, Bone
  Wraith, Tomb King, Plaguefather and Frost Wyrm. Known spell IDs preserve
  identity even when the summoned creature's name is temporarily unavailable.
- Creature-name checks match complete recognized names rather than arbitrary
  substrings. An Animate: prefix alone is insufficient: Animate: Skeletal Smith
  is a repair helper. Verified temporary summons remain free of capacity costs
  and keep their identity/classification through /nm clear.
Use /reload after installing. Utility rows from the old session disappear with
the reload; resummoning or targeting helpers will no longer add them. Existing
saved appearance and Life Force settings are preserved.

Retained 0.6 improvements
- /nm clear preserves temporary-summon classification, spell identity and
  duplicate numbers. Temporary summons cannot become permanent Life Force
  candidates simply because the display was rebuilt.
- Unavailable/zero native health no longer suppresses useful combat-log damage
  and healing estimates. A positive current unit read still takes precedence.
- Background colour and opacity use the same convention throughout the colour
  picker. Changing RGB preserves opacity; Cancel restores the original RGBA.
- A successful native nameplate enumeration skips redundant token scans.
  Unchanged rows reuse geometry, styling, text and targeting attributes.
  Health changes do not rebuild row layout.
- Life Force costs are configurable per character for different builds.
- Saved appearance, costs, anchors and managed nameplate backups are validated.
  Death history keeps compact metadata and minimal duplicate/death guards.
  Every slash command and settings handler observes the shutdown guard.
- A pooled nameplate restores its previous opacity when freshly active again,
  before its new friendly/enemy identity is checked. Inactive cached native
  frames are never dereferenced. Logout makes no native nameplate/CVar calls.

Appearance options: /nm options (or Interface > AddOns > NecroMinions)
- Fresh installs and appearance reset place the HUD near the left edge, above
  the screen's vertical centre, clear of the standard Interface Options panel.
  Existing saved positions are preserved.
- Hold left mouse on the small Move tab to drag the live HUD outside combat;
  preview mode is optional. Summon rows keep their targeting clicks. Targeting
  overlays hide during a drag and realign when released. Entering combat stops
  the drag and saves the current position. The tab hides in combat, with an
  empty army, or when whole-HUD opacity is zero.
- Drag the corner grabber on the last row to resize row width and height.
- Right-click the Move tab for the options menu, including Lock HUD.
  Preview shows sample rows only; your real army keeps being tracked.
- Position, scale, row width/height/spacing and health-bar proportions.
- Whole-HUD opacity, separate from the background colour's opacity.
- Optional combat and out-of-combat opacity multipliers. For example, a master
  opacity of 80% and combat opacity of 50% produce 40% effective opacity.
  The move/preview mode stays visible even when normal opacity is zero.
- Health text: Auto, current/max HP, percentage, both, or hidden. Estimated
  health is marked with ~. Auto adapts to the available bar width.
- Optional green > yellow > red health colours, or a fixed custom colour.
- Optional stable numbers for identical summons. #1, #2, etc. stay attached to
  each minion's GUID while it is tracked, including after /nm clear. Numbers
  are assigned within each summon type and may have gaps after deaths.
- Rows growing upward or downward from the anchor.
- Full-name/health tooltips, including when names are clipped or in combat.
- Reset appearance restores position, scale, colours and display options while
  preserving the tracked army, configured Life Force costs and auto-health.
New appearance options retain the previous look until enabled.

Life Force settings
Match each cost to your spell tooltip for the current build. A cost of 0 means
unknown: that type is excluded from capacity estimates. Unknown types default
to 0 rather than guessing a cost. Known defaults preserve the previous build's
values, including Abomination = 2. These are manual per-character settings;
they do not automatically discover talent-specific spell costs.
Temporary summons remain excluded regardless of the configured cost.

Commands
/nm options        Open settings (also /nm config).
/nm change         Move and preview the display outside combat.
/nm resetui        Reset appearance without clearing tracked minions.
/nm refresh        Rescan accessible minions.
/nm clear          Rebuild from currently detectable living minions.
/nm autohealth on  Enable automatic nearby nameplate health (off by default).
/nm autohealth off Disable it and restore managed nameplate preferences.
/nm status         Counts, free/max Life Force and last removal reason.
/nm trace          Up to 12 recent removal reasons for diagnosis.
/nm summons        Up to 12 recent summon events with spell IDs.
/nm temporary on   Track temporary summons (off by default; also in options).
/nm lock | unlock  Lock or unlock the HUD position (also in the right-click menu).

Retained tracking and targeting corrections
A matching current unit token with positive health takes precedence over owner
auras and Life Force estimates. Owner aura counts alone do not define row
counts. Missing nameplates and movement alone cannot rearm replacement cleanup.
Capacity cleanup belongs to a unique permanent summon or an explicit build
change, with bounded settling time and protection for observed living units.
Confirmed deaths and successful Sacrifice Undead still remove their rows.
/nm clear remembers ownership but only rebuilds rows from current living unit
evidence. Dead/sacrificed GUID guards prevent stale events from resurrecting rows.

Each row targets a current unit token matching its own GUID and rechecks that
identity at click time. It never falls back to a shared creature name. The
secure macro uses /target TOKEN, without the client's unreliable unit attribute.
Target clicks are available outside combat. Tracking/tooltips continue in combat.

Automatic health and shutdown
Automatic health temporarily enables friendly guardian/pet nameplate CVars to
obtain readable unit tokens. Extra friendly world plates are hidden when the
original friendly-nameplate preference was off. Original values remain saved
at logout because native frame/CVar calls are unsafe during client teardown.
Use /nm autohealth off in a live game to restore them safely. A fresh login
with auto-health disabled also restores a deferred backup.

Installation
Extract the NecroMinions folder into Interface/AddOns. Keep all five runtime
files together: NecroMinions.toc, NecroMinionsConfig.lua, NecroMinionsClient.lua,
NecroMinionsOptions.lua and NecroMinions.lua. Appearance settings use the
account-wide NecroMinionsDB; Life Force costs use per-character NecroMinionsCharDB.
Start the game normally, or /reload if it was already running.

Validation
0.7.1 changes were reviewed and structure-checked but not run against the
mocked-client suite (it is not included in this package) or in the game.
For 0.7: 113 Lua 5.1 mocked-client scenarios pass, covering refresh/clear/sacrifice/replacement
cases, individual targeting, combat and shutdown safety, temporary metadata,
unavailable-health estimates, colour-picker opacity/cancel, new UI controls,
layout-call caching, configurable costs, saved data and compact death history.
They also cover default/saved placement, live dragging, targeting realignment,
combat interruption, drag callback shutdown guards and right-click preview exit.
Utility filtering is exercised through summon events, combat flags and owned
unit scans, with valid combat-spell IDs, missing-name recovery, temporary costs
and replacement-state isolation covered separately.
Mock API-call profiling confirms fewer redundant nameplate probes, not native
FPS results. The new interface layout and pooled nameplate restoration still
need testing in the actual game. Live testing is left to the user as requested.
No game executable, DLL or archive is changed by this update.
