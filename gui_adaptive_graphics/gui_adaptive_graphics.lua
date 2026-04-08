local widget = widget ---@type Widget

function widget:GetInfo()
    return {
        name = "Adaptive Graphics",
        desc = "Dynamically adjusts graphics settings based on FPS performance.",
        author = "uBdead",
        date = "2026-04-07",
        license = "GNU GPL, v2 or later",
        layer = 0,
        enabled = true
    }
end

--------------------------------------------------------------------------------
-- Constants & Defaults
--------------------------------------------------------------------------------

local PREFIX = "[AdaptiveGFX] "

-- The ordered list of graphics settings we can toggle.
-- Each entry: { id, down (lower quality value), up (higher quality value) }
-- Settings are degraded in order (index 1 first) and upgraded in reverse order.
-- 'down' = the value we set when degrading; 'up' = the restored value when upgrading
-- (real up values are captured from the original settings at startup via snapshotOriginalValues).
-- Note: 'decals' and 'msaa' require restart so are intentionally excluded.
--
-- Organised into four passes that mirror the built-in quality presets:
--   Pass 1  ultra  → high
--   Pass 2  high   → medium
--   Pass 3  medium → low
--   Pass 4  low    → lowest
-- Within each pass, more GPU-expensive settings are listed first.
local SETTING_LEVELS = {
    -- ── Pass 1: Ultra → High ──────────────────────────────────────────────────
    -- supersampling is not in the presets but is the costliest setting overall
    { id = "supersampling",                   down = false,  up = true  }, -- oversamples every pixel; very GPU-heavy
    { id = "bloomdeferred_quality",           down = 2,      up = 3     }, -- ultra(3) → high(2)
    { id = "ssao_quality",                    down = 2,      up = 3     }, -- ultra(3) → high(2)
    { id = "lighteffects_screenspaceshadows", down = 3,      up = 4     }, -- ultra(4) → high(3)
    { id = "particles",                       down = 30000,  up = 40000 }, -- ultra(40k) → high(30k)
    { id = "shadowslider",                    down = 5,      up = 6     }, -- ultra(6) → high(5)

    -- ── Pass 2: High → Medium ─────────────────────────────────────────────────
    { id = "bloomdeferred_quality",           down = 1,      up = 2     }, -- high(2) → medium(1)
    { id = "lighteffects_screenspaceshadows", down = 2,      up = 3     }, -- high(3) → medium(2)
    { id = "particles",                       down = 20000,  up = 30000 }, -- high(30k) → medium(20k)
    { id = "shadowslider",                    down = 4,      up = 5     }, -- high(5) → medium(4)
    -- { id = "dof",                             down = false,  up = true  }, -- depth of field (not in presets; fits high→medium cost)
    { id = "featuredrawdist",                 down = 5000,   up = 10000 }, -- feature draw distance (not in presets)

    -- ── Pass 3: Medium → Low ──────────────────────────────────────────────────
    { id = "ssao_quality",                    down = 1,      up = 2     }, -- reduce quality before disabling SSAO
    { id = "ssao",                            down = false,  up = true  }, -- medium(on) → low(off)
    { id = "lighteffects_additionalflashes",  down = false,  up = true  }, -- medium(on) → low(off)
    { id = "lighteffects_screenspaceshadows", down = 1,      up = 2     }, -- medium(2) → low(1)
    { id = "shadowslider",                    down = 3,      up = 4     }, -- medium(4) → low(3)
    { id = "particles",                       down = 15000,  up = 20000 }, -- medium(20k) → low(15k)
    { id = "grass",                           down = false,  up = true  }, -- medium(on) → low(off)
    { id = "snow",                            down = false,  up = true  }, -- medium(on) → low(off)
    { id = "mapedgeextension",                down = false,  up = true  }, -- medium(on) → low(off)
    { id = "clouds",                          down = false,  up = true  }, -- not in presets; fits medium→low cost
    { id = "grassdistance",                   down = 0.5,    up = 1.0   }, -- not in presets; fits medium→low cost
    { id = "resurrectionhalos",               down = false,  up = true  }, -- not in presets; fits medium→low cost
    { id = "treewind",                        down = false,  up = true  }, -- not in presets; fits medium→low cost

    -- ── Pass 4: Low → Lowest ──────────────────────────────────────────────────
    { id = "bloomdeferred",                   down = false,  up = true  }, -- low(on) → lowest(off)
    { id = "lighteffects_screenspaceshadows", down = 0,      up = 1     }, -- low(1) → lowest(0)
    { id = "lighteffects",                    down = false,  up = true  }, -- low(on) → lowest(off)
    { id = "distortioneffects",               down = false,  up = true  }, -- low(on) → lowest(off)
    { id = "shadowslider",                    down = 1,      up = 3     }, -- low(3) → lowest(1)
    { id = "particles",                       down = 10000,  up = 15000 }, -- low(15k) → lowest(10k)
    { id = "cusgl4",                          down = false,  up = true  }, -- low(on) → lowest(off)
    { id = "advmapshading",                   down = false,  up = true  }, -- low(on) → lowest(off)
    { id = "water",                           down = 1,      up = 2     }, -- low(2) → lowest(1); only relevant on water maps
    { id = "decalsgl4",                       down = false,  up = true  }, -- low(1) → lowest(0)
}

