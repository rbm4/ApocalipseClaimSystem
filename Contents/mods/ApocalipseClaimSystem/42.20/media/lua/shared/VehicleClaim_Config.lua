VehicleClaim = VehicleClaim or {}

-- Storage Configuration (File-based data export)
VehicleClaim.Sync = {
    -- Legacy filename used to derive the export directory.
    -- "VehicleClaimSystemDatabase.json" writes indexed files under:
    -- {Zomboid}/Lua/VehicleClaimSystemDatabase/index.json
    filename = "VehicleClaimSystemDatabase.json",
}
