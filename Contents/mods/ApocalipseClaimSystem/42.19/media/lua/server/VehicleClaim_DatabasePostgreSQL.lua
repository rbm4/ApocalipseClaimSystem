-- Scoped keyed mutations are projected into the V58 index and item tables.
-- Each save/delete is one atomic transaction with stable replay after a lost ACK.
local Export = require "server/VehicleClaim_DatabaseExport"
local Native = require "server/VehicleClaim_DatabaseNative"
local PostgreSQL = { name = "postgresql" }
local DOCUMENT = "VehicleClaim.Export.v1"

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function checkEntry(hash, entry)
    if type(hash) ~= "string" or #hash < 1 or #hash > 512 or type(entry) ~= "table"
        or entry.vehicleHash ~= hash or type(entry.ownerSteamID) ~= "string"
        or type(entry.ownerName) ~= "string" or type(entry.vehicleName) ~= "string"
        or type(entry.scriptName) ~= "string" or not finite(entry.x) or not finite(entry.y)
        or type(entry.lastUpdated) ~= "string" or type(entry.hasInventorySnapshot) ~= "boolean"
        or type(entry.items) ~= "table" then error("Invalid vehicle export " .. tostring(hash)) end
    local count = 0
    for key, item in pairs(entry.items) do
        count = count + 1
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0
            or type(item) ~= "table" or type(item.fullType) ~= "string"
            or type(item.container) ~= "string" or not finite(item.count) or item.count < 0 then
            error("Invalid vehicle inventory " .. hash)
        end
    end
    if count ~= #entry.items then error("Invalid inventory array " .. hash) end
end

function PostgreSQL.schemas(entities)
    local keys = {
        server_id = { type = "integer", id = true }, world = { type = "string", id = true },
        vehicle_hash = { type = "string", id = true }
    }
    local function fields(extra)
        local result = {}
        for name, value in pairs(keys) do result[name] = value end
        for name, value in pairs(extra) do result[name] = { type = value } end
        return result
    end
    return {
        entities.define("VehicleClaim.Export.Index.v1", {
            table = "vehicle_claim_export_index",
            fields = fields({ owner_steam_id = "text", owner_name = "text", vehicle_name = "text",
                script_name = "text", x = "number", y = "number", last_updated = "text" })
        }),
        entities.define("VehicleClaim.Export.Items.v1", {
            table = "vehicle_claim_export_items",
            fields = fields({ has_inventory_snapshot = "boolean", items_json = "text" })
        })
    }
end

