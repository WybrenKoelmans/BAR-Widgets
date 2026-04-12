local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Resource Panels",
		desc = "Shows the amount of metal/energy units are using during Resource Mode screenmode.",
		author = "uBdead",
		date = "2026-04-12",
		license = "GNU GPL, v2 or later",
		layer = 1,
		enabled = true
	}
end

--------------------------------------------------------------------------------
-- Localized Spring API
--------------------------------------------------------------------------------
local spGetMapDrawMode = Spring.GetMapDrawMode
local spGetMyTeamID = Spring.GetMyTeamID
local spGetTeamUnits = Spring.GetTeamUnits
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitResources = Spring.GetUnitResources
local spGetUnitViewPosition = Spring.GetUnitViewPosition
local spGetUnitHealth = Spring.GetUnitHealth
local spIsSphereInView = Spring.IsSphereInView
local spGetViewGeometry = Spring.GetViewGeometry
local spGetCameraPosition = Spring.GetCameraPosition
local spGetGameFrame = Spring.GetGameFrame
local spGetSpectatingState = Spring.GetSpectatingState
local spWorldToScreenCoords = Spring.WorldToScreenCoords
local spGetGroundHeight = Spring.GetGroundHeight
local spValidUnitID = Spring.ValidUnitID
local spGetUnitIsBuilding = Spring.GetUnitIsBuilding

local glColor = gl.Color
local glPushMatrix = gl.PushMatrix
local glPopMatrix = gl.PopMatrix
local glTranslate = gl.Translate
local glBillboard = gl.Billboard
local glDepthTest = gl.DepthTest
local glLineWidth = gl.LineWidth
local glRect = gl.Rect
local glTexture = gl.Texture
local glBeginEnd = gl.BeginEnd
local glVertex = gl.Vertex
local GL_QUADS = GL.QUADS

local mathMax = math.max
local mathMin = math.min
local mathFloor = math.floor
local mathAbs = math.abs
local mathSqrt = math.sqrt
local strFormat = string.format
local tableSort = table.sort
local tableInsert = table.insert

--------------------------------------------------------------------------------
-- Constants & Configuration
--------------------------------------------------------------------------------
local UPDATE_RATE = 15 -- frames between data refreshes
local OVERVIEW_UPDATE_RATE = 30 -- frames between overview data refreshes
local MAX_WORLD_LABELS = 200 -- max labels drawn in world view
local MIN_RESOURCE_THRESHOLD = 0.1 -- ignore units with resource flow below this
local OVERVIEW_PANEL_WIDTH_FRAC = 0.20 -- fraction of screen width
local OVERVIEW_PANEL_MAX_ROWS = 20

local CLUSTER_SCREEN_DIST = 120 -- screen pixel radius for merging labels

-- Colors
local COLOR_METAL_MAKE = { 0.4, 0.9, 1.0, 1.0 } -- cyan-ish for metal income
local COLOR_METAL_USE = { 0.3, 0.7, 0.85, 1.0 } -- darker cyan for metal drain
local COLOR_ENERGY_MAKE = { 1.0, 1.0, 0.3, 1.0 } -- yellow for energy income
local COLOR_ENERGY_USE = { 0.85, 0.85, 0.2, 1.0 } -- darker yellow for energy drain
local COLOR_BG = { 0.0, 0.0, 0.0, 0.55 }
local COLOR_BG_HEADER = { 0.0, 0.0, 0.0, 0.7 }
local COLOR_TEXT_WHITE = { 1.0, 1.0, 1.0, 1.0 }
local COLOR_TEXT_DIM = { 0.7, 0.7, 0.7, 1.0 }
local COLOR_METAL = { 0.5, 0.9, 1.0 }
local COLOR_ENERGY = { 1.0, 1.0, 0.3 }
local COLOR_DRAIN_HIGH = { 1.0, 0.3, 0.3 } -- red for biggest drain
local COLOR_DRAIN_MED = { 1.0, 0.6, 0.2 } -- orange for medium drain
local COLOR_DRAIN_LOW = { 0.8, 0.8, 0.8 } -- gray for low drain

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local vsx, vsy = spGetViewGeometry()
local widgetScale = (0.80 + (vsx * vsy / 6000000))

local font, font2
local screenmode = "normal"
local isResourceMode = false

