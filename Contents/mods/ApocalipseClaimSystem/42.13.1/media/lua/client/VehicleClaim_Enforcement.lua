--[[
    VehicleClaim_Enforcement.lua
    Client-side interaction blocking for claimed vehicles
    Build 42.13.1 compatible
]]

require "shared/VehicleClaim_Shared"

local VehicleClaimEnforcement = {}

-----------------------------------------------------------
-- Helper Function: Check Vehicle Access
-----------------------------------------------------------

--- Check if player has access to a vehicle
--- @param player IsoPlayer
--- @param vehicle BaseVehicle
--- @return boolean
function VehicleClaimEnforcement.hasAccess(player, vehicle)
    if not player or not vehicle then return true end
    
    -- Check if vehicle is claimed
    if not VehicleClaim.isClaimed(vehicle) then return true end
    
    local steamID = VehicleClaim.getPlayerSteamID(player)
    local isAdmin = player:getAccessLevel() == "admin" or player:getAccessLevel() == "moderator"
    
    -- Admins bypass all checks
    if isAdmin then return true end
    
    return VehicleClaim.hasAccess(vehicle, steamID)
end

--- Get denial message
--- @param vehicle BaseVehicle
--- @return string
function VehicleClaimEnforcement.getDenialMessage(vehicle)
    local ownerName = VehicleClaim.getOwnerName(vehicle) or "another player"
    return getText("UI_VehicleClaim_VehicleBelongsTo", ownerName)
end

-----------------------------------------------------------
-- Context Menu Blocking (Right-click menu)
-----------------------------------------------------------

--- Comprehensive context menu blocking for claimed vehicles
--- This blocks ALL context menu options for non-authorized players
local function onFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if test then return end
    
    local player = getSpecificPlayer(playerNum)
    if not player then return end
    
    -- Find vehicles in worldObjects
    local vehicle = nil
    for i = 1, #worldObjects do
        local obj = worldObjects[i]
        if obj and instanceof(obj, "BaseVehicle") then
            vehicle = obj
            break
        end
    end
    
    if not vehicle then return end
    if VehicleClaimEnforcement.hasAccess(player, vehicle) then return end
    
    -- Vehicle is claimed and player has no access - block ALL vehicle interactions
    local ownerName = VehicleClaim.getOwnerName(vehicle) or "Owner"
    local denyMessage = getText("UI_VehicleClaim_AccessDenied")
    local denyDescription = getText("UI_VehicleClaim_AccessDeniedDescription", ownerName)
    
    -- Get all menu options and disable them
    local options = context:getOptions()
    if not options then return end
    
    local claimMenuTitle = getText("UI_VehicleClaim_ContextTitle")
    
    for i = 0, options:size() - 1 do
        local option = options:get(i)
        if option and option.name then
            -- Don't block the Vehicle Claim menu itself
            local isClaimMenu = string.find(tostring(option.name), claimMenuTitle) or 
                               string.find(tostring(option.name), "Vehicle Claim") or
                               string.find(tostring(option.name), "Claim") or
                               string.find(tostring(option.name), "Meus Veículos")
            
            if not isClaimMenu then
                option.notAvailable = true
                
                if not option.toolTip then
                    option.toolTip = ISWorldObjectContextMenu.addToolTip()
                end
                option.toolTip:setName(denyMessage)
                option.toolTip.description = denyDescription
            end
        end
    end
end

-----------------------------------------------------------
-- Vehicle Entry Blocking
-----------------------------------------------------------

--- Block vehicle entry via ISVehicleMenu.onEnter hook
local function hookVehicleEntry()
    if not ISVehicleMenu or not ISVehicleMenu.onEnter then return end
    
    local originalOnEnter = ISVehicleMenu.onEnter
    ISVehicleMenu.onEnter = function(playerObj, vehicle, seat)
        if not VehicleClaimEnforcement.hasAccess(playerObj, vehicle) then
            playerObj:Say(VehicleClaimEnforcement.getDenialMessage(vehicle))
            return
        end
        return originalOnEnter(playerObj, vehicle, seat)
    end