-- Default configuration values
local DEFAULT_SAMPLE_INTERVAL = 1  -- seconds between FPS samples
local DEFAULT_SAMPLE_COUNT    = 3    -- samples to average before deciding
local DEFAULT_TARGET_FPS      = 45
local DEFAULT_MIN_FPS         = 30
local DEFAULT_COOLDOWN        = 10.0 -- seconds after a change before reconsidering
local DEFAULT_ENABLED         = true

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local config = {
    enabled        = DEFAULT_ENABLED,
    targetFps      = DEFAULT_TARGET_FPS,
    minFps         = DEFAULT_MIN_FPS,
    sampleInterval = DEFAULT_SAMPLE_INTERVAL,
    sampleCount    = DEFAULT_SAMPLE_COUNT,
    cooldown       = DEFAULT_COOLDOWN,
}

local fpsSamples = {}
local sampleTimer = 0
local cooldownTimer = 0
local currentDegradeIndex = 0   -- 0 = nothing degraded; n = first n settings degraded
local initialized = false
local myPlayerID = Spring.GetMyPlayerID()

-- Saved value per SETTING_LEVELS index, captured just before each degradation step.
-- Keyed by index (not by ID) so multi-step entries for the same option are handled correctly.
local originalValues = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function log(msg)
    Spring.Echo(PREFIX .. msg)
end

local function getOptionValue(optionId)
    if WG['options'] and WG['options'].getOptionValue then
        return WG['options'].getOptionValue(optionId)
    end
    return nil
end

local function setOptionValue(optionId, value)
    if WG['options'] and WG['options'].applyOptionValue then
        if getOptionValue(optionId) == nil then
            log("Skipping '" .. optionId .. "' (option not registered in this game version)")
            return
        end
        -- The options API passes values through tonumber(), which destroys booleans.
        -- Convert bools to 0/1 so they survive the coercion.
        if type(value) == "boolean" then
            value = value and 1 or 0
        end
        WG['options'].applyOptionValue(optionId, value)
        log("Set '" .. optionId .. "' = " .. tostring(value))
    else
        log("WARNING: WG['options'] not available, cannot set '" .. optionId .. "'")
    end
end

local function getAverageFps()
    if #fpsSamples == 0 then return 0 end
    local sum = 0
    for _, v in ipairs(fpsSamples) do
        sum = sum + v
    end
    return sum / #fpsSamples
end

local function getCpuUsage()
    -- Spring.GetPlayerInfo returns: name, active, spectator, teamID, allyTeamID, pingTime, cpuUsage, ...
    local _, _, _, _, _, _, cpuUsage = Spring.GetPlayerInfo(myPlayerID, false)
    return cpuUsage  -- 0..1 fraction
end

--- Scan settings to log and estimate the current degradation state.
--- Returns the highest step index whose 'down' condition is satisfied.
--- Used ONLY for diagnostics at startup — the widget always starts at index 0.
local function detectCurrentDegradeIndex()
    for i = #SETTING_LEVELS, 1, -1 do
        local s = SETTING_LEVELS[i]
        local current = getOptionValue(s.id)
        if current ~= nil then
            if type(s.down) == "boolean" then
                local currentBool = (current == true or current == 1)
                if currentBool == s.down then
                    return i
                end
            else
                if tonumber(current) and tonumber(current) <= s.down then
                    return i
                end
            end
        end
    end
    return 0
end

--- Log the current value of every managed setting (diagnostic only).
local function snapshotOriginalValues()
    log("Current graphics settings at startup:")
    for i, s in ipairs(SETTING_LEVELS) do
        local val = getOptionValue(s.id)
        log(string.format("  [%2d] %-44s = %s", i, s.id, tostring(val)))
    end
end

--------------------------------------------------------------------------------
-- Core Logic
--------------------------------------------------------------------------------