-- Per-unit live data: unitID -> { mMake, mUse, eMake, eUse, defID, x, y, z }
local unitResourceData = {}

-- Aggregated per-unitDefID data for overview
-- defID -> { name, count, totalMUse, totalMMake, totalEUse, totalEMake }
local overviewData = {}
local overviewSorted = {} -- sorted array of overviewData entries
local overviewTotals = { mMake = 0, mUse = 0, eMake = 0, eUse = 0 }

-- Pre-cached unitDef info: defID -> { name, height, isBuilding }
local unitDefCache = {}

local lastUpdateFrame = -999
local lastOverviewUpdateFrame = -999
local chobbyInterface = false

--------------------------------------------------------------------------------
-- UnitDef cache (built once)
--------------------------------------------------------------------------------
local function buildUnitDefCache()
	for defID, def in pairs(UnitDefs) do
		local name = def.translatedHumanName or def.humanName or def.name or "Unknown"
		local height = def.height or 40
		local isBuilding = not def.canMove
		local isFactory = def.isFactory or false
		local isBuilder = def.isBuilder or false
		local isMex = (def.extractsMetal or 0) > 0
		local isWind = def.windGenerator and def.windGenerator > 0
		local isTidal = def.tidalGenerator and def.tidalGenerator > 0

		local category = "Other"
		if isMex then
			category = "Metal Extractor"
		elseif isFactory then
			category = "Factory"
		elseif isBuilder and not isFactory then
			category = "Constructor"
		elseif isBuilding then
			category = "Building"
		else
			category = "Unit"
		end

		unitDefCache[defID] = {
			name = name,
			height = height,
			isBuilding = isBuilding,
			category = category,
		}
	end
end

--------------------------------------------------------------------------------
-- Data collection (throttled)
--------------------------------------------------------------------------------
local function collectUnitData()
	local myTeamID = spGetMyTeamID()
	local units = spGetTeamUnits(myTeamID)
	if not units then return end

	-- Clear old data
	unitResourceData = {}
	local overview = {}
	local totals = { mMake = 0, mUse = 0, eMake = 0, eUse = 0 }

	for i = 1, #units do
		local unitID = units[i]
		local defID = spGetUnitDefID(unitID)
		if defID then
			local mMake, mUse, eMake, eUse = spGetUnitResources(unitID)
			if mMake then
				local hasActivity = mMake > MIN_RESOURCE_THRESHOLD
					or mUse > MIN_RESOURCE_THRESHOLD
					or eMake > MIN_RESOURCE_THRESHOLD
					or eUse > MIN_RESOURCE_THRESHOLD

				if hasActivity then
					-- Check if unit is being built (skip incomplete)
					local _, _, _, _, buildProgress = spGetUnitHealth(unitID)
					if buildProgress and buildProgress >= 1.0 then
						local x, y, z = spGetUnitViewPosition(unitID)
						if x then
							unitResourceData[unitID] = {
								mMake = mMake,
								mUse = mUse,
								eMake = eMake,
								eUse = eUse,
								defID = defID,
								x = x, y = y, z = z,
							}
						end

							-- Detect what this unit is actively building
							local buildTargetDefID = 0
							local buildeeID = spGetUnitIsBuilding(unitID)
							if buildeeID then
								local buildeeDefID = spGetUnitDefID(buildeeID)
								if buildeeDefID then
									buildTargetDefID = buildeeDefID
								end
							end

							-- Determine display name for grouping
							local cache = unitDefCache[defID]
							local displayName
							if buildTargetDefID ~= 0 and unitDefCache[buildTargetDefID] then
								displayName = unitDefCache[buildTargetDefID].name
							else
								displayName = cache and cache.name or "Unknown"
							end

							-- Aggregate for overview, grouped by display name
							local overviewKey = displayName
							if not overview[overviewKey] then
								overview[overviewKey] = {
									name = displayName,
									category = cache and cache.category or "Other",
									count = 0,
									totalMMake = 0,
									totalMUse = 0,
									totalEMake = 0,
									totalEUse = 0,
								}
							end
							local o = overview[overviewKey]
						o.count = o.count + 1
						o.totalMMake = o.totalMMake + mMake
						o.totalMUse = o.totalMUse + mUse
						o.totalEMake = o.totalEMake + eMake
						o.totalEUse = o.totalEUse + eUse

						totals.mMake = totals.mMake + mMake
						totals.mUse = totals.mUse + mUse
						totals.eMake = totals.eMake + eMake
						totals.eUse = totals.eUse + eUse
					end
				end
			end
		end
	end

	overviewData = overview
	overviewTotals = totals

	-- Sort overview by total resource drain (metal use + energy use) descending
	overviewSorted = {}
	for defID, data in pairs(overview) do
		data.defID = defID
		data.totalDrain = data.totalMUse + data.totalEUse
		data.totalIncome = data.totalMMake + data.totalEMake
		tableInsert(overviewSorted, data)
	end
	tableSort(overviewSorted, function(a, b)
		return a.totalDrain > b.totalDrain
	end)
