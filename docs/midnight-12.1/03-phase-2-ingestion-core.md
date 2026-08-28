# Phase 2 — Ingestion Core Rewrite

**Goal:** restore scrolling combat text without the combat log. Replace the CLEU-based parser with sanctioned 12.x feeds, emitting the same normalized `parserEvent` shape so `MSBTMain`'s dispatch, per-event settings, scroll areas, and existing user profiles keep working.

**Effort:** the bulk of the project (multi-day). **Depends on:** Phase 0. **Informs:** Phase 3.
**Status:** Implemented 2026-08-27 — in-game validation pending (see test matrix).

## Design: data sources

| Source | Payload | Feeds | Secrecy notes |
|---|---|---|---|
| `UNIT_COMBAT` | `unitTarget, event, flagText, amount, schoolMask` — event ∈ `WOUND/HEAL/MISS/DODGE/PARRY/BLOCK/RESIST/ABSORB/…`, flagText ∈ `CRITICAL/CRUSHING/GLANCING` | Incoming **and** outgoing damage/heal/miss amounts (fires for any valid unit token, incl. `nameplateN` → outgoing) | Amount/names may be secret in restricted content; display still possible (see rules) |
| `UNIT_SPELLCAST_SUCCEEDED` | `unit, castGUID, spellID` | Ring buffer of recent player/pet casts → correlate spell name/icon onto `UNIT_COMBAT` amounts ("Unit Correlation Engine", per prior art; short time window) | `spellID` may be secret in restricted content → degrade to generic text |
| `COMBAT_TEXT_UPDATE` + `C_CombatText.GetCurrentEventInfo()` | `arg1` = messageType (~40 types); call returns `(data, arg3, arg4)` = amount/spellname, secondary, crit-or-absorb | Player-centric typed feed: crit/absorb detail, player auras (`SPELL_AURA_START/END`), power gains (`ENERGIZE`, `COMBO_POINTS`), `HEALTH_LOW`/`MANA_LOW`, `ENTERING/LEAVING_COMBAT`, `INTERRUPT`, `EXTRA_ATTACKS`, `HONOR_GAINED`, `FACTION`. Blizzard's own FCT runs on exactly this. | Payload secrecy per context must be measured (test matrix below) |
| `PARTY_KILL`, `UNIT_DIED`, `PLAYER_TARGET_DIED` | unit/GUID (secret in restricted content) | Killing-blow notifications | Type-only display ("Killing Blow!") when GUID secret |
| `UNIT_POWER_UPDATE` | unit, powerType | CP/Chi/Holy Power/Essence gains & full | Player **secondary** resources are non-secret (primary stay secret) |
| `UNIT_LOOT` + `CHAT_MSG_LOOT/MONEY/CURRENCY` | structured event + chat strings | Loot/money/currency alerts | Chat strings secret in instances — guard with `issecretvalue` before `string.match`; prefer `UNIT_LOOT` where it covers the case |

Architecture: keep one parser frame and the `parserEvent`/`SendParserEvent()` fan-out in `MSBTParser.lua`; swap the CLEU capture closures (`:630-702`) for per-source translators that fill the same fields (`eventType`, `amount`, `damageType`/school, `isCrit`, `skillName`/`skillID`, `sourceName`/`recipientName`, miss types, partial effects where available). `MSBTMain.ParserEventsHandler` (`MSBTMain.lua:1114`) and the display engine should need **no** changes.

## Non-negotiable rule: secret-safe pipeline

Secret values may be stored, passed, concatenated, and `string.format`-ed — never compared, arithmetized, length-measured, indexed, or used as table keys (immediate Lua error). Concretely:

