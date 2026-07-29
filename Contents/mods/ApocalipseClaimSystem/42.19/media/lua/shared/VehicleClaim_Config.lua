VehicleClaim = VehicleClaim or {}

-- Storage Configuration (File-based data export)
VehicleClaim.Sync = {
    -- Legacy filename used to derive the export directory.
    -- "VehicleClaimSystemDatabase.json" writes indexed files under:
    -- {Zomboid}/Lua/VehicleClaimSystemDatabase/index.txt
    -- Files contain JSON, but use .txt because B42 Lua getFileWriter
    -- only allows ini/cfg/txt/log extensions.
    filename = "VehicleClaimSystemDatabase.json",
}
