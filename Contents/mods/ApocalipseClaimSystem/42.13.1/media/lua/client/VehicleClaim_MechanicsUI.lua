--[[
    VehicleClaim_MechanicsUI.lua
    Integrates claim information and actions into the vehicle mechanics UI
    Shows ownership, last seen, and claim/release buttons
]]

require "ISUI/ISPanel"
require "shared/VehicleClaim_Shared"

-----------------------------------------------------------
-- Vehicle Claim Info Panel (embedded in mechanics window)
-----------------------------------------------------------

ISVehicleClaimInfoPanel = ISPanel:derive("ISVehicleClaimInfoPanel")

function ISVehicleClaimInfoPanel:new(x, y, width, height, vehicle, player)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.vehicle = vehicle
    o.player = player
    o.borderColor = {r=0.4, g=0.4, b=0.4, a=1}
    o.backgroundColor = {r=0, g=0, b=0, a=0.8}
    
    return o
end

function ISVehicleClaimInfoPanel:createChildren()
    ISPanel.createChildren(self)
    
    print("[VehicleClaim] createChildren: vehicle=" .. tostring(self.vehicle))
    
    local padding = 10
    local yOffset = padding
    local buttonHeight = 25
    
    -- Title
    self.titleLabel = ISLabel:new(padding, yOffset, 20, "Vehicle Ownership", 1, 1, 1, 1, UIFont.Medium, true)
    self.titleLabel:initialise()
    self:addChild(self.titleLabel)
    yOffset = yOffset + 25
    
    -- Vehicle ID (will be updated in prerender when vehicle is available)
    self.vehicleIDLabel = ISLabel:new(padding, yOffset, 20, "Vehicle ID: Loading...", 0.5, 0.5, 0.5, 1, UIFont.Small, true)
    self.vehicleIDLabel:initialise()
    self:addChild(self.vehicleIDLabel)
    yOffset = yOffset + 20
    
    -- Separator line
    yOffset = yOffset + 5
    
    -- Status info labels (created dynamically based on claim state)
    self.statusLabel = ISLabel:new(padding, yOffset, 20, "", 1, 1, 1, 1, UIFont.Small, true)
    self.statusLabel:initialise()
    self:addChild(self.statusLabel)
    yOffset = yOffset + 20
    
    self.ownerLabel = ISLabel:new(padding, yOffset, 20, "", 0.7, 0.7, 0.7, 1, UIFont.Small, true)
    self.ownerLabel:initialise()
    self:addChild(self.ownerLabel)
    yOffset = yOffset + 20
    
    self.lastSeenLabel = ISLabel:new(padding, yOffset, 20, "", 0.7, 0.7, 0.7, 1, UIFont.Small, true)
    self.lastSeenLabel:initialise()
    self:addChild(self.lastSeenLabel)
    yOffset = yOffset + 25
    
    -- Action button (Claim or Release)
    self.actionButton = ISButton:new(padding, yOffset, self.width - (padding * 2), buttonHeight, "", self, ISVehicleClaimInfoPanel.onActionButton)
    self.actionButton:initialise()
    self.actionButton.borderColor = {r=1, g=1, b=1, a=0.3}
    self:addChild(self.actionButton)
    yOffset = yOffset + buttonHeight + 5
    
    -- Manage button (only shown if owner)
    self.manageButton = ISButton:new(padding, yOffset, self.width - (padding * 2), buttonHeight, "Manage Access", self, ISVehicleClaimInfoPanel.onManageButton)
    self.manageButton:initialise()
    self.manageButton.borderColor = {r=1, g=1, b=1, a=0.3}
    self:addChild(self.manageButton)
    
    -- Force immediate update
    self.lastUpdateTime = 0
end