- [ ] Every value arriving from a game API is treated as possibly-secret: format text via `string.format`/concat and hand straight to `FontString:SetText`; **branch on contents only behind `issecretvalue()` guards**.
- [ ] School-coloring, merge windows, throttles, crit amplification, % calculations run only when `not issecretvalue(amount)`; otherwise emit plain formatted text.
- [ ] Names: `UnitName`/`UnitNameFromGUID` secret → fall back to generic labels (prior art uses `"Enemy"`); never key tables by possibly-secret names/GUIDs.
- [ ] SavedVariables must never contain secrets — audit anything written to `MSBTProfiles_SavedVars`.

## Tasks

- [x] **Parser skeleton:** kept the GUID→unit map for party/raid; nameplate-unit bookkeeping turned out unnecessary because `UNIT_COMBAT` carries the affected unit token directly. Added secrecy guards to the mouseover/target/arena class-map branches (`MSBTParser.lua` OnEvent). — *done 2026-08-27*
- [x] **`UNIT_COMBAT` translator:** `ParseUnitCombat` (`MSBTParser.lua:445`) maps `WOUND`→damage, miss family→miss with missType, `flagText`→crit/glancing/crushing, `schoolMask`→damage-type coloring. *Deviation:* `HEAL` is **not** taken from UNIT_COMBAT — incoming heals come from CTU (typed, with crit/absorb), and outgoing heals can't be attributed on this feed (cut, see decisions).
- [x] **Cast correlation:** `UNIT_SPELLCAST_SUCCEEDED` ring buffer (`TrackSpellCast`/`CorrelateCast`, 1.2 s window, 10 entries) attaches spellID/name to outgoing wounds; secret spell IDs are skipped.
- [x] **CTU translator:** `ParseCombatTextUpdate` (`MSBTParser.lua:527`) handles player auras (`SPELL_AURA_START/END[_HARMFUL]` → buff/debuff gain/fade), incoming heals (all 8 `HEAL` types), power gains (`ENERGIZE`/`PERIODIC_ENERGIZE` → token→`Enum.PowerType` map), `INTERRUPT`, `EXTRA_ATTACKS`; `C_CombatText.SetActiveUnit("player")` at Enable. Damage/miss types deliberately skipped (UNIT_COMBAT owns them); `FACTION`/`HONOR_GAINED`/`HEALTH_LOW`/etc. skipped to avoid duplicating existing paths.
- [x] **Killing blows:** `ParsePartyKill` (`MSBTParser.lua:613`) — `attackerGUID == playerGUID`, victim classified PC/NPC by GUID prefix, name via `UnitNameFromGUID`; silently skipped when GUIDs are secret (restricted content). `UNIT_DIED`/`PLAYER_TARGET_DIED` not needed.
- [~] **Loot module rewiring:** chat parsing kept with a secrecy guard at `ParseSearchMessage` (secret chat in instances can't be pattern-matched). **`UNIT_LOOT` investigated and dropped: its payload is `unitGUID, hasLoot` — a "corpse has loot" ping, not looted-item data.** Loot/money/currency alerts work outside instances only (12.x limitation).
- [x] **Merge/throttle subsystems:** `ParserEventsHandler` forces direct display when `parserEvent.amount` is secret; `FormatEvent` skips shorten/group and splices `%a` via plain find+concat for secret amounts; damage/heal/power threshold checks skip secrets (show unthresholded). — *done 2026-08-27*
- [ ] **Test matrix run** (below). — *pending in-game*

### Additional implementation decisions (2026-08-27)

- **Removed, not just gated:** `ParseLogMessage`, `CreateCaptureFuncs`, `CreateFullParseList`, reflect tracking, and the CLEU registration/handler in `MSBTParser.lua` are deleted (CLEU never returns). The parser no longer references `MikSBT.CLEU_AVAILABLE`; the gate remains for `MSBTTriggers`/`MSBTCooldowns` until Phase 3. Dead CLEU-era leftovers kept for now (Obliterate/Stormstrike locals, `FLAGS_MINE`, unit-map builder) — Phase 4 cleanup.
- **MSBTTriggers impact:** with `MSBTParser.captureFuncs` gone, combat-subevent trigger `mainEvents` (e.g. `SPELL_DAMAGE`) fall through to raw event registration (inert, mostly nonexistent event names — no errors). Triggers are dispositioned wholesale in Phase 3.
- **Outgoing attribution caveat:** UNIT_COMBAT reports the victim, not the attacker — damage to other units is attributed to the player (pre-2.4 SCT semantics; approximate in groups/multi-target).
- **Lost distinctions in this feed:** DoT vs direct and HoT vs direct (no periodic flag) — periodic ticks display as `_DAMAGE`/`_HEAL` (CTU heals keep their `_HOT` variants); incoming events have no attacker name; swing vs spell on outgoing requires a correlated cast.
- **No sanctioned feed found for:** enemy buff gains (`NOTIFICATION_ENEMY_BUFF`), enchants/item buffs, dispels/steals, power *loss* (drain/leech), environmental *typing* (environmental damage may surface as generic incoming `WOUND`). Phase 3 dispositions.
- **Also guarded for secrecy:** `UNIT_POWER_UPDATE` power amounts (primary power secret in combat), `CHAT_MSG_MONSTER_EMOTE` (message/name), trigger `UNIT_HEALTH`/`UNIT_POWER_UPDATE` handlers.

## Acceptance criteria

- [ ] Incoming damage/heals/misses scroll with correct school colors and crit styling, in open world **and** inside a dungeon/raid, with zero secret-value Lua errors.
- [ ] Outgoing amounts scroll for the current target and nameplate units; degrade to generic (no spell name) in restricted content without errors.
- [ ] Notifications work: power gains, enter/leave combat, low health/mana, killing blows, loot (outside instances at minimum).
- [ ] Per-event settings (scroll area, colors, font, output message) apply to the new feed unchanged on an existing profile.
- [ ] `/msbt` event test/preview functions still work.

## Test matrix (run in-game for every row)

| Context | Expected |
|---|---|
| Open world, out of combat | Full data (names, spell names, icons, amounts) — logic paths live |
| Open world, in combat | Per `C_Secrets` predicates; verify which values turn secret |
| Dungeon/raid encounter | Heaviest restriction: names/GUIDs/cooldowns/auras secret; display-only path |
| M+ run / PvP match | Same class as encounter; verify chat-secrecy guards on loot |
| `/console addonChatRestrictionsForced 1` | Dev-forced lockdown for quick regression checks |

## Open questions (validate before finalizing)

- Exact secrecy of `COMBAT_TEXT_UPDATE` payloads per context — decides how much crit/absorb logic survives in combat. *(Code ships with issecretvalue guards on every field, so either behavior is safe; this only affects richness.)*
- ~~`UNIT_LOOT` payload shape/secrecy~~ — **resolved 2026-08-27:** payload is `unitGUID, hasLoot` (corpse-lootable ping); useless for loot alerts. Loot stays chat-based with secrecy guards (works outside instances).
- `C_DamageMeter` granularity — last resort for an outgoing-damage approximation; investigate only if UNIT_COMBAT proves insufficient in practice.
- CTU watched-unit semantics (`SetActiveUnit`) — assumed `"player"`; verify on client whether it can follow other units for outgoing detail (heals on target, etc.).
- Whether `UNIT_COMBAT` fires for environmental damage on the player (would surface as generic incoming damage without hazard typing).

## References

- [12.0.0 API changes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes) · [Secret Values](https://warcraft.wiki.gg/wiki/Secret_Values) · [12.1.0 API changes](https://warcraft.wiki.gg/wiki/Patch_12.1.0/API_changes)
- Blizzard's `Blizzard_CombatText` (12.x UI source) — canonical CTU usage.
- [Nakuromi/MSBT](https://github.com/Nakuromi/MSBT) — UNIT_COMBAT + cast-correlation prior art (inspiration only; see license note in [README](README.md)).