end

-----------------------------------------------------------
-- Mechanics Panel Blocking (V Keybind)
-----------------------------------------------------------

--- Block the mechanics panel from opening via OnKeyPressed
--- The V key opens ISVehicleMechanics panel
local function onKeyPressed(key)
    -- V key code is typically 47 in PZ
    local vKeyCode = getCore():getKey("VehicleMechanics")
    if key ~= vKeyCode then return end
    
    local player = getPlayer()
    if not player then return end
    
    local vehicle = player:getVehicle()
    if not vehicle then return end
    
    if not VehicleClaimEnforcement.hasAccess(player, vehicle) then
        player:Say(VehicleClaimEnforcement.getDenialMessage(vehicle))
        -- Close the mechanics panel if it opens
        if ISVehicleMechanics.instance then
            ISVehicleMechanics.instance:close()
        end
    end
end

-----------------------------------------------------------
-- E Key Interaction Blocking (Hood/Engine Access)
-----------------------------------------------------------

--- Find the nearest vehicle to the player within interaction range
local function getNearbyVehicle(player)
    if not player then return nil end
    
    local px, py = player:getX(), player:getY()
    local cell = getCell()
    if not cell then return nil end
    
    local vehicles = cell:getVehicles()
    if not vehicles then return nil end
    
    local closestVehicle = nil
    local closestDist = 3.0  -- Interaction range
    
    for i = 0, vehicles:size() - 1 do
        local v = vehicles:get(i)
        if v then
            local vx, vy = v:getX(), v:getY()
            local dist = math.sqrt((px - vx)^2 + (py - vy)^2)
            if dist < closestDist then
                closestDist = dist
                closestVehicle = v
            end
        end
    end
    
    return closestVehicle
end

--- Block E key interaction with vehicle hood/engine
local function onKeyPressedInteract(key)
    -- E key / Interact key
    local interactKey = getCore():getKey("Interact")
    if key ~= interactKey then return end
    
    local player = getPlayer()
    if not player then return end
    
    -- Don't block if player is inside a vehicle
    if player:getVehicle() then return end
    
    -- Check for nearby vehicle
    local vehicle = getNearbyVehicle(player)
    if not vehicle then return end
    
    if not VehicleClaimEnforcement.hasAccess(player, vehicle) then
        -- Cancel any pending timed actions related to vehicles
        if player:getCurrentState() then
            local stateName = tostring(player:getCurrentState())
            if string.find(stateName, "Vehicle") or string.find(stateName, "Hood") then
                player:StopAllActionQueue()
            end
        end
    end
end

