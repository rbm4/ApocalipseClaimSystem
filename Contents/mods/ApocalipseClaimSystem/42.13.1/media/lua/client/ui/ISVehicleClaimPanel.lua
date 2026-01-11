--[[
    ISVehicleClaimPanel.lua
    ISUI-based management panel for vehicle claims
    Allows owner/admin to manage access and release claims
]]

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"
require "ISUI/ISScrollingListBox"
require "shared/VehicleClaim_Shared"

ISVehicleClaimPanel = ISPanel:derive("ISVehicleClaimPanel")

-----------------------------------------------------------
-- Constructor
-----------------------------------------------------------

function ISVehicleClaimPanel:new(x, y, width, height, player, vehicle)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.player = player
    o.vehicle = vehicle
    o.vehicleID = vehicle:getId()
    
    o.backgroundColor = {r = 0.1, g = 0.1, b = 0.1, a = 0.9}
    o.borderColor = {r = 0.4, g = 0.4, b = 0.4, a = 1}
    
    o.title = "Manuseio do meu veiculo"
    o.moveWithMouse = true
    o.anchorLeft = true
    o.anchorRight = false
    o.anchorTop = true
    o.anchorBottom = false
    
    -- Data cache
    o.ownerName = ""
    o.ownerSteamID = ""
    o.allowedPlayers = {}
    o.claimTime = 0
    o.lastSeen = 0
    
    return o
end

-----------------------------------------------------------
-- Initialization
-----------------------------------------------------------

function ISVehicleClaimPanel:initialise()
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
    
    -- Vehicle name
    local vehicleName = VehicleClaim.getVehicleName(self.vehicle)
    self.vehicleLabel = ISLabel:new(padding, y, labelHeight, "Vehicle: " .. vehicleName, 0.9, 0.9, 0.9, 1, UIFont.Small, true)
    self.vehicleLabel:initialise()
    self:addChild(self.vehicleLabel)
    y = y + labelHeight + 5
    
    -- Owner info
    self.ownerLabel = ISLabel:new(padding, y, labelHeight, "Owner: Loading...", 0.7, 0.9, 0.7, 1, UIFont.Small, true)
    self.ownerLabel:initialise()
    self:addChild(self.ownerLabel)
    y = y + labelHeight + 5
    
    -- Claim time
    self.claimTimeLabel = ISLabel:new(padding, y, labelHeight, "Claimed: -", 0.7, 0.7, 0.7, 1, UIFont.Small, true)
    self.claimTimeLabel:initialise()
    self:addChild(self.claimTimeLabel)
    y = y + labelHeight + 5
    
    -- Last seen
    self.lastSeenLabel = ISLabel:new(padding, y, labelHeight, "Last seen: -", 0.7, 0.7, 0.7, 1, UIFont.Small, true)
    self.lastSeenLabel:initialise()
    self:addChild(self.lastSeenLabel)
    y = y + labelHeight + padding
    
    -- Separator
    y = y + 5
    
    -- Allowed players section
    self.allowedLabel = ISLabel:new(padding, y, labelHeight, "Allowed Players:", 1, 1, 1, 1, UIFont.Small, true)
    self.allowedLabel:initialise()
    self:addChild(self.allowedLabel)
    y = y + labelHeight + 5
    
    -- Scrolling list for allowed players
    local listHeight = 80
    self.playerList = ISScrollingListBox:new(padding, y, self.width - (padding * 2), listHeight)
    self.playerList:initialise()
    self.playerList:instantiate()
    self.playerList.backgroundColor = {r = 0.15, g = 0.15, b = 0.15, a = 1}
    self.playerList.borderColor = {r = 0.3, g = 0.3, b = 0.3, a = 1}
    self.playerList.itemheight = 22
    self.playerList.doDrawItem = self.drawPlayerListItem
    self.playerList.drawBorder = true
    self:addChild(self.playerList)
    y = y + listHeight + padding
    
    -- Add player section
    self.addPlayerLabel = ISLabel:new(padding, y, labelHeight, "Add Player:", 0.8, 0.8, 0.8, 1, UIFont.Small, true)
    self.addPlayerLabel:initialise()
    self:addChild(self.addPlayerLabel)
    y = y + labelHeight + 5
    
    -- Text entry for player name
    local entryWidth = self.width - (padding * 3) - 80
    self.playerNameEntry = ISTextEntryBox:new("", padding, y, entryWidth, btnHeight)
    self.playerNameEntry:initialise()
    self.playerNameEntry:instantiate()
    self.playerNameEntry:setTooltip("Enter player username")
    self:addChild(self.playerNameEntry)
    
    -- Add button
    self.addButton = ISButton:new(padding + entryWidth + 5, y, 70, btnHeight, "Add", self, ISVehicleClaimPanel.onAddPlayer)
    self.addButton:initialise()
    self.addButton:instantiate()
    self.addButton.borderColor = {r = 0.3, g = 0.5, b = 0.3, a = 1}
    self:addChild(self.addButton)
    y = y + btnHeight + padding
    
    -- Remove selected player button
    self.removeButton = ISButton:new(padding, y, 120, btnHeight, "Remove Selected", self, ISVehicleClaimPanel.onRemovePlayer)
    self.removeButton:initialise()
    self.removeButton:instantiate()
    self.removeButton.borderColor = {r = 0.5, g = 0.3, b = 0.3, a = 1}
    self:addChild(self.removeButton)
    y = y + btnHeight + padding + 10
    
    -- Bottom buttons
    local btnWidth = (self.width - (padding * 3)) / 2
    
    -- Release claim button
    self.releaseButton = ISButton:new(padding, y, btnWidth, btnHeight, "Release Claim", self, ISVehicleClaimPanel.onReleaseClaim)
    self.releaseButton:initialise()
    self.releaseButton:instantiate()
    self.releaseButton.borderColor = {r = 0.7, g = 0.3, b = 0.3, a = 1}
    self.releaseButton.backgroundColor = {r = 0.3, g = 0.1, b = 0.1, a = 0.8}
    self:addChild(self.releaseButton)
    
    -- Close button
    self.closeButton = ISButton:new(padding * 2 + btnWidth, y, btnWidth, btnHeight, "Close", self, ISVehicleClaimPanel.onClose)
    self.closeButton:initialise()
    self.closeButton:instantiate()
    self:addChild(self.closeButton)
    
    -- Register for refresh events
    if VehicleClaimClientCommands then
        VehicleClaimClientCommands.registerPanel(self)
    end
    
    -- Load initial data
    self:refreshData()