local function degradeOneStep()
    local nextIndex = currentDegradeIndex + 1
    if nextIndex > #SETTING_LEVELS then
        log("Already at lowest quality — nothing more to degrade")
        return false
    end

    local s = SETTING_LEVELS[nextIndex]
    local currentVal = getOptionValue(s.id)

    -- Save the value we're about to overwrite, keyed by step index so that
    -- multi-step entries for the same option ID each save their own intermediate state.
    originalValues[nextIndex] = currentVal

    log("DEGRADING step " .. nextIndex .. "/" .. #SETTING_LEVELS
        .. ": '" .. s.id .. "' " .. tostring(currentVal) .. " -> " .. tostring(s.down))
    setOptionValue(s.id, s.down)
    currentDegradeIndex = nextIndex
    return true
end

local function upgradeOneStep()
    if currentDegradeIndex <= 0 then
        log("Already at original quality — nothing to upgrade")
        return false
    end

    local s = SETTING_LEVELS[currentDegradeIndex]
    -- Restore the exact value that was in place before this step was degraded.
    -- Fallback to s.up only if we have no snapshot (e.g., widget was reloaded mid-play).
    local restoreValue = originalValues[currentDegradeIndex]
    if restoreValue == nil then
        restoreValue = s.up
        log("WARNING: no snapshot for step " .. currentDegradeIndex .. ", using fallback value " .. tostring(restoreValue))
    end

    local currentVal = getOptionValue(s.id)
    log("UPGRADING step " .. currentDegradeIndex .. "/" .. #SETTING_LEVELS
        .. ": '" .. s.id .. "' " .. tostring(currentVal) .. " -> " .. tostring(restoreValue))
    setOptionValue(s.id, restoreValue)
    originalValues[currentDegradeIndex] = nil
    currentDegradeIndex = currentDegradeIndex - 1
    return true
end

