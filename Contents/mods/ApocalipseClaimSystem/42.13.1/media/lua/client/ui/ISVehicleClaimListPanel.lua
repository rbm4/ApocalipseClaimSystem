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
    self.refreshButton = ISButton:new(padding * 2 + btnWidth, y, btnWidth, btnHeight, getText("UI_VehicleClaim_Refresh"), self, ISVehicleClaimListPanel.onRefresh)
    self.refreshButton:initialise()
    self.refreshButton:instantiate()
    self:addChild(self.refreshButton)
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
    
    -- Force refresh on panel open by clearing cache
    self.lastCacheTime = nil
    
    -- Load initial data from server
    self:refreshData()
end

-----------------------------------------------------------
-- Data Loading
-----------------------------------------------------------

function ISVehicleClaimListPanel:refreshData()
    local currentTime = getTimestampMs()
    local cacheExpireTime = 30000 -- 1 minute in milliseconds
    
    -- Check if we have cached data and it's still fresh
    if self.lastCacheTime and (currentTime - self.lastCacheTime) < cacheExpireTime then
        local cachedClaims = self.cachedClaimsData
        if cachedClaims then
            self:onClaimsReceived({
                claims = cachedClaims,
                currentCount = self.cachedClaimCount,
                maxClaims = self.cachedMaxCount
            })
            return
        end
    end
    
    -- Cache expired or doesn't exist, request from server
    if VehicleClaimClientCommands then
        VehicleClaimClientCommands.requestMyClaims(function(args)
            -- Update cache with timestamp
            self.lastCacheTime = getTimestampMs()
            self.cachedClaimsData = args.claims
            self.cachedClaimCount = args.currentCount
            self.cachedMaxCount = args.maxClaims
            
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
        self.vehicleList:addItem(getText("UI_VehicleClaim_NoVehiclesClaimed"), {vehicleHash = nil})
        return
    end
    
    -- Add vehicles to list (from server data only)
    for _, claimData in ipairs(self.claimedVehiclesData) do
        local vehicleHash = claimData.vehicleHash
        local x = claimData.x or 0
        local y = claimData.y or 0
        
        -- Show vehicle hash and last known position
        local displayText = string.format("Vehicle %s - (%d, %d)", vehicleHash, math.floor(x), math.floor(y))
        
        self.vehicleList:addItem(displayText, {
            vehicleHash = vehicleHash,
            x = x,
            y = y,
            claimData = claimData
        })
    end
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
    
    if item.item.vehicleHash == nil then
        -- "No vehicles" placeholder
        r, g, b = 0.5, 0.5, 0.5
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
    if not item or not item.item or not item.item.vehicleHash then
        return
    end
    
    local vehicleHash = item.item.vehicleHash
    local claimData = item.item.claimData
    
    -- Try to find the vehicle in the world to check proximity
    local vehicle = nil
    local vehicles = getCell():getVehicles()
    if vehicles then
        for i = 0, vehicles:size() - 1 do
            local v = vehicles:get(i)
            if v and VehicleClaim.getVehicleHash(v) == vehicleHash then
                vehicle = v
                break
            end
        end
    end
    
    -- Open management panel with vehicle reference if found
    local panel = ISVehicleClaimPanel:new(
        self.x + 50,
        self.y + 50,
        400,
        440,
        self.player,
        vehicle,  -- Will be nil if vehicle is not loaded
        vehicleHash,
        claimData
    )
    panel:initialise()
    panel:addToUIManager()
    panel:setVisible(true)
end

function ISVehicleClaimListPanel:onRefresh()
    if VehicleClaimClientCommands then
        VehicleClaimClientCommands.requestMyClaims(function(args)
            -- Update cache with timestamp
            self.lastCacheTime = getTimestampMs()
            self.cachedClaimsData = args.claims
            self.cachedClaimCount = args.currentCount
            self.cachedMaxCount = args.maxClaims
            
            self:onClaimsReceived(args)
        end)
    end
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

-- function ISVehicleClaimListPanel:update()
--     ISPanel.update(self)
    
--     -- Auto-refresh every 5 seconds using timestamp-based throttling
--     local currentTime = getTimestampMs()
    
--     if not self.lastUpdateTime then
--         self.lastUpdateTime = currentTime
--         return
--     end
    
--     local elapsedTime = currentTime - self.lastUpdateTime
    
--     -- Refresh every 5000ms (5 seconds)
--     if elapsedTime >= 5000 then
--         self.lastUpdateTime = currentTime
--         self:refreshData()
--     end
-- end

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
