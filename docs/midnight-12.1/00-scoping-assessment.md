# MSBT → WoW Midnight 12.1: Scoping Assessment

**Date:** 2026-08-27
**Status:** Assessment complete — feeds the phase plans in this directory
**Target:** World of Warcraft Midnight, patch 12.1 (TOC interface `120100`)

---

## 1. Current state of this repo

MSBT 5.9.4 (Placidina fork lineage): a MoP-era core with partial 11.0.2 shims added in 2024 and a "% of target max HP" feature merged Aug 2025. Both TOCs declare `## Interface: 100200`.

Architecture:

- `MikScrollingBattleText/MSBTParser.lua` — the heart. Registers `COMBAT_LOG_EVENT_UNFILTERED` (`:899`), reads the payload via `CombatLogGetCurrentEventInfo()` (`:821`), normalizes events into a `parserEvent` table (`ParseLogMessage` `:370`, per-event capture closures `:630-702`), and fans out to registered handlers (`SendParserEvent` `:177`). Also parses `CHAT_MSG_*` events via global-string-derived Lua patterns (`CreateSearchMap` `:473`).
- `MikScrollingBattleText/MSBTMain.lua` — event dispatch and business logic; `ParserEventsHandler` (`:1114`) maps parser events to display events (`:1506-1520`).
- `MikScrollingBattleText/MSBTAnimations.lua` + `MSBTAnimationStyles.lua` — display engine. Pooled FontStrings/Textures, master OnUpdate at 66 Hz, 5 self-registered animation styles. **Combat-data-agnostic.**
- `MikScrollingBattleText/MSBTTriggers.lua` — trigger engine over combat subevents + `UNIT_HEALTH`/`UNIT_POWER_UPDATE` thresholds + aura exceptions.
- `MikScrollingBattleText/MSBTCooldowns.lua` — spell/pet/item cooldown completion alerts.
- `MikScrollingBattleText/MSBTLoot.lua` — loot/money/currency alerts via chat parsing.
- `MikScrollingBattleText/MSBTProfiles.lua` — saved variables and defaults; **two full copies of the default profile** (Classic `:171-1635`, retail `:1636-3113`).
- `MSBTOptions/` — load-on-demand, fully custom options UI (no XML frames, no Ace).
- Embedded libs: LibStub, CallbackHandler-1.0 (current), LibSharedMedia-3.0 (2019-era r128). Framework-free otherwise.

## 2. The Midnight wall — why this is not a normal version bump

