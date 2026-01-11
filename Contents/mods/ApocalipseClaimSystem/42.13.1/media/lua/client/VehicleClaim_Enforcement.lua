--[[
    VehicleClaim_Enforcement.lua
    Client-side interaction blocking for claimed vehicles
    Works alongside server-side enforcement as a UX optimization
]]

require "shared/VehicleClaim_Shared"

local VehicleClaimEnforcement = {}

-----------------------------------------------------------
-- Vehicle Entry Blocking
-----------------------------------------------------------

--- Check if player can enter a vehicle (client-side pre-check)
--- @param player IsoPlayer
--- @param vehicle IsoVehicle
--- @return boolean
function VehicleClaimEnforcement.canEnterVehicle(player, vehicle)
    if not player or not vehicle then return true end
    
    local steamID = VehicleClaim.getPlayerSteamID(player)
    local isAdmin = player:getAccessLevel() == "admin" or player:getAccessLevel() == "moderator"
    
    -- Admins bypass all checks
    if isAdmin then return true end
    
    return VehicleClaim.hasAccess(vehicle, steamID)
end

--- Hook vehicle entry attempt
local originalVehicleEnter = ISVehicleMenu.onEnter
if ISVehicleMenu and ISVehicleMenu.onEnter then
    ISVehicleMenu.onEnter = function(playerObj, vehicle, seat)
        if not VehicleClaimEnforcement.canEnterVehicle(playerObj, vehicle) then
            local ownerName = VehicleClaim.getOwnerName(vehicle) or "another player"
            playerObj:Say("This vehicle belongs to " .. ownerName)
            return
        end
        return originalVehicleEnter(playerObj, vehicle, seat)
    end
end

-----------------------------------------------------------
-- Mechanics Menu Blocking
-----------------------------------------------------------

--- Block mechanics context options for non-owners
local function onFillVehicleMenu(playerNum, context, vehicle, test)
    if test then return end
    if not vehicle then return end
    
    local player = getSpecificPlayer(playerNum)
    if not player then return end
    
    local steamID = VehicleClaim.getPlayerSteamID(player)
    local isAdmin = player:getAccessLevel() == "admin" or player:getAccessLevel() == "moderator"
    
    -- Skip if player has access
    if VehicleClaim.hasAccess(vehicle, steamID) or isAdmin then
        return
    end
    
    -- Vehicle is claimed and player has no access - disable relevant options
    local ownerName = VehicleClaim.getOwnerName(vehicle) or "Owner"
    
    -- Find and disable mechanics/interaction options
    local options = context:getMenuOptionNames()
    if options then
        for i = 1, #options do
            local optName = options[i]
            local opt = context:getOptionFromName(optName)
            if opt then
                -- Disable various vehicle interaction options
                local blockedOptions = {
                    "Mechanics", "Vehicle Mechanics", "Sleep", "Sleep in vehicle",
                    "Lock", "Unlock", "Hotwire", "Start Engine", "Siphon Gas",
                    "Remove Key", "Switch Seat", "Get/Take Key"
                }
                
                for _, blocked in ipairs(blockedOptions) do
                    if string.find(optName, blocked) then
                        opt.notAvailable = true
                        opt.toolTip = ISWorldObjectContextMenu.addToolTip()
                        opt.toolTip:setName("Access Denied")
                        opt.toolTip.description = "This vehicle belongs to " .. ownerName
                        break
                    end
                end
            end
        end
    end
end

-----------------------------------------------------------
-- Timed Action Validation
-----------------------------------------------------------

--- Validate timed actions that target claimed vehicles
local originalTimedActionIsValid = ISBaseTimedAction.isValid
if ISBaseTimedAction and ISBaseTimedAction.isValid then
    local hookedIsValid = function(self)
        -- Check if this action involves a vehicle
        if self.vehicle then
            local player = self.character
            if player then
                local steamID = VehicleClaim.getPlayerSteamID(player)
                local isAdmin = player:getAccessLevel() == "admin" or player:getAccessLevel() == "moderator"
                
                if not VehicleClaim.hasAccess(self.vehicle, steamID) and not isAdmin then
                    -- Block the action
                    return false
                end
            end
        end
        
        -- Call original validation
        if originalTimedActionIsValid then
            return originalTimedActionIsValid(self)
        end
        return true
    end
    
    -- Only hook if we have the original
    -- ISBaseTimedAction.isValid = hookedIsValid
end

-----------------------------------------------------------
-- Part Interaction Blocking
-----------------------------------------------------------

