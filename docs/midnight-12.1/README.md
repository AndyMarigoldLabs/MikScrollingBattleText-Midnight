# MSBT — Midnight 12.1 Update: Roadmap

MSBT 5.9.4 (interface `100200`) does not load on WoW Midnight: 12.0 hard-blocks addons below interface `120000`, removes the combat log event stream, and makes most combat data "secret" in restricted content. This directory holds the assessment and the phase plans for the rewrite.

| Doc | Purpose | Status |
|---|---|---|
| [00-scoping-assessment.md](00-scoping-assessment.md) | What breaks, what survives, why | Done (2026-08-27) |
| [01-phase-0-load-blockers.md](01-phase-0-load-blockers.md) | Make the addon load on 12.1 | Implemented 2026-08-27; in-game smoke test pending |
| [02-phase-1-api-sanitation.md](02-phase-1-api-sanitation.md) | Replace removed/deprecated APIs | Implemented 2026-08-27; in-game verification pending |
| [03-phase-2-ingestion-core.md](03-phase-2-ingestion-core.md) | Rebuild combat-data ingestion without CLEU | Implemented 2026-08-27; in-game validation pending |
| [04-phase-3-feature-triage.md](04-phase-3-feature-triage.md) | Triggers, cooldowns, merging: keep / rework / cut | Implemented 2026-08-27; in-game validation pending |
| [05-phase-4-release-polish.md](05-phase-4-release-polish.md) | Options cleanup, docs, packaging, release | Safe subset done 2026-08-27; rest awaits in-game validation |

Phases 0–1 are sequential prerequisites. Phase 2 is the core rewrite and can start as soon as Phase 0 lands. Phase 3 overlaps late Phase 2. Phase 4 wraps up.

## Decision log

