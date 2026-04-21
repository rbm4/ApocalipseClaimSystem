--[[
    ISVehicleClaimStatusPanel.lua
    Standalone window showing vehicle claim status and actions
    Opened from the right-click context menu on a vehicle
]]

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "shared/VehicleClaim_Shared"
require "client/ui/ISVehicleClaimPanel"

ISVehicleClaimStatusPanel = ISPanel:derive("ISVehicleClaimStatusPanel")

function ISVehicleClaimStatusPanel:new(x, y, width, height, vehicle, player)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    o.vehicle = vehicle
    o.player = player
    o.vehicleHash = VehicleClaim.getVehicleHash(vehicle)
    o.backgroundColor = {r=0.1, g=0.1, b=0.1, a=0.9}
    o.borderColor = {r=0.4, g=0.4, b=0.4, a=1}
    o.moveWithMouse = true
    o.title = getText("UI_VehicleClaim_MechanicsTitle")

    return o
end

function ISVehicleClaimStatusPanel:initialise()
    ISPanel.initialise(self)

    self:setupEventListeners()

    local padding = 10
    local yOffset = 30
    local buttonHeight = 25

    -- Title
    self.titleLabel = ISLabel:new(padding, yOffset, 20, self.title, 1, 1, 1, 1, UIFont.Medium, true)
    self.titleLabel:initialise()
    self:addChild(self.titleLabel)
    yOffset = yOffset + 25

    -- Vehicle ID
    local vehicleHash = VehicleClaim.getVehicleHash(self.vehicle)
    local idText = vehicleHash and getText("UI_VehicleClaim_VehicleIDLabel", vehicleHash) or getText("UI_VehicleClaim_VehicleIDLoading")
    self.vehicleIDLabel = ISLabel:new(padding, yOffset, 20, idText, 0.5, 0.5, 0.5, 1, UIFont.Small, true)
    self.vehicleIDLabel:initialise()
    self:addChild(self.vehicleIDLabel)
    yOffset = yOffset + 20

    -- Separator
    yOffset = yOffset + 5

    -- Status label
    self.statusLabel = ISLabel:new(padding, yOffset, 20, "", 1, 1, 1, 1, UIFont.Small, true)
    self.statusLabel:initialise()
    self:addChild(self.statusLabel)
    yOffset = yOffset + 20

    -- Owner label
    self.ownerLabel = ISLabel:new(padding, yOffset, 20, "", 0.7, 0.7, 0.7, 1, UIFont.Small, true)
    self.ownerLabel:initialise()
    self:addChild(self.ownerLabel)
    yOffset = yOffset + 20

    -- Last seen label
    self.lastSeenLabel = ISLabel:new(padding, yOffset, 20, "", 0.7, 0.7, 0.7, 1, UIFont.Small, true)
    self.lastSeenLabel:initialise()
    self:addChild(self.lastSeenLabel)
    yOffset = yOffset + 25

    -- Action button (Claim / Release / Contest)
    self.actionButton = ISButton:new(padding, yOffset, self.width - (padding * 2), buttonHeight, "", self, ISVehicleClaimStatusPanel.onActionButton)
    self.actionButton:initialise()
    self.actionButton.borderColor = {r=1, g=1, b=1, a=0.3}
    self:addChild(self.actionButton)
    yOffset = yOffset + buttonHeight + 5

    -- Manage button (only shown for owner/admin)
    self.manageButton = ISButton:new(padding, yOffset, self.width - (padding * 2), buttonHeight, getText("UI_VehicleClaim_ManageAccess"), self, ISVehicleClaimStatusPanel.onManageButton)
    self.manageButton:initialise()
    self.manageButton.borderColor = {r=1, g=1, b=1, a=0.3}
    self:addChild(self.manageButton)
    yOffset = yOffset + buttonHeight + 10

    -- Close button
    self.closeButton = ISButton:new(padding, yOffset, self.width - (padding * 2), buttonHeight, getText("UI_VehicleClaim_Close"), self, ISVehicleClaimStatusPanel.onClose)
    self.closeButton:initialise()
    self:addChild(self.closeButton)

    -- Load initial data from vehicle ModData
    self:updateInfo()

    -- Request hash generation from server if vehicle doesn't have one
    self:requestVehicleHashIfNeeded()
