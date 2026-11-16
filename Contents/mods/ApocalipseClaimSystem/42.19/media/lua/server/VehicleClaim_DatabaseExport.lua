-- Shared cache and capture policy. Backends own persistence and acknowledgments.
local Export = {}
local FLUSH_INTERVAL_MS = 30 * 60 * 1000
local VEHICLE_COOLDOWN_MS = 5 * 60 * 1000
local MAX_PENDING = 100000
local MAX_CARS = 49999

function Export.registry()
    local data = ModData.getOrCreate(VehicleClaim.GLOBAL_REGISTRY_KEY)
    data.claims = data.claims or {}
    return data.claims
end

function Export.entry(hash, claim, previous)
    previous = previous or {}
    return {
        vehicleHash = hash,
        ownerSteamID = tostring(claim.ownerSteamID or ""),
        ownerName = claim.ownerName or "",
        vehicleName = claim.vehicleName or "Unknown Vehicle",
        scriptName = previous.scriptName or "Unknown",
        x = claim.x or 0, y = claim.y or 0,
        lastUpdated = previous.lastUpdated or string.format("%.0f", getTimestampMs()),
        hasInventorySnapshot = previous.hasInventorySnapshot == true
            or (previous.hasInventorySnapshot == nil and previous.items ~= nil),
        items = previous.items or {}
    }
end

local metadataFields = { "ownerSteamID", "ownerName", "vehicleName", "scriptName", "x", "y", "lastUpdated" }
function Export.sameMetadata(a, b)
    if not a or not b then return false end
    for _, key in ipairs(metadataFields) do
        if a[key] ~= b[key] then return false end
    end
    return true
end

local function inventory(vehicle)
    local items = {}
    for i = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(i)
        local container = part and part:getItemContainer()
        local contents = container and container:getItems()
        if contents then
            for j = 0, contents:size() - 1 do
                local item = contents:get(j)
                if item then
                    if #items >= 100000 then error("Vehicle inventory snapshot item limit") end
                    items[#items + 1] = {
                        fullType = item:getFullType() or "unknown", count = item:getCount() or 1,
                        container = part:getId() or "unknown"
                    }
                end
            end
        end
    end
    return items
end

