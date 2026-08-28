# MikScrollingBattleText (MSBT) — Midnight

**A community-maintained restoration of Mik's Scrolling Battle Text for World of Warcraft: Midnight (patch 12.1).** Original addon by Mikord. This fork targets retail 12.x.

MSBT is a lightweight, highly configurable replacement for Blizzard's floating combat text: incoming/outgoing damage and heals, notifications, and alerts scroll through separate, dynamically creatable scroll areas.

## Midnight status

Midnight (12.0) removed addon access to the combat log and made most combat data "secret" in combat, encounters, M+, and PvP. MSBT has been rebuilt around the remaining sanctioned feeds (`UNIT_COMBAT`, `COMBAT_TEXT_UPDATE`, `PARTY_KILL`).

**Works:**
- Incoming/outgoing damage, misses, and crits with damage-school coloring
- Incoming heals (crit, HoT, and absorb variants; self-heals routed separately)
- Player buff/debuff gain & fade notifications (where names aren't secret — typically out of combat / open world)
- Power gains; combo point / Chi / Holy Power / Arcane Charge / Essence changes and FULL alerts; enter/leave combat
- Killing blows; low health/mana/pet-health threshold triggers (with Blizzard-threshold fallback events where values are secret); aura-proc triggers (e.g. Clearcasting) by skill name
- DoT/HoT ticks named via guarded aura lookups where auras aren't secret; ground-effect (Consecration, Healing Rain, …) attribution while active
- Loot, money, reputation, XP, honor, and skill-up notifications (outside instances)
- Cooldown completion alerts (out of combat)
- Full customization: scroll areas, fonts, colors, animation styles, per-event output formats, icons, sounds

**Degraded (API secrecy — the addon adapts automatically):**
- Enemy names/classes in combat and instanced content display generically
- AoE merging and spam throttles auto-disable where amounts are secret
- Outgoing damage spell attribution uses recent-cast correlation plus ground-effect/aura fallbacks (approximate)
- Cooldown alerts pause in combat
- Execute-style (target health %) triggers may not fire in combat

**Cut (no sanctioned API remains):**
- Outgoing heals to other units; enemy buff gains; item buffs/enchants; dispel/steal alerts; power-loss (drain/leech) events; environmental typing; aura stack-count triggers; `skillID`-based trigger conditions
- Chat-parsed notifications (loot/rep/XP/honor) are silent inside instances, where chat is secret

Technical write-ups, phase plans, and the in-game test guide: [docs/midnight-12.1/](docs/midnight-12.1/README.md).

## Commands

```sh
/msbt	        Shows the options interface.
/msbt reset	    Resets the current profile to the default settings.
/msbt disable	Disables the mod.
/msbt enable	Enables the mod.
/msbt version   Shows the current version.
/msbt help	    Shows the command usage.
```

## Installation

1. Download the zipped addon from the [releases page](https://github.com/Placidina/MikScrollingBattleText/releases).
2. Extract and place the `MikScrollingBattleText` and `MSBTOptions` folders in `World of Warcraft/_retail_/Interface/AddOns/`.
3. Enable both in the addon list.

## For mod developers

The display-side API is unchanged in Midnight — output your own scrolling messages with `MikSBT.DisplayMessage`, register custom fonts/sounds, and create custom animation styles. See [API.md](MikScrollingBattleText/API.md).

## License & attribution

Original MSBT © Mikord, all rights reserved. This is an unofficial community restoration; prior-art credit in [docs/midnight-12.1/](docs/midnight-12.1/README.md).
