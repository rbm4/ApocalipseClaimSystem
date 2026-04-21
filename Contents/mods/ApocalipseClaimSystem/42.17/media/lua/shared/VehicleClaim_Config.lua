VehicleClaim = VehicleClaim or {}

-- Storage Configuration (File-based data export)
VehicleClaim.Sync = {
    -- Filename for car database (written to {Zomboid}/Lua/{filename})
    -- Your external backend should read this file periodically to sync data
    filename = "VehicleClaimSystemDatabase.json",
}