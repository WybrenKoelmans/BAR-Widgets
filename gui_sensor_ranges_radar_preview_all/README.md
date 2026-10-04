# Sensor Ranges Radar Preview (All radars)

**Description:** Shows raytraced radar coverage for all allied radar buildings when placing or selecting a radar.

- **Author:** uBdead, Beherith
- **License:** Lua: GPLv2, GLSL: (c) Beherith (mysterme@gmail.com)

This widget displays the terrain-aware coverage of all allied radar buildings while building or selecting a radar, including radar buildings owned by allies.

## How it works

The vertex shader samples the heightmap along the line from each terrain grid point to the radar. Terrain-obscured points are discarded and visible points are rendered as a translucent green overlay.

- Coverage is rendered directly from the raymarched radar meshes.
- Radar centers use the exact live unit positions, so the overlay stays aligned with the game world.
- All allied radars are retained; overlapping coverage uses normal alpha blending.
- The widget activates only when a radar build command is active or a radar building is selected.

## Performance notes

Compared with the original implementation, this version:

- Uses a coarser cached grid and bounded ray-march sample count.
- Samples the heightmap at mip level 1.
- Skips vertices outside the radar range before ray-marching.
- Maintains the allied-radar list through unit/player events, with a slow fallback rescan.
- Renders directly with alpha blending instead of clearing/testing the stencil buffer and rasterizing an additional full-map ground quad.

VAOs are created lazily and cached per distinct radar range. The visual coverage remains terrain-aware while avoiding the expensive full-map composition pass.