end

-----------------------------------------------------------
-- Hash Generation Request
-----------------------------------------------------------

function ISVehicleClaimStatusPanel:requestVehicleHashIfNeeded()
    if not self.vehicle then return end

    local vehicleHash = VehicleClaim.getVehicleHash(self.vehicle)
    if vehicleHash then return end

    -- Vehicle has no hash - request the server to generate one
    VehicleClaim.log("Vehicle has no hash, requesting generation from server")
    sendClientCommand(self.player, VehicleClaim.COMMAND_MODULE, VehicleClaim.CMD_REQUEST_HASH, {
        vehicleX = self.vehicle:getX(),
        vehicleY = self.vehicle:getY(),
        vehicleZ = self.vehicle:getZ()
    })
end

-----------------------------------------------------------
-- Event Listeners
-----------------------------------------------------------

function ISVehicleClaimStatusPanel:setupEventListeners()
    self.onClaimChangedHandler = function(vehicleHash, claimData)
        if self.vehicleHash and self.vehicleHash == vehicleHash then
            self:updateInfo(claimData)
        end
    end

    self.onClaimReleasedHandler = function(vehicleHash, claimData)
        if self.vehicleHash and self.vehicleHash == vehicleHash then
            self:resetToUnclaimedState()
        end
    end

    self.onAccessChangedHandler = function(vehicleHash, claimData)
        if self.vehicleHash and self.vehicleHash == vehicleHash then
            self:updateInfo(claimData)
        end
    end

    self.onVehicleInfoReceivedHandler = function(vehicleHash, claimData)
        if self.vehicleHash and self.vehicleHash == vehicleHash then
            self:updateInfo(claimData)
        end
    end

    self.onVehicleHashGeneratedHandler = function(vehicleHash, vehicle)
        if self.vehicle == vehicle or (not self.vehicleHash and self.vehicle and
            math.abs(self.vehicle:getX() - vehicle:getX()) < 1 and
            math.abs(self.vehicle:getY() - vehicle:getY()) < 1) then
            self.vehicleHash = vehicleHash
            if self.vehicleIDLabel then
                self.vehicleIDLabel:setName(getText("UI_VehicleClaim_VehicleIDLabel", vehicleHash))
            end
            self:updateInfo()
        end
    end

    Events.OnVehicleClaimChanged.Add(self.onClaimChangedHandler)
    Events.OnVehicleClaimReleased.Add(self.onClaimReleasedHandler)
    Events.OnVehicleClaimAccessChanged.Add(self.onAccessChangedHandler)
    Events.OnVehicleInfoReceived.Add(self.onVehicleInfoReceivedHandler)
    Events.OnVehicleHashGenerated.Add(self.onVehicleHashGeneratedHandler)
end

function ISVehicleClaimStatusPanel:removeEventListeners()
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
    if self.onVehicleHashGeneratedHandler then
        Events.OnVehicleHashGenerated.Remove(self.onVehicleHashGeneratedHandler)
    end
end

-----------------------------------------------------------
-- State Updates
-----------------------------------------------------------

function ISVehicleClaimStatusPanel:resetToUnclaimedState()
    self.statusLabel:setName(getText("UI_VehicleClaim_StatusUnclaimed"))
    self.statusLabel:setColor(0.5, 1, 0.5)
    self.ownerLabel:setName("")
    self.lastSeenLabel:setName(getText("UI_VehicleClaim_AvailableToClaim"))

    self.actionButton:setTitle(getText("UI_VehicleClaim_ClaimButton"))
    self.actionButton:setVisible(true)
    self.actionButton.backgroundColor = {r=0.2, g=0.6, b=0.2, a=1}

    self.manageButton:setVisible(false)
end

