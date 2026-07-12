# Sensor Ranges Radar Preview (All radars)

**Description:** Shows raytraced radar coverage for all allied radar buildings when placing or selecting a radar. Uses stencil-based union rendering to display clean green/red coverage overlay without alpha accumulation artifacts.

- **Author:** uBdead, Beherith
- **Date:** 2025.08.13
- **License:** Lua: GPLv2, GLSL: (c) Beherith (mysterme@gmail.com)

Time to get rid of those nasty radar gaps. With this widget all radar coverages will be overlapped while building or selecting a radar (including allies).

## How it works

When you select a radar building or issue a radar build command, this widget draws the combined radar coverage of all your allied radar buildings on the terrain:

- **Green overlay** — ground covered by at least one radar (line-of-sight clear)
- **Red overlay** — ground not covered by any radar (blocked by terrain or out of range)

The ray-marching is performed in the vertex shader per grid point, checking terrain height samples between each point and the radar center. A stencil buffer forms the union of all individual radar coverages so overlapping radars don't cause visual artifacts.

## Implementation notes

- Shaders are inlined in the Lua file to avoid VFS path resolution issues
- VAOs are created lazily per distinct radar range and cached
- Radar list is refreshed every ~3 seconds as a safety net
- Activates only when a radar build command is active or a radar building is selected
