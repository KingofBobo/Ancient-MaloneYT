-- ============================================================================
-- ICARUS CUSTOM WAYPOINTS, WAYPOINT CUSTOMIZATION & LIVE HOSTILE RADAR (UE4SS)
-- Path: A:\SteamLibrary\steamapps\common\Icarus\Icarus\Binaries\Win64\ue4ss\Mods\CustomWaypoints\Scripts\main.lua
-- ============================================================================

local UEHelpers = require("UEHelpers")

-- ============================================================================
-- CONFIGURATION & ZOOM / COLOR PRESETS
-- ============================================================================
local CONFIG = {
    RADAR_X = 115.0,
    RADAR_Y = 210.0,
    RADAR_RADIUS = 85.0,
    ZOOM_LEVELS = { 7500.0, 15000.0, 30000.0, 60000.0 }, -- 75m, 150m, 300m, 600m
    DEFAULT_ZOOM_INDEX = 2,
    PREDATOR_ALERT_RANGE = 4500.0, -- 45m proximity danger warning
    NORTH_OFFSET = -90.0,          -- Calibrated for Icarus top compass bar (-Y = North)
    INVERT_YAW = false,            -- Set to true only if turning left/right spins compass backwards
    SCAN_INTERVAL_MS = 650,
    SAVE_FILE = "Mods/CustomWaypoints/waypoints_data.lua"
}

local WAYPOINT_COLORS = {
    { name = "Gold",    col = { R = 1.00, G = 0.82, B = 0.20, A = 1.00 } },
    { name = "Cyan",    col = { R = 0.20, G = 0.88, B = 1.00, A = 1.00 } },
    { name = "Lime",    col = { R = 0.30, G = 0.95, B = 0.40, A = 1.00 } },
    { name = "Magenta", col = { R = 0.95, G = 0.35, B = 0.90, A = 1.00 } },
    { name = "Orange",  col = { R = 1.00, G = 0.50, B = 0.15, A = 1.00 } },
    { name = "White",   col = { R = 0.95, G = 0.95, B = 0.95, A = 1.00 } }
}

local WAYPOINT_SHAPES = { "SQUARE", "DIAMOND", "CROSS", "TRIANGLE" }

-- ============================================================================
-- RUNTIME STATE
-- ============================================================================
local Waypoints = {}
local RadarEntities = {}
local NearestPredator = nil
local ZoomIndex = CONFIG.DEFAULT_ZOOM_INDEX
local ShowWorldPins = true
local ShowPredators = true
local EditMode = false
local PromptOpen = false
local PromptMode = "add" -- "add" | "rename"
local PromptTargetIndex = nil
local PromptBuffer = ""
local RowHitboxes = {}
local HookedHUDClasses = {}
local EngineHUDHooked = false
local LastMouseDown = false

-- Base UI Colors
local COL_BG       = { R = 0.06, G = 0.08, B = 0.09, A = 0.85 }
local COL_RING     = { R = 0.82, G = 0.84, B = 0.86, A = 0.72 }
local COL_TICK     = { R = 0.85, G = 0.85, B = 0.85, A = 0.55 }
local COL_CROSS    = { R = 0.55, G = 0.58, B = 0.60, A = 0.30 }
local COL_PLAYER   = { R = 0.25, G = 0.90, B = 0.45, A = 1.00 }
local COL_COOP     = { R = 0.25, G = 0.75, B = 1.00, A = 1.00 }
local COL_PREDATOR = { R = 1.00, G = 0.22, B = 0.22, A = 1.00 }
local COL_WARN_BG  = { R = 0.45, G = 0.05, B = 0.05, A = 0.90 }
local COL_GOLD     = { R = 1.00, G = 0.82, B = 0.20, A = 1.00 }
local COL_TELEM    = { R = 1.00, G = 0.55, B = 0.15, A = 0.95 }
local COL_TEXT     = { R = 0.95, G = 0.95, B = 0.95, A = 1.00 }
local COL_SUBTEXT  = { R = 0.75, G = 0.78, B = 0.80, A = 0.92 }
local COL_DANGER   = { R = 0.90, G = 0.20, B = 0.20, A = 0.95 }
local COL_BTN      = { R = 0.18, G = 0.22, B = 0.26, A = 0.95 }

-- ============================================================================
-- SAFE PROPERTY UNWRAPPING
-- ============================================================================
local function SafeNum(val, fallback)
    if val == nil then return fallback end
    if type(val) == "number" then return val end
    local ok, num = pcall(function() return tonumber(tostring(val)) end)
    if ok and num then return num end
    return fallback
