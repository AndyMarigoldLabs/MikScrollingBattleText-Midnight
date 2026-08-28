# Phase 3 — Feature Triage (secrecy-constrained features)

**Goal:** decide and implement the fate of every feature whose data is secret in combat/restricted content: keep (non-secret contexts only), rework through a sanctioned path, or cut cleanly. No half-working features and no Lua errors anywhere.

**Effort:** multi-day, overlaps late Phase 2. **Depends on:** Phase 2's secrecy findings (test matrix).
**Status:** Implemented 2026-08-27 — in-game validation pending.

## Disposition table (as implemented 2026-08-27)

| Feature | Data problem | Disposition | Notes |
|---|---|---|---|
| AoE merging | arithmetic/comparison on secret amounts | **Kept, auto-disabled on secrets** | Phase 2: `mergeEligible` forced false when amount is secret (`MSBTMain.lua`) |
| Spam throttles | same | **Kept, auto-disabled on secrets** | Same gate as merging (throttle lives inside the merge path) |
| Crit styling | `flagText` from UNIT_COMBAT | **Kept** | `flagText` drives crit/glance/crush; secret-guarded |
| Class-colored names | `UnitClass` secret for non-party in combat | **Kept for party/raid; skipped otherwise** | class-map writes are all secret-guarded (`MSBTParser.lua` OnEvent + `ParseUnitCombat`) |
| % of target max HP | target max health secret | **Kept where non-secret; skipped otherwise** | guarded at both compute sites |
| Trigger engine (combat-subevent conditions) | CLEU gone | **Cut; engine rewired** | Combat-subevent `mainEvents` are silently inert (never categorized/registered). CLEU machinery deleted from `MSBTTriggers.lua` (captureFuncs, HandleCombatLogTriggers, OnEvent branch, `MikSBT.CLEU_AVAILABLE` gate everywhere) |
| Aura proc triggers (Clearcasting, etc.) | aura data secret/nil in combat | **Partially restored** | New `ParserEventsHandler` in `MSBTTriggers.lua` maps parser aura events (CTU player auras) back onto `SPELL_AURA_APPLIED`/`_REMOVED` trigger conditions — `skillName`-keyed triggers fire again when names aren't secret. Stack-count (`_DOSE`) and `skillID`-keyed conditions don't fire |
| Low health / low mana alerts | health/power secret for non-player units | **Kept, secret-guarded** | `UNIT_HEALTH`/`UNIT_POWER_UPDATE` handlers skip secret values; player/pet thresholds work where values are plain. Execute-style triggers on hostile targets depend on enemy health secrecy — expected degraded in combat |
| Cooldown completion alerts | start/duration secret in combat | **Mostly restored (2026-08-27)** | 12.0.1 made `isActive`/`isEnabled`/`maxCharges` non-secret — restricted mode now tracks active→inactive transitions with zero secret math (`MSBTCooldowns.lua`); threshold applied to *observed* duration from our own timestamps. Items still pause in restricted content (`C_Container.GetItemCooldown` has no `isActive`). |
| Skill icons on events | spellID can be secret | **Kept when non-secret** | guarded in translators |
| Default trigger list | dead spells | **Pruned** | `SPELLID_FIRST_AID` (3273) removed from both profile branches' LOW_HEALTH icon |
| Enemy buff gains, item buffs/enchants, dispels/steals, power loss | no sanctioned feed | **Cut** | — |
| Suppression/throttle name-keyed lists | secret keys would error | **Safe by construction** | translators only ever put plain strings in `skillName`/`effectName` (verified across `MSBTMain.lua:1136+`) |

## Tasks

- [x] Dispositions implemented behind capability checks (`issecretvalue`, `C_Secrets.ShouldCooldownsBeSecret`, pcall on single-aura lookups).
- [x] **Options honesty pass:** restriction note added under the options window title (`MSBTOptionsMain.lua`, new `L.MSG_MIDNIGHT_LIMITED`). Finer per-tab annotations deferred to Phase 4's options cleanup.
- [x] `MSBTCooldowns.lua` CLEU dependence removed (pet-cast `COMBAT_LOG_EVENT_UNFILTERED`/`CombatLogEvent` methods deleted; gate block removed).
- [x] Name-keyed suppression lists are secret-safe by construction (translators never emit secret `skillName`); no re-keying needed.
- [x] **Classic branch decision: KEEP.** The duplicated Classic profile branch (`MSBTProfiles.lua`) is inert data under a retail-only TOC and the new feed translators are largely client-agnostic; dropping it is Phase 4 cleanup if ever warranted, not now.

## Acceptance criteria

- [ ] No feature throws or visibly glitches in any row of the Phase 2 test matrix. — *in-game pending*
- [x] Every cut/degraded feature is listed with its reason in the disposition table above; the options window carries a visible restriction note. Root `README.md` feature-list update lands in Phase 4.
- [x] Default profile ships only triggers that can actually fire (aura `skillName` triggers via CTU; health/power thresholds where non-secret; dead-spell icon pruned).
- [x] Saved variables never contain secrets — translators only store plain values in `parserEvent`, and profile writes never see feed data.

## Risks / notes

- Blizzard iterated restrictions repeatedly (12.0.1/12.0.5/12.0.7, then 12.1 auras). Read those blue posts before finalizing dispositions; another relaxation may land in 12.1.x hotfixes — capability checks beat hard cuts for exactly this reason.
- The trigger editor UI (`MSBTOptionsPopups.lua` trigger tab) is large; keep it but gate condition choices that are now non-functional.
