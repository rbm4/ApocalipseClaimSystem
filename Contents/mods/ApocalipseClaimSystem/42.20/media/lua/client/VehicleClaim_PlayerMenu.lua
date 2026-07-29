--[[
    VehicleClaim_PlayerMenu.lua
    Adds "My Vehicles" option to player context menu
]]

require "client/ui/ISVehicleClaimListPanel"

local VehicleClaimPlayerMenu = {}

--- Add "My Vehicles" option to any right-click context menu
--- @param playerNum number
--- @param context ISContextMenu
--- @param worldObjects table
--- @param test boolean
function VehicleClaimPlayerMenu.onFillWorldMenu(playerNum, context, worldObjects, test)
    if test then return end
    
    local player = getSpecificPlayer(playerNum)
    if not player then return end
    
    -- Add menu option (always visible on any right-click)
    local option = context:addOption(getText("UI_VehicleClaim_MyVehicles"), player, VehicleClaimPlayerMenu.onOpenVehicleList)
    
    -- Add tooltip
    local tooltip = ISWorldObjectContextMenu.addToolTip()
    tooltip:setName(getText("UI_VehicleClaim_MyVehicles"))
    tooltip.description = getText("UI_VehicleClaim_ViewManageVehicles")
    option.toolTip = tooltip
    
    -- Add admin option if player is admin
    local isAdmin = player:getAccessLevel() == "admin" or player:getAccessLevel() == "moderator"
    if isAdmin then
        local adminOption = context:addOption("[ADMIN] Clear All Vehicle Claims", player, VehicleClaimPlayerMenu.onAdminClearAll)
        
        local adminTooltip = ISWorldObjectContextMenu.addToolTip()
        adminTooltip:setName("[ADMIN] Clear All Vehicle Claims")
        adminTooltip.description = "Remove ALL vehicle claims from the server. This cannot be undone!"
        adminOption.toolTip = adminTooltip
    end
end

--- Open the vehicle list panel
--- @param playerObj IsoPlayer
function VehicleClaimPlayerMenu.onOpenVehicleList(playerObj)
    if not playerObj then return end
    
    -- Create and show panel
    local panel = ISVehicleClaimListPanel:new(
        100,
        100,
        500,
        480,
        playerObj
    )
    panel:initialise()
    panel:addToUIManager()
    panel:setVisible(true)
end

--- Show admin confirmation modal for clearing all claims
--- @param playerObj IsoPlayer
function VehicleClaimPlayerMenu.onAdminClearAll(playerObj)
    if not playerObj then return end
    
    -- Create confirmation modal
    local modal = ISModalDialog:new(
        getCore():getScreenWidth() / 2 - 250,
        getCore():getScreenHeight() / 2 - 100,
        500,
        200,
        "WARNING: Clear All Vehicle Claims",
        true,  -- yesNo = true for YES/NO buttons
        playerObj,  -- target object passed to onclick
        function(target, button)
            if button.internal == "YES" then
                VehicleClaimPlayerMenu.executeAdminClearAll(target)
            end
        end
    )
    modal:initialise()
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
    modal.text = "This will remove ALL vehicle claims from the server!\n\nThis action CANNOT be undone.\n\nAll players will lose ownership of their claimed vehicles.\n\nAre you sure you want to proceed?"
end

--- Execute the admin clear all command
--- @param playerObj IsoPlayer
function VehicleClaimPlayerMenu.executeAdminClearAll(playerObj)
    if not playerObj then return end
    
    print("[VehicleClaim Admin] Executing clear all claims command...")
    playerObj:Say("[ADMIN] Clearing all vehicle claims...")
    
    -- Send command to server
    sendClientCommand(playerObj, VehicleClaim.COMMAND_MODULE, VehicleClaim.CMD_ADMIN_CLEAR_ALL, {})
end

-----------------------------------------------------------
-- Event Registration
-----------------------------------------------------------

Events.OnFillWorldObjectContextMenu.Add(VehicleClaimPlayerMenu.onFillWorldMenu)

return VehicleClaimPlayerMenu