end

local function GetCurrentRadarRange()
    return CONFIG.ZOOM_LEVELS[ZoomIndex] or 15000.0
end

-- ============================================================================
-- PERSISTENCE (SAVE / LOAD CUSTOMIZED WAYPOINTS)
-- ============================================================================
local function SaveWaypoints()
    local file = io.open(CONFIG.SAVE_FILE, "w")
    if not file then return end
    file:write("return {\n")
    for _, wp in ipairs(Waypoints) do
        local safeName = tostring(wp.name):gsub("\\", "\\\\"):gsub('"', '\\"')
        local colIdx = wp.colorIndex or 1
        local shpIdx = wp.shapeIndex or 1
        local vis    = (wp.visible == nil) and true or wp.visible
        file:write(string.format(
            '    { name = "%s", x = %.2f, y = %.2f, z = %.2f, colorIndex = %d, shapeIndex = %d, visible = %s },\n',
            safeName, wp.x, wp.y, wp.z, colIdx, shpIdx, tostring(vis)
        ))
    end
    file:write("}\n")
    file:close()
end

local function LoadWaypoints()
    local chunk = loadfile(CONFIG.SAVE_FILE)
    if chunk then
        local ok, data = pcall(chunk)
        if ok and type(data) == "table" then
            for _, wp in ipairs(data) do
                wp.colorIndex = wp.colorIndex or 1
                wp.shapeIndex = wp.shapeIndex or 1
                if wp.visible == nil then wp.visible = true end
            end
            Waypoints = data
        end
    end
end

-- ============================================================================
-- LIVE PLAYER & CAMERA YAW READER (MULTI-FALLBACK FOR SMOOTH ROTATION)
-- ============================================================================
local function GetPlayerController()
    return UEHelpers.GetPlayerController()
end

local function GetPlayerPawnAndYaw()
    local pc = GetPlayerController()
    if not pc or not pc:IsValid() then return nil, 0.0 end

    local pawn = pc.Pawn
    if not pawn or not pawn:IsValid() then return nil, 0.0 end

    local yaw = nil

    -- 1. Primary: Live PlayerCameraManager rotation (updates smoothly every frame)
    local okCam, camMgr = pcall(function() return pc.PlayerCameraManager end)
    if okCam and camMgr and camMgr:IsValid() then
        local okCamRot, cRot = pcall(function() return camMgr:GetCameraRotation() end)
        if okCamRot and cRot then
            local val = SafeNum(cRot.Yaw, nil)
            if val ~= nil then yaw = val end
        end
    end

    -- 2. Fallback: Controller ControlRotation property
    if yaw == nil then
        local okCtrlProp, ctrlRot = pcall(function() return pc.ControlRotation end)
        if okCtrlProp and ctrlRot then
            local val = SafeNum(ctrlRot.Yaw, nil)
            if val ~= nil then yaw = val end
        end
    end

    -- 3. Fallback: Controller GetControlRotation() method
    if yaw == nil then
        local okRot, rot = pcall(function() return pc:GetControlRotation() end)
        if okRot and rot then
            local val = SafeNum(rot.Yaw, nil)
            if val ~= nil then yaw = val end
        end
    end

    -- 4. Fallback: Pawn ActorRotation
    if yaw == nil then
        local okActorRot, aRot = pcall(function() return pawn:K2_GetActorRotation() end)
        if okActorRot and aRot then
            local val = SafeNum(aRot.Yaw, nil)
            if val ~= nil then yaw = val end
        end
    end

    local finalYaw = yaw or 0.0
    if CONFIG.INVERT_YAW then
        finalYaw = -finalYaw
    end

    return pawn, finalYaw
end

-- ============================================================================
-- CLEAN MODAL INPUT LOCK (RESTORES MOVEMENT & CAMERA LOOK)
-- ============================================================================
local function SetModalInputLock(locked)
    local pc = GetPlayerController()
    if not pc or not pc:IsValid() then return end

    pcall(function()
        pc.bShowMouseCursor = locked
        pc.bEnableClickEvents = locked
        pc.bEnableMouseOverEvents = locked

        if locked then
            pc:SetIgnoreMoveInput(true)
            pc:SetIgnoreLookInput(true)
        else
            pc:ResetIgnoreMoveInput()
            pc:ResetIgnoreLookInput()
            pc:SetIgnoreMoveInput(false)
            pc:SetIgnoreLookInput(false)
            local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
            if wbl and wbl:IsValid() then
                wbl:SetInputMode_GameOnly(pc)
            end
        end
    end)