Sources: [Patch 12.0.0 API changes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes), [Blizzard's planned API changes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/Planned_API_changes), [Secret Values](https://warcraft.wiki.gg/wiki/Secret_Values), [Patch 12.1.0 API changes](https://warcraft.wiki.gg/wiki/Patch_12.1.0/API_changes), [Blizzard's 12.1 aura post](https://www.wowhead.com/news/addon-changes-in-patch-12-1-custom-aura-trackers-with-addons-382338).

- **Forced interface matching:** addons with `## Interface` below `120000` refuse to load at all — no "load out of date" override. 12.1's TOC value is `120100`.
- **Combat log events are gone:** registering `COMBAT_LOG_EVENT` / `COMBAT_LOG_EVENT_UNFILTERED` errors; `CombatLogGetCurrentEventInfo` is removed. This kills MSBT's core input outright — all of `MSBTParser.lua`'s CLEU path, plus CLEU consumers in `MSBTCooldowns.lua:319-321,360` and `MSBTTriggers.lua:272,286,300,322,435,822-823`.
- **Secret Values:** in combat / encounters / M+ / PvP, unit health, power, names, GUIDs, auras, and cooldowns return *secret* values. Tainted code may store, pass, concatenate, and `string.format` them — but **not compare, do arithmetic, measure length, index, or use them as table keys**. Violations are immediate Lua errors. This amputates MSBT's *logic* layer: AoE merging, throttle windows, crit detection, % calculations, trigger thresholds.
- **Chat is secret in instances** and combat-log chat messages are unparsable KStrings → `MSBTLoot.lua` and the chat-parsed notifications (rep, XP, honor, skill-ups, `MSBTParser.lua:473-498`) degrade inside dungeons/raids.
- **12.1 specifically:** all `UnitAura` APIs return secrets or nil when restricted; sanctioned aura *display* path is the new `AuraContainer`/`AuraButton` intrinsic frames; `getglobal`/`setglobal` deprecated; new interface texture filenames stop being published (existing ones keep working); `SPELL_UPDATE_COOLDOWN` gains an `itemID` payload.

## 3. Feature-by-feature impact

| MSBT feature | 12.1 status | Path forward |
|---|---|---|
| Display/animation engine | **Survives intact** | No data dependency; only API sanitation |
| Incoming damage/heals/misses | **Rebuildable** | `COMBAT_TEXT_UPDATE` + `C_CombatText.GetCurrentEventInfo()` (§4) |
| Notifications (player auras, power gains, enter/leave combat, low health/mana) | **Mostly rebuildable** | Same feed: `SPELL_AURA_START/END`, `ENERGIZE`, `HEALTH_LOW`, `MANA_LOW`, `ENTERING_COMBAT` |
| Combo points / Chi / Holy Power / etc. | **Survives** | Player secondary resources are non-secret; `UNIT_POWER_UPDATE` still fires |
| Killing blows | **Rebuildable** | New standalone `PARTY_KILL`, `UNIT_DIED`, `PLAYER_TARGET_DIED` events |
| Outgoing damage to enemies | **At risk** | No sanctioned per-hit outgoing feed; options: health-delta correlation (breaks under secrecy) or `C_DamageMeter` — main open research item |
| AoE merging / spam throttles on amounts | **Mostly dead in restricted content** | Requires arithmetic/comparison on secret numbers |
| Triggers on combat events / aura procs | **Largely dead in combat** | Aura data secret/nil; 12.1 Aura Containers are display-only, not alert logic |
| Cooldown completion alerts | **Partial** | Cooldown math secret in combat; charge-based spells work per prior art |
| Loot / money / currency alerts | **Partial** | New `UNIT_LOOT` event may help; chat parsing fine outside instances |
| Class-colored names / name display | **Degrades** | `UnitName` secret for non-party units in combat; `UnitNameFromGUID`/`UnitClassFromGUID` exist but secret-gated |
| Options UI | **Survives, needs fixes** | §5 |

## 4. The replacement core

Blizzard's own floating combat text (`Blizzard_CombatText` in the 12.x UI source) shows the sanctioned pattern:

```lua
-- on COMBAT_TEXT_UPDATE:
data, arg3, arg4 = C_CombatText.GetCurrentEventInfo()  -- amount/spellname, secondary, crit-or-absorb
messageType = arg1                                      -- e.g. "DAMAGE", "SPELL_DAMAGE_CRIT", "HEAL"
```

The event's ~40 message types (`DAMAGE`, `DAMAGE_CRIT`, `SPELL_DAMAGE`, `HEAL`, `HEAL_CRIT_ABSORB`, `PERIODIC_HEAL`, `ENERGIZE`, `COMBO_POINTS`, `SPELL_AURA_START(_HARMFUL)`, `SPELL_AURA_END(_HARMFUL)`, `HEALTH_LOW`, `MANA_LOW`, `ENTERING_COMBAT`, `LEAVING_COMBAT`, `INTERRUPT`, `EXTRA_ATTACKS`, `DAMAGE_SHIELD`, `SPLIT_DAMAGE`, `FACTION`, `HONOR_GAINED`, `ABSORB_ADDED`, `SPELL_DISPELLED`, …) map well onto MSBT's event catalog. Watched unit is controlled via `C_CombatText.SetActiveUnit`.

**Critical design constraint:** the formatting pipeline must be secret-safe — values flow through `string.format`/concatenation straight into `FontString:SetText` with zero branching on their contents. Gate richer logic behind `issecretvalue()`/`canaccessvalue()` and `C_Secrets.*`/`GetRestrictedActionStatus` so full logic still runs when values are plain (out of combat, open world).

## 5. Mechanical debt to fix regardless of strategy

- `MSBTCooldowns.lua:468` — `hooksecurefunc("UseItemByName", …)` on a removed global; errors at file load, kills the whole module.
- Unshimmed removed globals: `GetItemInfo` (`MSBTCooldowns.lua:90,132,243,441`), `GetSpellTexture` (`MSBTCooldowns.lua:92`), `GetItemClassInfo` (`MSBTLoot.lua:39`), `UnitBuff` (`MSBTTriggers.lua:216-217`) → `C_Item.*` / `C_UnitAuras.*` where they exist.
- 11.0.2 shim bug: `MSBTCooldowns.lua:162,187` test `enabled == 1`, but the shimmed return is boolean — player/pet cooldown alerts silently dead since that patch.
- Old `ColorPickerFrame` API (`MSBTOptionsControls.lua:1767-1805`) — removed in 10.2.5, already broken on 11.x; replace with the modern picker.
- Raw numeric sound-kit IDs (~8 sites: `MSBTOptionsMain.lua:145`, `MSBTOptionsPopups.lua:114,135`, `MSBTOptionsControls.lua:196,206,610,779`) → `SOUNDKIT.*`.
- `VARIABLES_LOADED` bootstrap (`MSBTProfiles.lua:3708,3739`) — legacy; move to `PLAYER_LOGIN`/`ADDON_LOADED`.
- Audit ~20 legacy texture paths in the options UI (silent green-box breakage on modern clients).
- Bump embedded LibSharedMedia-3.0 (embedded copy is 8.2-era r128).
- Decide fate of the duplicated Classic profile branch in `MSBTProfiles.lua` — every profile change is currently written twice.

## 6. Prior art

- [Wyveryx/MSBT](https://github.com/Wyveryx/MSBT) — WIP "Midnight Restoration" fork: rewrote the combat engine without CLEU ("Unit Correlation Engine"), fixed secret-value crashes, restored low-health/execute alerts; cooldowns and restricted-content names are known gaps.
- [MikScrollingBattleText (Midnight) on CurseForge](https://www.curseforge.com/wow/addons/mikscrollingbattletext-midnight) — revived build, actively maintained (last update 2026-08-25).
- **License caveat:** original MSBT is all-rights-reserved by Mikord. Verify the license position of any fork before lifting code; studying approaches is always fine.
- **Decision (2026-08-27):** use the CurseForge Midnight build as *inspiration*, but it is not supported enough to adopt — this repo takes over the work independently.

## 7. Phasing (each has a plan doc in this directory)

1. **Phase 0 — load blocker (hours):** TOC → `120100` both addons; fix load-time errors. Deliverable: addon loads, `/msbt` opens.
2. **Phase 1 — API sanitation (1–2 days):** mechanical replacements from §5, color picker, sound kits, lib bump.
3. **Phase 2 — new ingestion core (the bulk):** `COMBAT_TEXT_UPDATE`-based parser behind the existing `parserEvent` abstraction; secret-safe formatting; killing blows; loot.
4. **Phase 3 — feature triage:** triggers, cooldowns, merging — per-feature legality under secrecy; graceful degradation via `C_Secrets`; hide dead options.
5. **Phase 4 — polish/release:** options cleanup, docs (`API.html` is ancient), packaging.

## 8. Open questions to validate in-game (PTR/live)

- Whether/when `COMBAT_TEXT_UPDATE` payloads are secret; confirm `FontString:SetText` accepts secrets in all restriction states.
- Whether any sanctioned outgoing-damage feed exists (`C_DamageMeter` granularity) — decides the fate of the outgoing scroll area.
- `UNIT_LOOT` payload shape and secrecy.
- Whether `bit.*` and global `unpack` still ship in 12.1.
- Exact `AuraContainer`/`AuraButton` rules (12.1) if aura-style notifications are to return.
- Iterative relaxations landed in 12.0.1 / 12.0.5 / 12.0.7 — read those blue posts before finalizing Phase 2/3 designs.

## Bottom line

Not a version bump — a partial rewrite. The parser core and trigger/cooldown logic were designed around data sources that no longer exist. The display engine, options UI, and event-dispatch abstraction survive; Blizzard's own combat text proves a sanctioned feed exists; prior art has prototyped the hard part. Realistic shape: ~70% of the value (incoming text, notifications, power, kills, low-health alerts) is recoverable quickly; outgoing text and smart triggers are the lossy tail.