--- Hook vehicle interaction actions (install, uninstall, repair parts)
--- Instead of blocking at .new(), we let the action be created but block at .isValid()
local function hookVehiclePartActions()
    -- Hook ISInstallVehiclePart.isValid
    if ISInstallVehiclePart then
        local originalIsValid = ISInstallVehiclePart.isValid
        ISInstallVehiclePart.isValid = function(self)
            if self.vehicle and self.character then
                if not VehicleClaimEnforcement.hasAccess(self.character, self.vehicle) then
                    self.character:Say(VehicleClaimEnforcement.getDenialMessage(self.vehicle))
                    return false
                end
            end
            return originalIsValid(self)
        end
    end
    
    -- Hook ISUninstallVehiclePart.isValid
    if ISUninstallVehiclePart then
        local originalIsValid = ISUninstallVehiclePart.isValid
        ISUninstallVehiclePart.isValid = function(self)
            if self.vehicle and self.character then
                if not VehicleClaimEnforcement.hasAccess(self.character, self.vehicle) then
                    self.character:Say(VehicleClaimEnforcement.getDenialMessage(self.vehicle))
                    return false
                end
            end
            return originalIsValid(self)
        end
    end
    
    -- Hook ISRepairVehiclePartAction.isValid
    if ISRepairVehiclePartAction then
        local originalIsValid = ISRepairVehiclePartAction.isValid
        ISRepairVehiclePartAction.isValid = function(self)
            if self.vehicle and self.character then
                if not VehicleClaimEnforcement.hasAccess(self.character, self.vehicle) then
                    self.character:Say(VehicleClaimEnforcement.getDenialMessage(self.vehicle))
                    return false
                end
            end
            return originalIsValid(self)
        end
    end
    
    -- Hook ISTakeGasFromVehicle.isValid
    if ISTakeGasFromVehicle then
        local originalIsValid = ISTakeGasFromVehicle.isValid
        ISTakeGasFromVehicle.isValid = function(self)
            local vehicle = nil
            pcall(function()
                if self.part and self.part.getVehicle then
                    vehicle = self.part:getVehicle()
                end
            end)
            if vehicle and self.character then
                if not VehicleClaimEnforcement.hasAccess(self.character, vehicle) then
                    self.character:Say(VehicleClaimEnforcement.getDenialMessage(vehicle))
                    return false
                end
            end
            return originalIsValid(self)
        end
    end
    
    -- Hook ISAddGasFromPump.isValid
    if ISAddGasFromPump then
        local originalIsValid = ISAddGasFromPump.isValid
        ISAddGasFromPump.isValid = function(self)
            local vehicle = nil
            pcall(function()
                if self.part and self.part.getVehicle then
                    vehicle = self.part:getVehicle()
                end
            end)
            if vehicle and self.character then
                if not VehicleClaimEnforcement.hasAccess(self.character, vehicle) then
                    self.character:Say(VehicleClaimEnforcement.getDenialMessage(vehicle))
                    return false
                end
            end
            return originalIsValid(self)
        end
    end
end

--- Alternative: Hook ISVehicleMechanics:new to prevent panel creation
local function hookMechanicsPanel()
    if not ISVehicleMechanics then return end
    
    -- Hook the show method
    local originalNew = ISVehicleMechanics.new
    ISVehicleMechanics.new = function(x, y, width, height, character, vehicle)
        if vehicle and character then
            if not VehicleClaimEnforcement.hasAccess(character, vehicle) then
                character:Say(VehicleClaimEnforcement.getDenialMessage(vehicle))
                return nil
            end
        end
        return originalNew(x, y, width, height, character, vehicle)
    end
end

-----------------------------------------------------------
-- Timed Action Blocking (Install/Uninstall/Repair Parts)
-----------------------------------------------------------

--- Hook ISBaseTimedAction to block vehicle-related timed actions
local function hookTimedActions()
    if not ISBaseTimedAction then return end
    
    local originalIsValid = ISBaseTimedAction.isValid
    ISBaseTimedAction.isValid = function(self)
        -- Check if this action involves a vehicle
        local vehicle = self.vehicle
        if not vehicle and self.part then
            -- Some actions store the part, get vehicle from part
            if self.part.getVehicle then
                vehicle = self.part:getVehicle()
            end
        end
        
        if vehicle and self.character then
            if not VehicleClaimEnforcement.hasAccess(self.character, vehicle) then
                return false
            end
        end
        
        -- Call original
        return originalIsValid(self)
    end
    
    -- Also hook perform to double-check
    local originalPerform = ISBaseTimedAction.perform
    ISBaseTimedAction.perform = function(self)
        local vehicle = self.vehicle
        if not vehicle and self.part then
            if self.part.getVehicle then
                vehicle = self.part:getVehicle()
            end
        end
        
        if vehicle and self.character then
            if not VehicleClaimEnforcement.hasAccess(self.character, vehicle) then
                self.character:Say(VehicleClaimEnforcement.getDenialMessage(vehicle))
                return
            end
        end
        
        return originalPerform(self)
    end
