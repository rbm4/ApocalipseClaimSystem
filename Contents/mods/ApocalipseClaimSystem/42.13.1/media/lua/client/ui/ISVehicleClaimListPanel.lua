--[[
    ISVehicleClaimListPanel.lua
    Shows all vehicles claimed by the player
    Provides quick access to manage each vehicle
]]

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISScrollingListBox"
require "shared/VehicleClaim_Shared"

ISVehicleClaimListPanel = ISPanel:derive("ISVehicleClaimListPanel")

-----------------------------------------------------------
-- Constructor
-----------------------------------------------------------

function ISVehicleClaimListPanel:new(x, y, width, height, player)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.player = player
    o.steamID = VehicleClaim.getPlayerSteamID(player)
    
    o.backgroundColor = {r = 0.1, g = 0.1, b = 0.1, a = 0.9}
    o.borderColor = {r = 0.4, g = 0.4, b = 0.4, a = 1}
    
    o.title = getText("UI_VehicleClaim_MyVehicles")
    o.moveWithMouse = true
    o.anchorLeft = true
    o.anchorRight = false
    o.anchorTop = true
    o.anchorBottom = false
    
    -- Data cache
    o.claimedVehicles = {}
    
    return o
end

-----------------------------------------------------------
-- Initialization
-----------------------------------------------------------