function ISVehicleClaimStatusPanel:updateInfo(claimData)
    if not self.vehicle then
        if self.statusLabel then self.statusLabel:setVisible(false) end
        if self.ownerLabel then self.ownerLabel:setVisible(false) end
        if self.lastSeenLabel then self.lastSeenLabel:setVisible(false) end
        if self.actionButton then self.actionButton:setVisible(false) end
        if self.manageButton then self.manageButton:setVisible(false) end
        return
    end

    if not claimData then
        claimData = VehicleClaim.getClaimData(self.vehicle)
    end

    self.statusLabel:setVisible(true)
    self.ownerLabel:setVisible(true)
    self.lastSeenLabel:setVisible(true)

    local steamID = VehicleClaim.getPlayerSteamID(self.player)
    local isClaimed = claimData ~= nil
    local ownerID = claimData and claimData[VehicleClaim.OWNER_KEY]
    local ownerName = claimData and claimData[VehicleClaim.OWNER_NAME_KEY]
    local isOwner = (ownerID == steamID)
    local hasAccess = false
    if claimData then
        local allowedPlayers = claimData[VehicleClaim.ALLOWED_PLAYERS_KEY] or {}
        hasAccess = allowedPlayers[steamID] ~= nil
    end
    local isAdmin = self.player:getAccessLevel() == "admin" or self.player:getAccessLevel() == "moderator"

    if not isClaimed then
        self.statusLabel:setName(getText("UI_VehicleClaim_StatusUnclaimed"))
        self.statusLabel:setColor(0.5, 1, 0.5)
        self.ownerLabel:setName("")
        self.lastSeenLabel:setName(getText("UI_VehicleClaim_AvailableToClaim"))

        self.actionButton:setTitle(getText("UI_VehicleClaim_ClaimButton"))
        self.actionButton:setVisible(true)
        self.actionButton.backgroundColor = {r=0.2, g=0.6, b=0.2, a=1}

        self.manageButton:setVisible(false)
    else
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
                local realWorldMinutes = timeSince / 16
                local realWorldHours = math.floor(realWorldMinutes / 60)
                local realWorldDays = math.floor(realWorldHours / 24)

                if realWorldDays > 0 then
                    self.lastSeenLabel:setName(getText("UI_VehicleClaim_LastSeenDays", realWorldDays))
                elseif realWorldHours > 0 then
                    self.lastSeenLabel:setName(getText("UI_VehicleClaim_LastSeenHours", realWorldHours))
                else
                    self.lastSeenLabel:setName(getText("UI_VehicleClaim_LastSeenRecently"))
                end
            end
        end

        -- Action button
        if isOwner or isAdmin then
            self.actionButton:setTitle(getText("UI_VehicleClaim_ReleaseButton"))
            self.actionButton:setVisible(true)
            self.actionButton.backgroundColor = {r=0.8, g=0.3, b=0.3, a=1}
        else
            local isAbandoned, daysSinceLastSeen = VehicleClaim.isVehicleAbandoned(self.vehicle)
            local threshold = VehicleClaim.getAbandonedDaysThreshold()

            if threshold == 0 or isAbandoned then
                self.actionButton:setTitle(getText("UI_VehicleClaim_ContestClaim"))
                self.actionButton:setVisible(true)
                self.actionButton.backgroundColor = {r=0.8, g=0.6, b=0.2, a=1}
            else
                self.actionButton:setVisible(false)
            end
        end

        -- Manage button
        if isOwner or isAdmin then
            self.manageButton:setVisible(true)
        else
            self.manageButton:setVisible(false)
        end
    end

    -- Update vehicle ID label in case hash arrived
    local vehicleHash = VehicleClaim.getVehicleHash(self.vehicle)
    if vehicleHash and self.vehicleIDLabel then
        self.vehicleIDLabel:setName(getText("UI_VehicleClaim_VehicleIDLabel", vehicleHash))
    end
end

-----------------------------------------------------------
-- Button Handlers
-----------------------------------------------------------

