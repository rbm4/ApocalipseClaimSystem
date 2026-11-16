-- Production factory/cache/backends/facade, with detached asynchronous I/O doubles.
local checks, clock, sequence = 0, 3600000, 0
local realPrint = print
local function check(value, message) checks = checks + 1; assert(value, message) end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
local hooks, logs, requests, responses, payloads, document, files, registry
local revision, lastToken, lastBody, encodes, writes, scans, busy, definitions
function isServer() return true end
function isClient() return false end
function isDebugEnabled() return false end
function getTimestampMs() return clock end
function print(value) logs[#logs + 1] = tostring(value) end
local function event(name)
    hooks[name] = {}
    return { Add = function(fn) hooks[name][#hooks[name] + 1] = fn end }
end
local function tick() for _, fn in ipairs(hooks.tick) do fn() end end
local function hasLog(text)
    for _, line in ipairs(logs) do if string.find(line, text, 1, true) then return true end end
    return false
end
local function reset(pack, claims, existing, existingFiles, missingBridge)
    VehicleClaim, ApocBREntities = nil, nil
    for name in pairs(package.loaded) do
        if string.find(name, "VehicleClaim", 1, true) or name == "ApocBR/Entities" then package.loaded[name] = nil end
    end
    hooks, logs, requests, responses, payloads, definitions = {}, {}, {}, {}, {}, {}
    files, registry, document = copy(existingFiles or {}), { claims = claims or {} }, copy(existing)
    revision, lastToken, lastBody, encodes, writes, scans, busy = existing and 1 or 0, nil, nil, 0, 0, 0, false
    Events = { OnServerStarted = event("start"), OnTickEvenPaused = event("tick"), OnServerShutdown = event("shutdown") }
    function getActivatedMods() return { contains = function(_, name) return pack and name == "APOCALISEBR_PACK" end } end
    ModData = { getOrCreate = function(key) check(key == "VehicleClaimRegistry", "only claim registry read"); return registry end }
    function getCell() return nil end
    function getFileReader(path)
        local text, done = files[path], false
        if not text then return nil end
        return { readLine = function() if not done then done = true; return text end end, close = function() end }
    end
    function getFileWriter(path)
        writes = writes + 1
        return { write = function(_, text) files[path] = text end, close = function() end }
    end
    ApocBRModEntities = {
        define = function(name, mapping) definitions[name] = copy(mapping) end,
        encode = function(value)
            encodes = encodes + 1
            local id = "payload" .. sequence .. "_" .. encodes
            payloads[id] = copy(value)
            return id
        end,
        decode = function(id) return copy(assert(payloads[id], "missing payload " .. id)) end,
        newMessageId = function() sequence = sequence + 1; return "mutation" .. sequence end,
        submit = function(name, action)
            check(action == "validate", "mapped entity used for schema validation")
            sequence = sequence + 1
            requests[#requests + 1] = { id = tostring(sequence), kind = "validate", name = name }
            return { accepted = true, id = tostring(sequence) }
        end,
        documentLoad = function(name)
            check(name == "VehicleClaim.Export.v1", "isolated export document")
            sequence = sequence + 1
            requests[#requests + 1] = { id = tostring(sequence), kind = "load" }
            return { accepted = true, id = tostring(sequence) }
        end,
        documentMutate = function(name, expected, token, operations)
            if busy then return { accepted = false, status = "BUSY" } end
            sequence = sequence + 1
            requests[#requests + 1] = { id = tostring(sequence), kind = "write", expected = expected,
                token = token, operations = copy(operations) }
            return { accepted = true, id = tostring(sequence) }
        end,
        poll = function() local result = responses; responses = {}; return result end
    }
    if missingBridge then ApocBRModEntities = nil end
    local factory = require "server/VehicleClaim_DatabaseFactory"
    for _, fn in ipairs(hooks.start) do fn() end
    return factory
end

local function respond(status, committed)
    local request = table.remove(requests, 1)
    assert(request, "missing request")
    local result = { id = request.id, status = status or "OK" }
    if request.kind == "load" and not status then
        result.status, result.revision, result.records = document and "OK" or "NOT_FOUND", tostring(revision), {}
        for _, row in pairs(document or {}) do result.records[#result.records + 1] = copy(row) end
    elseif request.kind == "write" and (not status or status == "OK" or committed) then
        if lastToken == request.token then
            check(#lastBody == #request.operations, "stable replay operation count")
            for i, op in ipairs(lastBody) do check(op.payload == request.operations[i].payload, "stable replay body") end
        else
            check(request.expected == tostring(revision), "expected revision")
            document = document or {}
            for _, op in ipairs(request.operations) do
                local key = op.collection .. ":" .. op.key
                document[key] = not op.deleted and copy(op) or nil
            end
            revision, lastToken, lastBody = revision + 1, request.token, copy(request.operations)
        end
        result.revision = tostring(revision)
    end
    responses[#responses + 1] = result
    tick()
    return request
end

local function drain(count)
    for _ = 1, count or 25 do if #requests > 0 then respond() else tick() end end
end

local function claim(owner)
    return { vehicleHash = "VH1", ownerSteamID = owner or "76561198012345679", ownerName = "Owner",
        vehicleName = "Car", x = 0, y = 0, allowedPlayers = {}, claimTime = 1, lastSeen = 2 }
end

local function vehicle(hash)
    local position = { x = 0 }
    return {
        position = position,
        getModData = function() return { vehicleHash = hash or "VH1" } end,
        getX = function() return position.x end, getY = function() return 0 end,
        getScript = function() return { getScriptObjectFullType = function() return "Base.Car" end } end,
        getPartCount = function() scans = scans + 1; return 1 end,
        getPartByIndex = function() return {
            getId = function() return "TruckBed" end,
            getItemContainer = function() return { getItems = function() return {
                size = function() return 1 end,
                get = function() return { getFullType = function() return "Base.Hammer" end, getCount = function() return 1 end } end
            } end } end
        } end
    }
end

local factory = reset(false, { VH1 = claim() })
check(factory.state == "ready" and #requests == 0, "native selected without database requests")
local v = vehicle()
VehicleClaim.updateCarDatabase(v)
drain()
check(files["VehicleClaimSystemDatabase/cars/VH1.txt"] ~= nil, "native car export")
check(files["VehicleClaimSystemDatabase/index.txt"] ~= nil, "native index")
check(string.find(files["VehicleClaimSystemDatabase/cars/VH1.txt"], "76561198012345679", 1, true), "Steam ID precision preserved")
local previousWrites, previousScans = writes, scans
for _ = 1, 100 do VehicleClaim.updateCarDatabase(v); tick() end
check(writes == previousWrites and scans == previousScans, "native unchanged avoids extraction and writes")
registry.claims.VH1 = nil
VehicleClaim.removeFromCarDatabase("VH1")
drain(); clock = clock + 1800000; drain()
check(string.find(files["VehicleClaimSystemDatabase/deleted/VH1.txt"], "Base.Hammer", 1, true), "native deletion archives payload")
check(not string.find(files["VehicleClaimSystemDatabase/cars/VH1.txt"], "Base.Hammer", 1, true), "old native path retired")
check(string.find(files["VehicleClaimSystemDatabase/index.txt"], '"count":0', 1, true), "deleted car leaves active index")

factory = reset(true, { VH1 = claim() })
check(factory.state == "validating", "schema validated before startup")
respond("SCHEMA_ERROR")
check(factory.state == "blocked" and writes == 0, "schema error blocks export without file writes")
factory = reset(true, nil, nil, nil, true)
check(factory.state == "blocked" and hasLog("MISSING OR OUTDATED ENTITY BRIDGE"), "missing bridge blocks explicitly")

factory = reset(true, { VH1 = claim() })
local authoritative = registry.claims
drain()
check(factory.state == "ready" and writes == 0 and registry.claims == authoritative, "SQL migration preserves native authority")
check(hasLog("MIGRATION COMMITTED") and hasLog("POSTGRESQL EXPORT ACTIVE"), "acknowledged startup banner")
check(document["meta:initialization"] and document["index:VH1"] and document["items:VH1"], "index/items and empty snapshot imported")
check(definitions["VehicleClaim.Export.Index.v1"].table == "vehicle_claim_export_index", "index table mapping")
check(definitions["VehicleClaim.Export.Items.v1"].table == "vehicle_claim_export_items", "item table mapping")
v = vehicle()
VehicleClaim.updateCarDatabase(v)
drain()
check(scans == 1 and payloads[document["items:VH1"].payload].items[1].fullType == "Base.Hammer", "capture persisted item summary")
local idleEncodes, idleRevision, idleScans = encodes, revision, scans
for _ = 1, 200 do VehicleClaim.updateCarDatabase(v); tick() end
check(encodes == idleEncodes and revision == idleRevision and scans == idleScans, "SQL idle avoids traversal encoding and writes")
clock = clock + 1800000
drain()
check(encodes == idleEncodes and revision == idleRevision, "periodic wakeup does not snapshot unchanged state")

registry.claims.VH1.ownerName = "Renamed"
VehicleClaim.refreshCarDatabase("VH1")
clock = clock + 1800000; tick()
local metadataRequest = requests[1]
check(metadataRequest and #metadataRequest.operations == 1 and metadataRequest.operations[1].collection == "index", "metadata-only save excludes item payload")
respond(); drain()
check(scans == idleScans and encodes == idleEncodes + 1, "metadata does not traverse inventory")

clock = clock + 300000
v.position.x = 20
VehicleClaim.updateCarDatabase(v)
tick()
check(#requests == 1, "changed vehicle queued")
local ambiguous = respond("OUTCOME_UNKNOWN", true)
local afterCommit = revision
clock = clock + 5000; tick()
check(requests[1].token == ambiguous.token, "ambiguous retry keeps mutation ID")
respond(); drain()
check(revision == afterCommit, "ambiguous save committed once")

clock = clock + 300000
v.position.x = 40
VehicleClaim.updateCarDatabase(v); tick()
registry.claims.VH1 = nil
VehicleClaim.removeFromCarDatabase("VH1")
respond(); drain()
check(not document["index:VH1"] and not document["items:VH1"], "delete during save retained after older acknowledgment")

factory = reset(true)
drain()
check(factory.state == "ready" and document["meta:initialization"], "empty SQL initialized once")
local existing, existingPayloads = copy(document), copy(payloads)
factory = reset(true, { VH1 = claim() }, existing)
payloads = existingPayloads
drain()
check(factory.state == "ready" and document["index:VH1"], "existing SQL cache reconciles current registry")
check(not hasLog("MIGRATION COMMITTED"), "existing state skips legacy import")

local many = {}
for i = 1, 1200 do local c = claim(); c.vehicleHash = "VH" .. i; many[c.vehicleHash] = c end
factory = reset(true, many)
drain()
check(factory.state == "ready", "more than 256 claims reconstruct through document API")
local before = encodes
registry.claims.VH1.ownerName = "Only target"
VehicleClaim.refreshCarDatabase("VH1")
clock = clock + 1800000; tick()
check(encodes == before + 1 and #requests[1].operations == 1, "one change with 1200 unrelated records encodes one index")
respond(); drain()
registry.claims = {}
VehicleClaim.clearCarDatabase()
drain(2500)
local remaining = 0
for _ in pairs(document) do remaining = remaining + 1 end
check(remaining == 1 and document["meta:initialization"], "admin clear drains 1200 physical deletions in bounded transactions")

factory = reset(true, { VH1 = claim() })
drain()
v = vehicle(); busy = true
VehicleClaim.updateCarDatabase(v); tick()
local encodedBusy = encodes
for _ = 1, 100 do tick() end
check(encodes == encodedBusy and #requests == 0, "BUSY retries preserve prepared payload without spinning")
busy = false; clock = clock + 5000; tick(); respond(); drain()
check(factory.state == "ready", "bounded delayed retry recovers")

factory = reset(true, {}, nil, { ["VehicleClaimSystemDatabase/index.txt"] = '{"version":2,"cars":{}}',
    ["VehicleClaimSystemDatabase/cars/stale.txt"] = "unread stale file" })
drain()
check(factory.state == "ready" and not document["index:stale"], "orphan car files excluded from migration")
factory = reset(true, { VH1 = claim() }, nil, { ["VehicleClaimSystemDatabase.json"] = "invalid" })
drain()
check(factory.state == "blocked" and document == nil, "malformed legacy data blocks import before commit")

local snapshotFiles = {
    ["VehicleClaimSystemDatabase/index.txt"] = '{"version":2,"cars":{"VH1":{"vehicleHash":"VH1","path":"VehicleClaimSystemDatabase/cars/VH1.txt"}}}',
    ["VehicleClaimSystemDatabase/cars/VH1.txt"] = '{"vehicleHash":"VH1","ownerSteamID":"old","scriptName":"Base.Car","lastUpdated":"123","hasInventorySnapshot":true,"items":[{"fullType":"Base.Indexed","count":2,"container":"TruckBed"}]}',
    ["VehicleClaimSystemDatabase.json"] = '{"VH1":{"vehicleHash":"VH1","items":[{"fullType":"Base.Legacy","count":1,"container":"TruckBed"}]}}'
}
factory = reset(true, { VH1 = claim() }, nil, snapshotFiles)
drain()
check(factory.state == "ready", "indexed snapshot imports successfully")
check(payloads[document["items:VH1"].payload].items[1].fullType == "Base.Indexed", "indexed snapshot precedes legacy")
check(payloads[document["index:VH1"].payload].ownerSteamID == "76561198012345679", "registry owner wins over legacy export")
existing, existingPayloads = copy(document), copy(payloads)
factory = reset(true, {}, existing, { ["VehicleClaimSystemDatabase.json"] = "invalid" })
payloads = existingPayloads
drain()
check(factory.state == "ready" and not document["index:VH1"] and not document["items:VH1"], "restart removes stale SQL and skips stale native files")

factory = reset(true, { VH1 = claim() })
drain()
v = vehicle(); VehicleClaim.updateCarDatabase(v); tick()
registry.claims.VH1.ownerName = "New during flight"
VehicleClaim.refreshCarDatabase("VH1")
respond(); clock = clock + 300000; drain()
check(payloads[document["index:VH1"].payload].ownerName == "New during flight", "newer dirty metadata survives older save acknowledgment")
local beforeCapture = scans
registry.claims.VH1.x = 25
VehicleClaim.refreshCarDatabase("VH1")
v.position.x = 25
VehicleClaim.updateCarDatabase(v)
check(scans == beforeCapture + 1, "metadata refresh does not erase movement capture baseline")

factory = reset(true)
for _ = 1, 5 do respond("DATABASE_ERROR"); clock = clock + 5000; tick() end
check(factory.state == "blocked" and hasLog("RETRY LIMIT"), "startup retry exhaustion explicit")
factory = reset(false, { VH1 = claim() })
function getFileWriter() return nil end
for _ = 1, 5 do tick(); clock = clock + 5000 end
check(factory.state == "blocked", "native failed writes retain work and stop after bounded retries")
factory = reset(true, { VH1 = claim() }, nil, {
    ["VehicleClaimSystemDatabase/index.txt"] = snapshotFiles["VehicleClaimSystemDatabase/index.txt"],
    ["VehicleClaimSystemDatabase/cars/VH1.txt"] = '{"vehicleHash":"VH1","deletedAt":"123"}'
})
drain()
check(factory.state == "ready" and not payloads[document["items:VH1"].payload].hasInventorySnapshot,
    "reclaimed native vehicle retirement marker imports as absent snapshot")

realPrint("PASS " .. checks .. " vehicle export checks in production Kahlua modules")
