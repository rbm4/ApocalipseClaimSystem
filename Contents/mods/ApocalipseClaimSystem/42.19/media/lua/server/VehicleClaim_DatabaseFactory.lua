if not isServer() then return end
require "shared/VehicleClaim_Shared"
require "shared/VehicleClaim_Config"
if VehicleClaim.DatabaseFactory then return VehicleClaim.DatabaseFactory end

local Export = require "server/VehicleClaim_DatabaseExport"
local Factory = { state = "waiting" }
VehicleClaim.DatabaseFactory = Factory
local backend, cache, repositories
local validationIndex, validationAttempts, retryAt, validating = 1, 0, 0, false

local function log(message)
    print("[VehicleClaim/Persistence] " .. message)
end

local function block(reason)
    Factory.state = "blocked"
    log("EXPORT STORAGE BLOCKED " .. tostring(reason))
end

local function guarded(action)
    local ok, reason = pcall(action)
    if not ok then block(reason) end
end

local function banner(mode)
    log("============================================================")
    log("VEHICLE DATABASE EXPORT " .. mode)
    log("Claim authority uses native VehicleClaimRegistry GlobalModData.")
    log("PostgreSQL support https://plataforma.apocalipse.cloud/")
    log("Documentation .docs/features/database-export.md")
    log("Server patches https://github.com/rbm4/apocalipsebr-zomboid-patches.git")
    log("============================================================")
end

local function startCache()
    Factory.state = "loading"
    cache = Export.new(backend, log, block)
    cache.start(function(result)
        guarded(function()
            if result.status ~= "OK" then block("CACHE STARTUP " .. tostring(result.status)); return end
            if Factory.state == "blocked" then return end
            Factory.state = "ready"
            log(backend.name == "postgresql" and "POSTGRESQL EXPORT ACTIVE" or "NATIVE FILE EXPORT ACTIVE")
            -- Vehicle load events may have fired while schema/load requests were pending.
            local cell = getCell()
            local vehicles = cell and cell:getVehicles()
            if vehicles then
                local iterator = vehicles:iterator()
                while iterator:hasNext() do cache.update(iterator:next()) end
            end
        end)
    end)
end

local function validate()
    if Factory.state ~= "validating" or validating or getTimestampMs() < retryAt then return end
    if validationAttempts >= 5 then block("SCHEMA/CONNECTIVITY RETRY LIMIT"); return end
    validating, validationAttempts = true, validationAttempts + 1
    retryAt = getTimestampMs() + 5000
    repositories[validationIndex]:validate(function(result)
        guarded(function()
            validating = false
            if result.status == "OK" then
                validationIndex, validationAttempts, retryAt = validationIndex + 1, 0, 0
                if validationIndex > #repositories then startCache() end
            elseif result.status == "BUSY" or result.status == "UNAVAILABLE" or result.status == "DATABASE_ERROR" then
                log("SCHEMA/CONNECTIVITY CHECK DEFERRED " .. result.status)
            else block("SCHEMA/CONNECTIVITY " .. tostring(result.status)) end
        end)
    end)
end

function Factory.start()
    if Factory.state ~= "waiting" then return end
    if not getActivatedMods():contains("APOCALISEBR_PACK") then
        backend = require "server/VehicleClaim_DatabaseNative"
        banner("NATIVE FILE EXPORT SELECTED")
        startCache()
        return
    end
    banner("APOCALISEBR_PACK DETECTED - VALIDATING POSTGRESQL SCHEMA AND CONNECTIVITY")
    if not ApocBRModEntities or not ApocBRModEntities.documentLoad or not ApocBRModEntities.documentMutate then
        block("MISSING OR OUTDATED ENTITY BRIDGE")
        return
    end
    require "ApocBR/Entities"
    local entities = ApocBREntities
    if not entities or not entities.define or not entities.document or not entities.encode
        or not entities.decode or not entities.newMutationId then block("OUTDATED ENTITY FACADE"); return end
    local PostgreSQL = require "server/VehicleClaim_DatabasePostgreSQL"
    repositories = PostgreSQL.schemas(entities)
    backend = PostgreSQL.new(entities, log)
    Factory.state = "validating"
    validate()
end

function VehicleClaim.updateCarDatabase(vehicle)
    if Factory.state == "ready" then guarded(function() cache.update(vehicle) end) end
end

function VehicleClaim.refreshCarDatabase(hash)
    if Factory.state == "ready" then guarded(function() cache.refresh(hash) end) end
end

function VehicleClaim.removeFromCarDatabase(hash)
    if Factory.state == "ready" then guarded(function() cache.remove(hash) end) end
end

function VehicleClaim.clearCarDatabase()
    if Factory.state == "ready" then guarded(function() cache.clear() end) end
end

Events.OnServerStarted.Add(function() guarded(Factory.start) end)
Events.OnTickEvenPaused.Add(function()
    if Factory.state == "blocked" or Factory.state == "waiting" then return end
    guarded(function()
        validate()
        if backend and backend.poll then backend:poll() end
        if Factory.state == "ready" then cache.tick() end
    end)
end)
if Events.OnServerShutdown then
    Events.OnServerShutdown.Add(function() if cache then guarded(cache.shutdown) end end)
end

return Factory