- **2026-08-27 — Independent takeover.** The CurseForge build [MikScrollingBattleText (Midnight)](https://www.curseforge.com/wow/addons/mikscrollingbattletext-midnight) and the [Nakuromi/MSBT](https://github.com/Nakuromi/MSBT) fork prove a ~85% restoration is possible, but they are not maintained deeply enough for our needs. We rewrite in this repo, using them as inspiration only. Original MSBT is all-rights-reserved by Mikord — verify license position before reusing any third-party code.
- **2026-08-27 — Preserve the `parserEvent` contract.** The display engine (`MSBTAnimations.lua`) and dispatcher (`MSBTMain.ParserEventsHandler`) are source-agnostic. New ingestion feeds emit the same normalized event shape so downstream code and user profiles keep working.
- **2026-08-27 — Phases 0–3 implemented.** Load blockers, API sanitation, ingestion rewrite (`UNIT_COMBAT` + cast correlation + `COMBAT_TEXT_UPDATE` + `PARTY_KILL`), and feature triage including aura-trigger restoration via parser events. All pending in-game validation per the testing guide below.
- **2026-08-27 — Classic profile branch kept.** The duplicated Classic defaults in `MSBTProfiles.lua` are inert data under a retail-only TOC; removal is Phase 4 cleanup if ever needed.
- **2026-08-27 — 12.0.1/12.0.5/12.0.7 blue posts reviewed.** Findings folded in: cooldown APIs expose non-secret `isActive`/`isEnabled`/`maxCharges` (in-combat cooldown completion restored via an `isActive` state machine in `MSBTCooldowns.lua`; item cooldowns still pause), and Blizzard flags many rotational spells/long buffs as non-secret (aura triggers should fire in combat more often than originally predicted). No structural breakage found in them.
- **2026-08-27 — Offline verification pass.** All 25 registered event names, every `Enum.PowerType` member used, all hooked/unit/currency/container APIs, and all 22 chat-parsing global strings (enUS) were verified against the 12.x interface dumps; the module enable/disable chain (`SetOptionUserDisabled` → Main→Parser→Triggers→Cooldowns, Loot always-on) was re-confirmed end to end; all 33 Lua files pass a parser check; profile migration needs no code (differential defaults fall through cleanly from 5.9.4 profiles).
- **2026-08-27 — Enhancement round (post-implementation, pre-live-validation).** Landed: dead roster unit-map builder removed (class-map maintenance preserved via `rosterGUIDs`/`rosterPetGUIDs`); cast buffer clears on mount/shapeshift/summon casts; ground-effect persistence table (Consecration, Healing Rain, etc.) extends correlation past the 1.2 s window; periodic ticks get spell names via guarded aura iteration (`C_UnitAuras.GetAuraDataByIndex` + non-secret `isFromPlayerOrPlayerPet`, no duration/secret math — safe under 12.1, unlike prior art's version), restoring `_DOT`/`_HOT` routing and names where auras aren't secret; new `NOTIFICATION_LOW_HEALTH`/`NOTIFICATION_LOW_MANA` events fed by CTU `HEALTH_LOW`/`MANA_LOW`, **emitted only when player vitals are secret** so they can't double up with the UNIT_HEALTH/UNIT_POWER_UPDATE triggers. Resolved the `C_DamageMeter` open question: sessions are aggregates (per-source → per-spell totals) and the whole table is secret in combat — useless for per-hit scrolling text; UNIT_COMBAT + correlation remains the best available outgoing feed.
- **2026-08-27 — Re-validated against live 12.1.** Confirmed zero reliance on 12.0.x-only behavior: 12.1.0 removed none of the APIs/events we use (its only event removals are Battle.net/housing; `CHAT_MSG_*`/`SPELL_UPDATE_COOLDOWN` changes are additive); the interface dumps used for verification are provably ≥12.1 (contain 12.1-added events); all load-bearing APIs (`C_CombatText.*`, `C_Secrets.*`, `issecretvalue`, `UnitNameFromGUID`, `C_Spell.GetSpellCooldown` incl. the `isActive`/`isEnabled` struct fields, `C_Item.*`, `C_UnitAuras.*`) exist in the live 12.1 dumps; 12.1's aura clampdown (`UnitAura` secrets/nil, AuraContainer/Button) touches only our pcall-guarded `buffActive` path; 12.1 deprecations (`getglobal`/`setglobal`, `UIParentLoadAddOn`) are unused by us. No 12.1.5 API page exists at validation time — 12.1.0 is the current surface.
- **2026-08-27 — Differential validation against Nakuromi/MSBT (prior art running on live 12.0.x).** Feed choices confirmed sound; one robustness fix landed (`flagText` matched by substring — compound flags like critical-blocks occur in practice). Deliberate divergences: we keep pet-specific incoming events (theirs misroutes pet damage as outgoing), we show all outgoing wounds (theirs drops non-correlated ones, losing melee swings), we use CTU for typed player events (they don't use it at all). Not adopted: their DoT/HoT tick naming via `C_UnitAuras.GetAuraDataByIndex` iteration (does arithmetic on possibly-secret aura fields — errors under 12.1's aura clampdown), their hardcoded ground-effect spell table, and their mount/form cast-buffer clearing heuristic (both candidates for a later enhancement pass). **Watch item:** MSBT's `DisableBlizzardCombatText` zeroes the FCT CVars (`enableFloatingCombatText` etc.) — Blizzard's own consumer filters CTU messages in Lua *after* the event fires, so the feed should be CVar-independent, but if incoming heal/aura/power notifications are totally absent in live testing, re-enable those CVars first to isolate the cause.
- **2026-08-28 — First live validation pass; one error class found and fixed.** In-game testing showed general function but a repeating Lua error on incoming heals with secret amounts (182x "attempt to perform string conversion on a secret string value"). Root cause: `FormatEvent` (`MSBTMain.lua`) spliced the secret `%a` amount into the message *first*, turning `message` itself into a secret string, after which every remaining `string.find`/`gsub` substitution (`%n`, `%e`, `%s`, paren cleanup, `%t`) errored. Fix: `%a` substitution now runs last, after all pattern work. Same path also covers secret power-gain amounts. New watch item: `MSBTAnimationStyles.lua:682` calls `fontString:GetStringWidth()` (horizontal animation style only) — unverified against secret text; check if horizontal scrolling is used in restricted content.

## Prior-art notes (from Nakuromi/MSBT v6.0.3-12.0.1)

- Ingestion via `UNIT_COMBAT` (per-unit damage/miss/heal amounts, incl. nameplate units for outgoing) + `UNIT_SPELLCAST_SUCCEEDED` ring buffer for spell-name/icon correlation ("Unit Correlation Engine"). They do **not** use `COMBAT_TEXT_UPDATE`.
- Their stated gaps: triggers disabled, buff/debuff notifications unavailable in combat, enemy names hidden in restricted content, standard cooldown alerts WIP.
- Their loot parsing uses raw `string.match` on chat messages — unguarded against secret chat strings in instances; we should do better.

## In-game testing guide

Phases 0–3 are implemented as of 2026-08-27 and pending live validation. Test in this order; everything under "known-degraded" is an accepted 12.x limitation, not a bug.

**Setup**

- Copy `MikScrollingBattleText/` and `MSBTOptions/` into `World of Warcraft/_retail_/Interface/AddOns/`, enable both.
- `/console scriptErrors 1` (or install BugSack) — watch for Lua errors during every step below.

**Phase 0/1 — loads & sanitation**

- Log in / `/reload`: zero Lua errors; addon shows in the list without "out of date".
- `/msbt` opens; orange Midnight restriction note shows under the window title.
- Click through all tabs: no green/missing textures; checkboxes and buttons play sounds; open a color swatch — picker opens, choose + cancel both restore correctly; `/msbt reset` works.

**Phase 2 — ingestion (open world)**

- Hit a mob: outgoing damage scrolls, crit-styled, school-colored; a spell cast right before shows its name/icon.
- Get hit: incoming damage/misses scroll. Heal yourself: incoming heal (HoTs use `_HOT` styles; self-heals route to `SELF_*`).
- Killing blow on a mob: notification fires. Loot items/money: notifications fire. Enter/leave combat: messages fire.
- Combo points / Chi / Holy Power / etc. gains and FULL alerts fire.
- Class proc: on a druid/mage/priest/shaman, get a Clearcasting proc → trigger fires.
- DoT/HoT ticks: where auras aren't secret, ticks carry the spell name and use `_DOT`/`_HOT` events (named via the victim's/player's auras — heuristic: first player-sourced aura wins). Ground effects (Consecration etc.) attribute while active.
- Drop below 35% health/mana: exactly ONE alert fires — the trigger where values are visible, the new `NOTIFICATION_LOW_HEALTH`/`LOW_MANA` fallback events where they're secret.
- Dungeon/raid run: text still flows, zero errors; enemy names may show as "Unknown"; AoE merging/throttles auto-disable where amounts are secret.
- Quick lockdown simulation: `/console addonChatRestrictionsForced 1` then repeat a few steps.
- **If NO incoming heals/aura/power notifications appear at all:** `/console enableFloatingCombatText 1` and retest. MSBT zeroes Blizzard's FCT CVars on first load (`DisableBlizzardCombatText`); the CTU feed is expected to be CVar-independent (Blizzard filters messages in Lua after the event fires), but this isolates the cause if not.

**Phase 3 — triggers & cooldowns**

- `/msbt` → Triggers: default triggers present (Clearcasting, Low Health, Low Mana, Low Pet Health, Execute-style). Drop below 35% health → alert + sound. Same for mana/pet.
- Cooldowns: use a long-cooldown spell → completion alert when ready, **in and out of combat** (in-combat uses the non-secret `isActive` transition; item cooldown alerts still pause in restricted content).
- Known-degraded (accepted): no outgoing heals, no DoT/HoT vs direct split on the UNIT_COMBAT feed, no enemy-buff/item-buff/dispel notifications, execute-range triggers may not fire in combat (enemy health secrecy), loot/rep/XP/honor alerts go silent inside instances (secret chat), aura stack-count triggers never fire (CTU carries no stacks).

**If something errors:** note the phase, context (open world vs combat vs instance), and the exact Lua error; check the phase doc's disposition table to see if it's an accepted limitation before filing it as a bug.