end

-----------------------------------------------------------
-- Data Loading
-----------------------------------------------------------

function ISVehicleClaimPanel:refreshData()
    -- Get data directly from vehicle modData (synced by server)
    local claimData = VehicleClaim.getClaimData(self.vehicle)
    
    if claimData then
        self.ownerName = claimData[VehicleClaim.OWNER_NAME_KEY] or "Unknown"
        self.ownerSteamID = claimData[VehicleClaim.OWNER_KEY] or ""
        self.allowedPlayers = claimData[VehicleClaim.ALLOWED_PLAYERS_KEY] or {}
        self.claimTime = claimData[VehicleClaim.CLAIM_TIME_KEY] or 0
        self.lastSeen = claimData[VehicleClaim.LAST_SEEN_KEY] or 0
    else
        self.ownerName = "Unclaimed"
        self.ownerSteamID = ""
        self.allowedPlayers = {}
        self.claimTime = 0
        self.lastSeen = 0
    end
    
    -- Update labels
    self.ownerLabel:setName("Owner: " .. self.ownerName)
    self.claimTimeLabel:setName("Claimed: " .. VehicleClaim.formatTimestamp(self.claimTime))
    self.lastSeenLabel:setName("Last seen: " .. VehicleClaim.formatTimestamp(self.lastSeen))
    
    -- Update player list
    self.playerList:clear()
    for steamID, playerName in pairs(self.allowedPlayers) do
        self.playerList:addItem(playerName, {steamID = steamID, name = playerName})
    end
    
    if self.playerList:size() == 0 then
        self.playerList:addItem("(No players added)", {steamID = nil, name = nil})
    end
end

-----------------------------------------------------------
-- Rendering
-----------------------------------------------------------

function ISVehicleClaimPanel:prerender()
    ISPanel.prerender(self)
    
    -- Draw header background
    self:drawRect(0, 0, self.width, 28, 0.4, 0.2, 0.2, 0.2)
    
    -- Draw title bar
    self:drawTextCentre(self.title, self.width / 2, 5, 1, 1, 1, 1, UIFont.Medium)
