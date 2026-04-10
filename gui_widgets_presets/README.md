# Widget Presets

Stores and applies presets of widget states, with automatic mode switching for Player/Spectator/Replay.

## Features

- **Preset Management**: Save, load, update, and delete named widget presets
- **Defaults Preset**: Built-in preset that restores all widgets to the game's default enabled state
- **Game State Detection**: Automatically detects Player, Spectator, and Replay modes
- **Auto-Switch**: Configure presets to be suggested (or auto-applied) when game state changes (e.g., player dies and becomes spectator)
- **State Change Banner**: Non-intrusive notification when game state changes, offering to switch to the configured preset
- **Match Detection**: Shows how closely your current widget configuration matches each preset (percentage)
- **Active Preset Indicator**: Highlights which preset is currently active (100% match)
- **Widget Selector Integration**: Panel appears alongside the widget selector (F11)
- **Draggable Panel**: Position persists across sessions
- **WG API**: Other widgets can interact via `WG['widget_presets']`

## Usage

1. Open the widget selector (F11) or use `/widget_presets_toggle`
2. Save your current widget set as a named preset
3. Configure auto-switch presets for each game state
 OR
4. When your state changes (e.g., you die and become a spectator), a banner offers to switch presets

## Text Commands

- `/widget_presets_toggle` - Toggle the panel
- `/widget_presets_show` - Show the panel
- `/widget_presets_hide` - Hide the panel

## WG API

```lua
WG['widget_presets'].show()       -- Show the panel
WG['widget_presets'].hide()       -- Hide the panel
WG['widget_presets'].toggle()     -- Toggle visibility
WG['widget_presets'].isvisible()  -- Check if visible
WG['widget_presets'].getPresetNames() -- Get sorted list of preset names
WG['widget_presets'].applyPreset("name") -- Apply a preset by name
```