end

-- ============================================================================
-- LOW-OVERHEAD HOSTILE CREATURE & CO-OP PLAYER RADAR SCANNER
-- ============================================================================
local PredatorKeywords = {
    { key = "PolarBear", label = "Polar Bear" },
    { key = "Bear",      label = "Bear" },
    { key = "Wolf",      label = "Wolf" },
    { key = "Cougar",    label = "Cougar" },
    { key = "Jaguar",    label = "Jaguar" },
    { key = "Puma",      label = "Puma" },
    { key = "Boar",      label = "Boar" },
    { key = "Crocodile", label = "Crocodile" },
    { key = "Komodo",    label = "Komodo" },
    { key = "Scorpion",  label = "Scorpion" },
    { key = "Spider",    label = "Spider" },
    { key = "Hyena",     label = "Hyena" },
    { key = "Needler",   label = "Needler" },
    { key = "Dreadwing", label = "Dreadwing" },
    { key = "Drac",      label = "Drac" },
    { key = "Caveworm",  label = "Caveworm" },
    { key = "Sandworm",  label = "Sandworm" },
    { key = "Mammoth",   label = "Mammoth" },
	{ key = "Terranus",  label = "Terranus"},
	{ key = "Moa",		 label = "Moa" },
	{ key = "Snow Moa",		 label = "Snow Moa" }
}

local JUVENILE_KEYWORDS = {
    "juvenile",
    "baby",
    "cub",
    "pup",
    "calf",
    "fawn",
    "chick",
    "hatchling",
    "young",
    "infant"
}

local function IsJuvenileOrBabyCreature(actor)
    if not actor or not actor:IsValid() then return true end

    local okFull, fullName = pcall(function() return actor:GetFullName() end)
    local fullLower = okFull and tostring(fullName):lower() or ""

    local cls = actor:GetClass()
    local okCls, clsName = pcall(function() return cls and cls:GetFName():ToString() end)
    local clsLower = okCls and tostring(clsName):lower() or ""

    for i = 1, #JUVENILE_KEYWORDS do
        local kw = JUVENILE_KEYWORDS[i]
        if fullLower:find(kw, 1, true) or clsLower:find(kw, 1, true) then
            return true
        end
    end

    local boolFlags = { "bIsJuvenile", "IsJuvenile", "bJuvenile", "bIsBaby", "IsBaby", "bIsYoung" }
    for i = 1, #boolFlags do
        local okB, val = pcall(function() return actor[boolFlags[i]] end)
        if okB and val == true then
            return true
        end
    end

    local growthFields = { "GrowthProgress", "Maturity", "GrowthPercent", "AgePercent" }
    for i = 1, #growthFields do
        local okG, gVal = pcall(function() return actor[growthFields[i]] end)
        if okG and type(gVal) == "number" and gVal > 0.0 and gVal < 0.95 then
            return true
        end
    end

    local okS, scale = pcall(function() return actor:GetActorScale3D() end)
    if okS and scale and type(scale.X) == "number" and scale.X > 0.0 and scale.X < 0.85 then
        return true
    end

    return false
end

local function ScanNearbyEntities()
    local pawn = GetPlayerPawnAndYaw()
    if not pawn then
        RadarEntities = {}
        NearestPredator = nil
        return
    end

    local okLoc, pLoc = pcall(function() return pawn:K2_GetActorLocation() end)
    if not okLoc or not pLoc then return end
local px, py = SafeNum(pLoc.X, 0.0), SafeNum(pLoc.Y, 0.0)
local maxRange = GetCurrentRadarRange()
local maxRangeSq = maxRange * maxRange
local found = {}
local closestPred = nil
local closestPredDist = math.huge
local actors = FindAllOf("Character")
if actors then
for _, actor in ipairs(actors) do
        if actor:IsValid() and actor ~= pawn and not IsJuvenileOrBabyCreature(actor) then