end

function ISVehicleClaimPanel:render()
    ISPanel.render(self)
    
    -- Draw separator lines
    local separatorY = 120
    self:drawRect(10, separatorY, self.width - 20, 1, 0.5, 0.3, 0.3, 0.3)
end

--- Custom draw function for player list items
function ISVehicleClaimPanel.drawPlayerListItem(self, y, item, alt)
    local r, g, b = 0.8, 0.8, 0.8
    
    if item.item.steamID == nil then
        -- "No players" placeholder
        r, g, b = 0.5, 0.5, 0.5
    end
    
    if self.selected == item.index then
        self:drawRect(0, y, self:getWidth(), self.itemheight, 0.3, 0.3, 0.5, 0.7)
    elseif self.mouseoverselected == item.index then
        self:drawRect(0, y, self:getWidth(), self.itemheight, 0.2, 0.3, 0.3, 0.5)
    end
    
    self:drawText(item.text, 10, y + 3, r, g, b, 1, UIFont.Small)
    
    return y + self.itemheight
end

-----------------------------------------------------------
-- Button Handlers
-----------------------------------------------------------

function ISVehicleClaimPanel:onAddPlayer()
    local playerName = self.playerNameEntry:getText()
    
    if not playerName or playerName == "" then
        return
    end
    
    -- Trim whitespace
    playerName = string.match(playerName, "^%s*(.-)%s*$")
    
    if playerName == "" then
        return
    end
    
    -- Send request to server via client commands
    if VehicleClaimClientCommands then
        VehicleClaimClientCommands.addPlayer(self.vehicle, playerName)
    end
    
    -- Clear entry
    self.playerNameEntry:setText("")
end

function ISVehicleClaimPanel:onRemovePlayer()
    local selected = self.playerList.selected
    if not selected or selected < 1 then return end
    
    local item = self.playerList.items[selected]
    if not item or not item.item or not item.item.steamID then
        return
    end
    
    local targetSteamID = item.item.steamID
    
    -- Send request to server
    if VehicleClaimClientCommands then
        VehicleClaimClientCommands.removePlayer(self.vehicle, targetSteamID)
    end
end

function ISVehicleClaimPanel:onReleaseClaim()
    -- Confirm action
    local modal = ISModalDialog:new(
        self.x + 50, 
        self.y + 100, 
        280, 
        100, 
        "Release ownership of this vehicle?", 
        true, 
        self, 
        ISVehicleClaimPanel.onReleaseConfirm
    )
    modal:initialise()
    modal:addToUIManager()
end

function ISVehicleClaimPanel:onReleaseConfirm(button)
    if button.internal == "YES" then
        -- Queue release action
        local action = ISReleaseVehicleClaimAction:new(self.player, self.vehicle, VehicleClaim.CLAIM_TIME_TICKS / 2)
        ISTimedActionQueue.add(action)
        
        -- Close panel
        self:onClose()
    end
end

function ISVehicleClaimPanel:onClose()
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

function ISVehicleClaimPanel:update()
    ISPanel.update(self)
    
    -- Check if vehicle is still valid and in range
    if not self.vehicle or not self.vehicle:getSquare() then
        self:onClose()
        return
    end
    
    if not VehicleClaim.isWithinRange(self.player, self.vehicle) then
        self:onClose()
        return
    end
    
    -- Check if player still has management rights
    local steamID = VehicleClaim.getPlayerSteamID(self.player)
    local ownerID = VehicleClaim.getOwnerID(self.vehicle)
    local isAdmin = self.player:getAccessLevel() == "admin" or self.player:getAccessLevel() == "moderator"
    
    if ownerID ~= steamID and not isAdmin then
        self:onClose()
        return
    end
end

-----------------------------------------------------------
-- Input Handling
-----------------------------------------------------------

function ISVehicleClaimPanel:onMouseDown(x, y)
    -- Bring to front on click
    self:bringToTop()
    return ISPanel.onMouseDown(self, x, y)
end

function ISVehicleClaimPanel:onKeyPress(key)
    if key == Keyboard.KEY_ESCAPE then
        self:onClose()
        return true
    end
    return false
end

return ISVehicleClaimPanel