end

-----------------------------------------------------------
-- Transfer Items Blocking (Trunk/Glove Box Access)
-----------------------------------------------------------

--- Hook ISInventoryTransferAction to block item transfers to/from vehicle containers
local function hookInventoryTransfer()
    if not ISInventoryTransferAction then return end
    
    local originalIsValid = ISInventoryTransferAction.isValid
    ISInventoryTransferAction.isValid = function(self)
        -- Check source container
        if self.srcContainer then
            local srcVehicle = nil
            pcall(function()
                if self.srcContainer.getVehicle then
                    srcVehicle = self.srcContainer:getVehicle()
                end
            end)
            if srcVehicle and not VehicleClaimEnforcement.hasAccess(self.character, srcVehicle) then
                return false
            end
        end
        
        -- Check destination container
        if self.destContainer then
            local destVehicle = nil
            pcall(function()
                if self.destContainer.getVehicle then
                    destVehicle = self.destContainer:getVehicle()
                end
            end)
            if destVehicle and not VehicleClaimEnforcement.hasAccess(self.character, destVehicle) then
                return false
            end
        end
        
        return originalIsValid(self)
    end
end

-----------------------------------------------------------
-- Container Update Blocking
-----------------------------------------------------------

--- Close vehicle containers if player doesn't have access
local function onContainerUpdate(container)
    if not container then return end
    
    local player = getPlayer()
    if not player then return end
    
    -- Safely check if container has getVehicle method
    local vehicle = nil
    pcall(function()
        if container.getVehicle then
            vehicle = container:getVehicle()
        end
    end)
    
    if not vehicle then return end
    if VehicleClaimEnforcement.hasAccess(player, vehicle) then return end
    
    -- Block access - close the container
    player:Say(VehicleClaimEnforcement.getDenialMessage(vehicle))
    
    -- Force close the inventory panel for this container
    pcall(function()
        if ISInventoryPage and ISInventoryPage.closeContainerUI then
            ISInventoryPage.closeContainerUI(container)
        end
    end)
end

-----------------------------------------------------------
-- Window Smash Blocking
-----------------------------------------------------------

local function hookSmashWindow()
    if not ISVehicleMenu or not ISVehicleMenu.onSmashWindow then return end
    
    local originalSmashWindow = ISVehicleMenu.onSmashWindow
    ISVehicleMenu.onSmashWindow = function(playerObj, vehicle, window)
        if not VehicleClaimEnforcement.hasAccess(playerObj, vehicle) then
            playerObj:Say(VehicleClaimEnforcement.getDenialMessage(vehicle))
            return
        end
        return originalSmashWindow(playerObj, vehicle, window)
    end
end

-----------------------------------------------------------
-- Radial Menu Blocking (Controller/Gamepad support)
-----------------------------------------------------------

local function hookRadialMenu()
    -- Hook the vehicle radial menu if it exists
    if not ISRadialMenu then return end
    
    -- Hook vehicle-specific radial menus
    if ISVehicleMenu and ISVehicleMenu.onMechanic then
        local originalOnMechanic = ISVehicleMenu.onMechanic
        ISVehicleMenu.onMechanic = function(playerObj, vehicle)
            if not VehicleClaimEnforcement.hasAccess(playerObj, vehicle) then
                playerObj:Say(VehicleClaimEnforcement.getDenialMessage(vehicle))
                return
            end
            return originalOnMechanic(playerObj, vehicle)
        end
    end
end

-----------------------------------------------------------
-- Siphon Gas Blocking
-----------------------------------------------------------

local function hookSiphonGas()
    if not ISVehicleMenu or not ISVehicleMenu.onSiphonGas then return end
    
    local originalSiphonGas = ISVehicleMenu.onSiphonGas
    ISVehicleMenu.onSiphonGas = function(playerObj, vehicle)
        if not VehicleClaimEnforcement.hasAccess(playerObj, vehicle) then
            playerObj:Say(VehicleClaimEnforcement.getDenialMessage(vehicle))
            return
        end
        return originalSiphonGas(playerObj, vehicle)
    end
