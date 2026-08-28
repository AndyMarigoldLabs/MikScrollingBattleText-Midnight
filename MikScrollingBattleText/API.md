# MSBT Public API

The **display-side** API is unchanged by the Midnight rewrite — only combat-data ingestion changed (see [docs/midnight-12.1](../docs/midnight-12.1/README.md)). Everything on this page behaves as it always has.

## Constants

- `MikSBT.DISPLAYTYPE_INCOMING`
- `MikSBT.DISPLAYTYPE_OUTGOING`
- `MikSBT.DISPLAYTYPE_NOTIFICATION`
- `MikSBT.DISPLAYTYPE_STATIC`

## MikSBT.DisplayMessage

```lua
MikSBT.DisplayMessage(message [, scrollArea, isSticky, colorR, colorG, colorB, fontSize, fontName, outlineIndex, texturePath])
```

Outputs a message to a scroll area.

- `message` (string) — text to display.
- `scrollArea` — scroll area name or a `MikSBT.DISPLAYTYPE_*` constant (default: Notification).
- `isSticky` (boolean) — use the sticky (crit) animation style.
- `colorR/G/B` — 0–255 color components.
- `fontSize` (number), `fontName` (string, a registered font name), `outlineIndex` (number: 1 = none, 2 = thin, 3 = thick).
- `texturePath` (string) — icon shown next to the message.

Examples:

```lua
MikSBT.DisplayMessage("Test Message")
MikSBT.DisplayMessage("Another Message", MikSBT.DISPLAYTYPE_INCOMING, true)
MikSBT.DisplayMessage("Uber Damage!", MikSBT.DISPLAYTYPE_OUTGOING, false, 0, 0, 255)
MikSBT.DisplayMessage("Enemy begins to flee", nil, false, 0, 255, 0, nil, "MSBT Yellowjacket", 1, "Interface\\Icons\\Spell_Shadow_Possession")
```

## MikSBT.RegisterFont(fontName, fontPath)

Registers a font for use in MSBT's font settings and as `fontName` in `DisplayMessage`.

```lua
MikSBT.RegisterFont("MyUberFont", "Interface\\AddOns\\MyModName\\Fonts\\MyUberFont.ttf")
```

## MikSBT.RegisterSound(soundName, soundPath)

Registers a sound for use in MSBT's event/trigger sound settings. `soundPath` may be a file path or a FileDataID.

## MikSBT.RegisterAnimationStyle(styleID, initHandler, availableDirections, availableBehaviors [, localizationTable])

Registers a custom animation style. `initHandler` is called when a scroll area using the style is initialized and is responsible for setting up the area's animation behavior.

## MikSBT.RegisterStickyAnimationStyle(styleID, initHandler, availableDirections, availableBehaviors [, localizationTable])

Same as `RegisterAnimationStyle`, but registers the style as a sticky (crit) style.

The built-in styles in `MSBTAnimationStyles.lua` (Angled, Straight, Parabola, Horizontal, Static) are the canonical, working examples of both functions.
