# Phase 1 — API Sanitation

**Goal:** purge every removed/deprecated API and known latent bug so the *non-combat* surface (options, media, profiles, loot outside instances) works fully on 12.1. Mechanical work; no redesign.

**Effort:** 1–2 days. **Depends on:** Phase 0.
**Status:** Implemented 2026-08-27 — in-game verification pending (colors, sounds, textures).

## Tasks

### Removed globals → modern namespaces
- [x] `MSBTCooldowns.lua:90,132,243,441` — `GetItemInfo` → `C_Item.GetItemInfo`. *(done in Phase 0)*
- [x] `MSBTCooldowns.lua:92` — `GetSpellTexture` → `C_Spell.GetSpellTexture`. *(done in Phase 0)*
- [x] `MSBTLoot.lua:39` — `GetItemClassInfo` → `C_Item.GetItemClassInfo` (keep the existing `LE_ITEM_CLASS_QUESTITEM or Enum.ItemClass.Questitem` constant fallback). *(done in Phase 0)*
- [x] `MSBTTriggers.lua:216-217` — `UnitBuff` → pcall-wrapped `C_UnitAuras.GetAuraDataBySpellName` via new `IsPlayerBuffActive` helper (`MSBTTriggers.lua:213-219`); in 12.1 single-aura name lookups are *not callable* while aura access is secret, so failures evaluate as "not active" rather than erroring.
- [x] Consolidate: the shim block in `MikSBT.lua:30-40` now exposes `mod.IsClassic/LoadAddOn/GetAddOnMetadata/IsAddOnLoaded/GetSpellInfo/GetSpellCooldown/GetSpellTexture/GetItemInfo/GetItemCount/GetItemClassInfo`; `MSBTProfiles.lua`, `MSBTLoot.lua`, and `MSBTCooldowns.lua` import from there.

### Latent bugs (broken since the 11.0.2 shim patch)
- [x] `MSBTCooldowns.lua` — both `enabled == 1` sites now accept `enabled == 1 or enabled == true` (the shimmed return is boolean `isEnabled`). Same shape for items via `C_Container.GetItemCooldown`.
- [x] *Added during implementation:* secrecy guards — `OnUpdateCooldown` and `OnUpdate` early-out on `C_Secrets.ShouldCooldownsBeSecret()` so cooldown logic pauses in combat/encounters instead of erroring on secret arithmetic (`MSBTCooldowns.lua:36-38,165-166,230-231`). In-combat cooldown alerts remain Phase 3 scope by design.

### Options UI
- [x] **Color picker rewrite** — `MSBTOptionsControls.lua:1764-1787` now uses `ColorPickerFrame:SetupColorPickerAndShow(info)` with closure-based `swatchFunc`/`cancelFunc` (via `GetPreviousValues()`). Discovery: MSBT's swatches were always RGB-only (`hasOpacity = false`), so no opacity support was needed; the `associatedColorSwatch` global-field hack and both dead handler functions were removed.
- [x] **Sound kits** — replaced with `SOUNDKIT.*`, mapping verified against Blizzard's own `SoundKitConstants.lua` (12.x client source): `799`→`GS_TITLE_OPTION_EXIT` (`MSBTOptionsMain.lua:150`, `MSBTOptionsPopups.lua:114`), `852`→`IG_MAINMENU_OPTION` (`MSBTOptionsPopups.lua:135`), `826/827`→`IG_CHAT_SCROLL_UP/DOWN` (`MSBTOptionsControls.lua:196,206`), `856/857`→`IG_MAINMENU_OPTION_CHECKBOX_ON/OFF` (`:610,779`).
- [~] **Texture audit** — replaced the known-dead `"Interface\\Icons\\Temp"` sentinel with `Interface\Icons\INV_Misc_QuestionMark` (`MSBTAnimations.lua:65-67`). The remaining ~20 legacy paths (`PaperDollInfoFrame\*`, `QuestFrame\*`, `Buttons\*`, `ChatFrame\*`, `Tooltips\*`) need an in-game eyeball pass — they are believed to still ship (Blizzard keeps legacy art; 12.1 only stopped publishing *new* filenames) but that cannot be verified from the dev environment.
- [x] **Bootstrap event** — `VARIABLES_LOADED` → `PLAYER_LOGIN` (`MSBTProfiles.lua:3708,3739`).

### Libraries
- [x] LibSharedMedia-3.0: current releases are only on the Cloudflare-protected CurseForge CDN (GitHub mirrors are stale 2020/2021 clones), so the embedded r128 stays; added the same `bit or bit32` load-guard it lacked (`Libs/LibSharedMedia-3.0.lua:23`). Re-bump if issues surface in-game. LibStub/CallbackHandler-1.0 remain current.

## Acceptance criteria

- [x] `grep` clean: no remaining references to `GetItemInfo(`, `GetSpellTexture(`, `UnitBuff(`, `GetItemClassInfo(`, `UseItemByName` outside the compat shim block. — *verified 2026-08-27 (also clean: numeric `PlaySound`, old `ColorPickerFrame` fields, `VARIABLES_LOADED`, `Icons\Temp`)*
- [ ] Color picking (with opacity) works from every color swatch in options. — *in-game pending; note: swatches are RGB-only, no opacity slider by original design*
- [ ] All options tabs render without missing-texture green boxes; all UI sounds play. — *in-game pending*
- [ ] Cooldown *activation detection* works out of combat (the boolean fix), even though in-combat alerts remain Phase 3 scope. — *in-game pending; in-combat now intentionally pauses via `ShouldCooldownsBeSecret`*

## Risks / notes

- Aura-related replacements compile fine but will silently return secrets/nil in combat — that is expected at this phase; do not "fix" it here.
- Keep the diff mechanical. No behavior changes, no refactoring of the options control toolkit.