function ISVehicleClaimInfoPanel:updateInfo()
    if not self.vehicle then 
        print("[VehicleClaim] updateInfo: No vehicle")
        return 
    end
    
    print("[VehicleClaim] updateInfo: Checking vehicle " .. tostring(self.vehicle:getId()))
    
    local steamID = VehicleClaim.getPlayerSteamID(self.player)
    local isClaimed = VehicleClaim.isClaimed(self.vehicle)
    local ownerID = VehicleClaim.getOwnerID(self.vehicle)
    local ownerName = VehicleClaim.getOwnerName(self.vehicle)
    
    print("[VehicleClaim] isClaimed=" .. tostring(isClaimed) .. " ownerID=" .. tostring(ownerID))
    
    local isOwner = ownerID == steamID
    local hasAccess = VehicleClaim.hasAccess(self.vehicle, steamID)
    local isAdmin = self.player:getAccessLevel() == "admin" or self.player:getAccessLevel() == "moderator"
    
    if not isClaimed then
        -- Unclaimed vehicle
        self.statusLabel:setName("Status: Unclaimed")
        self.statusLabel:setColor(0.5, 1, 0.5)
        self.ownerLabel:setName("")
        self.lastSeenLabel:setName("This vehicle is available to claim")
        
        self.actionButton:setTitle("Claim This Vehicle")
        self.actionButton:setVisible(true)
        self.actionButton.backgroundColor = {r=0.2, g=0.6, b=0.2, a=1}
        
        self.manageButton:setVisible(false)
        
    else
        -- Claimed vehicle
        self.statusLabel:setName("Status: Claimed")
        self.statusLabel:setColor(1, 0.8, 0.2)
        
        if isOwner then
            self.ownerLabel:setName("Owner: You")
            self.ownerLabel:setColor(0.5, 1, 0.5)
        elseif hasAccess then
            self.ownerLabel:setName("Owner: " .. (ownerName or "Unknown"))
            self.ownerLabel:setColor(0.5, 0.8, 1)
            self.lastSeenLabel:setName("(You have access)")
            self.lastSeenLabel:setColor(0.5, 0.8, 1)
        else
            self.ownerLabel:setName("Owner: " .. (ownerName or "Unknown"))
            self.ownerLabel:setColor(1, 0.5, 0.5)
        end
        
        -- Last seen info
        local claimData = VehicleClaim.getClaimData(self.vehicle)
        if claimData then
            local lastSeen = claimData[VehicleClaim.LAST_SEEN_KEY]
            if lastSeen then
                local timeSince = VehicleClaim.getCurrentTimestamp() - lastSeen
                local hours = math.floor(timeSince / 3600)
                if hours > 24 then
                    local days = math.floor(hours / 24)
                    self.lastSeenLabel:setName("Last seen: " .. days .. " days ago")
                elseif hours > 0 then
                    self.lastSeenLabel:setName("Last seen: " .. hours .. " hours ago")
                else
                    self.lastSeenLabel:setName("Last seen: Recently")
                end
            end
        end
        
        -- Action button
        if isOwner or isAdmin then
            self.actionButton:setTitle("Release Claim")
            self.actionButton:setVisible(true)
            self.actionButton.backgroundColor = {r=0.8, g=0.3, b=0.3, a=1}
        else
            self.actionButton:setVisible(false)
        end
        
        -- Manage button
        if isOwner or isAdmin then
            self.manageButton:setVisible(true)
        else
            self.manageButton:setVisible(false)
        end
    end
end

function ISVehicleClaimInfoPanel:onActionButton()
    if not self.vehicle then return end
    
    local steamID = VehicleClaim.getPlayerSteamID(self.player)
    local isClaimed = VehicleClaim.isClaimed(self.vehicle)
    
    if not isClaimed then
        -- Claim vehicle
        local vehicleID = self.vehicle:getId()
        local playerName = self.player:getUsername()
        
        sendClientCommand(self.player, VehicleClaim.COMMAND_MODULE, VehicleClaim.CMD_CLAIM, {
            vehicleID = vehicleID,
            steamID = steamID,
            playerName = playerName
        })
        
    else
        -- Release claim
        local vehicleID = self.vehicle:getId()
        
        sendClientCommand(self.player, VehicleClaim.COMMAND_MODULE, VehicleClaim.CMD_RELEASE, {
            vehicleID = vehicleID,
            steamID = steamID
        })
    end
    
    -- Close mechanics UI after action
    if ISVehicleMechanics.instance then
        ISVehicleMechanics.instance:close()
    end
end

function ISVehicleClaimInfoPanel:onManageButton()
    if not self.vehicle then return end
    
    -- Open the manage access panel
    local panel = ISVehicleClaimPanel:new(100, 100, 400, 300, self.vehicle, self.player)
    panel:initialise()
    panel:addToUIManager()
    
    -- Close mechanics UI
    if ISVehicleMechanics.instance then
        ISVehicleMechanics.instance:close()
    end
end

function ISVehicleClaimInfoPanel:update()
    ISPanel.update(self)
    
    -- Get vehicle reference from parent if we don't have it
    if not self.vehicle and self.parent and self.parent.vehicle then
        self.vehicle = self.parent.vehicle
        print("[VehicleClaim] Got vehicle reference from parent: " .. tostring(self.vehicle:getId()))
    end
    
    -- Update vehicle ID label if vehicle is available
    if self.vehicle and self.vehicleIDLabel then
        local vehicleID = tostring(self.vehicle:getId())
        local currentText = "Vehicle ID: " .. vehicleID
        if self.vehicleIDLabel:getName() ~= currentText then
            self.vehicleIDLabel:setName(currentText)
        end
    end
    
    -- Simple throttled updates: check every 2 seconds
    local currentTime = os.time()
    if not self.lastUpdateTime or (currentTime - self.lastUpdateTime) >= 2 then
        self:updateInfo()
        self.lastUpdateTime = currentTime
    end
end

function ISVehicleClaimInfoPanel:prerender()
    ISPanel.prerender(self)
    self:drawRect(0, 0, self.width, self.height, self.backgroundColor.a, self.backgroundColor.r, self.backgroundColor.g, self.backgroundColor.b)
    self:drawRectBorder(0, 0, self.width, self.height, self.borderColor.a, self.borderColor.r, self.borderColor.g, self.borderColor.b)
end

