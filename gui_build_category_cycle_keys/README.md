# Build Category Cycle Keys

**Description:** The Z/X/C/V keys cycle through the selected builder's Economy/Combat/Utility/Production build options.

- **Author:** uBdead
- **Date:** 2026-07-10
- **License:** GNU GPL, v2 or later
- **Layer:** -1
- **Enabled by default:** true

## Controls

With a mobile builder selected:

- **Z** — cycle Economy build options
- **X** — cycle Combat build options
- **C** — cycle Utility build options
- **V** — cycle Production build options

Pressing the same key again advances to the next option in that category, wrapping around at the end. Pressing a different key switches to that category's cycle. Picking a blueprint with the mouse in between is fine: the cycle resumes from whatever is currently selected. Shift can be held while cycling, so you can keep queueing placements.

The keys are matched by physical position (scancode), so the layout works on any keyboard.

## Notes

- Works with both the **grid menu** (cycle order follows the grid layout, and the visible category switches along) and the classic **build menu** (cycle order follows its display order).
- Categories come from `luaui/configs/gridmenu_config.lua`, so the grouping always matches the grid menu's categories.
- Factories are unaffected: in labs the bottom-row grid keys still queue units as usual.
- Also works during pregame for setting up the commander's start queue.
- Disables the **Context Build** widget while active (re-enabled on shutdown), since its key bindings conflict with this control scheme.
