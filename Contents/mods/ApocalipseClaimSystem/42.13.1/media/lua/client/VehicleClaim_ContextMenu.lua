--[[
    VehicleClaim_ContextMenu.lua
    Client-side context menu integration and timed actions
    Adds claim/manage options to vehicle right-click menu
]] require "shared/VehicleClaim_Shared"

local VehicleClaimMenu = {}

-----------------------------------------------------------
-- Timed Action: Claim Vehicle
-----------------------------------------------------------

ISClaimVehicleAction = ISBaseTimedAction:derive("ISClaimVehicleAction")

function ISClaimVehicleAction:isValid()
    -- Validate vehicle still exists and is in range
    if not self.vehicle or not self.vehicle:getSquare() then
        return false
    end
    return VehicleClaim.isWithinRange(self.character, self.vehicle)
end

function ISClaimVehicleAction:waitToStart()
    -- No waiting required
    return false
end

function ISClaimVehicleAction:update()
    -- Could add progress feedback here
end

function ISClaimVehicleAction:start()
    -- Animation: character interacts with vehicle
    self:setActionAnim("Loot")
end

function ISClaimVehicleAction:stop()
    ISBaseTimedAction.stop(self)
end

function ISClaimVehicleAction:perform()
    -- Send claim request to server
    local vehicleID = self.vehicle:getId()
    local steamID = VehicleClaim.getPlayerSteamID(self.character)
    local playerName = self.character:getUsername() or "Unknown"

    local args = {
        vehicleID = vehicleID,
        steamID = steamID,
        playerName = playerName
    }

    sendClientCommand(self.character, VehicleClaim.COMMAND_MODULE, VehicleClaim.CMD_CLAIM, args)

    -- Action complete
    ISBaseTimedAction.perform(self)
end

function ISClaimVehicleAction:new(character, vehicle, time)
    local o = ISBaseTimedAction.new(self, character)
    o.vehicle = vehicle
    o.maxTime = time
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = false
    return o
end

-----------------------------------------------------------
-- Timed Action: Release Claim
-----------------------------------------------------------

ISReleaseVehicleClaimAction = ISBaseTimedAction:derive("ISReleaseVehicleClaimAction")

function ISReleaseVehicleClaimAction:isValid()
    if not self.vehicle or not self.vehicle:getSquare() then
        return false
    end
    return VehicleClaim.isWithinRange(self.character, self.vehicle)
end

function ISReleaseVehicleClaimAction:waitToStart()
    return false
end

function ISReleaseVehicleClaimAction:start()
    self:setActionAnim("Loot")
end

function ISReleaseVehicleClaimAction:stop()
    ISBaseTimedAction.stop(self)
end

function ISReleaseVehicleClaimAction:perform()
    local vehicleID = self.vehicle:getId()
    local steamID = VehicleClaim.getPlayerSteamID(self.character)

    local args = {
        vehicleID = vehicleID,
        steamID = steamID
    }

    sendClientCommand(self.character, VehicleClaim.COMMAND_MODULE, VehicleClaim.CMD_RELEASE, args)

    ISBaseTimedAction.perform(self)
end

function ISReleaseVehicleClaimAction:new(character, vehicle, time)
    local o = ISBaseTimedAction.new(self, character)
    o.vehicle = vehicle
    o.maxTime = time
    o.stopOnWalk = true
    o.stopOnRun = true
    return o
end

-----------------------------------------------------------
-- Context Menu Builder
-----------------------------------------------------------

