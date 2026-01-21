--[[
    VehicleClaim_MechanicsUI.lua
    Integrates claim information and actions into the vehicle mechanics UI
    Shows ownership, last seen, and claim/release buttons
]]

require "ISUI/ISPanel"
require "shared/VehicleClaim_Shared"
require "client/VehicleClaim_ContextMenu"

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
    
    -- Set up event listeners for claim changes
    self:setupEventListeners()
    
    local padding = 10
    local yOffset = padding
    local buttonHeight = 25
    
    -- Title
    self.titleLabel = ISLabel:new(padding, yOffset, 20, getText("UI_VehicleClaim_MechanicsTitle"), 1, 1, 1, 1, UIFont.Medium, true)
    self.titleLabel:initialise()
    self:addChild(self.titleLabel)
    yOffset = yOffset + 25
    
    -- Vehicle ID (will be updated in prerender when vehicle is available)
    self.vehicleIDLabel = ISLabel:new(padding, yOffset, 20, getText("UI_VehicleClaim_VehicleIDLoading"), 0.5, 0.5, 0.5, 1, UIFont.Small, true)
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
    
    -- Loading indicator (initially hidden)
    self.loadingLabel = ISLabel:new(padding, yOffset, 20, getText("UI_VehicleClaim_Processing"), 1, 1, 0, 1, UIFont.Small, true)
    self.loadingLabel:initialise()
    self.loadingLabel:setVisible(false)
    self:addChild(self.loadingLabel)
    
    -- Action button (Claim or Release)
    self.actionButton = ISButton:new(padding, yOffset, self.width - (padding * 2), buttonHeight, "", self, ISVehicleClaimInfoPanel.onActionButton)
    self.actionButton:initialise()
    self.actionButton.borderColor = {r=1, g=1, b=1, a=0.3}
    self:addChild(self.actionButton)
    yOffset = yOffset + buttonHeight + 5
    
    -- Manage button (only shown if owner)
    self.manageButton = ISButton:new(padding, yOffset, self.width - (padding * 2), buttonHeight, getText("UI_VehicleClaim_ManageAccess"), self, ISVehicleClaimInfoPanel.onManageButton)
    self.manageButton:initialise()
    self.manageButton.borderColor = {r=1, g=1, b=1, a=0.3}
    self:addChild(self.manageButton)
end

function ISVehicleClaimInfoPanel:setupEventListeners()
    -- Create event handler functions that check if event is for our vehicle
    self.onClaimSuccessHandler = function(vehicleHash, claimData)
        local currentHash = self.vehicle and VehicleClaim.getVehicleHash(self.vehicle)
        if currentHash == vehicleHash then
            print("[VehicleClaim] Claim success event for our vehicle: " .. vehicleHash)
            self:updateInfo(claimData)
        end
    end
    
    self.onClaimChangedHandler = function(vehicleHash, claimData)
        local currentHash = self.vehicle and VehicleClaim.getVehicleHash(self.vehicle)
        if currentHash == vehicleHash then
            print("[VehicleClaim] Claim changed event for our vehicle: " .. vehicleHash)
            self:updateInfo(claimData)
        end
    end
    
    self.onClaimReleasedHandler = function(vehicleHash, claimData)
        local currentHash = self.vehicle and VehicleClaim.getVehicleHash(self.vehicle)
        if currentHash == vehicleHash then
            print("[VehicleClaim] Claim released event for our vehicle: " .. vehicleHash)
            -- Vehicle was released, reset UI to unclaimed state
            self:resetToUnclaimedState()
        end
    end
    
    self.onAccessChangedHandler = function(vehicleHash, claimData)
        local currentHash = self.vehicle and VehicleClaim.getVehicleHash(self.vehicle)
        if currentHash == vehicleHash then
            print("[VehicleClaim] Access changed event for our vehicle: " .. vehicleHash)
            self:updateInfo(claimData)
        end
    end
    
    self.onVehicleInfoReceivedHandler = function(vehicleHash, claimData)
        local currentHash = self.vehicle and VehicleClaim.getVehicleHash(self.vehicle)
        if currentHash == vehicleHash then
            print("[VehicleClaim] Vehicle info received for our vehicle: " .. vehicleHash)
            self:updateInfo(claimData)
        end
    end
    
    -- Subscribe to events
    --Events.OnVehicleClaimSuccess.Add(self.onClaimSuccessHandler)
    Events.OnVehicleClaimChanged.Add(self.onClaimChangedHandler)
    Events.OnVehicleClaimReleased.Add(self.onClaimReleasedHandler)
    Events.OnVehicleClaimAccessChanged.Add(self.onAccessChangedHandler)
    Events.OnVehicleInfoReceived.Add(self.onVehicleInfoReceivedHandler)
    
    print("[VehicleClaim] Event listeners registered")