function ISVehicleClaimInfoPanel:render()
    ISPanel.render(self)
end

function ISVehicleClaimInfoPanel:isMouseOver()
    -- Override to always check mouse position, even outside parent bounds
    if not self:getIsVisible() then
        return false
    end
    
    local mouseX = getMouseX()
    local mouseY = getMouseY()
    local absX = self:getAbsoluteX()
    local absY = self:getAbsoluteY()
    
    return mouseX >= absX and mouseX <= absX + self.width and 
           mouseY >= absY and mouseY <= absY + self.height
end

-----------------------------------------------------------
-- Hook into ISVehicleMechanics to add our panel
-----------------------------------------------------------

local function integrateWithMechanicsUI()
    -- Wait for ISVehicleMechanics to be available
    if not ISVehicleMechanics then
        print("[VehicleClaim] ISVehicleMechanics not available yet, will retry...")
        return false
    end
    
    print("[VehicleClaim] Hooking into ISVehicleMechanics...")
    
    -- Store original methods
    local original_createChildren = ISVehicleMechanics.createChildren
    local original_prerender = ISVehicleMechanics.prerender
    local original_onMouseDown = ISVehicleMechanics.onMouseDown
    local original_onMouseUp = ISVehicleMechanics.onMouseUp
    local original_onMouseMove = ISVehicleMechanics.onMouseMove
    
    -- Hook the createChildren method to add our panel
    ISVehicleMechanics.createChildren = function(self)
        print("[VehicleClaim] ISVehicleMechanics.createChildren called")
        
        -- Call original
        original_createChildren(self)
        
        -- Add our claim info panel at the bottom of the mechanics window
        local panelHeight = 180
        local panelWidth = 250
        local panelX = -250
        local panelY = self.height - panelHeight - 10
        
        print("[VehicleClaim] Creating claim panel at x=" .. panelX .. " y=" .. panelY .. " w=" .. panelWidth .. " h=" .. panelHeight)
        
        self.claimInfoPanel = ISVehicleClaimInfoPanel:new(panelX, panelY, panelWidth, panelHeight, self.vehicle, self.chr)
        self.claimInfoPanel:initialise()
        self.claimInfoPanel:instantiate()
        self:addChild(self.claimInfoPanel)
        
        print("[VehicleClaim] Claim info panel added to vehicle mechanics window")
    end
    
    -- Hook prerender to sync data when window opens
    ISVehicleMechanics.prerender = function(self)
        original_prerender(self)
        
        -- Request fresh data from server when mechanics UI is open
        if self.claimInfoPanel and self.vehicle then
            -- Only request once when window first opens
            if not self.claimInfoPanel.dataRequested then
                local vehicleID = self.vehicle:getId()
                sendClientCommand(self.chr, VehicleClaim.COMMAND_MODULE, VehicleClaim.CMD_REQUEST_INFO, {
                    vehicleID = vehicleID
                })
                self.claimInfoPanel.dataRequested = true
                print("[VehicleClaim] Requested fresh claim data for vehicle " .. vehicleID)
            end
        end
    end
    
    -- Hook mouse events to forward to claim panel even if outside parent bounds
    ISVehicleMechanics.onMouseDown = function(self, x, y)
        -- Check if claim panel exists and if mouse is over it
        if self.claimInfoPanel and self.claimInfoPanel:isMouseOver() then
            self.claimInfoPanel:onMouseDown(x - self.claimInfoPanel:getAbsoluteX(), y - self.claimInfoPanel:getAbsoluteY())
            return
        end
        -- Otherwise call original
        if original_onMouseDown then
            original_onMouseDown(self, x, y)
        end
    end
    
    ISVehicleMechanics.onMouseUp = function(self, x, y)
        -- Check if claim panel exists and if mouse is over it
        if self.claimInfoPanel and self.claimInfoPanel:isMouseOver() then
            self.claimInfoPanel:onMouseUp(x - self.claimInfoPanel:getAbsoluteX(), y - self.claimInfoPanel:getAbsoluteY())
            return
        end
        -- Otherwise call original
        if original_onMouseUp then
            original_onMouseUp(self, x, y)
        end
    end
    
    ISVehicleMechanics.onMouseMove = function(self, dx, dy)
        -- Check if claim panel exists and if mouse is over it
        if self.claimInfoPanel and self.claimInfoPanel:isMouseOver() then
            self.claimInfoPanel:onMouseMove(dx, dy)
            return
        end
        -- Otherwise call original
        if original_onMouseMove then
            original_onMouseMove(self, dx, dy)
        end
    end
    
    print("[VehicleClaim] Successfully integrated with vehicle mechanics UI")
    return true
end

-- Try to integrate immediately when this file loads
local integrated = integrateWithMechanicsUI()

-- If not successful, try again on game start
if not integrated then
    Events.OnGameStart.Add(function()
        integrateWithMechanicsUI()
    end)
end

-- Also try on OnGameBoot as a fallback
Events.OnGameBoot.Add(function()
    if not integrated then
        integrateWithMechanicsUI()
    end
end)
