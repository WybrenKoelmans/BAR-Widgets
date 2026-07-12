# Idle Auto Repair

**Description:** Idle repair units automatically repair nearby damaged allied units in range

I mean, nano turrets do it, why not the other constructors?

Note that I made it specifically so your constructors dont follow the damaged units around, if they move out of range, they will simply stop.

UPDATE: Now also supports "maneuver" and "roam"
Roam: Will find repair targets in a range of 4 times the build range.
Maneuver: Will find repair targets in a range of 2 times the build range. After repairs are done, returns to the start position.

Note that it will only move towards targets that are standing still outside of the build range. If units move while in build range, the constructor will keep repairing.

- **Author:** uBdead
- **Date:** 2025-07-20
- **License:** GNU GPL, v2 or later