function ISVehicleClaimListPanel:initialise()
    ISPanel.initialise(self)
    
    local btnHeight = 25
    local padding = 10
    local labelHeight = 20
    local y = 30
    
    -- Title label
    self.titleLabel = ISLabel:new(padding, y, labelHeight, self.title, 1, 1, 1, 1, UIFont.Medium, true)
    self.titleLabel:initialise()
    self:addChild(self.titleLabel)
    y = y + labelHeight + padding
    
    -- Info label
    local maxClaims = VehicleClaim.getMaxClaimsPerPlayer()
    local infoText = getText("UI_VehicleClaim_VehicleCount", 0, maxClaims)
    self.infoLabel = ISLabel:new(padding, y, labelHeight, infoText, 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    self.infoLabel:initialise()
    self:addChild(self.infoLabel)
    y = y + labelHeight + 10
    
    -- Vehicle list
    local listHeight = 300
    self.vehicleList = ISScrollingListBox:new(padding, y, self.width - (padding * 2), listHeight)
    self.vehicleList:initialise()
    self.vehicleList:instantiate()
    self.vehicleList.backgroundColor = {r = 0.15, g = 0.15, b = 0.15, a = 1}
    self.vehicleList.borderColor = {r = 0.3, g = 0.3, b = 0.3, a = 1}
    self.vehicleList.itemheight = 30
    self.vehicleList.doDrawItem = self.drawVehicleListItem
    self.vehicleList.drawBorder = true
    self:addChild(self.vehicleList)
    y = y + listHeight + padding
    
    -- Bottom buttons
    local btnWidth = (self.width - (padding * 3)) / 2
    
    -- Manage button
    self.manageButton = ISButton:new(padding, y, btnWidth, btnHeight, getText("UI_VehicleClaim_Manage"), self, ISVehicleClaimListPanel.onManageVehicle)
    self.manageButton:initialise()
    self.manageButton:instantiate()
    self.manageButton.borderColor = {r = 0.3, g = 0.5, b = 0.3, a = 1}
    self:addChild(self.manageButton)
    
    -- Refresh button
    -- self.refreshButton = ISButton:new(padding * 2 + btnWidth, y, btnWidth, btnHeight, getText("UI_VehicleClaim_Refresh"), self, ISVehicleClaimListPanel.onRefresh)
    -- self.refreshButton:initialise()
    -- self.refreshButton:instantiate()
    -- self:addChild(self.refreshButton)
    y = y + btnHeight + padding
    
    -- Close button
    self.closeButton = ISButton:new(padding, y, self.width - (padding * 2), btnHeight, getText("UI_VehicleClaim_Close"), self, ISVehicleClaimListPanel.onClose)
    self.closeButton:initialise()
    self.closeButton:instantiate()
    self:addChild(self.closeButton)
    
    -- Register for refresh events
    if VehicleClaimClientCommands then
        VehicleClaimClientCommands.registerPanel(self)
    end
    
    -- Load initial data from server
    self:refreshData()
end

-----------------------------------------------------------
-- Data Loading
-----------------------------------------------------------

function ISVehicleClaimListPanel:refreshData()
    -- Throttle to prevent excessive server requests (5 second minimum interval)
    local currentTime = getTimestampMs()
    
    if self.lastRefreshTime then
        local elapsed = currentTime - self.lastRefreshTime
        if elapsed < 30000 then
            -- Too soon, skip this request
            return
        end
    end
    
    -- Update last refresh time
    self.lastRefreshTime = currentTime
    
    -- Request claims from server (works for ALL vehicles, even unloaded)
    if VehicleClaimClientCommands then
        VehicleClaimClientCommands.requestMyClaims(function(args)
            self:onClaimsReceived(args)
        end)
    end
end

--- Called when server responds with claim data
function ISVehicleClaimListPanel:onClaimsReceived(args)
    local claims = args.claims or {}
    
    -- Double-check: Filter to only show this player's vehicles (client-side verification)
    local filteredClaims = {}
    for _, claimData in ipairs(claims) do
        if claimData.ownerSteamID == self.steamID then
            table.insert(filteredClaims, claimData)
        end
    end
    
    self.claimedVehiclesData = filteredClaims
    self.currentClaimCount = #filteredClaims
    self.maxClaimCount = args.maxClaims or 5
    
    -- Update the list display
    self:updateVehicleList()
end

function ISVehicleClaimListPanel:updateVehicleList()
    self.vehicleList:clear()
    
    -- Update info label
    local maxClaims = self.maxClaimCount or VehicleClaim.getMaxClaimsPerPlayer()
    local currentClaims = self.currentClaimCount or 0
    local infoText = getText("UI_VehicleClaim_VehicleCount", currentClaims, maxClaims)
    self.infoLabel:setName(infoText)
    
    if not self.claimedVehiclesData or #self.claimedVehiclesData == 0 then
        self.vehicleList:addItem(getText("UI_VehicleClaim_NoVehiclesClaimed"), {vehicleID = nil, isLoaded = false})
        return
    end
    
    -- Add vehicles to list (from server data, not local scan)
    for _, claimData in ipairs(self.claimedVehiclesData) do
        local vehicleName = claimData.vehicleName or "Unknown Vehicle"
        local vehicleID = claimData.vehicleID
        local x = claimData.x or 0
        local y = claimData.y or 0
        
        -- Try to find the vehicle if it's loaded (for distance calculation)
        local loadedVehicle = self:findLoadedVehicle(vehicleID)
        local statusText = ""
        
        if loadedVehicle then
            -- Vehicle is loaded - show distance
            local distance = VehicleClaim.getDistance(self.player, loadedVehicle)
            statusText = string.format(" - %.0fm", distance)
        else
            -- Vehicle is not loaded - show last known position
            statusText = string.format(" - %s (%d, %d)", getText("UI_VehicleClaim_NotLoaded"), math.floor(x), math.floor(y))
        end
        
        local displayText = string.format("%s (ID: %d)%s", vehicleName, vehicleID, statusText)
        
        self.vehicleList:addItem(displayText, {
            vehicleID = vehicleID,
            vehicle = loadedVehicle,  -- May be nil if not loaded
            name = vehicleName,
            x = x,
            y = y,
            isLoaded = loadedVehicle ~= nil
        })
    end
end

--- Try to find a loaded vehicle by ID
function ISVehicleClaimListPanel:findLoadedVehicle(vehicleID)
    if not vehicleID then return nil end
    
    local cell = getCell()
    if not cell then return nil end
    
    local vehicles = cell:getVehicles()
    if not vehicles then return nil end
    
    for i = 0, vehicles:size() - 1 do
        local vehicle = vehicles:get(i)
        if vehicle and vehicle:getId() == vehicleID then
            return vehicle
        end
    end
    
    return nil
end

-----------------------------------------------------------
-- Rendering
-----------------------------------------------------------

function ISVehicleClaimListPanel:prerender()
    ISPanel.prerender(self)
    
    -- Draw header background
    self:drawRect(0, 0, self.width, 28, 0.4, 0.2, 0.2, 0.2)
    
    -- Draw title bar
    self:drawTextCentre(self.title, self.width / 2, 5, 1, 1, 1, 1, UIFont.Medium)
end

function ISVehicleClaimListPanel:render()
    ISPanel.render(self)
end

--- Custom draw function for vehicle list items
function ISVehicleClaimListPanel.drawVehicleListItem(self, y, item, alt)
    local r, g, b = 0.9, 0.9, 0.9
    
    if item.item.vehicleID == nil then
        -- "No vehicles" placeholder
        r, g, b = 0.5, 0.5, 0.5
    elseif not item.item.isLoaded then
        -- Unloaded vehicle - show in yellow
        r, g, b = 0.9, 0.8, 0.4
    end
    
    if self.selected == item.index then
        self:drawRect(0, y, self:getWidth(), self.itemheight, 0.3, 0.3, 0.5, 0.7)
    elseif self.mouseoverselected == item.index then
        self:drawRect(0, y, self:getWidth(), self.itemheight, 0.2, 0.3, 0.3, 0.5)
    end
    
    self:drawText(item.text, 10, y + 8, r, g, b, 1, UIFont.Small)
    
    return y + self.itemheight
end

-----------------------------------------------------------
-- Button Handlers
-----------------------------------------------------------

function ISVehicleClaimListPanel:onManageVehicle()
    local selected = self.vehicleList.selected
    if not selected or selected < 1 then return end
    
    local item = self.vehicleList.items[selected]
    if not item or not item.item or not item.item.vehicleID then
        return
    end
    
    local vehicleID = item.item.vehicleID
    local vehicle = item.item.vehicle  -- May be nil if not loaded
    
    -- If vehicle is not loaded, check again (might have loaded since list was generated)
    if not vehicle then
        vehicle = self:findLoadedVehicle(vehicleID)
    end
    
    -- If still not loaded, show message that player needs to go closer
    if not vehicle then
        self.player:Say(getText("UI_VehicleClaim_VehicleNotLoaded"))
        return
    end
    
    -- Check if vehicle still exists and is valid
    if not vehicle:getSquare() then
        self.player:Say(getText("UI_VehicleClaim_VehicleNotFound"))
        self:refreshData()
        return
    end
    
    -- Open management panel for this vehicle
    local panel = ISVehicleClaimPanel:new(
        self.x + 50,
        self.y + 50,
        400,
        440,
        self.player,
        vehicle
    )
    panel:initialise()
    panel:addToUIManager()
    panel:setVisible(true)
end

function ISVehicleClaimListPanel:onRefresh()
    self:refreshData()
end

function ISVehicleClaimListPanel:onClose()
    -- Unregister from refresh events
    if VehicleClaimClientCommands then
        VehicleClaimClientCommands.unregisterPanel(self)
    end
    
    self:setVisible(false)
    self:removeFromUIManager()
end

-----------------------------------------------------------
-- Update Loop
-----------------------------------------------------------

function ISVehicleClaimListPanel:update()
    ISPanel.update(self)
    
    -- Auto-refresh every 5 seconds using timestamp-based throttling
    local currentTime = getTimestampMs()
    
    if not self.lastUpdateTime then
        self.lastUpdateTime = currentTime
        return
    end
    
    local elapsedTime = currentTime - self.lastUpdateTime
    
    -- Refresh every 5000ms (5 seconds)
    if elapsedTime >= 5000 then
        self.lastUpdateTime = currentTime
        self:refreshData()
    end
end

-----------------------------------------------------------
-- Input Handling
-----------------------------------------------------------

function ISVehicleClaimListPanel:onMouseDown(x, y)
    self:bringToTop()
    return ISPanel.onMouseDown(self, x, y)
end

function ISVehicleClaimListPanel:onKeyPress(key)
    if key == Keyboard.KEY_ESCAPE then
        self:onClose()
        return true
    end
    return false
end

return ISVehicleClaimListPanel