function PostgreSQL.new(entities, log)
    local self = { name = PostgreSQL.name }
    local repository, revision = entities.document(DOCUMENT), "0"
    local saved, batch, starting = {}, nil, nil
    local retryAt = 0

    local function operation(collection, hash, value)
        return { collection = collection, key = hash, payload = entities.encode(value) }
    end

    local function indexValue(entry)
        return {
            vehicleHash = entry.vehicleHash, ownerSteamID = entry.ownerSteamID, ownerName = entry.ownerName,
            vehicleName = entry.vehicleName, scriptName = entry.scriptName,
            x = entry.x, y = entry.y, lastUpdated = entry.lastUpdated
        }
    end

    local function operations(entry, previous)
        local result = {}
        if not Export.sameMetadata(entry, previous) then
            result[#result + 1] = operation("index", entry.vehicleHash, indexValue(entry))
        end
        -- Reference identity is safe here: captured inventory arrays are immutable.
        -- Metadata-only changes do not walk/encode the inventory.
        if not previous or previous.items ~= entry.items
            or previous.hasInventorySnapshot ~= entry.hasInventorySnapshot then
            result[#result + 1] = operation("items", entry.vehicleHash, {
                hasInventorySnapshot = entry.hasInventorySnapshot, items = entry.items
            })
        end
        return result
    end

    local function finish(current, result)
        batch = nil
        if result.status == "OK" then
            if type(result.revision) ~= "string" then result = { status = "BLOCKED" }
            else revision = result.revision end
        end
        current.callback(result)
    end

    local function submit()
        local current = batch
        if not current or current.inFlight or getTimestampMs() < retryAt then return end
        if current.attempts >= 5 then finish(current, { status = "BLOCKED" }); return end
        current.attempts, current.inFlight = current.attempts + 1, true
        retryAt = getTimestampMs() + 5000
        local ok, reason = pcall(function()
            repository:mutate(current.revision, current.id, current.operations, function(result)
                if batch ~= current then return end
                current.inFlight = false
                if result.status == "OK" then finish(current, result)
                elseif result.status == "BUSY" or result.status == "UNAVAILABLE"
                    or result.status == "DATABASE_ERROR" or result.status == "OUTCOME_UNKNOWN" then
                    log("POSTGRESQL WRITE DEFERRED " .. result.status .. " (" .. current.attempts .. "/5)")
                else
                    log("POSTGRESQL WRITE BLOCKED " .. tostring(result.status))
                    finish(current, { status = "BLOCKED" })
                end
            end)
        end)
        if not ok then
            current.inFlight = false
            log("POSTGRESQL MUTATION ERROR " .. tostring(reason))
            finish(current, { status = "BLOCKED" })
        end
    end

    local function begin(ops, callback)
        if batch then error("Vehicle export mutation already in flight") end
        batch = { revision = revision, id = entities.newMutationId(), operations = ops,
            callback = callback, attempts = 0 }
        retryAt = 0
        submit()
    end

    local function restore(result)
        if type(result.revision) ~= "string" or type(result.records) ~= "table" then error("Invalid export document") end
        local index, items, initialized = {}, {}, false
        for _, row in ipairs(result.records) do
            local value = entities.decode(row.payload)
            if row.collection == "index" and not index[row.key] then index[row.key] = value
            elseif row.collection == "items" and not items[row.key] then items[row.key] = value
            elseif row.collection == "meta" and row.key == "initialization" and not initialized
                and value.version == 1 then initialized = true
            else error("Unknown or duplicate export record") end
        end
        if not initialized then error("Export initialization marker missing") end
        local snapshots = {}
        for hash, entry in pairs(index) do
            local snapshot = items[hash]
            if not snapshot then error("Missing inventory record " .. hash) end
            entry.items, entry.hasInventorySnapshot = snapshot.items, snapshot.hasInventorySnapshot
            checkEntry(hash, entry)
            snapshots[hash], items[hash] = entry, nil
        end
        for _ in pairs(items) do error("Orphan inventory record") end
        saved, revision = snapshots, result.revision
        return snapshots
    end

    local function import(registry, callback)
        local previous = Native.readSnapshots(registry)
        local snapshots, ops, count = {}, {}, 0
        for hash, claim in pairs(registry) do
            count = count + 1
            if count > 49999 then error("Export import vehicle limit") end
            local entry = Export.entry(hash, claim, previous[hash])
            checkEntry(hash, entry)
            snapshots[hash] = entry
            for _, op in ipairs(operations(entry)) do ops[#ops + 1] = op end
        end
        ops[#ops + 1] = operation("meta", "initialization", { version = 1 })
        begin(ops, function(result)
            if result.status == "OK" then
                saved = snapshots
                log("MIGRATION COMMITTED " .. count .. " vehicle exports")
                callback({ status = "OK", snapshots = snapshots })
            else callback(result) end
        end)
    end

    function self:start(registry, callback)
        if starting then error("Export startup already running") end
        starting = { callback = callback, attempts = 0 }
        retryAt = 0
    end

    local function load()
        local current = starting
        if not current or current.inFlight or batch or getTimestampMs() < retryAt then return end
        if current.attempts >= 5 then starting = nil; current.callback({ status = "BLOCKED" }); return end
        current.attempts, current.inFlight = current.attempts + 1, true
        retryAt = getTimestampMs() + 5000
        repository:load(function(result)
            if starting ~= current then return end
            current.inFlight = false
            local ok, reason = pcall(function()
                if result.status == "OK" then
                    local snapshots = restore(result)
                    starting = nil
                    current.callback({ status = "OK", snapshots = snapshots })
                elseif result.status == "NOT_FOUND" then
                    -- Read the current registry after the asynchronous load.
                    starting = nil
                    import(Export.registry(), current.callback)
                elseif result.status == "BUSY" or result.status == "UNAVAILABLE" or result.status == "DATABASE_ERROR" then
                    log("POSTGRESQL LOAD DEFERRED " .. result.status)
                else starting = nil; current.callback({ status = "BLOCKED" }) end
            end)
            if not ok then starting = nil; log(tostring(reason)); current.callback({ status = "BLOCKED" }) end
        end)
    end

    function self:save(entry, callback)
        local previous = saved[entry.vehicleHash]
        -- Full item validation is done on capture/load, not metadata-only updates.
        if not previous or previous.items ~= entry.items then checkEntry(entry.vehicleHash, entry) end
        local ops = operations(entry, previous)
        if #ops == 0 then callback({ status = "OK" }); return end
        begin(ops, function(result)
            if result.status == "OK" then saved[entry.vehicleHash] = entry end
            callback(result)
        end)
    end

    function self:delete(hash, previous, callback)
        if not saved[hash] then callback({ status = "OK" }); return end
        begin({ { collection = "index", key = hash, deleted = true },
            { collection = "items", key = hash, deleted = true } }, function(result)
            if result.status == "OK" then saved[hash] = nil end
            callback(result)
        end)
    end

    function self:poll()
        submit()
        load()
    end

    return self
end

return PostgreSQL
