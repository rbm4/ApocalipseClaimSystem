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
    
    o.title = "Meus Veiculos"
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
    local infoText = string.format("Veiculos: %d / %d", 0, maxClaims)
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
    self.manageButton = ISButton:new(padding, y, btnWidth, btnHeight, "Gerenciar", self, ISVehicleClaimListPanel.onManageVehicle)
    self.manageButton:initialise()
    self.manageButton:instantiate()
    self.manageButton.borderColor = {r = 0.3, g = 0.5, b = 0.3, a = 1}
    self:addChild(self.manageButton)
    
    -- Refresh button
    self.refreshButton = ISButton:new(padding * 2 + btnWidth, y, btnWidth, btnHeight, "Atualizar", self, ISVehicleClaimListPanel.onRefresh)
    self.refreshButton:initialise()
    self.refreshButton:instantiate()
    self:addChild(self.refreshButton)
    y = y + btnHeight + padding
    
    -- Close button
    self.closeButton = ISButton:new(padding, y, self.width - (padding * 2), btnHeight, "Fechar", self, ISVehicleClaimListPanel.onClose)
    self.closeButton:initialise()
    self.closeButton:instantiate()
    self:addChild(self.closeButton)
    
    -- Load initial data
    self:refreshData()
end

-----------------------------------------------------------
-- Data Loading
-----------------------------------------------------------

function ISVehicleClaimListPanel:refreshData()
    -- Find all vehicles claimed by this player
    self.claimedVehicles = {}
    
    local cell = getCell()
    if not cell then return end
    
    local vehicles = cell:getVehicles()
    if not vehicles then return end
    
    for i = 0, vehicles:size() - 1 do
        local vehicle = vehicles:get(i)
        if vehicle then
            local ownerID = VehicleClaim.getOwnerID(vehicle)
            if ownerID == self.steamID then
                table.insert(self.claimedVehicles, vehicle)
            end
        end
    end
    
    -- Update list
    self:updateVehicleList()
end

function ISVehicleClaimListPanel:updateVehicleList()
    self.vehicleList:clear()
    
    -- Update info label
    local maxClaims = VehicleClaim.getMaxClaimsPerPlayer()
    local currentClaims = #self.claimedVehicles
    local infoText = string.format("Veiculos: %d / %d", currentClaims, maxClaims)
    self.infoLabel:setName(infoText)
    
    if #self.claimedVehicles == 0 then
        self.vehicleList:addItem("(Nenhum veiculo reivindicado)", {vehicle = nil})
        return
    end
    
    -- Add vehicles to list
    for _, vehicle in ipairs(self.claimedVehicles) do
        local vehicleName = VehicleClaim.getVehicleName(vehicle)
        local vehicleID = vehicle:getId()
        local distance = VehicleClaim.getDistance(self.player, vehicle)
        
        local displayText = string.format("%s (ID: %d) - %.1fm", vehicleName, vehicleID, distance)
        
        self.vehicleList:addItem(displayText, {
            vehicle = vehicle,
            vehicleID = vehicleID,
            name = vehicleName,
            distance = distance
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
    
    if item.item.vehicle == nil then
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
    if not item or not item.item or not item.item.vehicle then
        return
    end
    
    local vehicle = item.item.vehicle
    
    -- Check if vehicle still exists and is valid
    if not vehicle:getSquare() then
        self.player:Say("Veiculo nao encontrado")
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
    self:setVisible(false)
    self:removeFromUIManager()
end

-----------------------------------------------------------
-- Update Loop
-----------------------------------------------------------

function ISVehicleClaimListPanel:update()
    ISPanel.update(self)
    
    -- Auto-refresh every few seconds
    if not self.lastUpdate then
        self.lastUpdate = 0
    end
    
    self.lastUpdate = self.lastUpdate + 1
    
    if self.lastUpdate >= 300 then -- Every ~5 seconds
        self.lastUpdate = 0
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