end

--------------------------------------------------------------------------------
-- Formatting helpers
--------------------------------------------------------------------------------
local function formatResource(value)
	if value >= 1000 then
		return strFormat("%.1fk", value / 1000)
	elseif value >= 100 then
		return strFormat("%.0f", value)
	elseif value >= 10 then
		return strFormat("%.1f", value)
	else
		return strFormat("%.1f", value)
	end
end

local function getDrainColor(drain, maxDrain)
	if maxDrain <= 0 then return COLOR_DRAIN_LOW end
	local ratio = drain / maxDrain
	if ratio > 0.5 then
		return COLOR_DRAIN_HIGH
	elseif ratio > 0.2 then
		return COLOR_DRAIN_MED
	else
		return COLOR_DRAIN_LOW
	end
end

--------------------------------------------------------------------------------
-- Screen-space unit panels with clustering
--------------------------------------------------------------------------------
local function clusterLabels(labels)
	local clusters = {}
	local assigned = {}

	for i = 1, #labels do
		if not assigned[i] then
			assigned[i] = true
			local cl = {
				sx = labels[i].sx,
				sy = labels[i].sy,
				dist = labels[i].dist,
				mMake = labels[i].data.mMake,
				mUse = labels[i].data.mUse,
				eMake = labels[i].data.eMake,
				eUse = labels[i].data.eUse,
				count = 1,
				names = {},
			}
			local cache = unitDefCache[labels[i].data.defID]
			cl.names[cache and cache.name or "Unknown"] = 1

			local sumSx = labels[i].sx
			local sumSy = labels[i].sy

			for j = i + 1, #labels do
				if not assigned[j] then
					local avgX = sumSx / cl.count
					local avgY = sumSy / cl.count
					local dx = avgX - labels[j].sx
					local dy = avgY - labels[j].sy
					if dx * dx + dy * dy < CLUSTER_SCREEN_DIST * CLUSTER_SCREEN_DIST then
						assigned[j] = true
						cl.mMake = cl.mMake + labels[j].data.mMake
						cl.mUse = cl.mUse + labels[j].data.mUse
						cl.eMake = cl.eMake + labels[j].data.eMake
						cl.eUse = cl.eUse + labels[j].data.eUse
						cl.count = cl.count + 1
						cl.dist = mathMin(cl.dist, labels[j].dist)
						sumSx = sumSx + labels[j].sx
						sumSy = sumSy + labels[j].sy
						local name = unitDefCache[labels[j].data.defID]
						name = name and name.name or "Unknown"
						cl.names[name] = (cl.names[name] or 0) + 1
					end
				end
			end

			cl.sx = sumSx / cl.count
			cl.sy = sumSy / cl.count

			tableInsert(clusters, cl)
		end
	end

	return clusters
end