end

function ISVehicleClaimInfoPanel:removeEventListeners()
    -- Unsubscribe from events
    if self.onClaimSuccessHandler then
        Events.OnVehicleClaimSuccess.Remove(self.onClaimSuccessHandler)
    end
    if self.onClaimChangedHandler then
        Events.OnVehicleClaimChanged.Remove(self.onClaimChangedHandler)
    end
    if self.onClaimReleasedHandler then
        Events.OnVehicleClaimReleased.Remove(self.onClaimReleasedHandler)
    end
    if self.onAccessChangedHandler then
        Events.OnVehicleClaimAccessChanged.Remove(self.onAccessChangedHandler)
    end
    if self.onVehicleInfoReceivedHandler then
        Events.OnVehicleInfoReceived.Remove(self.onVehicleInfoReceivedHandler)
    end
    
    print("[VehicleClaim] Event listeners removed")
end

function ISVehicleClaimInfoPanel:resetToUnclaimedState()
    -- Reset UI to show unclaimed vehicle state
    -- This is called when a vehicle is released to avoid reading stale cached data
    
    print("[VehicleClaim] Resetting panel to unclaimed state")
    
    -- Server will clear ModData automatically, just update UI
    
    -- Show all status labels
    if self.loadingLabel then self.loadingLabel:setVisible(false) end
    if self.statusLabel then self.statusLabel:setVisible(true) end
    if self.ownerLabel then self.ownerLabel:setVisible(true) end
    if self.lastSeenLabel then self.lastSeenLabel:setVisible(true) end
    
    -- Set unclaimed state
    self.statusLabel:setName(getText("UI_VehicleClaim_StatusUnclaimed"))
    self.statusLabel:setColor(0.5, 1, 0.5)
    self.ownerLabel:setName("")
    self.lastSeenLabel:setName(getText("UI_VehicleClaim_AvailableToClaim"))
    
    -- Show claim button
    self.actionButton:setTitle(getText("UI_VehicleClaim_ClaimButton"))
    self.actionButton:setVisible(true)
    self.actionButton.backgroundColor = {r=0.2, g=0.6, b=0.2, a=1}
    
    -- Hide manage button
    self.manageButton:setVisible(false)
end