--- Block trunk/hood/door interactions for non-owners
local function onVehiclePartInteraction(player, vehicle, part)
    if not player or not vehicle then return true end
    
    local steamID = VehicleClaim.getPlayerSteamID(player)
    local isAdmin = player:getAccessLevel() == "admin" or player:getAccessLevel() == "moderator"
    
    if VehicleClaim.hasAccess(vehicle, steamID) or isAdmin then
        return true
    end
    
    -- Block interaction
    local ownerName = VehicleClaim.getOwnerName(vehicle) or "another player"
    player:Say("This vehicle belongs to " .. ownerName)
    return false
end

-----------------------------------------------------------
-- Context Menu Enforcement
-----------------------------------------------------------

--- Late hook to modify context menu after all other mods
local function lateContextMenuHook(playerNum, context, worldObjects, test)
    if test then return end
    
    local player = getSpecificPlayer(playerNum)
    if not player then return end
    
    -- Find vehicles in context
    for _, obj in ipairs(worldObjects) do
        if instanceof(obj, "IsoVehicle") then
            local vehicle = obj
            local steamID = VehicleClaim.getPlayerSteamID(player)
            local isAdmin = player:getAccessLevel() == "admin" or player:getAccessLevel() == "moderator"
            
            if not VehicleClaim.hasAccess(vehicle, steamID) and not isAdmin and VehicleClaim.isClaimed(vehicle) then
                -- Mark all vehicle-related options as unavailable
                local ownerName = VehicleClaim.getOwnerName(vehicle) or "Owner"
                
                -- Iterate through menu options
                for i = 1, context:getOptions():size() do
                    local opt = context:getOptions():get(i - 1)
                    if opt and opt.target == vehicle then
                        opt.notAvailable = true
                        if not opt.toolTip then
                            opt.toolTip = ISWorldObjectContextMenu.addToolTip()
                        end
                        opt.toolTip:setName("Access Denied")
                        opt.toolTip.description = "Vehicle owned by " .. ownerName
                    end
                end
            end
            break
        end
    end
end

-----------------------------------------------------------
-- HUD Indicator
-----------------------------------------------------------

--- Show ownership indicator when looking at claimed vehicle
local function onPreUIDraw()
    local player = getPlayer()
    if not player then return end
    
    -- Check if player is looking at a vehicle
    local worldX, worldY = screenToIso(getMouseX(), getMouseY(), 0)
    if not worldX then return end
    
    local cell = getCell()
    if not cell then return end
    
    -- Find nearest vehicle to mouse
    local vehicles = cell:getVehicles()
    if not vehicles then return end
    
    local closestVehicle = nil
    local closestDist = 2.0  -- Only show for vehicles very close to cursor
    
    for i = 0, vehicles:size() - 1 do
        local v = vehicles:get(i)
        if v then
            local vx, vy = v:getX(), v:getY()
            local dist = math.sqrt((worldX - vx)^2 + (worldY - vy)^2)
            if dist < closestDist then
                closestDist = dist
                closestVehicle = v
            end
        end
    end
    
    if closestVehicle and VehicleClaim.isClaimed(closestVehicle) then
        local steamID = VehicleClaim.getPlayerSteamID(player)
        local ownerName = VehicleClaim.getOwnerName(closestVehicle) or "Unknown"
        local hasAccess = VehicleClaim.hasAccess(closestVehicle, steamID)
        
        -- Draw ownership indicator near mouse
        local mx, my = getMouseX(), getMouseY()
        local font = UIFont.Small
        
        local text
        local r, g, b
        
        if hasAccess then
            if VehicleClaim.getOwnerID(closestVehicle) == steamID then
                text = "[Your Vehicle]"
                r, g, b = 0.3, 0.9, 0.3
            else
                text = "[Shared - " .. ownerName .. "]"
                r, g, b = 0.9, 0.9, 0.3
            end
        else
            text = "[Owned: " .. ownerName .. "]"
            r, g, b = 0.9, 0.3, 0.3
        end
        
        -- Draw with shadow
        local textW = getTextManager():MeasureStringX(font, text)
        local drawX = mx + 20
        local drawY = my - 10
        
        -- Shadow
        getTextManager():DrawString(font, drawX + 1, drawY + 1, text, 0, 0, 0, 0.8)
        -- Text
        getTextManager():DrawString(font, drawX, drawY, text, r, g, b, 1)
    end
end

-----------------------------------------------------------
-- Event Registration
-----------------------------------------------------------

Events.OnFillWorldObjectContextMenu.Add(lateContextMenuHook)

-- Optional: HUD indicator (can be resource intensive)
-- Events.OnPreUIDraw.Add(onPreUIDraw)

return VehicleClaimEnforcement
