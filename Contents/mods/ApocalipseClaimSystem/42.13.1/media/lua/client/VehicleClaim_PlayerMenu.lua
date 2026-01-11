--[[
    VehicleClaim_PlayerMenu.lua
    Adds "My Vehicles" option to player context menu
]]

require "client/ui/ISVehicleClaimListPanel"

local VehicleClaimPlayerMenu = {}

--- Add "My Vehicles" option to player self context menu
--- @param playerNum number
--- @param context ISContextMenu
--- @param playerObj IsoPlayer
function VehicleClaimPlayerMenu.onFillPlayerMenu(playerNum, context, playerObj)
    if not playerObj then return end
    
    -- Only show for the local player (not on other players)
    local player = getSpecificPlayer(playerNum)
    if player ~= playerObj then return end
    
    -- Add menu option
    local option = context:addOption("Meus Veiculos", playerObj, VehicleClaimPlayerMenu.onOpenVehicleList)
    
    -- Add tooltip
    local tooltip = ISWorldObjectContextMenu.addToolTip()
    tooltip:setName("Meus Veiculos")
    tooltip.description = "Ver e gerenciar todos os veiculos que voce reivindicou"
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

Events.OnFillWorldObjectContextMenu.Add(VehicleClaimPlayerMenu.onFillPlayerMenu)

return VehicleClaimPlayerMenu