function ISVehicleClaimInfoPanel:updateInfo(claimData)
    if not self.vehicle then 
        print("[VehicleClaim] updateInfo: No vehicle")
        -- Hide all UI elements when no vehicle
        if self.loadingLabel then self.loadingLabel:setVisible(false) end
        if self.statusLabel then self.statusLabel:setVisible(false) end
        if self.ownerLabel then self.ownerLabel:setVisible(false) end
        if self.lastSeenLabel then self.lastSeenLabel:setVisible(false) end
        if self.actionButton then self.actionButton:setVisible(false) end
        if self.manageButton then self.manageButton:setVisible(false) end
        return 
    end
    
    -- Read directly from vehicle ModData (single source of truth)
    if not claimData then
        claimData = VehicleClaim.getClaimData(self.vehicle)
    end
    
    -- Show all status labels
    if self.loadingLabel then self.loadingLabel:setVisible(false) end
    if self.statusLabel then self.statusLabel:setVisible(true) end
    if self.ownerLabel then self.ownerLabel:setVisible(true) end
    if self.lastSeenLabel then self.lastSeenLabel:setVisible(true) end
    
    local steamID = VehicleClaim.getPlayerSteamID(self.player)
    
    -- Determine if claimed based on claimData
    local isClaimed = claimData ~= nil
    local ownerID = claimData and claimData[VehicleClaim.OWNER_KEY]
    local ownerName = claimData and claimData[VehicleClaim.OWNER_NAME_KEY]

    print("[VehicleClaim] updateInfo DEBUG:")
    local lastSeenTimestamp = claimData and claimData[VehicleClaim.LAST_SEEN_KEY]
    print("[VehicleClaim] claimData contents:")
    if claimData then
        for key, value in pairs(claimData) do
            print("  - " .. tostring(key) .. ": " .. tostring(value) .. " (type: " .. type(value) .. ")")
        end
    else
        print("  - claimData is nil")
    end
    print("  - steamID: " .. tostring(steamID) .. " (type: " .. type(steamID) .. ")")
    print("  - ownerID: " .. tostring(ownerID) .. " (type: " .. type(ownerID) .. ")")
    print("  - isClaimed: " .. tostring(isClaimed))
    print("  - ownerName: " .. tostring(ownerName))
    
    local isOwner = (ownerID == steamID)
    print("  - isOwner: " .. tostring(isOwner))
    
    local hasAccess = false
    if claimData then
        local allowedPlayers = claimData[VehicleClaim.ALLOWED_PLAYERS_KEY] or {}
        hasAccess = allowedPlayers[steamID] ~= nil
        print("  - hasAccess: " .. tostring(hasAccess))
    end
    local isAdmin = self.player:getAccessLevel() == "admin" or self.player:getAccessLevel() == "moderator"
    print("  - isAdmin: " .. tostring(isAdmin))
    
    if not isClaimed then
        -- Unclaimed vehicle
        self.statusLabel:setName(getText("UI_VehicleClaim_StatusUnclaimed"))
        self.statusLabel:setColor(0.5, 1, 0.5)
        self.ownerLabel:setName("")
        self.lastSeenLabel:setName(getText("UI_VehicleClaim_AvailableToClaim"))
        
        self.actionButton:setTitle(getText("UI_VehicleClaim_ClaimButton"))
        self.actionButton:setVisible(true)
        self.actionButton.backgroundColor = {r=0.2, g=0.6, b=0.2, a=1}
        
        self.manageButton:setVisible(false)
        
    else
        -- Claimed vehicle
        self.statusLabel:setName(getText("UI_VehicleClaim_StatusClaimed"))
        self.statusLabel:setColor(1, 0.8, 0.2)
        
        if isOwner then
            self.ownerLabel:setName(getText("UI_VehicleClaim_OwnerYou"))
            self.ownerLabel:setColor(0.5, 1, 0.5)
        elseif hasAccess then
            self.ownerLabel:setName(getText("UI_VehicleClaim_OwnerLabel", ownerName or getText("UI_VehicleClaim_Unknown")) .. " " .. getText("UI_VehicleClaim_AccessGranted"))
            self.ownerLabel:setColor(0.5, 0.8, 1)
        else
            self.ownerLabel:setName(getText("UI_VehicleClaim_OwnerLabel", ownerName or getText("UI_VehicleClaim_Unknown")) .. " " .. getText("UI_VehicleClaim_NoAccess"))
            self.ownerLabel:setColor(1, 0.5, 0.5)
        end
        
        -- Last seen info
        if claimData then
            local lastSeen = claimData[VehicleClaim.LAST_SEEN_KEY]
            if lastSeen then
                local timeSince = VehicleClaim.getCurrentTimestamp() - lastSeen
                local hours = math.floor(timeSince / 3600)
                if hours > 24 then
                    local days = math.floor(hours / 24)
                    self.lastSeenLabel:setName(getText("UI_VehicleClaim_LastSeenDays", days))
                elseif hours > 0 then
                    self.lastSeenLabel:setName(getText("UI_VehicleClaim_LastSeenHours", hours))
                else
                    self.lastSeenLabel:setName(getText("UI_VehicleClaim_LastSeenRecently"))
                end
            end
        end
        
        -- Action button
        if isOwner or isAdmin then
            print("[VehicleClaim] Showing release button (isOwner=" .. tostring(isOwner) .. ", isAdmin=" .. tostring(isAdmin) .. ")")
            self.actionButton:setTitle(getText("UI_VehicleClaim_ReleaseButton"))
            self.actionButton:setVisible(true)
            self.actionButton.backgroundColor = {r=0.8, g=0.3, b=0.3, a=1}
        else
            print("[VehicleClaim] Hiding action button (isOwner=" .. tostring(isOwner) .. ", isAdmin=" .. tostring(isAdmin) .. ")")
            self.actionButton:setVisible(false)
        end
        
        -- Manage button
        if isOwner or isAdmin then
            print("[VehicleClaim] Showing manage button (isOwner=" .. tostring(isOwner) .. ", isAdmin=" .. tostring(isAdmin) .. ")")
            self.manageButton:setVisible(true)
        else
            print("[VehicleClaim] Hiding manage button (isOwner=" .. tostring(isOwner) .. ", isAdmin=" .. tostring(isAdmin) .. ")")
            self.manageButton:setVisible(false)
        end
    end
end