local function drawUnitPanels()
	local camX, camY, camZ = spGetCameraPosition()
	if not camX then return end

	local labels = {}
	for unitID, data in pairs(unitResourceData) do
		local x, y, z = data.x, data.y, data.z
		local height = (unitDefCache[data.defID] and unitDefCache[data.defID].height or 40) + 15
		local drawY = y + height

		if spIsSphereInView(x, drawY, z, 80) then
			local dx = camX - x
			local dy = camY - drawY
			local dz = camZ - z
			local dist = mathSqrt(dx * dx + dy * dy + dz * dz)

			local sx, sy = spWorldToScreenCoords(x, drawY, z)
			if sx then
				tableInsert(labels, {
					data = data,
					dist = dist,
					sx = sx,
					sy = sy,
				})
			end
		end
	end

	if #labels == 0 then return end

	-- Always cluster labels
	local panels = clusterLabels(labels)

	-- Sort closest first, limit count
	tableSort(panels, function(a, b) return a.dist < b.dist end)
	local count = mathMin(#panels, MAX_WORLD_LABELS)

	local fontSize = mathFloor(11 * widgetScale)
	local lineH = mathFloor(fontSize * 1.4)
	local padX = mathFloor(6 * widgetScale)
	local padY = mathFloor(4 * widgetScale)

	-- Pre-compute panel geometry and text
	local panelRenders = {}
	for i = 1, count do
		local p = panels[i]

		local lines = {}
		local lineColors = {}

		-- Show unit type summary for clusters
		if p.count > 1 then
			local parts = {}
			local partCount = 0
			for name, cnt in pairs(p.names) do
				partCount = partCount + 1
				if partCount > 3 then
					parts[#parts + 1] = "..."
					break
				end
				if cnt > 1 then
					parts[#parts + 1] = cnt .. "x " .. name
				else
					parts[#parts + 1] = name
				end
			end
			lines[#lines + 1] = p.count .. " units"
			lineColors[#lineColors + 1] = COLOR_TEXT_WHITE
		end

		-- Net metal
		local mNet = p.mMake - p.mUse
		if mathAbs(mNet) > MIN_RESOURCE_THRESHOLD then
			local sign = mNet >= 0 and "+" or ""
			lines[#lines + 1] = sign .. formatResource(mNet) .. " M"
			lineColors[#lineColors + 1] = mNet >= 0 and COLOR_METAL_MAKE or COLOR_METAL_USE
		end

		-- Net energy
		local eNet = p.eMake - p.eUse
		if mathAbs(eNet) > MIN_RESOURCE_THRESHOLD then
			local sign = eNet >= 0 and "+" or ""
			lines[#lines + 1] = sign .. formatResource(eNet) .. " E"
			lineColors[#lineColors + 1] = eNet >= 0 and COLOR_ENERGY_MAKE or COLOR_ENERGY_USE
		end

		if #lines > 0 then
			local maxW = 0
			for j = 1, #lines do
				local w = font2:GetTextWidth(lines[j]) * fontSize
				if w > maxW then maxW = w end
			end

			local panelW = maxW + padX * 2
			local panelH = #lines * lineH + padY * 2
			local px = p.sx - panelW * 0.5
			local py = p.sy

			panelRenders[#panelRenders + 1] = {
				px = px, py = py,
				panelW = panelW, panelH = panelH,
				lines = lines, lineColors = lineColors,
				alpha = 1.0, count = p.count,
			}
		end
	end

	-- Pass 1: draw all panel backgrounds
	for i = 1, #panelRenders do
		local pd = panelRenders[i]
		glColor(0, 0, 0, 0.7 * pd.alpha)
		glRect(pd.px, pd.py, pd.px + pd.panelW, pd.py + pd.panelH)
		-- Subtle border
		glColor(0.5, 0.5, 0.5, 0.3 * pd.alpha)
		glRect(pd.px, pd.py + pd.panelH, pd.px + pd.panelW, pd.py + pd.panelH + 1)
		glRect(pd.px, pd.py - 1, pd.px + pd.panelW, pd.py)
		glRect(pd.px - 1, pd.py, pd.px, pd.py + pd.panelH)
		glRect(pd.px + pd.panelW, pd.py, pd.px + pd.panelW + 1, pd.py + pd.panelH)
		-- Cluster accent bar
		if pd.count > 1 then
			glColor(0.8, 0.8, 0.2, 0.3 * pd.alpha)
			glRect(pd.px, pd.py + pd.panelH - 2, pd.px + pd.panelW, pd.py + pd.panelH)
		end
	end

	-- Pass 2: draw all text in a single batch
	font2:Begin()
	for i = 1, #panelRenders do
		local pd = panelRenders[i]
		for j = 1, #pd.lines do
			local c = pd.lineColors[j]
			font2:SetTextColor(c[1], c[2], c[3], pd.alpha)
			font2:Print(pd.lines[j], pd.px + padX, pd.py + pd.panelH - padY - j * lineH + lineH * 0.3, fontSize, "o")
		end
	end
	font2:End()

	glColor(1, 1, 1, 1)
end

--------------------------------------------------------------------------------
-- DrawScreen: overview panel
--------------------------------------------------------------------------------
local function drawRoundedRect(x1, y1, x2, y2, r, g, b, a)
	glColor(r, g, b, a)
	glRect(x1, y1, x2, y2)
end

local function drawOverviewPanel()
	if #overviewSorted == 0 then return end

	local panelW = mathFloor(vsx * OVERVIEW_PANEL_WIDTH_FRAC)
	local panelMinW = 280
	local panelMaxW = 450
	panelW = mathMax(panelMinW, mathMin(panelMaxW, panelW))

	local rowH = mathFloor(22 * widgetScale)
	local headerH = mathFloor(32 * widgetScale)
	local sectionHeaderH = mathFloor(26 * widgetScale)
	local padding = mathFloor(8 * widgetScale)
	local totalRows = mathMin(#overviewSorted, OVERVIEW_PANEL_MAX_ROWS)

	-- Calculate panel height: header + totals row + separator + data rows
	local panelH = headerH + rowH * 2 + padding + (totalRows * rowH) + padding * 2

	local x1 = vsx - panelW - mathFloor(10 * widgetScale)
	local y1 = vsy - panelH - mathFloor(80 * widgetScale) -- below top bar
	local x2 = x1 + panelW
	local y2 = y1 + panelH

	-- Background
	drawRoundedRect(x1, y1, x2, y2, COLOR_BG[1], COLOR_BG[2], COLOR_BG[3], COLOR_BG[4])

	-- Header
	drawRoundedRect(x1, y2 - headerH, x2, y2, COLOR_BG_HEADER[1], COLOR_BG_HEADER[2], COLOR_BG_HEADER[3], COLOR_BG_HEADER[4])

	local headerFontSize = mathFloor(14 * widgetScale)
	local rowFontSize = mathFloor(11 * widgetScale)
	local smallFontSize = mathFloor(10 * widgetScale)

	font2:Begin()

	-- Title
	font2:SetTextColor(1, 1, 1, 1)
	font2:Print("Resource Overview", x1 + padding, y2 - headerH * 0.65, headerFontSize, "o")

	-- Column headers
	local colName = x1 + padding
	local colCount = x1 + panelW * 0.45
	local colMetal = x1 + panelW * 0.58
	local colEnergy = x1 + panelW * 0.79

	local headerY = y2 - headerH - rowH * 0.65

	font2:SetTextColor(COLOR_TEXT_DIM[1], COLOR_TEXT_DIM[2], COLOR_TEXT_DIM[3], 1)
	font2:Print("Unit Type", colName, headerY, smallFontSize, "o")
	font2:Print("#", colCount, headerY, smallFontSize, "o")
	font2:SetTextColor(COLOR_METAL[1], COLOR_METAL[2], COLOR_METAL[3], 1)
	font2:Print("Metal", colMetal, headerY, smallFontSize, "o")
	font2:SetTextColor(COLOR_ENERGY[1], COLOR_ENERGY[2], COLOR_ENERGY[3], 1)
	font2:Print("Energy", colEnergy, headerY, smallFontSize, "o")

	-- Totals row
	local totalsY = headerY - rowH
	font2:SetTextColor(1, 1, 1, 1)
	font2:Print("TOTALS", colName, totalsY, rowFontSize, "o")

	font2:SetTextColor(COLOR_METAL[1], COLOR_METAL[2], COLOR_METAL[3], 1)
	local metalNet = overviewTotals.mMake - overviewTotals.mUse
	local metalSign = metalNet >= 0 and "+" or ""
	font2:Print(metalSign .. formatResource(metalNet), colMetal, totalsY, rowFontSize, "o")

	font2:SetTextColor(COLOR_ENERGY[1], COLOR_ENERGY[2], COLOR_ENERGY[3], 1)
	local energyNet = overviewTotals.eMake - overviewTotals.eUse
	local energySign = energyNet >= 0 and "+" or ""
	font2:Print(energySign .. formatResource(energyNet), colEnergy, totalsY, rowFontSize, "o")

	-- Separator line
	local sepY = totalsY - padding * 0.5
	glColor(0.4, 0.4, 0.4, 0.6)
	glRect(x1 + padding, sepY, x2 - padding, sepY + 1)

	-- Data rows
	local maxDrain = overviewSorted[1] and overviewSorted[1].totalDrain or 0

	for i = 1, totalRows do
		local entry = overviewSorted[i]
		local rowY = sepY - (i * rowH) + rowH * 0.35

		-- Drain bar background (visual indicator of relative drain)
		if entry.totalDrain > 0 and maxDrain > 0 then
			local barFrac = entry.totalDrain / maxDrain
			local barW = (panelW - padding * 2) * barFrac
			local drainCol = getDrainColor(entry.totalDrain, maxDrain)
			glColor(drainCol[1], drainCol[2], drainCol[3], 0.12)
			glRect(x1 + padding, rowY - rowH * 0.35, x1 + padding + barW, rowY + rowH * 0.65)
		end

		-- Unit name (truncated if needed)
		local nameStr = entry.name
		if #nameStr > 20 then
			nameStr = nameStr:sub(1, 18) .. ".."
		end
		local drainCol = getDrainColor(entry.totalDrain, maxDrain)
		font2:SetTextColor(drainCol[1], drainCol[2], drainCol[3], 1)
		font2:Print(nameStr, colName, rowY, rowFontSize, "o")

		-- Count
		font2:SetTextColor(COLOR_TEXT_DIM[1], COLOR_TEXT_DIM[2], COLOR_TEXT_DIM[3], 1)
		font2:Print(tostring(entry.count), colCount, rowY, rowFontSize, "o")

		-- Metal net
		local mNet = entry.totalMMake - entry.totalMUse
		if mathAbs(mNet) > MIN_RESOURCE_THRESHOLD then
			local sign = mNet >= 0 and "+" or ""
			font2:SetTextColor(COLOR_METAL[1], COLOR_METAL[2], COLOR_METAL[3], 1)
			font2:Print(sign .. formatResource(mNet), colMetal, rowY, rowFontSize, "o")
		end

		-- Energy net
		local eNet = entry.totalEMake - entry.totalEUse
		if mathAbs(eNet) > MIN_RESOURCE_THRESHOLD then
			local sign = eNet >= 0 and "+" or ""
			font2:SetTextColor(COLOR_ENERGY[1], COLOR_ENERGY[2], COLOR_ENERGY[3], 1)
			font2:Print(sign .. formatResource(eNet), colEnergy, rowY, rowFontSize, "o")
		end
	end

	-- Show "... and N more" if truncated
	if #overviewSorted > totalRows then
		local moreY = sepY - ((totalRows + 1) * rowH) + rowH * 0.35
		font2:SetTextColor(COLOR_TEXT_DIM[1], COLOR_TEXT_DIM[2], COLOR_TEXT_DIM[3], 0.7)
		font2:Print("... and " .. (#overviewSorted - totalRows) .. " more types", colName, moreY, smallFontSize, "o")
	end

	font2:End()
end

--------------------------------------------------------------------------------
-- Widget callins
--------------------------------------------------------------------------------
function widget:Initialize()
	buildUnitDefCache()
	widget:ViewResize()
end

function widget:ViewResize()
	vsx, vsy = spGetViewGeometry()
	widgetScale = (0.80 + (vsx * vsy / 6000000))

	if WG['fonts'] then
		font = WG['fonts'].getFont(nil, 1.2, 0.2, 20)
		font2 = WG['fonts'].getFont(2, 1.0)
	end
end

function widget:RecvLuaMsg(msg, playerID)
	if msg:sub(1, 18) == 'LobbyOverlayActive' then
		chobbyInterface = (msg:sub(1, 19) == 'LobbyOverlayActive1')
	end
end

function widget:Update(dt)
	local newMode = spGetMapDrawMode()
	isResourceMode = (newMode == 'metal')
	screenmode = newMode
end

function widget:DrawWorld()
	if chobbyInterface then return end
	if not isResourceMode then return end

	local gameFrame = spGetGameFrame()
	if gameFrame - lastUpdateFrame >= UPDATE_RATE then
		lastUpdateFrame = gameFrame
		collectUnitData()
	end
end

function widget:DrawScreen()
	if chobbyInterface then return end
	if not isResourceMode then return end
	if not font2 then return end
	if WG['topbar'] and WG['topbar'].showingQuit() then return end

	drawUnitPanels()
	drawOverviewPanel()
end

function widget:GameOver()
	widgetHandler:RemoveWidget()
end

