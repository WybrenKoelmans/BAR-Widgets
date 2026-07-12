# Turbo Catchup Widget

A performance optimization widget for Beyond All Reason that automatically disables UI widgets when the game falls behind the server, maximizing frame rate to catch up to real-time gameplay.

## Description

When playing online, sometimes your client can fall behind the server due to network latency, intensive gameplay scenarios, or system load. This widget monitors the frame rate differential and automatically disables non-essential UI widgets during these "catchup" periods to free up resources and improve performance.

## Features

- **Automatic Detection**: Monitors game frame rate and server synchronization
- **Smart Disabling**: Automatically disables widgets when the client falls behind
- **Smart Re-enabling**: Restores widgets once caught up to the server
- **Whitelisted Widgets**: Keeps essential widgets active during catchup mode:
  - Turbo Catchup (itself)
  - Rejoin progress (important during reconnections)
  - Chat (communication remains available)
- **Performance Focus**: Prioritizes frame rate during catch-up situations

## How It Works

The widget monitors two key metrics:

1. **Frame Lag**: The difference between server frame and client frame
2. **Frame Rate**: Client-side frames per second

When the client falls more than `3 * Game.gameSpeed` frames behind the server, catchup mode activates and disables all non-whitelisted widgets. The mode deactivates once the client catches up to the server.

## Configuration

### Adjusting the Catch-up Threshold

To change when catchup mode triggers, modify the `CATCH_UP_THRESHOLD` value in the widget code:

```lua
local CATCH_UP_THRESHOLD = 3 * Game.gameSpeed
```

Lower values = more aggressive catchup (triggers sooner)
Higher values = more lenient catchup (tolerates more lag)

### Adding Widgets to the Whitelist

Other widgets can register themselves to remain active during catchup mode using the provided API:

```lua
WG['turbo_catchup'].RegisterWidget("Your Widget Name")
```

To unregister:

```lua
WG['turbo_catchup'].UnregisterWidget("Your Widget Name")
```

## Requirements

- Beyond All Reason
- Not compatible with replays (widget auto-disables in replay mode)

## Author

- **Author**: uBdead
- **License**: GNU GPL v2 or later
- **Date**: 2026-08-04

## Debugging

The widget outputs messages to the in-game console when:
- Entering catchup mode (displays frame lag)
- Exiting catchup mode

You can enable additional debug output by uncommenting the Spring.Echo calls in the code.

## Notes

- The widget requires handler status to manage other widgets
- Some widgets (like Chat) are whitelisted because they don't reload cleanly
- The widget automatically disables itself in replay mode to avoid conflicts