function ISVehicleClaimInfoPanel:onActionButton()
    if not self.vehicle then return end
    
    -- Read claim state directly from vehicle ModData
    local isClaimed = VehicleClaim.isClaimed(self.vehicle)
    print("[VehicleClaim] onActionButton: self.vehicle=" .. tostring(self.vehicle))
    print("[VehicleClaim] onActionButton: isClaimed=" .. tostring(isClaimed))
    
    if not isClaimed then
        -- Claim vehicle - use timed action
        local action = ISClaimVehicleAction:new(self.player, self.vehicle, VehicleClaim.CLAIM_TIME_TICKS)
        ISTimedActionQueue.add(action)
    else
        -- Release claim - use timed action
        local action = ISReleaseVehicleClaimAction:new(self.player, self.vehicle, VehicleClaim.CLAIM_TIME_TICKS / 2)
        ISTimedActionQueue.add(action)
    end
    
    -- UI will update automatically via events when server confirms
end

function ISVehicleClaimInfoPanel:onManageButton()
    if not self.vehicle then return end
    
    -- Get vehicle ID and claim data
    local claimData = VehicleClaim.getClaimData(self.vehicle)
    local vehicleHash = VehicleClaim.getVehicleHash(self.vehicle)
    
    -- Open the manage access panel with correct parameter order
    local panel = ISVehicleClaimPanel:new(100, 100, 400, 500, self.player, self.vehicle, vehicleHash, claimData)
    panel:initialise()
    panel:addToUIManager()
    
    -- UI will update automatically via events when changes are made
end

function ISVehicleClaimInfoPanel:update()
    ISPanel.update(self)
    
    -- Get vehicle reference from parent and update UI when vehicle changes
    if self.parent and self.parent.vehicle then
        if self.vehicle ~= self.parent.vehicle then
            -- Vehicle reference changed (first time or different vehicle)
            print("[VehicleClaim] Vehicle changed to: " .. tostring(self.parent.vehicle))
            self.vehicle = self.parent.vehicle
            
            -- Update UI to reflect new vehicle's claim status
            self:updateInfo()
            
            -- Update vehicle hash label
            if self.vehicleIDLabel then
                local vehicleHash = VehicleClaim.getVehicleHash(self.vehicle) or "Not Generated"
                self.vehicleIDLabel:setName(getText("UI_VehicleClaim_VehicleIDLabel", vehicleHash))
            end
        end
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

function ISVehicleClaimInfoPanel:close()
    -- Unsubscribe from events when panel closes
    self:removeEventListeners()
    
    ISPanel.close(self)
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
    local original_close = ISVehicleMechanics.close
    local original_onResize = ISVehicleMechanics.onResize
    local original_onMouseDown = ISVehicleMechanics.onMouseDown
    local original_onMouseUp = ISVehicleMechanics.onMouseUp
    local original_onMouseMove = ISVehicleMechanics.onMouseMove
    
    -- Hook the createChildren method to add our panel
    ISVehicleMechanics.createChildren = function(self)
        print("[VehicleClaim] ISVehicleMechanics.createChildren called")
        
        -- Call original
        original_createChildren(self)
        
        -- Increase window height to fit our panel
        local originalHeight = self.height
        self:setHeight(originalHeight+180)
        
        print("[VehicleClaim] Increased mechanics window height from " .. originalHeight .. " to " .. self.height)

        
        -- Add our claim info panel at the bottom of the extended window
        local panelHeight = 180
        local panelWidth = 300
        local panelX = self.width - panelWidth - 10  -- Right side with padding
        local panelY = self.height - (panelHeight*2) - 10  -- Bottom of window
        
        print("[VehicleClaim] Creating claim panel at x=" .. panelX .. " y=" .. panelY .. " w=" .. panelWidth .. " h=" .. panelHeight)
        
        self.claimInfoPanel = ISVehicleClaimInfoPanel:new(panelX, panelY, panelWidth, panelHeight, self.vehicle, self.chr)
        self.claimInfoPanel:initialise()
        self.claimInfoPanel:instantiate()
        self:addChild(self.claimInfoPanel)
        
        print("[VehicleClaim] Claim info panel added to vehicle mechanics window")
    end

    -- Hook prerender for any additional rendering needs
    ISVehicleMechanics.prerender = function(self)
        original_prerender(self)
        
        -- Panel will read ModData directly when needed
        -- No need to request info from server
    end
    
    -- Hook close to reset panel state when window closes
    ISVehicleMechanics.close = function(self)
        original_close(self)
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