function ISVehicleClaimStatusPanel:onActionButton()
    if not self.vehicle then return end

    local isClaimed = VehicleClaim.isClaimed(self.vehicle)
    local steamID = VehicleClaim.getPlayerSteamID(self.player)
    local claimData = VehicleClaim.getClaimData(self.vehicle)
    local isOwner = claimData and (claimData[VehicleClaim.OWNER_KEY] == steamID)
    local isAdmin = self.player:getAccessLevel() == "admin" or self.player:getAccessLevel() == "moderator"

    if not isClaimed then
        if self.player:getVehicle() then
            ISVehicleMenu.onExit(self.player)
        end
        ISTimedActionQueue.add(ISPathFindAction:pathToVehicleAdjacent(self.player, self.vehicle))
        ISTimedActionQueue.add(ISClaimVehicleAction:new(self.player, self.vehicle, VehicleClaim.CLAIM_TIME_TICKS))
    elseif isOwner or isAdmin then
        -- Remote release via modal confirmation (no timed action)
        local modal = ISModalDialog:new(self:getX() + 50, self:getY() + 100, 380, 140,
            getText("UI_VehicleClaim_ReleaseRemoteConfirm"),
            true, self, ISVehicleClaimStatusPanel.onReleaseRemoteConfirm)
        modal:initialise()
        modal:addToUIManager()
    else
        if self.player:getVehicle() then
            ISVehicleMenu.onExit(self.player)
        end
        ISTimedActionQueue.add(ISPathFindAction:pathToVehicleAdjacent(self.player, self.vehicle))
        ISTimedActionQueue.add(ISContestVehicleClaimAction:new(self.player, self.vehicle, VehicleClaim.CLAIM_TIME_TICKS))
    end
end

function ISVehicleClaimStatusPanel:onReleaseRemoteConfirm(button)
    if button.internal == "YES" then
        local vehicleHash = VehicleClaim.getVehicleHash(self.vehicle)
        if not vehicleHash then return end

        local args = {
            vehicleHash = vehicleHash,
            steamID = VehicleClaim.getPlayerSteamID(self.player)
        }
        sendClientCommand(self.player, VehicleClaim.COMMAND_MODULE, VehicleClaim.CMD_RELEASE_REMOTE, args)

        self.player:Say(getText("UI_VehicleClaim_RemoteReleaseInitiated"))
    end
end

function ISVehicleClaimStatusPanel:onManageButton()
    if not self.vehicle then return end

    local claimData = VehicleClaim.getClaimData(self.vehicle)
    local vehicleHash = VehicleClaim.getVehicleHash(self.vehicle)

    local panel = ISVehicleClaimPanel:new(self:getX() + 30, self:getY() + 30, 400, 500, self.player, self.vehicle, vehicleHash, claimData)
    panel:initialise()
    panel:addToUIManager()
end

-----------------------------------------------------------
-- Rendering
-----------------------------------------------------------

function ISVehicleClaimStatusPanel:prerender()
    ISPanel.prerender(self)

    -- Draw header background
    self:drawRect(0, 0, self.width, 28, 0.4, 0.2, 0.2, 0.2)
    self:drawTextCentre(self.title, self.width / 2, 5, 1, 1, 1, 1, UIFont.Medium)
end

function ISVehicleClaimStatusPanel:render()
    ISPanel.render(self)
end

-----------------------------------------------------------
-- Close / Cleanup
-----------------------------------------------------------

function ISVehicleClaimStatusPanel:onClose()
    self:removeEventListeners()
    self:setVisible(false)
    self:removeFromUIManager()
end

function ISVehicleClaimStatusPanel:close()
    self:removeEventListeners()
    ISPanel.close(self)
end

-----------------------------------------------------------
-- Input Handling
-----------------------------------------------------------

function ISVehicleClaimStatusPanel:onMouseDown(x, y)
    self:bringToTop()
    return ISPanel.onMouseDown(self, x, y)
end

function ISVehicleClaimStatusPanel:onKeyPress(key)
    if key == Keyboard.KEY_ESCAPE then
        self:onClose()
        return true
    end
    return false
end

return ISVehicleClaimStatusPanel
