---@diagnostic disable: undefined-global
local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Top Bar Extra",
		desc = "Adds a more detailed resource display.",
		author = "uBdead",
		date = "2025.08.16",
		license = "GNU GPL, v2 or later",
		layer = -9999991,
		enabled = true,
	}
end

-- Spring API
local spGetMyTeamID = Spring.GetMyTeamID
local spGetTeamResources = Spring.GetTeamResources

-- UI
local font

-- State
local history_size
local metal_history
local energy_history
local smoothed_metal_balance
local smoothed_energy_balance

-- Math
local sformat = string.format
local math_floor = math.floor

local function short(n, f)
	if f == nil then f = 0 end
	local abs_n = math.abs(n)

	if abs_n > 999999 then
		return sformat("%+." .. f .. "fm", n / 1000000)
	elseif abs_n > 999 then
		return sformat("%+." .. f .. "fk", n / 1000)
	else
		return sformat("%+d", n)
	end
end

function widget:Initialize()
    if WG.fonts then
        font = WG.fonts.getFont(2)
    end

    history_size = 10 * (Game.gameSpeed or 30)
    metal_history = {}
    energy_history = {}
    smoothed_metal_balance = 0
    smoothed_energy_balance = 0
end

function widget:Update(dt)
    local myTeamID = spGetMyTeamID()
    if not myTeamID then return end

    -- Metal
    local _, _, m_pull, m_income = spGetTeamResources(myTeamID, 'metal')
    local m_balance = m_income - m_pull
    table.insert(metal_history, m_balance)
    if #metal_history > history_size then
        table.remove(metal_history, 1)

        local m_sum = 0
        for i = 1, #metal_history do
            m_sum = m_sum + metal_history[i]
        end
        if #metal_history > 0 then
            smoothed_metal_balance = m_sum / #metal_history
        end

        metal_history = {}
    end

    -- Energy
    local _, _, e_pull, e_income = spGetTeamResources(myTeamID, 'energy')
    local e_balance = e_income - e_pull
    table.insert(energy_history, e_balance)
    if #energy_history > history_size then
        table.remove(energy_history, 1)

        local e_sum = 0
        for i = 1, #energy_history do
            e_sum = e_sum + energy_history[i]
        end
        if #energy_history > 0 then
            smoothed_energy_balance = e_sum / #energy_history
        end

        energy_history = {}
    end
end

function widget:DrawScreen()
    if not font then
        if WG.fonts then
            font = WG.fonts.getFont(2)
            if not font then return end
        else
            return
        end
    end

    -- Re-calculate bar positions since we cannot rely on WG.topbar
    local vsx, vsy = Spring.GetViewGeometry()
    local ui_scale = tonumber(Spring.GetConfigFloat("ui_scale", 1) or 1)
    local orgHeight = 46
    local height = orgHeight * (1 + (ui_scale - 1) / 1.7)
    local widgetScale = (0.80 + (vsx * vsy / 6000000))
    local relXpos = 0.3
    local borderPadding = 5
    local xPos = math_floor(vsx * relXpos)
    local widgetSpaceMargin = 5 -- Default value from FlowUI

    local topbarArea = { math_floor(xPos + (borderPadding * widgetScale)), math_floor(vsy - (height * widgetScale)), vsx, vsy }
    local totalWidth = topbarArea[3] - topbarArea[1]
    local metal_width = math_floor(totalWidth / 4.4)
    local energy_width = metal_width

    local metalArea = { topbarArea[1], topbarArea[2], topbarArea[1] + metal_width, topbarArea[4] }
    local energy_x = topbarArea[1] + metal_width + widgetSpaceMargin
    local energyArea = { energy_x, topbarArea[2], energy_x + energy_width, topbarArea[4] }

    font:Begin()
    font:SetOutlineColor(0,0,0,1)

    -- Energy Balance
    local e_balance = smoothed_energy_balance
    local e_color
    if e_balance >= 0 then
        e_color = "\255\120\235\120" -- green
    else
        e_color = "\255\240\125\125" -- red
    end
    local e_barHeight = energyArea[4] - energyArea[2]
    local e_x = energyArea[1] + e_barHeight / 2
    local e_y = energyArea[2] + e_barHeight * 0.5
    font:Print(e_color .. short(e_balance, 1), e_x, e_y, 24, "co")

    -- Metal Balance
    local m_balance = smoothed_metal_balance
    local m_color
    if m_balance >= 0 then
        m_color = "\255\120\235\120" -- green
    else
        m_color = "\255\240\125\125" -- red
    end
    local m_barHeight = metalArea[4] - metalArea[2]
    local m_x = metalArea[1] + m_barHeight / 2
    local m_y = metalArea[2] + m_barHeight * 0.5
    font:Print(m_color .. short(m_balance, 1), m_x, m_y, 24, "co")

    font:End()
end
