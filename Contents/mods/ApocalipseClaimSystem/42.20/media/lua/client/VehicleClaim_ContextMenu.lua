--[[
    VehicleClaim_ContextMenu.lua
    Client-side context menu integration and timed actions
    Adds claim/manage options to vehicle right-click menu
]]

require "shared/VehicleClaim_Shared"
require "client/ui/ISVehicleClaimPanel"
require "client/ui/ISVehicleClaimStatusPanel"

local VehicleClaimMenu = {}

-----------------------------------------------------------
-- Timed Action: Claim Vehicle
-----------------------------------------------------------

ISClaimVehicleAction = ISBaseTimedAction:derive("ISClaimVehicleAction")

function ISClaimVehicleAction:isValid()
    -- Validate vehicle still exists (pathfinding handles positioning)
    if not self.vehicle or not self.vehicle:getSquare() then
        return false
    end
    return true
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
    -- Get vehicle hash (should already exist from mechanics UI)
    local vehicleHash = VehicleClaim.getVehicleHash(self.vehicle)
    if not vehicleHash then
        VehicleClaim.log("ERROR: Vehicle hash not found - this shouldn't happen if mechanics UI was opened")
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
    return true
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

-----------------------------------------------------------
-- Timed Action: Contest Claim (for abandoned vehicles)
-----------------------------------------------------------

ISContestVehicleClaimAction = ISBaseTimedAction:derive("ISContestVehicleClaimAction")

function ISContestVehicleClaimAction:isValid()
    -- Validate vehicle still exists (pathfinding handles positioning)
    if not self.vehicle or not self.vehicle:getSquare() then
        return false
    end
    return true
end

function ISContestVehicleClaimAction:waitToStart()
    return false
end

function ISContestVehicleClaimAction:start()
    self:setActionAnim("Loot")
end

function ISContestVehicleClaimAction:stop()
    ISBaseTimedAction.stop(self)
end

function ISContestVehicleClaimAction:perform()
    -- Get vehicle hash
    local vehicleHash = VehicleClaim.getVehicleHash(self.vehicle)
    if not vehicleHash then
        VehicleClaim.log("ERROR: Could not get vehicle hash for contest")
        ISBaseTimedAction.perform(self)
        return
    end
    
    -- Mark action as pending
    VehicleClaim.pendingActions[vehicleHash] = "CONTEST"
    
    local steamID = VehicleClaim.getPlayerSteamID(self.character)

    local args = {
        vehicleHash = vehicleHash,
        steamID = steamID
    }

    sendClientCommand(self.character, VehicleClaim.COMMAND_MODULE, VehicleClaim.CMD_CONTEST_CLAIM, args)

    ISBaseTimedAction.perform(self)
end

function ISContestVehicleClaimAction:new(character, vehicle, time)
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
-- Context Menu: Vehicle Claim option
-----------------------------------------------------------

--- Add "Vehicle Claim" option to vehicle right-click context menu
--- Shows current claim status in tooltip and opens the status panel on click
function VehicleClaimMenu.onFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if test then return end

    local player = getSpecificPlayer(playerNum)
    if not player then return end

    -- Find a vehicle in the clicked world objects
    -- Check both direct BaseVehicle instances and squares containing a vehicle
    local vehicle = nil
    for _, obj in ipairs(worldObjects) do
        if instanceof(obj, "BaseVehicle") then
            vehicle = obj
            break
        elseif obj:getSquare() and obj:getSquare():getVehicleContainer() then
            vehicle = obj:getSquare():getVehicleContainer()
            break
        end
    end
    if not vehicle then return end

    -- Read current claim data for tooltip
    local claimData = VehicleClaim.getClaimData(vehicle)
    local isClaimed = claimData ~= nil
    local ownerName = claimData and claimData[VehicleClaim.OWNER_NAME_KEY]
    local vehicleHash = VehicleClaim.getVehicleHash(vehicle)

    -- Build tooltip description
    local tooltipDesc
    if isClaimed then
        local steamID = VehicleClaim.getPlayerSteamID(player)
        local ownerID = claimData[VehicleClaim.OWNER_KEY]
        if ownerID == steamID then
            tooltipDesc = getText("UI_VehicleClaim_OwnerYou")
        else
            local allowedPlayers = claimData[VehicleClaim.ALLOWED_PLAYERS_KEY] or {}
            if allowedPlayers[steamID] then
                tooltipDesc = getText("UI_VehicleClaim_OwnerLabel", ownerName or getText("UI_VehicleClaim_Unknown")) .. " " .. getText("UI_VehicleClaim_AccessGranted")
            else
                tooltipDesc = getText("UI_VehicleClaim_OwnerLabel", ownerName or getText("UI_VehicleClaim_Unknown")) .. " " .. getText("UI_VehicleClaim_NoAccess")
            end
        end
    else
        tooltipDesc = getText("UI_VehicleClaim_AvailableToClaim")
    end

    -- Add menu option
    local option = context:addOption(getText("UI_VehicleClaim_ContextTitle"), worldObjects, VehicleClaimMenu.onOpenStatusPanel, player, vehicle)

    local tooltip = ISWorldObjectContextMenu.addToolTip()
    tooltip:setName(getText("UI_VehicleClaim_ContextTitle"))
    tooltip.description = tooltipDesc
    option.toolTip = tooltip
end

--- Open the standalone claim status panel
function VehicleClaimMenu.onOpenStatusPanel(worldObjects, player, vehicle)
    if not player or not vehicle then return end

    local screenW = getCore():getScreenWidth()
    local screenH = getCore():getScreenHeight()
    local panelW = 320
    local panelH = 260
    local panelX = (screenW - panelW) / 2
    local panelY = (screenH - panelH) / 2

    local panel = ISVehicleClaimStatusPanel:new(panelX, panelY, panelW, panelH, vehicle, player)
    panel:initialise()
    panel:addToUIManager()
    panel:setVisible(true)
end

-----------------------------------------------------------
-- Event Registration
-----------------------------------------------------------

Events.OnFillWorldObjectContextMenu.Add(VehicleClaimMenu.onFillWorldObjectContextMenu)

return VehicleClaimMenu
