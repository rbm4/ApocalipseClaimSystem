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

-----------------------------------------------------------
-- Event Registration
-----------------------------------------------------------

Events.OnFillWorldObjectContextMenu.Add(VehicleClaimPlayerMenu.onFillWorldMenu)

return VehicleClaimPlayerMenu