local okClass, cls = pcall(function() return actor:GetClass():GetFullName() end)
local okName, name = pcall(function() return actor:GetFullName() end)
if okClass and okName then
local kind, label = ClassifyActor(cls, name)
if kind then
local okALoc, aLoc = pcall(function() return actor:K2_GetActorLocation() end)
if okALoc and aLoc then
local ax, ay = SafeNum(aLoc.X, 0.0), SafeNum(aLoc.Y, 0.0)
local dx, dy = ax - px, ay - py
local distSq = dx * dx + dy * dy
if distSq <= maxRangeSq then
local dist = math.sqrt(distSq)
table.insert(found, {
name = label,
x = ax,
y = ay,
dist = dist,
kind = kind
})
if kind == "predator" and dist < closestPredDist then
closestPredDist = dist
closestPred = { name = label, dist = dist }
end
end
end
end
end
end
end
end
RadarEntities = found
if closestPred and closestPred.dist <= CONFIG.PREDATOR_ALERT_RANGE then
NearestPredator = closestPred
else
NearestPredator = nil
end
end
LoopAsync(CONFIG.SCAN_INTERVAL_MS, function()
pcall(ScanNearbyEntities)
return false
end)
-- ============================================================================
-- DRAWING & FORWARD-LOCKED RADAR PROJECTION HELPERS
-- ============================================================================
local function DrawCircleOutline(hud, cx, cy, r, segments, color, thickness)
local step = (2.0 * math.pi) / segments
for i = 0, segments - 1 do
local a1 = i * step
local a2 = (i + 1) * step
hud:DrawLine(
cx + math.cos(a1) * r, cy + math.sin(a1) * r,
cx + math.cos(a2) * r, cy + math.sin(a2) * r,
color, thickness or 1.4
)
end
end
local function DrawFilledCircle(hud, cx, cy, r, color)
local rSq = r * r
for dy = -r, r, 2 do
local halfW = math.sqrt(math.max(0, rSq - dy * dy))
hud:DrawRect(color, cx - halfW, cy + dy, halfW * 2.0, 2.0)
end
end
local function DrawWaypointMarkerShape(hud, x, y, shapeName, color, size)
local s = size or 4.0
if shapeName == "DIAMOND" then
hud:DrawLine(x, y - s, x + s, y, color, 1.8)
hud:DrawLine(x + s, y, x, y + s, color, 1.8)
hud:DrawLine(x, y + s, x - s, y, color, 1.8)
hud:DrawLine(x - s, y, x, y - s, color, 1.8)
elseif shapeName == "CROSS" then
hud:DrawLine(x - s, y, x + s, y, color, 2.0)
hud:DrawLine(x, y - s, x, y + s, color, 2.0)
elseif shapeName == "TRIANGLE" then
hud:DrawLine(x, y - s, x + s, y + s, color, 1.8)
hud:DrawLine(x + s, y + s, x - s, y + s, color, 1.8)
hud:DrawLine(x - s, y + s, x, y - s, color, 1.8)
else
hud:DrawRect(color, x - s, y - s, s * 2.0, s * 2.0)
end
end
-- Forward-Locked Radar Projection:
-- Straight ahead of camera (targetYaw == yawDeg) -> 12 o'clock (top, -Y).
-- Directly behind camera (targetYaw == yawDeg + 180) -> 6 o'clock (bottom, +Y).
local function WorldDeltaToRadar(cx, cy, dx, dy, yawDeg, maxRange, radiusPx)
local dist = math.sqrt(dx * dx + dy * dy)
local norm = math.min(dist / maxRange, 1.0)
local rPx  = norm * radiusPx
local targetYaw = math.deg(math.atan(dy, dx))
local relDeg    = targetYaw - yawDeg
local rad       = math.rad(relDeg - 90.0)
return cx + math.cos(rad) * rPx, cy + math.sin(rad) * rPx, dist
end
-- ============================================================================
-- MAIN HUD RENDER CALLBACK
-- ============================================================================
local function OnDrawHUD(hud)
if not hud or not hud:IsValid() then return end
pcall(function() hud.bShowHUD = true end)
local screenW = SafeNum(hud.SizeX, 1920.0)
local screenH = SafeNum(hud.SizeY, 1080.0)
if screenW <= 0 or screenH <= 0 then return end
local pawn, yawDeg = GetPlayerPawnAndYaw()
if not pawn then return end
local okLoc, pLoc = pcall(function() return pawn:K2_GetActorLocation() end)
if not okLoc or not pLoc then return end
local px, py = SafeNum(pLoc.X, 0.0), SafeNum(pLoc.Y, 0.0)
local cx = CONFIG.RADAR_X
local cy = CONFIG.RADAR_Y
local R  = CONFIG.RADAR_RADIUS
local maxRange = GetCurrentRadarRange()
local rangeMeters = math.floor(maxRange / 100.0)
-- 1. Top Orange Telemetry & Range Header
local telemText = string.format("RADAR [%dm] | CONTACTS: %d", rangeMeters, #RadarEntities)
hud:DrawText(telemText, COL_TELEM, cx - R, cy - R - 18.0, nil, 0.76, false)
-- 2. Hostile Predator Proximity Alert Banner
if NearestPredator then
local warnMeters = math.floor(NearestPredator.dist / 100.0)
local warnW = 240.0
local warnX = (screenW - warnW) * 0.5
local warnY = 58.0
hud:DrawRect(COL_WARN_BG, warnX, warnY, warnW, 22.0)
hud:DrawRect(COL_PREDATOR, warnX, warnY, warnW, 1.5)
hud:DrawRect(COL_PREDATOR, warnX, warnY + 20.5, warnW, 1.5)
hud:DrawText(
string.format("HOSTILE NEARBY: %s (%dm)", NearestPredator.name:upper(), warnMeters),
COL_TEXT, warnX + 12.0, warnY + 4.0, nil, 0.82, false
)
end
-- 3. Radar Background, Concentric Rings, Crosshairs & Forward Sightline
DrawFilledCircle(hud, cx, cy, R, COL_BG)
DrawCircleOutline(hud, cx, cy, R, 56, COL_RING, 1.6)
DrawCircleOutline(hud, cx, cy, R * 0.5, 36, COL_CROSS, 1.0)
hud:DrawLine(cx - R, cy, cx + R, cy, COL_CROSS, 1.0)
hud:DrawLine(cx, cy - R, cx, cy + R, COL_CROSS, 1.0)
hud:DrawLine(cx, cy, cx, cy - R, COL_GOLD, 1.4)
-- 4. Actively Rotating Outer Degree Tick Marks (every 30 deg)
for deg = 0, 330, 30 do
local rad = math.rad((deg + CONFIG.NORTH_OFFSET) - yawDeg - 90.0)
hud:DrawLine(
cx + math.cos(rad) * (R - 4.0), cy + math.sin(rad) * (R - 4.0),
cx + math.cos(rad) * R,         cy + math.sin(rad) * R,
COL_TICK, 1.2
)
end
-- 5. Actively Rotating Cardinal Directions (N, E, S, W) - 1:1 with Top Bar
local cardinals = {
{ label = "N", deg = 0.0 },
{ label = "E", deg = 90.0 },
{ label = "S", deg = 180.0 },
{ label = "W", deg = 270.0 }
}
for _, dir in ipairs(cardinals) do
local rad = math.rad((dir.deg + CONFIG.NORTH_OFFSET) - yawDeg - 90.0)
local lx = cx + math.cos(rad) * (R - 14.0)
local ly = cy + math.sin(rad) * (R - 14.0)
hud:DrawText(dir.label, COL_TEXT, lx - 4.0, ly - 6.0, nil, 0.95, false)
end
-- 6. Nearby Entities (Co-op Players & Hostile Predators)
for _, ent in ipairs(RadarEntities) do
local bx, by = WorldDeltaToRadar(cx, cy, ent.x - px, ent.y - py, yawDeg, maxRange, R - 8.0)
local col = (ent.kind == "player") and COL_COOP or COL_PREDATOR
DrawWaypointMarkerShape(hud, bx, by, (ent.kind == "player") and "TRIANGLE" or "DIAMOND", col, 3.5)
hud:DrawText(ent.name, col, bx + 5.0, by - 5.0, nil, 0.72, false)
end
-- 7. Customized Waypoints (Radar Blips + In-World 3D Projected Beacons)
for _, wp in ipairs(Waypoints) do
if wp.visible ~= false then
local colorEntry = WAYPOINT_COLORS[wp.colorIndex or 1] or WAYPOINT_COLORS[1]
local shapeName  = WAYPOINT_SHAPES[wp.shapeIndex or 1] or "SQUARE"
local wpCol      = colorEntry.col
local bx, by, dist = WorldDeltaToRadar(cx, cy, wp.x - px, wp.y - py, yawDeg, maxRange, R - 8.0)
local meters = math.floor(dist / 100.0)
-- Radar Blip
DrawWaypointMarkerShape(hud, bx, by, shapeName, wpCol, 3.8)
hud:DrawText(wp.name, wpCol, bx + 6.0, by - 6.0, nil, 0.82, false)
-- 3D World Projection
if ShowWorldPins then
local okProj, screenPos = pcall(function()
return hud:Project({ X = wp.x, Y = wp.y, Z = wp.z + 120.0 })
end)
if okProj and screenPos then
local sx = SafeNum(screenPos.X, -1.0)
local sy = SafeNum(screenPos.Y, -1.0)
local sz = SafeNum(screenPos.Z, 0.0)
if sz > 0.0 and sx > 20.0 and sx < (screenW - 20.0) and sy > 20.0 and sy < (screenH - 20.0) then
DrawWaypointMarkerShape(hud, sx, sy, shapeName, wpCol, 4.5)
hud:DrawText(string.format("%s (%dm)", wp.name, meters), wpCol, sx + 8.0, sy - 6.0, nil, 0.85, false)
end
end
end
end
end
-- 8. Center Player Arrow (Fixed pointing Up / 12 o'clock while world orbits around it)
hud:DrawLine(cx, cy - 6.0, cx - 4.5, cy + 5.0, COL_PLAYER, 1.8)
hud:DrawLine(cx, cy - 6.0, cx + 4.5, cy + 5.0, COL_PLAYER, 1.8)
hud:DrawLine(cx - 4.5, cy + 5.0, cx + 4.5, cy + 5.0, COL_PLAYER, 1.5)
-- 9. Waypoint List & Customization Panel Below Radar
local listX = cx - R
local listY = cy + R + 10.0
local listW = EditMode and 275.0 or (R * 2.0 + 42.0)
local headerText = EditMode
and "CUSTOMIZE: [NAME] [CLR] [SHP] [VIS] [X]"
or  "BEACONS  NUM1:ADD  NUM0:EDIT  NUM+:ZOOM"
hud:DrawRect(COL_BG, listX, listY, listW, 18.0)
hud:DrawText(headerText, COL_SUBTEXT, listX + 5.0, listY + 3.0, nil, 0.70, false)
RowHitboxes = {}
local curY = listY + 20.0
for i, wp in ipairs(Waypoints) do
local colorEntry = WAYPOINT_COLORS[wp.colorIndex or 1] or WAYPOINT_COLORS[1]
local shapeName  = WAYPOINT_SHAPES[wp.shapeIndex or 1] or "SQUARE"
local wpCol      = (wp.visible ~= false) and colorEntry.col or COL_SUBTEXT
local dx = wp.x - px
local dy = wp.y - py
local meters = math.floor(math.sqrt(dx * dx + dy * dy) / 100.0)
hud:DrawRect(COL_BG, listX, curY, listW, 19.0)
DrawWaypointMarkerShape(hud, listX + 9.0, curY + 9.5, shapeName, wpCol, 3.2)
hud:DrawText(wp.name, wpCol, listX + 18.0, curY + 2.5, nil, 0.80, false)
if EditMode then
local delX1 = listX + listW - 22.0
local visX1 = delX1 - 30.0
local shpX1 = visX1 - 36.0
local colX1 = shpX1 - 36.0
-- Color Cycle Button
hud:DrawRect(COL_BTN, colX1, curY + 1.5, 34.0, 16.0)
hud:DrawText(colorEntry.name:sub(1, 3):upper(), wpCol, colX1 + 5.0, curY + 2.5, nil, 0.72, false)
-- Shape Cycle Button
hud:DrawRect(COL_BTN, shpX1, curY + 1.5, 34.0, 16.0)
hud:DrawText(shapeName:sub(1, 3), COL_TEXT, shpX1 + 5.0, curY + 2.5, nil, 0.72, false)
-- Visibility Toggle Button
hud:DrawRect(COL_BTN, visX1, curY + 1.5, 28.0, 16.0)
hud:DrawText((wp.visible ~= false) and "ON" or "OFF", COL_TEXT, visX1 + 4.0, curY + 2.5, nil, 0.72, false)
-- Delete Button
hud:DrawRect(COL_DANGER, delX1, curY + 1.5, 20.0, 16.0)
hud:DrawText("X", COL_TEXT, delX1 + 6.0, curY + 2.5, nil, 0.78, false)
table.insert(RowHitboxes, {
index  = i,
y1     = curY,
y2     = curY + 19.0,
nameX1 = listX,
nameX2 = colX1 - 2.0,
colX1  = colX1,
colX2  = colX1 + 34.0,
shpX1  = shpX1,
shpX2  = shpX1 + 34.0,
visX1  = visX1,
visX2  = visX1 + 28.0,
delX1  = delX1,
delX2  = delX1 + 20.0
})
else
hud:DrawText(string.format("%dm", meters), wpCol, listX + listW - 42.0, curY + 2.5, nil, 0.80, false)
end
curY = curY + 20.0
end
-- 10. Handle Free-Cursor Clicks in Waypoint Customization Mode
if EditMode and not PromptOpen then
local pc = GetPlayerController()
if pc and pc:IsValid() then
local okM, mx, my = pcall(function() return pc:GetMousePosition() end)
local okD, isDown = pcall(function() return pc:IsInputKeyDown({ KeyName = FName("LeftMouseButton") }) end)
mx, my = SafeNum(mx, -1), SafeNum(my, -1)
if okD and isDown and not LastMouseDown then
for _, box in ipairs(RowHitboxes) do
if my >= box.y1 and my <= box.y2 then
local wp = Waypoints[box.index]
if not wp then break end
if mx >= box.delX1 and mx <= box.delX2 then
table.remove(Waypoints, box.index)
SaveWaypoints()
break
elseif mx >= box.visX1 and mx <= box.visX2 then
wp.visible = not (wp.visible ~= false)
SaveWaypoints()
break
elseif mx >= box.shpX1 and mx <= box.shpX2 then
wp.shapeIndex = ((wp.shapeIndex or 1) % #WAYPOINT_SHAPES) + 1
SaveWaypoints()
break
elseif mx >= box.colX1 and mx <= box.colX2 then
wp.colorIndex = ((wp.colorIndex or 1) % #WAYPOINT_COLORS) + 1
SaveWaypoints()
break
elseif mx >= box.nameX1 and mx <= box.nameX2 then
PromptMode = "rename"
PromptTargetIndex = box.index
PromptBuffer = wp.name
PromptOpen = true
break
end
end
end
end
LastMouseDown = (okD and isDown) or false
end
end
-- 11. Waypoint Name Input Modal Overlay
if PromptOpen then
local mw, mh = 350.0, 84.0
local mx = (screenW - mw) * 0.5
local my = (screenH - mh) * 0.5
hud:DrawRect({ R = 0.05, G = 0.06, B = 0.08, A = 0.96 }, mx, my, mw, mh)
hud:DrawRect(COL_GOLD, mx, my, mw, 2.0)
hud:DrawRect(COL_GOLD, mx, my + mh - 2.0, mw, 2.0)
hud:DrawRect(COL_GOLD, mx, my, 2.0, mh)
hud:DrawRect(COL_GOLD, mx + mw - 2.0, my, 2.0, mh)
local title = (PromptMode == "rename")
and "RENAME BEACON (ENTER: SAVE | ESC: CANCEL)"
or  "NEW BEACON NAME (ENTER: SAVE | ESC: CANCEL)"
hud:DrawText(title, COL_SUBTEXT, mx + 12.0, my + 12.0, nil, 0.78, false)
hud:DrawText("> " .. PromptBuffer .. "_", COL_GOLD, mx + 14.0, my + 44.0, nil, 1.05, false)
end
end
-- ============================================================================
-- DUAL HUD HOOKING (ENGINE AHUD + RUNTIME BLUEPRINT HUD DISCOVERY)
-- ============================================================================
local function HookHUDClass(hudObj)
if not hudObj or not hudObj:IsValid() then return end
pcall(function() hudObj.bShowHUD = true end)
local cls = hudObj:GetClass()
if not cls or not cls:IsValid() then return end
local fullName = cls:GetFullName()
if HookedHUDClasses[fullName] then return end
local fnPath = fullName:match("Class%s+(.+)") or fullName
local hookTarget = fnPath .. ":ReceiveDrawHUD"
local ok = pcall(function()
RegisterHook(hookTarget, function(self)
pcall(OnDrawHUD, self:get())
end)
end)
if ok then
HookedHUDClasses[fullName] = true
end
end
local function DiscoverAndHookHUDs()
if not EngineHUDHooked then
local ok = pcall(function()
RegisterHook("/Script/Engine.HUD:ReceiveDrawHUD", function(self)
pcall(OnDrawHUD, self:get())
end)
end)
if ok then EngineHUDHooked = true end
end
local huds = FindAllOf("HUD")
if huds then
for _, h in ipairs(huds) do
HookHUDClass(h)
end
end
end
NotifyOnNewObject("/Script/Engine.HUD", function(newHud)
ExecuteWithDelay(200, function()
pcall(HookHUDClass, newHud)
end)
end)
LoopAsync(2000, function()
pcall(DiscoverAndHookHUDs)
return false
end)
-- ============================================================================
-- KEYBINDS & TEXT INPUT HANDLING
-- ============================================================================
-- NUMPAD 1: Add Waypoint at Current Position
RegisterKeyBind(Key.NUM_ONE, function()
if PromptOpen then return end
local pawn = GetPlayerPawnAndYaw()
if not pawn then return end
PromptMode = "add"
PromptTargetIndex = nil
PromptBuffer = ""
PromptOpen = true
SetModalInputLock(true)
end)
-- NUMPAD 0: Toggle Free-Cursor Waypoint Customization Mode
RegisterKeyBind(Key.NUM_ZERO, function()
if PromptOpen then return end
EditMode = not EditMode
SetModalInputLock(EditMode)
end)
-- NUMPAD + (ADD): Cycle Radar Zoom Range (75m -> 150m -> 300m -> 600m)
RegisterKeyBind(Key.ADD, function()
if PromptOpen then return end
ZoomIndex = (ZoomIndex % #CONFIG.ZOOM_LEVELS) + 1
pcall(ScanNearbyEntities)
end)
-- NUMPAD - (SUBTRACT): Toggle 3D In-World Beacon Pins On/Off
RegisterKeyBind(Key.SUBTRACT, function()
if PromptOpen then return end
ShowWorldPins = not ShowWorldPins
end)
-- NUMPAD * (MULTIPLY): Toggle Hostile Predator Radar Detection On/Off
RegisterKeyBind(Key.MULTIPLY, function()
if PromptOpen then return end
ShowPredators = not ShowPredators
pcall(ScanNearbyEntities)
end)
-- ENTER: Confirm Prompt
RegisterKeyBind(Key.RETURN, function()
if not PromptOpen then return end
local finalName = (PromptBuffer ~= "") and PromptBuffer or "Beacon"
if PromptMode == "add" then
local pawn = GetPlayerPawnAndYaw()
if pawn then
local okLoc, loc = pcall(function() return pawn:K2_GetActorLocation() end)
if okLoc and loc then
table.insert(Waypoints, {
name = finalName,
x = SafeNum(loc.X, 0.0),
y = SafeNum(loc.Y, 0.0),
z = SafeNum(loc.Z, 0.0),
colorIndex = 1,
shapeIndex = 1,
visible = true
})
SaveWaypoints()
end
end
elseif PromptMode == "rename" and PromptTargetIndex and Waypoints[PromptTargetIndex] then
Waypoints[PromptTargetIndex].name = finalName
SaveWaypoints()
end
PromptOpen = false
SetModalInputLock(EditMode)
end)
-- ESCAPE: Cancel Prompt or Exit Customization Mode
RegisterKeyBind(Key.ESCAPE, function()
if PromptOpen then
PromptOpen = false
SetModalInputLock(EditMode)
elseif EditMode then
EditMode = false
SetModalInputLock(false)
end
end)
-- BACKSPACE: Delete Last Character in Prompt
RegisterKeyBind(Key.BACKSPACE, function()
if PromptOpen and #PromptBuffer > 0 then
PromptBuffer = PromptBuffer:sub(1, -2)
end
end)
-- Alphanumeric & Space Input While Prompt Is Open
local TypingKeys = {
{ Key.A, "A" }, { Key.B, "B" }, { Key.C, "C" }, { Key.D, "D" }, { Key.E, "E" },
{ Key.F, "F" }, { Key.G, "G" }, { Key.H, "H" }, { Key.I, "I" }, { Key.J, "J" },
{ Key.K, "K" }, { Key.L, "L" }, { Key.M, "M" }, { Key.N, "N" }, { Key.O, "O" },
{ Key.P, "P" }, { Key.Q, "Q" }, { Key.R, "R" }, { Key.S, "S" }, { Key.T, "T" },
{ Key.U, "U" }, { Key.V, "V" }, { Key.W, "W" }, { Key.X, "X" }, { Key.Y, "Y" },
{ Key.Z, "Z" }, { Key.ZERO, "0" }, { Key.ONE, "1" }, { Key.TWO, "2" },
{ Key.THREE, "3" }, { Key.FOUR, "4" }, { Key.FIVE, "5" }, { Key.SIX, "6" },
{ Key.SEVEN, "7" }, { Key.EIGHT, "8" }, { Key.NINE, "9" }, { Key.SPACE, " " }
}
for _, pair in ipairs(TypingKeys) do
local keyCode = pair[1]
local charStr = pair[2]
RegisterKeyBind(keyCode, function()
if PromptOpen and #PromptBuffer < 24 then
PromptBuffer = PromptBuffer .. charStr
end
end)
end
-- ============================================================================
-- STARTUP INITIALIZATION
-- ============================================================================
LoadWaypoints()
DiscoverAndHookHUDs()