local function evaluatePerformance()
    local avgFps = getAverageFps()
    local cpu = getCpuUsage()
    local cpuPct = cpu and math.floor(cpu * 100) or -1

    log(string.format(
         "Evaluating: avgFPS=%.1f  targetFPS=%d  minFPS=%d  cpuUsage=%d%%  degradeLevel=%d/%d",
         avgFps, config.targetFps, config.minFps, cpuPct,
         currentDegradeIndex, #SETTING_LEVELS))

    if avgFps < config.minFps then
        log(string.format("FPS %.1f is BELOW minimum %d — degrading!", avgFps, config.minFps))
        if degradeOneStep() then
            cooldownTimer = config.cooldown
            fpsSamples = {}
        end
    elseif avgFps < config.targetFps then
        log(string.format("FPS %.1f is below target %d — degrading one step", avgFps, config.targetFps))
        if degradeOneStep() then
            cooldownTimer = config.cooldown
            fpsSamples = {}
        end
    elseif avgFps > config.targetFps * 1.3 and currentDegradeIndex > 0 then
        log(string.format("FPS %.1f is well above target %d (130%%) — trying to upgrade", avgFps, config.targetFps))
        if upgradeOneStep() then
            cooldownTimer = config.cooldown
            fpsSamples = {}
        end
    else
        log(string.format("FPS %.1f is acceptable (target=%d) — no changes", avgFps, config.targetFps))
    end
end

--------------------------------------------------------------------------------
-- Options Integration (via WG['options'])
--------------------------------------------------------------------------------

local optionsRegistered = false

local function registerOptions()
    if not WG['options'] or not WG['options'].addOptions then
        return false
    end

    WG['options'].addOptions({
        { id = "adaptive_gfx_label", name = "Adaptive Graphics", type = "label" },
        { id = "adaptive_gfx_spacer" },
        { id = "adaptive_gfx_enabled",
          name = "Adaptive Graphics",
          type = "bool",
          value = config.enabled,
          description = "Automatically adjust graphics settings when FPS drops below target.",
          onchange = function(i, value)
              config.enabled = value
            --   if value then
            --       log("Enabled — will monitor FPS and adjust settings")
            --   else
            --       log("Disabled — graphics settings will not be auto-adjusted")
            --   end
          end,
        },
        { id = "adaptive_gfx_target_fps",
          name = "   Target FPS",
          type = "slider",
          min = 20, max = 200, step = 5,
          value = config.targetFps,
          description = "The FPS the widget tries to maintain. Settings degrade if FPS drops below this.",
          onchange = function(i, value)
              config.targetFps = value
            --   log("Target FPS set to " .. value)
          end,
        },
        { id = "adaptive_gfx_min_fps",
          name = "   Minimum FPS",
          type = "slider",
          min = 10, max = 100, step = 5,
          value = config.minFps,
          description = "Below this FPS, settings are degraded more aggressively.",
          onchange = function(i, value)
              config.minFps = value
            --   log("Minimum FPS set to " .. value)
          end,
        },
        { id = "adaptive_gfx_cooldown",
          name = "   Cooldown (seconds)",
          type = "slider",
          min = 1, max = 30, step = 1,
          value = config.cooldown,
          description = "Wait time after a change before considering another adjustment.",
          onchange = function(i, value)
              config.cooldown = value
            --   log("Cooldown set to " .. value .. "s")
          end,
        },
        { id = "adaptive_gfx_restore",
          name = "   Restore Original Settings",
          type = "bool",
          value = false,
          description = "Toggle to restore all settings to their values before adaptive changes.",
          onchange = function(i, value)
              if value then
                  log("Restoring all settings to original values...")
                  while currentDegradeIndex > 0 do
                      upgradeOneStep()
                  end
                  log("All settings restored")
                  -- Reset the toggle back to off
                  if WG['options'] and WG['options'].applyOptionValue then
                      WG['options'].applyOptionValue("adaptive_gfx_restore", 0)
                  end
              end
          end,
        },
    })

    log("Options registered in settings menu (Custom tab)")
    optionsRegistered = true
    return true
end

local function removeOptions()
    if WG['options'] and WG['options'].removeOptions then
        WG['options'].removeOptions({
            "adaptive_gfx_label",
            "adaptive_gfx_spacer",
            "adaptive_gfx_enabled",
            "adaptive_gfx_target_fps",
            "adaptive_gfx_min_fps",
            "adaptive_gfx_cooldown",
            "adaptive_gfx_restore",
        })
        log("Options removed from settings menu")
    end
end

--------------------------------------------------------------------------------
-- Widget Callins
--------------------------------------------------------------------------------

function widget:Initialize()
    log("Initializing...")
    log("  Spring.GetFPS available: " .. tostring(Spring.GetFPS ~= nil))
    log("  Spring.GetPlayerInfo available: " .. tostring(Spring.GetPlayerInfo ~= nil))

    myPlayerID = Spring.GetMyPlayerID()
    log("  My player ID: " .. tostring(myPlayerID))

    -- Try to register options immediately (may fail if options widget loads later)
    -- if not registerOptions() then
    --     log("WG['options'] not ready yet — will retry on next Update()")
    -- end
end

function widget:Update(dt)
    -- Finish initialization once the options widget is available
    if not initialized then
        if not optionsRegistered then
            if not registerOptions() then
                return
            end
        end
        -- Log the current state of all managed settings for diagnostics
        snapshotOriginalValues()
        -- Detect if any settings appear already degraded (e.g. from a previous session)
        local detectedLevel = detectCurrentDegradeIndex()
        -- if detectedLevel > 0 then
        --     log("WARNING: detected " .. detectedLevel .. " setting(s) already at degraded values — starting fresh from index 0 anyway")
        -- end
        -- Always start from 0: treat current settings as the pristine baseline for this session
        -- currentDegradeIndex = 0
        currentDegradeIndex = detectedLevel
        initialized = true
        log("Monitoring started (enabled=" .. tostring(config.enabled) .. ", levels=" .. #SETTING_LEVELS .. ")")
        return
    end

    if not config.enabled then
        return
    end

    -- Handle cooldown
    if cooldownTimer > 0 then
        cooldownTimer = cooldownTimer - dt
        return
    end

    -- Sample FPS periodically
    sampleTimer = sampleTimer + dt
    if sampleTimer >= config.sampleInterval then
        sampleTimer = 0

        local fps = Spring.GetFPS()
        local cpu = getCpuUsage()

        fpsSamples[#fpsSamples + 1] = fps

        log(string.format("Sample %d/%d: FPS=%d  CPU=%.0f%%",
            #fpsSamples, config.sampleCount,
            fps, (cpu or 0) * 100))

        -- Once we have enough samples, evaluate and decide
        if #fpsSamples >= config.sampleCount then
            evaluatePerformance()
            fpsSamples = {}
        end
    end
end

function widget:Shutdown()
    log("Shutting down...")
    removeOptions()
    log("Shutdown complete")
end

function widget:GetConfigData()
    return {
        enabled        = config.enabled,
        targetFps      = config.targetFps,
        minFps         = config.minFps,
        cooldown       = config.cooldown,
        sampleInterval = config.sampleInterval,
        sampleCount    = config.sampleCount,
    }
end

function widget:SetConfigData(data)
    if data then
        if data.enabled ~= nil then config.enabled = data.enabled end
        if data.targetFps then config.targetFps = data.targetFps end
        if data.minFps then config.minFps = data.minFps end
        if data.cooldown then config.cooldown = data.cooldown end
        if data.sampleInterval then config.sampleInterval = data.sampleInterval end
        if data.sampleCount then config.sampleCount = data.sampleCount end
        log("Loaded saved config: targetFPS=" .. config.targetFps
            .. "  minFPS=" .. config.minFps
            .. "  cooldown=" .. config.cooldown .. "s"
            .. "  enabled=" .. tostring(config.enabled))
    end
end

