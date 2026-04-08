--[[
    VehicleClaim_MechanicsUI.lua
    Hooks into the vehicle mechanics UI to generate the vehicle hash
    when a player opens the mechanics panel (V key).
    No UI is embedded — claim info is accessed via the context menu.
]]

require "shared/VehicleClaim_Shared"

-----------------------------------------------------------
-- Hook into ISVehicleMechanics for vehicle hash generation
-----------------------------------------------------------

local function integrateWithMechanicsUI()
    if not ISVehicleMechanics then
        print("[VehicleClaim] ISVehicleMechanics not available yet, will retry...")
        return false
    end

    print("[VehicleClaim] Hooking into ISVehicleMechanics (hash generation only)...")

    local original_createChildren = ISVehicleMechanics.createChildren

    ISVehicleMechanics.createChildren = function(self)
        original_createChildren(self)

        -- Generate hash for the vehicle when mechanics UI opens
        if self.vehicle then
            local vehicleHash = VehicleClaim.getVehicleHash(self.vehicle)
            if not vehicleHash then
                vehicleHash = VehicleClaim.getOrCreateVehicleHash(self.vehicle)
                if vehicleHash then
                    print("[VehicleClaim] Generated hash for vehicle via mechanics UI: " .. vehicleHash)
                    triggerEvent("OnVehicleHashGenerated", vehicleHash, self.vehicle)
                end
            end
        end
    end

    print("[VehicleClaim] Successfully hooked ISVehicleMechanics for hash generation")
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
