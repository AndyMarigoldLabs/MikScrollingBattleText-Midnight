# Phase 4 — Release Polish

**Goal:** ship a coherent, documented, packaged 12.1 release of MSBT.

**Effort:** 1–2 days. **Depends on:** Phases 0–3.
**Status:** Safe subset implemented 2026-08-27 (no in-game dependency); presentation/audit/final-validation items held for the in-game test report.

## Tasks

### In-game presentation
- [ ] Options "what changed in Midnight" summary panel or changelog popup (reuse the popup framework in `MSBTOptionsPopups.lua`).
- [ ] Prune/annotate every dead setting per Phase 3; verify all 9 options tabs (`MSBTOptionsTabs.lua:3861-3931`) against a fresh profile and an upgraded 5.9.4 profile.
- [ ] Confirm load-on-demand behavior (`LoadOnDemand` options, `LoadAddOn("MSBTOptions")` at `MSBTProfiles.lua:3124-3140`) and the Blizzard Settings category registration (`:3264-3287`) on 12.1.

### Documentation
- [x] Update `README.md` — rewritten 2026-08-27 with the Midnight works/degraded/cut matrix, install/upgrade notes, and license/attribution block.
- [x] `MikScrollingBattleText/API.html` retired → `MikScrollingBattleText/API.md` (display-side API: `DisplayMessage`, `RegisterFont`/`RegisterSound`, `RegisterAnimationStyle`/`RegisterStickyAnimationStyle` — all survive Midnight). Code comments updated to point at API.md. (`readme.html` — the original author's ancient changelog — intentionally left untouched as a historical artifact.)
- [x] Localization: `L.MSG_MIDNIGHT_LIMITED` added to the English base file; other locales inherit it automatically (English loads first). New options strings beyond that are pending the per-tab honesty pass.

### Versioning & packaging
- [x] Version scheme: `6.0.0-12.1.0` set in `MikScrollingBattleText.toc` (major bump for the rewrite; suffix tracks target patch). Verified `MikSBT.lua`'s version-string parsing handles the format.
- [x] Release pipeline: `.github/workflows/release.yml` added — on a `v*` tag push, packages both addon folders into a zip and creates a GitHub release. CurseForge/Wago publishing pending (needs project IDs).
- [ ] `.toc` metadata: `## X-Website`/`## X-Curse-Project-ID` if publishing.
- [ ] License/attribution statement: original © Mikord, all rights reserved — stated in README + roadmap; no third-party Midnight fork code was copied (inspiration only).

### Deferred code cleanup landed early (2026-08-27)
Removed provably dead leftovers from Phases 2–3: Parser's Obliterate/FrostStrike/Stormstrike spell locals, `MAX_BUFFS`/`MAX_DEBUFFS`, `FLAGS_MINE`/`FLAGS_MY_GUARDIAN`; Triggers' unused `unitMap`/`classMap` imports and `playerGUID`. The roster-driven unit-map builder in `MSBTParser.lua` is now unread by anyone — candidate for removal after in-game validation (deliberately kept: blind excision touches event flow with no client to test against).

### Final validation
- [ ] Full Phase 2 test matrix green on live 12.1 (not just PTR).
- [ ] Upgrade path: install over a 5.9.4 profile → no errors, settings preserved, dead settings annotated.
- [ ] Fresh install → default profile sane, preview/test buttons working.
- [ ] Performance sanity: no per-frame leaks; FontString pooling (`MSBTAnimations.lua:80-81`) unchanged and healthy under sustained combat.

## Acceptance criteria

- [ ] Installable zip installs cleanly into `_retail_/Interface/AddOns/`.
- [ ] No open items remain in Phases 0–3 checklists.
- [ ] Changelog published with the "what works / what doesn't and why" matrix — users of old MSBT should understand the Midnight shape in 30 seconds.