end

-----------------------------------------------------------
-- Hotwire Blocking
-----------------------------------------------------------

local function hookHotwire()
    if not ISVehicleMenu or not ISVehicleMenu.onHotwire then return end
    
    local originalHotwire = ISVehicleMenu.onHotwire
    ISVehicleMenu.onHotwire = function(playerObj, vehicle)
        if not VehicleClaimEnforcement.hasAccess(playerObj, vehicle) then
            playerObj:Say(VehicleClaimEnforcement.getDenialMessage(vehicle))
            return
        end
        return originalHotwire(playerObj, vehicle)
    end
end

-----------------------------------------------------------
-- Lock/Unlock Door Blocking
-----------------------------------------------------------

local function hookLockDoors()
    if not ISVehicleMenu then return end
    
    if ISVehicleMenu.onLockDoor then
        local originalLockDoor = ISVehicleMenu.onLockDoor
        ISVehicleMenu.onLockDoor = function(playerObj, vehicle, part)
            if not VehicleClaimEnforcement.hasAccess(playerObj, vehicle) then
                playerObj:Say(VehicleClaimEnforcement.getDenialMessage(vehicle))
                return
            end
            return originalLockDoor(playerObj, vehicle, part)
        end
    end
    
    if ISVehicleMenu.onUnlockDoor then
        local originalUnlockDoor = ISVehicleMenu.onUnlockDoor
        ISVehicleMenu.onUnlockDoor = function(playerObj, vehicle, part)
            if not VehicleClaimEnforcement.hasAccess(playerObj, vehicle) then
                playerObj:Say(VehicleClaimEnforcement.getDenialMessage(vehicle))
                return
            end
            return originalUnlockDoor(playerObj, vehicle, part)
        end
    end
end

-----------------------------------------------------------
-- Sleep in Vehicle Blocking
-----------------------------------------------------------

local function hookSleepInVehicle()
    if not ISVehicleMenu or not ISVehicleMenu.onSleep then return end
    
    local originalSleep = ISVehicleMenu.onSleep
    ISVehicleMenu.onSleep = function(playerObj, vehicle, seat)
        if not VehicleClaimEnforcement.hasAccess(playerObj, vehicle) then
            playerObj:Say(VehicleClaimEnforcement.getDenialMessage(vehicle))
            return
        end
        return originalSleep(playerObj, vehicle, seat)
    end
end

-----------------------------------------------------------
-- Initialization
-----------------------------------------------------------

local function initializeHooks()
    print("[VehicleClaim] Initializing enforcement hooks for Build 42...")
    
    -- Apply all hooks
    hookVehicleEntry()
    hookMechanicsPanel()
    hookTimedActions()
    hookInventoryTransfer()
    hookSmashWindow()
    hookRadialMenu()
    hookSiphonGas()
    hookHotwire()
    hookLockDoors()
    hookSleepInVehicle()
    hookVehiclePartActions()    -- Block install/uninstall/repair parts
    
    print("[VehicleClaim] Enforcement hooks initialized")
end

-----------------------------------------------------------
-- Event Registration
-----------------------------------------------------------

-- Register context menu blocking
Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)

-- Register container update blocking with error handling
Events.OnContainerUpdate.Add(function(container)
    pcall(onContainerUpdate, container)
end)

-- Register key press handler for V key mechanics panel
Events.OnKeyPressed.Add(onKeyPressed)

-- Register E key interaction blocking
Events.OnKeyPressed.Add(onKeyPressedInteract)

-- Initialize hooks when game starts
Events.OnGameStart.Add(initializeHooks)

-- Also try to initialize immediately if game is already running
if getPlayer() then
    initializeHooks()
end

return VehicleClaimEnforcement