--- Add claim options to vehicle context menu
--- @param playerNum number
--- @param context ISContextMenu
--- @param worldObjects table
--- @param test boolean
function VehicleClaimMenu.onFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if test then
        return
    end

    local player = getSpecificPlayer(playerNum)
    if not player then
        return
    end

    -- Find vehicle in clicked objects
    local vehicle = nil
    for _, obj in ipairs(worldObjects) do
        if instanceof(obj, "IsoVehicle") then
            vehicle = obj
            break
        end
    end

    -- Check if the clicked square is inside the vehicle's area
    if not vehicle then
        local clickedSquare = nil
        for _, obj in ipairs(worldObjects) do
            if obj.getSquare then
                clickedSquare = obj:getSquare()
                break
            end
        end

        if clickedSquare then
            local clickX = clickedSquare:getX()
            local clickY = clickedSquare:getY()
            local clickZ = clickedSquare:getZ()

            local cell = getCell()
            if cell then
                local veh = cell:getVehicles()
                if veh then
                    local closestVehicle = nil
                    local closestDistance = VehicleClaim.CLAIM_DISTANCE

                    -- Find the closest vehicle to the clicked position
                    for i = 0, veh:size() - 1 do
                        local v = veh:get(i)
                        if v then
                            -- Calculate distance from clicked square to vehicle
                            local vx = v:getX()
                            local vy = v:getY()
                            local vz = v:getZ()

                            -- Only consider vehicles on same Z level
                            if vz == clickZ then
                                local dist = math.sqrt((clickX - vx) ^ 2 + (clickY - vy) ^ 2)

                                -- Keep track of closest vehicle
                                if dist < closestDistance then
                                    closestDistance = dist
                                    closestVehicle = v
                                end
                            end
                        end
                    end

                    -- Use the closest vehicle found
                    if closestVehicle then
                        vehicle = closestVehicle
                        print("[VehicleClaim] Found closest vehicle at distance: " ..
                                  string.format("%.2f", closestDistance))
                    end
                end
            end
        end
    end

    -- Also check if clicking on a vehicle part
    if not vehicle then
        -- Get the clicked square to use as reference point
        local clickedSquare = nil
        for _, obj in ipairs(worldObjects) do
            if instanceof(obj, "IsoObject") then
                clickedSquare = obj:getSquare()
                if clickedSquare then
                    break
                end
            end
        end

        -- If we found a clicked square, search for nearest vehicle
        if clickedSquare then
            local clickX = clickedSquare:getX()
            local clickY = clickedSquare:getY()
            local clickZ = clickedSquare:getZ()

            local cell = getCell()
            if cell then
                local veh = cell:getVehicles()
                if veh then
                    local closestVehicle = nil
                    local closestDistance = VehicleClaim.CLAIM_DISTANCE

                    -- Find the closest vehicle to the clicked position
                    for i = 0, veh:size() - 1 do
                        local v = veh:get(i)
                        if v then
                            -- Calculate distance from clicked square to vehicle
                            local vx = v:getX()
                            local vy = v:getY()
                            local vz = v:getZ()

                            -- Only consider vehicles on same Z level
                            if vz == clickZ then
                                local dist = math.sqrt((clickX - vx) ^ 2 + (clickY - vy) ^ 2)

                                -- Keep track of closest vehicle
                                if dist < closestDistance then
                                    closestDistance = dist
                                    closestVehicle = v
                                end
                            end
                        end
                    end

                    -- Use the closest vehicle found
                    if closestVehicle then
                        vehicle = closestVehicle
                        print("[VehicleClaim] Found closest vehicle at distance: " ..
                                  string.format("%.2f", closestDistance))
                    end
                end
            end
        end
    end

    if not vehicle then
        return
    end

    -- Check distance
    if not VehicleClaim.isWithinRange(player, vehicle) then
        return
    end

    local steamID = VehicleClaim.getPlayerSteamID(player)
    local isClaimed = VehicleClaim.isClaimed(vehicle)
    local ownerID = VehicleClaim.getOwnerID(vehicle)
    local isOwner = ownerID == steamID
    local hasAccess = VehicleClaim.hasAccess(vehicle, steamID)
    local isAdmin = player:getAccessLevel() == "admin" or player:getAccessLevel() == "moderator"

    local vehicleName = VehicleClaim.getVehicleName(vehicle)

    -- Create submenu for claim options
    local claimMenu = context:addOption("Vehicle Claim", worldObjects, nil)
    local subMenu = ISContextMenu:getNew(context)
    context:addSubMenu(claimMenu, subMenu)

    if not isClaimed then
        -- Unclaimed vehicle: show claim option
        local claimOption = subMenu:addOption("Claim " .. vehicleName, worldObjects, VehicleClaimMenu.onClaimVehicle,
            player, vehicle)

        -- Add tooltip
        local tooltip = ISWorldObjectContextMenu.addToolTip()
        tooltip:setName("Claim Vehicle")
        tooltip.description = "Register this vehicle as your property. " ..
                                  "Other players will not be able to use it without permission."
        claimOption.toolTip = tooltip

    else
        -- Claimed vehicle
        local ownerName = VehicleClaim.getOwnerName(vehicle) or "Unknown"

        -- Show owner info
        local infoOption = subMenu:addOption("Owner: " .. ownerName, nil, nil)
        infoOption.notAvailable = true

        if isOwner or isAdmin then
            -- Owner/admin options
            subMenu:addOption("Manage Access", worldObjects, VehicleClaimMenu.onOpenManagePanel, player, vehicle)

            local releaseOption = subMenu:addOption("Release Claim", worldObjects, VehicleClaimMenu.onReleaseClaim,
                player, vehicle)
            local releaseTip = ISWorldObjectContextMenu.addToolTip()
            releaseTip:setName("Release Claim")
            releaseTip.description = "Remove your ownership of this vehicle. " ..
                                         "Anyone will be able to claim or use it."
            releaseOption.toolTip = releaseTip

        elseif hasAccess then
            -- Allowed player
            local accessOption = subMenu:addOption("You have access", nil, nil)
            accessOption.notAvailable = true

        else
            -- No access
            local noAccessOption = subMenu:addOption("Access Denied", nil, nil)
            noAccessOption.notAvailable = true

            local tooltip = ISWorldObjectContextMenu.addToolTip()
            tooltip:setName("Access Denied")
            tooltip.description = "This vehicle belongs to " .. ownerName .. ". " ..
                                      "You cannot use it without their permission."
            noAccessOption.toolTip = tooltip
        end
    end
end

--- Handle claim vehicle action
function VehicleClaimMenu.onClaimVehicle(worldObjects, player, vehicle)
    if not player or not vehicle then
        return
    end

    -- Queue timed action
    local action = ISClaimVehicleAction:new(player, vehicle, VehicleClaim.CLAIM_TIME_TICKS)
    ISTimedActionQueue.add(action)
end

--- Handle release claim action
function VehicleClaimMenu.onReleaseClaim(worldObjects, player, vehicle)
    if not player or not vehicle then
        return
    end

    local action = ISReleaseVehicleClaimAction:new(player, vehicle, VehicleClaim.CLAIM_TIME_TICKS / 2)
    ISTimedActionQueue.add(action)
end

--- Open management panel
function VehicleClaimMenu.onOpenManagePanel(worldObjects, player, vehicle)
    if not player or not vehicle then
        return
    end

    -- Import UI panel (deferred to avoid circular deps)
    local panel = ISVehicleClaimPanel:new(100, 100, 400, 500, player, vehicle)
    panel:initialise()
    panel:addToUIManager()
    panel:setVisible(true)
end

-----------------------------------------------------------
-- Event Registration
-----------------------------------------------------------

Events.OnFillWorldObjectContextMenu.Add(VehicleClaimMenu.onFillWorldObjectContextMenu)

return VehicleClaimMenu
