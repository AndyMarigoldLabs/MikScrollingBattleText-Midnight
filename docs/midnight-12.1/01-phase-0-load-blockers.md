# Phase 0 — Load Blockers

**Goal:** the addon loads on WoW 12.1 without Lua errors; `/msbt` opens the options. Nothing needs to *work* yet — this is strictly the "refused to load / errors at load" floor.

**Effort:** hours. **Blocks:** everything.
**Status:** Implemented 2026-08-27 — pending in-game smoke test.

## Tasks

- [x] **TOC bump.** Set `## Interface: 120100` in `MikScrollingBattleText/MikScrollingBattleText.toc:1` and `MSBTOptions/MSBTOptions.toc:1`. (12.0.x accepted `120000`; 12.1 is `120100`. A comma list like `120000, 120001, 120100` is legal if multi-client support is wanted later — keep it simple: `120100`.) — *done 2026-08-27*
- [x] **Neutralize CLEU registration.** Registering `COMBAT_LOG_EVENT_UNFILTERED` raises an error on 12.x. Remove/feature-flag the registrations at: — *done 2026-08-27; single shared gate is `MikSBT.CLEU_AVAILABLE` (defined in `MikSBT.lua`), referenced by all three modules*
  - `MikScrollingBattleText/MSBTParser.lua:899` (main parser frame; this disables all combat parsing until Phase 2)
  - `MikScrollingBattleText/MSBTCooldowns.lua:319-321,360`
  - `MikScrollingBattleText/MSBTTriggers.lua:272,286,300,322,435,822-823`
  Use a single shared constant (e.g. `local CLEU_AVAILABLE = false`) so Phase 2 replaces one gate, not eleven call sites. Also remove the `CombatLogGetCurrentEventInfo()` call at `MSBTParser.lua:821`.
- [x] **Fix load-time hook error.** `MSBTCooldowns.lua:468` calls `hooksecurefunc("UseItemByName", …)` — the global is gone, erroring at file load and killing the module. Guard with the `C_Item.UseItemByName` namespace (or drop the hook; item-cooldown detection is revisited in Phase 3). — *done 2026-08-27; hooks `C_Item.UseItemByName` when present*
- [x] **Fix the remaining unshimmed globals that can error at load/enable time:** `GetSpellTexture` (`MSBTCooldowns.lua:92`), `GetItemInfo` (`MSBTCooldowns.lua:90,132`), `GetItemClassInfo` (`MSBTLoot.lua:39`). Reuse the existing `MikSBT.lua:24-28` shim pattern (`C_Spell and C_Spell.GetSpellTexture or …`). — *done 2026-08-27*
- [x] **Verify runtime primitives on 12.1:** confirm `bit.band`/`bit.bor` (used at `MSBTParser.lua:21-22`, `MSBTMain.lua:30`) and global `unpack` (`MSBTOptionsMain.lua:365`) still exist; shim to `bit32`/`table.unpack` if not. (`getglobal`/`setglobal` are deprecated in 12.1 but shimmed by Blizzard; MSBT doesn't use them.) — *done 2026-08-27: defensive fallbacks added (`bit or bit32`, `unpack or table.unpack`, `tinsert/tremove or table.insert/remove`); still confirm on the real client*
- [ ] **Boot smoke test** (see below). — *pending: requires the 12.1 client, cannot run from the dev environment*

Additional hardening done during implementation (beyond the original list): the "% of target max HP" paths did arithmetic on `UnitHealthMax("target")`, which returns a **secret** for enemy units in 12.x (immediate Lua error). Guarded with `issecretvalue` at `MSBTParser.lua` (`SendParserEvent`) and `MSBTMain.lua` (`FormatEvent`); feature degrades to no-percentage when the value is secret.

## Acceptance criteria

- Addon appears in the addon list without "out of date" and loads on login and `/reload` with zero Lua errors (BugSack or `/console scriptErrors 1`).
- `/msbt` loads MSBTOptions and shows the main window.
- Profile init runs: `MSBTProfiles_SavedVars` is created/round-trips.
- Expected-broken at this stage (tracked, not errors): no combat text output, cooldown/trigger modules inert.

## Risks / notes

- The parser frame's `OnEvent` (`MSBTParser.lua:818`) stays registered for chat events; with CLEU gated off, confirm no nil-path errors when `ParseLogMessage` never runs.
- Don't be tempted to start Phase 2 work here — Phase 0's value is a clean, loadable baseline to branch from.