function Export.new(backend, log, block)
    local cache, pending, persisted, captured = {}, {}, {}, {}
    local head, tail, pendingCount, carCount
    pendingCount, carCount = 0, 0
    local inFlight, ready, stopped = false, false, false
    local indexGeneration, savedIndexGeneration, indexAttempts = 0, 0, 0
    local indexDue, nextFlush = 0, 0
    local lastExport = {}
    local self = {}

    local function append(node)
        node.next = nil
        if tail then tail.next = node else head = node end
        tail = node
    end

    local function mark(hash, due)
        local node = pending[hash]
        if node then
            node.generation = node.generation + 1
            node.due = math.min(node.due, due)
            return
        end
        if pendingCount >= MAX_PENDING then
            stopped = true
            block("EXPORT QUEUE LIMIT (100000 changed vehicles)")
            return
        end
        node = { hash = hash, generation = 1, due = due, attempts = 0 }
        pending[hash], pendingCount = node, pendingCount + 1
        append(node)
    end

    local function changedIndex()
        if indexGeneration == savedIndexGeneration then indexDue = nextFlush end
        indexGeneration = indexGeneration + 1
    end

    function self.start(callback)
        backend:start(Export.registry(), function(result)
            if result.status ~= "OK" then callback(result); return end
            local ok, reason = pcall(function()
                local snapshots, registry = result.snapshots, Export.registry()
                -- One-time reconstruction. Normal updates name the changed hash.
                for hash, claim in pairs(registry) do
                    carCount = carCount + 1
                    if carCount > MAX_CARS then error("EXPORT VEHICLE LIMIT (49999)") end
                    local previous = snapshots[hash]
                    cache[hash] = Export.entry(hash, claim, previous)
                    persisted[hash] = previous
                    if previous and cache[hash].hasInventorySnapshot then
                        captured[hash] = {
                            owner = previous.ownerSteamID,
                            x = previous.x or cache[hash].x, y = previous.y or cache[hash].y
                        }
                    end
                    if result.rewrite or not Export.sameMetadata(cache[hash], previous) then mark(hash, 0) end
                end
                for hash, previous in pairs(snapshots) do
                    if not registry[hash] then persisted[hash] = previous; mark(hash, 0) end
                end
                nextFlush = getTimestampMs() + FLUSH_INTERVAL_MS
                indexGeneration, indexDue, ready = 1, 0, true
                callback({ status = "OK" })
            end)
            if not ok then block(reason); callback({ status = "BLOCKED" }) end
        end)
    end

    function self.refresh(hash)
        if not ready or stopped then return end
        local claim = Export.registry()[hash]
        if not claim then self.remove(hash); return end
        local previous = cache[hash]
        local entry = Export.entry(hash, claim, previous)
        if previous and Export.sameMetadata(previous, entry) then return end
        if not previous then
            if carCount >= MAX_CARS then stopped = true; block("EXPORT VEHICLE LIMIT"); return end
            carCount = carCount + 1
        end
        cache[hash] = entry
        mark(hash, nextFlush)
        changedIndex()
    end

    function self.update(vehicle)
        if not ready or stopped or not vehicle then return end
        local hash = VehicleClaim.getVehicleHash(vehicle)
        local claim = hash and Export.registry()[hash]
        if not claim then return end
        local previous = cache[hash]
        local snapshot = captured[hash]
        local x, y = vehicle:getX(), vehicle:getY()
        local owner = tostring(claim.ownerSteamID or "")
        if previous and snapshot and snapshot.owner == owner and previous.hasInventorySnapshot
            and math.abs(snapshot.x - x) <= 10 and math.abs(snapshot.y - y) <= 10 then return end
        if not previous and carCount >= MAX_CARS then stopped = true; block("EXPORT VEHICLE LIMIT"); return end
        local entry = Export.entry(hash, claim, previous)
        local script = vehicle:getScript()
        entry.scriptName = script and script:getScriptObjectFullType() or "Unknown"
        entry.x, entry.y = x, y
        entry.lastUpdated = string.format("%.0f", getTimestampMs())
        entry.hasInventorySnapshot, entry.items = true, inventory(vehicle)
        captured[hash] = { owner = owner, x = x, y = y }
        if not previous then carCount = carCount + 1 end
        cache[hash] = entry
        local due = math.min(nextFlush, (lastExport[hash] or -VEHICLE_COOLDOWN_MS) + VEHICLE_COOLDOWN_MS)
        mark(hash, due)
        changedIndex()
    end

    function self.remove(hash)
        if not ready or stopped or not hash then return end
        if cache[hash] then
            persisted[hash] = persisted[hash] or cache[hash]
            cache[hash], carCount = nil, carCount - 1
        end
        captured[hash] = nil
        mark(hash, 0)
        changedIndex()
    end

    function self.clear()
        if not ready or stopped then return end
        for hash in pairs(cache) do self.remove(hash) end
    end

    local function index()
        local cars = {}
        for hash, entry in pairs(cache) do
            cars[hash] = {
                vehicleHash = hash, ownerSteamID = entry.ownerSteamID, ownerName = entry.ownerName,
                vehicleName = entry.vehicleName, scriptName = entry.scriptName,
                x = entry.x, y = entry.y, lastUpdated = entry.lastUpdated,
                path = backend.carPath(hash)
            }
        end
        return { version = 2, generatedAt = string.format("%.0f", getTimestampMs()), count = carCount, cars = cars }
    end

    function self.tick(force)
        if not ready or stopped or inFlight then return end
        local now = getTimestampMs()
        if now >= nextFlush then nextFlush = now + FLUSH_INTERVAL_MS end
        local node = head
        if node then
            head = node.next
            if not head then tail = nil end
            if not force and now < node.due then append(node); return end
            inFlight = true
            local generation, entry = node.generation, cache[node.hash]
            local function completed(result)
                inFlight = false
                if result.status == "OK" then
                    persisted[node.hash] = entry
                    lastExport[node.hash] = entry and now or nil
                    node.attempts = 0
                    if node.generation == generation then
                        pending[node.hash], pendingCount = nil, pendingCount - 1
                    else
                        if cache[node.hash] then
                            node.due = math.min(nextFlush, now + VEHICLE_COOLDOWN_MS)
                        end
                        append(node)
                    end
                else
                    node.attempts, node.due = node.attempts + 1, getTimestampMs() + 5000
                    append(node)
                    if node.attempts >= 5 or result.status == "BLOCKED" then
                        stopped = true
                        block("EXPORT WRITE " .. tostring(result.status) .. ", pending data retained")
                    else log("EXPORT WRITE DEFERRED " .. tostring(result.status)) end
                end
            end
            if entry then backend:save(entry, completed)
            else backend:delete(node.hash, persisted[node.hash], completed) end
        elseif backend.writeIndex and indexGeneration ~= savedIndexGeneration and (force or now >= indexDue) then
            local generation = indexGeneration
            inFlight = true
            backend:writeIndex(index(), function(result)
                inFlight = false
                if result.status == "OK" then
                    savedIndexGeneration, indexDue, indexAttempts = generation, 0, 0
                else
                    indexAttempts, indexDue = indexAttempts + 1, now + 5000
                    if indexAttempts >= 5 then stopped = true; block("INDEX WRITE RETRY LIMIT")
                    else log("INDEX WRITE DEFERRED " .. tostring(result.status)) end
                end
            end)
        end
    end

    function self.shutdown()
        if backend.name == "native" then
            -- Native callbacks complete synchronously. Bound shutdown retries.
            for _ = 1, pendingCount + 1 do self.tick(true) end
        elseif pendingCount > 0 or inFlight then
            log("Shutdown with pending export work. Restart reconstructs claims from GlobalModData and committed snapshots.")
        end
    end

    return self
end

return Export
