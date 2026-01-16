--[[
    VehicleClaim_ContextMenu.lua
    Client-side context menu integration and timed actions
    Adds claim/manage options to vehicle right-click menu
]] require "shared/VehicleClaim_Shared"
require "client/ui/ISVehicleClaimPanel"

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
    -- Get or create vehicle hash
    local vehicleHash = VehicleClaim.getOrCreateVehicleHash(self.vehicle)
    if not vehicleHash then
        VehicleClaim.log("ERROR: Could not get/create vehicle hash for claim")
        ISBaseTimedAction.perform(self)
        return
    end
    
    -- Mark action as pending
    VehicleClaim.pendingActions[vehicleHash] = "CLAIM"
    
    -- Send claim request to server
    local steamID = VehicleClaim.getPlayerSteamID(self.character)
    local playerName = self.character:getUsername() or "Unknown"
    local vehicleName = self.vehicle:getScript():getName()

    local args = {
        vehicleHash = vehicleHash,
        ownerSteamID = steamID,
        ownerName = playerName,
        steamID = steamID,
        playerName = playerName,
        vehicleName = vehicleName
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
    -- Get vehicle hash
    local vehicleHash = VehicleClaim.getVehicleHash(self.vehicle)
    if not vehicleHash then
        VehicleClaim.log("ERROR: Could not get vehicle hash for release")
        ISBaseTimedAction.perform(self)
        return
    end
    
    -- Mark action as pending
    VehicleClaim.pendingActions[vehicleHash] = "RELEASE"
    
    local steamID = VehicleClaim.getPlayerSteamID(self.character)

    local args = {
        vehicleHash = vehicleHash,
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
