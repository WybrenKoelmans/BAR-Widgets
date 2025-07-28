local widget = widget ---@type Widget
local startTimer = 3
local fase = 0

function widget:GetInfo()
    return {
        name    = "Map Camera Startup",
        desc    = "",
        author  = "uBdead",
        date    = "Jul 28 2025",
        license = "GPL v3 or later",
        layer   = 0,
        enabled = true
    }
end

function widget:Update(dt)
    if (dt > 0.5) then
        -- If the dt is too large, we might be lagging, so we skip this update
        return
    end

    local cameraName = Spring.GetCameraState(false)
    if cameraName ~= "spring" and cameraName ~= "ta" then -- If the camera is not in spring or ta mode, we don't need to do anything
        Spring.Echo("Map Camera Startup: Camera is not in spring or ta mode, removing widget. \'" .. cameraName .. "\' not supported.")
        widgetHandler:RemoveWidget()
        return
    end 

    if Spring.GetGameFrame() > 1  then -- if the game already started, we don't need to do anything
        Spring.Echo("Map Camera Startup: Game already started, removing widget.")
        widgetHandler:RemoveWidget()
        return
    end

    startTimer = startTimer - dt

    if fase == 0 then
        -- Start by zooming out to the maximum zoom level
        local mapcx = Game.mapSizeX / 2
        local mapcz = Game.mapSizeZ / 2
        local mapcy = Spring.GetGroundHeight(mapcx, mapcz)

        local newCam = {
            px = mapcx,
            py = mapcy + 1000000, -- Set a high initial height to zoom out
            pz = mapcz,
            height = 1000000, -- Set a high initial height to zoom out
        }
        Spring.SetCameraState(newCam, 0)

        fase = 1
        return
    end

    if startTimer <= 0 then
        local camState = Spring.GetCameraState()

        -- Center the camera on the startbox
        local myAllyTeamID = Spring.GetMyAllyTeamID()
        local xn, zn, xp, zp = Spring.GetAllyTeamStartBox(myAllyTeamID)
        local x = (xn + xp) / 2
        local z = (zn + zp) / 2

        local mapHeightAtPos = Spring.GetGroundHeight(x, z)
        -- calculate the height based on the diagonal of the startbox
        local width = math.abs(xp - xn)
        local depth = math.abs(zp - zn)
        local diagonal = math.sqrt(width * width + depth * depth)
        local height = diagonal * 1.0 + mapHeightAtPos -- adjust multiplier as needed

        camState.px = x
        camState.pz = z
        camState.height = height
        camState.zoom = height / 2 -- Set a reasonable zoom level
        Spring.SetCameraState(camState, 1)
        widgetHandler:RemoveWidget()
    end
end
