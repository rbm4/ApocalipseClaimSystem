# ApocalipseClaimSystem - Vehicle Claim System

## Technical Documentation

A secure, server-authoritative vehicle ownership system for Project Zomboid multiplayer servers.

### Build Compatibility
**Tested and compatible with:** Project Zomboid Build 42.14 (also includes legacy 42.13.1 version)

### Multi-Language Support
The system supports multiple languages with automatic detection:
- **English (EN)** - Full UI and sandbox translations
- **Brazilian Portuguese (PTBR)** - Full UI and sandbox translations
- **Russian (RU)** - Full UI and sandbox translations

Translation files are located in `media/lua/shared/Translate/<LANG>/` with both `UI_<LANG>.txt` and `Sandbox_<LANG>.txt` per language.

## Overview

This mod implements a robust vehicle claiming system with proper client-server architecture, preventing cheating through server-side validation and providing a clean UI for vehicle management. Key features include:

- **Vehicle claiming & releasing** with proximity-based timed actions
- **Access control** - grant/revoke other players' access to your vehicles
- **Abandoned vehicle contest** - contest claims on vehicles inactive for configurable real-world days
- **Remote release** - unclaim vehicles from anywhere via the vehicle list panel
- **Admin tools** - clear all claims server-wide with confirmation
- **Embedded mechanics UI** - claim panel integrated directly into the vehicle mechanics window (V key)
- **Vehicle load synchronization** - stale claims auto-cleaned when vehicles load

---

## Architecture Philosophy

### **Server-Authoritative Design**
All critical operations (claiming, releasing, contesting, access control) are validated and executed **exclusively on the server**. Clients send requests, but the server has final authority over all state changes.

### **Anti-Cheat Measures**
- **Steam ID Verification**: Server validates that the requesting player's Steam ID matches the command
- **Proximity Checks**: Server verifies player is within range (4 tiles) before allowing claim actions
- **Ownership Validation**: All modifications require proof of ownership or admin privileges
- **ModData as Source of Truth**: Vehicle claim state is stored in vehicle ModData and synchronized by the game engine
- **Client-Side Enforcement**: Comprehensive hooks block unauthorized interactions locally (UX-only; server validates independently)

---

## Quick File Reference

```
Contents/mods/ApocalipseClaimSystem/42.14/
├── mod.info
├── media/
│   ├── sandbox-options.txt                      # MaxClaimsPerPlayer + AbandonedDaysThreshold
│   └── lua/
│       ├── shared/
│       │   ├── VehicleClaim_Shared.lua          # Constants, utilities, claim counting, abandoned detection
│       │   └── Translate/
│       │       ├── EN/
│       │       │   ├── UI_EN.txt                # English UI translations
│       │       │   └── Sandbox_EN.txt           # English sandbox option translations
│       │       ├── PTBR/
│       │       │   ├── UI_PTBR.txt              # Brazilian Portuguese UI translations
│       │       │   └── Sandbox_PTBR.txt         # Brazilian Portuguese sandbox option translations
│       │       └── RU/
│       │           ├── UI_RU.txt                # Russian UI translations
│       │           └── Sandbox_RU.txt           # Russian sandbox option translations
│       ├── server/
│       │   └── VehicleClaim_ServerCommands.lua  # Server-side validation, state changes, vehicle sync
│       └── client/
│           ├── VehicleClaim_ClientCommands.lua  # Server response handling & event dispatching
│           ├── VehicleClaim_ContextMenu.lua     # Right-click menu integration & timed actions
│           ├── VehicleClaim_Enforcement.lua     # ⭐ Build 42 interaction blocking (comprehensive hooks)
│           ├── VehicleClaim_MechanicsUI.lua     # ⭐ Embedded claim UI in mechanics window
│           ├── VehicleClaim_PlayerMenu.lua      # "My Vehicles" context menu + admin tools
│           └── ui/
│               ├── ISVehicleClaimPanel.lua      # Single vehicle management (with remote release)
│               └── ISVehicleClaimListPanel.lua  # All claimed vehicles list (server registry)
```

---

## File Structure & Responsibilities

### **📁 Shared Files** (`media/lua/shared/`)
Loaded on both client and server. Contains constants, utilities, and validation helpers.

#### **`VehicleClaim_Shared.lua`**
**Purpose:** Common functionality and constants available to both client and server.

**Key Responsibilities:**
- Define all command/response constants and error codes
- Define ModData keys for vehicle storage
- Provide utility functions: `isClaimed()`, `hasAccess()`, `getOwnerID()`, `getOwnerName()`, `getAllowedPlayers()`, etc.
- **Vehicle hash system**: `getOrCreateVehicleHash()` / `getVehicleHash()` - persistent unique vehicle identification
- Calculate distances and validate proximity (`CLAIM_DISTANCE = 4.0` tiles)
- Read sandbox configuration (`MaxClaimsPerPlayer`, `AbandonedDaysThreshold`)
- Count player claims and enforce limits
- **Abandoned vehicle detection**: `isVehicleAbandoned()` - converts in-game time to real-world days (16 in-game days = 1 real-world day)
- Track pending actions via `VehicleClaim.pendingActions`

**Vehicle Hash System:**
- Hash is generated on first interaction and stored in vehicle ModData under `vehicleHash` key
- Uses vehicle position, script name, timestamp, and random seed for uniqueness
- Format: `VH0000000000` (10-digit numeric hash)
- Persists across server restarts and is used as the registry index

**Data Reading:**
- `getClaimData()` reads directly from vehicle ModData (single source of truth)
- No client-side caching layer - all reads go to ModData

**Security Note:** All functions here are read-only or local calculations. No state mutations occur in shared code.

---

### **📁 Translation Files** (`media/lua/shared/Translate/`)

The system supports three languages, each with UI strings and sandbox option labels:

| Folder | Language | Files |
|--------|----------|-------|
| `EN/` | English | `UI_EN.txt`, `Sandbox_EN.txt` |
| `PTBR/` | Brazilian Portuguese | `UI_PTBR.txt`, `Sandbox_PTBR.txt` |
| `RU/` | Russian | `UI_RU.txt`, `Sandbox_RU.txt` |

**Key Translation Groups:**

| Group | Example Keys | Purpose |
|-------|-------------|---------|
| Vehicle List Panel | `UI_VehicleClaim_MyVehicles`, `UI_VehicleClaim_VehicleCount` | List panel strings |
| Management Panel | `UI_VehicleClaim_ManagementTitle`, `UI_VehicleClaim_AllowedPlayers` | Manage panel strings |
| Context Menu | `UI_VehicleClaim_ContextTitle`, `UI_VehicleClaim_ClaimVehicle` | Right-click menu |
| Messages | `UI_VehicleClaim_SuccessfullyClaimed`, `UI_VehicleClaim_ReleasedClaimOnVehicle` | Notifications |
| Error Messages | `UI_VehicleClaim_ClaimFailedPrefix`, `UI_VehicleClaim_TooFarFromVehicle` | Error feedback |
| Unloaded Vehicles | `UI_VehicleClaim_ReleaseRemoteConfirm`, `UI_VehicleClaim_RemoteReleaseInitiated` | Remote release strings |
| Mechanics UI | `UI_VehicleClaim_MechanicsTitle`, `UI_VehicleClaim_ContestClaim` | Embedded panel |
| Access Status | `UI_VehicleClaim_AccessGranted`, `UI_VehicleClaim_NoAccess` | Access indicators |
| Abandoned Vehicles | `UI_VehicleClaim_VehicleAbandoned`, `UI_VehicleClaim_VehicleNotAbandoned` | Contest system |
| Sandbox Options | `Sandbox_VehicleClaimSystem_MaxClaimsPerPlayer`, `Sandbox_VehicleClaimSystem_AbandonedDaysThreshold` | Server settings |

---

### **📁 Server Files** (`media/lua/server/`)
Server-only code with authority over all state changes.

#### **`VehicleClaim_ServerCommands.lua`**
**Purpose:** Authoritative command processor, state manager, and vehicle load synchronizer.

**Key Responsibilities:**
- **Receive client commands** via `onClientCommand()`
- **Validate all requests**:
  - Verify Steam ID matches requesting player
  - Check proximity (player within 4 tiles of vehicle)
  - Validate ownership for protected actions
  - Enforce claim limits (using global registry for accurate count)
- **Execute state changes**:
  - Update global registry (ModData) as authoritative source
  - Sync vehicle ModData from registry
  - Add/remove allowed players
  - Release claims (local and remote)
  - Contest abandoned vehicle claims
  - Admin-level bulk operations
- **Send responses** back to clients with claim data
- **Broadcast changes** via `vehicle:transmitModData()`
- **Synchronize on vehicle load** - checks registry vs. ModData when vehicles are created/loaded

**Command Handlers:**

| Handler | Command | Purpose |
|---------|---------|---------|
| `handleClaimVehicle` | `claimVehicle` | Claim an unclaimed vehicle (proximity required) |
| `handleReleaseClaim` | `releaseClaim` | Release own claim (proximity required) |
| `handleReleaseClaimRemote` | `releaseClaimRemote` | Release own claim from any distance |
| `handleContestClaim` | `contestClaim` | Contest an abandoned vehicle's claim (proximity required) |
| `handleAddPlayer` | `addAllowedPlayer` | Grant access to another player (proximity required) |
| `handleRemovePlayer` | `removeAllowedPlayer` | Revoke player access (proximity required) |
| `handleRequestInfo` | `requestVehicleInfo` | Deprecated - clients read ModData directly |
| `handleRequestMyClaims` | `requestMyClaims` | Get all player's claims from global registry |
| `handleAdminClearAllClaims` | `adminClearAllClaims` | Admin: clear ALL claims server-wide |
| `handleConsolidateClaims` | `consolidateClaims` | Admin: consolidate claims into registry |

**Vehicle Load Synchronization:**
```
Vehicle spawns/loads → syncVehicleClaimOnLoad()
  → Has claim ModData? → Check global registry
    → In registry: update position
    → NOT in registry: clear stale ModData (was remotely unclaimed)
```

**Data Flow:**
```
Global Registry (Server ModData) → Server Response Events → Client Events → UI
                                         ↓
                                  Vehicle ModData (sync layer via transmitModData)
```

**Server-Side Event Registration:**
- `Events.OnClientCommand.Add()` - command router
- `Events.OnSpawnVehicleStart.Add()` - vehicle load synchronization
- `Events.OnEnterVehicle.Add()` - vehicle entry enforcement

---

### **📁 Client Files** (`media/lua/client/`)
Client-side UI, context menus, enforcement hooks, and server response handling.

#### **`VehicleClaim_ContextMenu.lua`**
**Purpose:** Right-click context menu integration and timed action definitions.

**Timed Actions Defined:**
- `ISClaimVehicleAction` - Claim an unclaimed vehicle (~2 seconds, Loot animation)
- `ISReleaseVehicleClaimAction` - Release your own claim (~1 second, Loot animation)
- `ISContestVehicleClaimAction` - Contest an abandoned vehicle's claim (~2 seconds, Loot animation)

**Responsibilities:**
- Detect vehicle under cursor
- Show appropriate menu options based on claim state
- Queue timed actions for claiming/releasing/contesting
- Open management panels

**Security Note:** Only **initiates requests**. Does not modify state directly.

#### **`VehicleClaim_MechanicsUI.lua`** ⭐ (Event-Driven Integration)
**Purpose:** Embed claim info and controls directly in the vehicle mechanics window.

**Architecture:**
- Hooks `ISVehicleMechanics.createChildren()` to inject `ISVehicleClaimInfoPanel`
- Panel positioned at bottom-right of mechanics window (300x180px)
- Window height extended by 180px to accommodate the panel
- **Event-driven updates** - no polling or manual refresh needed
- Subscribes to custom events for reactive UI updates

**Panel Features:**
- Real-time claim status display (status, owner, last seen in real-world time)
- Quick action buttons:
  - **Unclaimed**: "Claim This Vehicle" button
  - **Owner/Admin**: "Release Claim" + "Manage Access" buttons
  - **Non-owner, abandoned**: "Contest Vehicle Claim" button (when vehicle exceeds abandoned threshold)
  - **Non-owner, active**: No action buttons
- Vehicle hash display for identification
- Loading indicator during pending actions

**Event Subscriptions:**
```lua
Events.OnVehicleClaimChanged.Add(handler)        -- Reacts to claims
Events.OnVehicleClaimReleased.Add(handler)       -- Reacts to releases
Events.OnVehicleClaimAccessChanged.Add(handler)  -- Reacts to access changes
Events.OnVehicleInfoReceived.Add(handler)        -- Reacts to info queries
Events.OnVehicleHashGenerated.Add(handler)       -- Reacts to hash generation
```

**Vehicle Detection:**
- `update()` monitors `self.parent.vehicle` for changes
- Auto-generates hash on first inspection if vehicle has no hash
- Triggers `OnVehicleHashGenerated` event when hash is created

**Security Note:** Panel reads from vehicle ModData directly (single source of truth). Server confirms all actions.

#### **`VehicleClaim_ClientCommands.lua`**
**Purpose:** Handle server responses and dispatch custom events for reactive UI updates.

**Custom Events Registered:**
```lua
LuaEventManager.AddEvent("OnVehicleClaimSuccess")
LuaEventManager.AddEvent("OnVehicleClaimChanged")
LuaEventManager.AddEvent("OnVehicleClaimReleased")
LuaEventManager.AddEvent("OnVehicleClaimAccessChanged")
LuaEventManager.AddEvent("OnVehicleInfoReceived")
LuaEventManager.AddEvent("OnVehicleHashGenerated")
```

**Response Handlers:**

| Handler | Trigger | Actions |
|---------|---------|---------|
| `onClaimSuccess` | Vehicle claimed | Display notification, trigger `OnVehicleClaimChanged` |
| `onClaimFailed` | Claim denied | Display localized error (supports abandoned contest errors) |
| `onReleaseSuccess` | Claim released | Display notification, trigger `OnVehicleClaimReleased`, close mechanics UI |
| `onPlayerAdded` | Access granted | Display notification, trigger `OnVehicleClaimAccessChanged` |
| `onPlayerRemoved` | Access revoked | Display notification, trigger `OnVehicleClaimAccessChanged` |
| `onAccessDenied` | Permission denied | Display denial message with owner name |
| `onVehicleInfo` | Info response | Deprecated - triggers `OnVehicleInfoReceived` for compatibility |
| `onMyClaims` | Claims list response | Cache claims data, refresh open panels |
| `onAdminClearAllSuccess` | Admin clear completed | Display statistics (claims removed, players affected) |

**Client Request Helpers:**
- `requestMyClaims(callback)` - Request all player's claims from registry
- `addPlayer(vehicle, targetPlayerName)` - Request to add player access
- `removePlayer(vehicle, targetSteamID)` - Request to remove player access
- `requestVehicleInfo(vehicle, callback)` - Deprecated (reads ModData directly)

**Panel Registry:**
- `VehicleClaimClient.openPanels` - tracks open UI panels
- `registerPanel()` / `unregisterPanel()` - panel lifecycle management
- `refreshOpenPanels()` - refresh all registered panels on data changes

**Important:** This file **receives** data from server but never modifies vehicle state locally.

#### **`VehicleClaim_Enforcement.lua`** ⭐ (Build 42 Compatible)
**Purpose:** Comprehensive client-side interaction blocking for claimed vehicles.

**Architecture:**
- Hooks are initialized via `OnGameStart` event to ensure all Build 42 classes are loaded
- Uses `.isValid()` method hooks instead of `.new()` constructor hooks (except for `ISVehicleMechanics.new` which blocks panel creation)
- Central `hasAccess()` function determines authorization
- Reads directly from vehicle ModData (single source of truth)

**CRITICAL: Why `.isValid()` instead of `.new()`:**
```lua
-- ❌ WRONG: Returning nil from .new() breaks ALL actions
ISUninstallVehiclePart.new = function(...)
    if not hasAccess(...) then return nil end  -- BREAKS GAME!
    return original_new(...)
end

-- ✅ CORRECT: Returning false from .isValid() gracefully cancels
ISUninstallVehiclePart.isValid = function(self)
    if not hasAccess(...) then return false end  -- Works correctly
    return original_isValid(self)
end
```

**Access Control:**
```lua
VehicleClaimEnforcement.hasAccess(player, vehicle)
-- Returns true if:
--   • Vehicle has no ModData yet (DENY until loaded)
--   • Vehicle is not claimed (no claim data)
--   • Player is the owner (Steam ID match)
--   • Player is in allowed players list
--   • Player is an admin or moderator
```

**Hooks Implemented:**

| Hook Function | Target | Purpose |
|--------------|--------|---------|
| `hookVehicleEntry` | `ISVehicleMenu.onEnter` | Block entering claimed vehicles |
| `hookMechanicsPanel` | `ISVehicleMechanics.new` | Block V key mechanics panel |
| `hookVehiclePartActions` | `ISInstallVehiclePart.isValid`, `ISUninstallVehiclePart.isValid`, `ISRepairVehiclePartAction.isValid`, `ISTakeGasFromVehicle.isValid`, `ISAddGasFromPump.isValid` | Block part install/uninstall/repair and gas actions |
| `hookTimedActions` | `ISBaseTimedAction.isValid`, `.perform` | Generic timed action blocking |
| `hookInventoryTransfer` | `ISInventoryTransferAction.isValid` | Block trunk/container access |
| `hookSmashWindow` | `ISVehicleMenu.onSmashWindow` | Block window smashing |
| `hookRadialMenu` | `ISVehicleMenu.onMechanic` | Block gamepad/controller radial menu |
| `hookSiphonGas` | `ISVehicleMenu.onSiphonGas` | Block gas siphon menu |
| `hookHotwire` | `ISVehicleMenu.onHotwire` | Block hotwiring |
| `hookLockDoors` | `onLockDoor`, `onUnlockDoor` | Block lock/unlock |
| `hookSleepInVehicle` | `ISVehicleMenu.onSleep` | Block sleeping in vehicle |
| `hookTowTrailer` | `ISVehicleMenu.onAttachTrailer` | Block towing/trailer attach (finds nearby claimed vehicles from rear attachment point) |
| `onFillWorldObjectContextMenu` | Event handler | Strip ALL context menu options except claim |
| `onKeyPressed` | Event handler | Block V key for mechanics panel |
| `onKeyPressedInteract` | Event handler | Block E key for hood interaction |
| `onContainerUpdate` | Event handler | Close vehicle containers for unauthorized players |

**Key Event Handlers:**
- `OnFillWorldObjectContextMenu` - Intercepts context menu before display
- `OnKeyPressed` - Intercepts V key and E key before actions
- `OnContainerUpdate` - Closes unauthorized container access
- `OnGameStart` - Initializes all hooks after game loads

**Security Note:** Client-side enforcement is **UX only**. Server still validates all actions. Modded clients cannot bypass server checks, they just won't see the blocking UI.

---

### **📁 Client UI Files** (`media/lua/client/ui/`)
ISUI-based panels for vehicle management.

#### **`ISVehicleClaimPanel.lua`**
**Purpose:** Management panel for a single vehicle.

**Features:**
- Display vehicle owner, claim time, and last seen info
- List allowed players with scrolling list
- Add/remove player access (proximity required; uses vehicle hash)
- Release claim with confirmation dialog:
  - **Nearby vehicle**: Standard release with timed action
  - **Far/unloaded vehicle**: Remote release via `releaseClaimRemote` command
- Event-driven auto-refresh via `OnVehicleClaimAccessChanged` and `OnVehicleClaimReleased`
- Works with both loaded vehicles (from context menu) and unloaded vehicles (from list panel with cached data)

**Panel Size:** 400x500px with move-with-mouse support

**Data Flow:**
- Reads claim data from vehicle ModData when vehicle is loaded
- Falls back to server-cached claim data when vehicle is unloaded
- Sends modification requests to server via `sendClientCommand()`
- Refreshes on server response via event listeners and panel registry

#### **`ISVehicleClaimListPanel.lua`**
**Purpose:** List all vehicles claimed by the current player.

**Features:**
- Shows ALL player's vehicles, even when not loaded (far away)
- Display claim count vs. limit (e.g., "Vehicles: 3 / 3")
- Loaded vehicles show distance in meters
- Shows vehicle name with last known coordinates
- Quick access to individual vehicle management via "Manage" button
- Cache-based refresh with 30-second expiry (requests from server when expired)
- Event-driven updates via `OnVehicleClaimChanged`, `OnVehicleClaimReleased`, `OnVehicleClaimAccessChanged`

**Panel Size:** 500x480px with scrolling list (300px height, 30px item height)

**Data Source:** Server-side Global Claim Registry (not local cell scan)

**Why Global Registry?**
- Vehicles outside loaded area don't exist in `cell:getVehicles()`
- Server maintains a persistent registry of ALL claims
- Client requests claim list from server, not local scan
- Allows players to see and manage vehicles across the entire map

#### **`VehicleClaim_PlayerMenu.lua`**
**Purpose:** Add "My Vehicles" and admin options to the right-click context menu.

**Functionality:**
- Adds "My Vehicles" option to **any** right-click context menu (not just self-menu)
- Opens `ISVehicleClaimListPanel` on click
- **Admin-only**: Adds "[ADMIN] Clear All Vehicle Claims" option
  - Shows confirmation modal with warning text
  - Sends `adminClearAllClaims` command to server on confirm

---

## Event-Driven UI Architecture

### **Custom Events**
The system uses LuaEventManager custom events for reactive UI updates:

| Event | Trigger | Parameters | Purpose |
|-------|---------|------------|----------|
| `OnVehicleClaimSuccess` | Vehicle claimed | `vehicleHash`, `claimData` | Initial claim notification |
| `OnVehicleClaimChanged` | Vehicle claimed or modified | `vehicleHash`, `claimData` | Update UI to show new owner/access |
| `OnVehicleClaimReleased` | Vehicle unclaimed | `vehicleHash`, `nil` | Update UI to show available |
| `OnVehicleClaimAccessChanged` | Access list modified | `vehicleHash`, `claimData` | Update UI to show new access list |
| `OnVehicleInfoReceived` | Info query response | `vehicleHash`, `claimData` | Populate UI with vehicle data (deprecated) |
| `OnVehicleHashGenerated` | Hash created for vehicle | `vehicleHash`, `vehicle` | Update hash display in UI |

### **Event Flow**
```
1. Server sends response with claim data
2. Client handler receives response
3. Client triggers custom event
4. All subscribed UI components receive event
5. Each component checks if event is for their vehicle
6. Matching components update immediately from ModData
```

### **Benefits**
- ✅ **No Polling:** UI doesn't spam server with requests
- ✅ **Instant Updates:** Changes propagate immediately
- ✅ **Consistent Data:** All UI reads from vehicle ModData (single source of truth)
- ✅ **Minimal Traffic:** Server sends data only when changed
- ✅ **Scalable:** Adding new UI components just subscribes to events

---

## Global Claim Registry

### **Purpose**
The Global Claim Registry solves the problem of vehicles not appearing in the player's list when they're far away (unloaded). It maintains a server-side record of all claims that persists regardless of vehicle loading state.

### **Storage**
```lua
ModData.getOrCreate("VehicleClaimRegistry")
-- Structure:
{
    claims = {
        ["VH0000000000"] = {
            vehicleHash = "VH0000000000",
            ownerSteamID = "76561198...",
            ownerName = "PlayerName",
            vehicleName = "Chevalier Dart",
            x = 10234,
            y = 8567,
            claimTime = 12345,
            allowedPlayers = { ["76561198YYY"] = "FriendName" }
        }
    }
}
```

### **Synchronization**
- Server updates registry on claim/release/access changes
- Clients request their claims via `requestMyClaims`
- Server responds with `myClaims` containing all player's claims
- Vehicle list panel uses this data instead of local cell scan
- **Vehicle load sync**: When vehicles load, server checks registry vs. ModData and clears stale claims

### **Remote Unclaiming**
When a player releases a vehicle remotely:
1. Registry entry is removed immediately
2. If vehicle is loaded, ModData is cleared immediately
3. If vehicle is not loaded, ModData will be cleared via `syncVehicleClaimOnLoad()` when the vehicle next loads

### **Benefits**
- ✅ See all vehicles regardless of distance
- ✅ Track vehicle last known position
- ✅ Accurate claim count even with unloaded vehicles
- ✅ Works across server restarts (persisted in ModData)
- ✅ Allowed players list synced to registry for display when unloaded
- ✅ Stale claims auto-cleaned on vehicle load

---

## Abandoned Vehicle Contest System

### **Purpose**
Allows players to contest (take over) claims on vehicles that have been abandoned by their owners for a configurable number of real-world days.

### **How It Works**
1. Every time the owner (or an allowed player) enters a claimed vehicle, the `lastSeenTimestamp` is updated
2. The system converts in-game time to real-world time: **16 in-game days = 1 real-world day**
3. When a non-owner approaches a claimed vehicle and opens the mechanics panel, the system checks if the vehicle is abandoned
4. If `realWorldDaysSinceLastSeen >= AbandonedDaysThreshold`, a "Contest Vehicle Claim" button appears
5. Contesting uses a timed action and sends `contestClaim` to the server
6. Server validates abandonment, then clears the claim (both ModData and registry)

### **Configuration**
```
option VehicleClaimSystem.AbandonedDaysThreshold
{
    type = integer, min = 0, max = 90, default = 7
}
```
- Set to `0` to disable (contest button always available for testing)
- Set higher to protect claims longer
- Threshold is in **real-world days** (24-hour periods)

### **Server Validation**
The server independently re-checks:
- Player proximity
- Vehicle is actually claimed
- Player is NOT the owner (owners should use normal release)
- Vehicle meets the abandoned threshold

---

## Client-Server Communication Flow

### **Command Types**

#### **Client → Server Commands**
Defined in `VehicleClaim.CMD_*` constants:

| Command | Purpose | Validation Required |
|---------|---------|-------------------|
| `claimVehicle` | Request to claim a vehicle | Proximity, not already claimed, under limit |
| `releaseClaim` | Release ownership (nearby) | Ownership or admin, proximity |
| `releaseClaimRemote` | Release ownership (any distance) | Ownership or admin |
| `contestClaim` | Contest an abandoned claim | Proximity, not owner, vehicle abandoned |
| `addAllowedPlayer` | Grant access to player | Ownership or admin, proximity |
| `removeAllowedPlayer` | Revoke access | Ownership or admin, proximity |
| `requestVehicleInfo` | Query vehicle details (deprecated) | None |
| `requestMyClaims` | Get all player's claims from registry | Steam ID verification |
| `adminClearAllClaims` | Clear ALL claims server-wide | Admin only |
| `consolidateClaims` | Consolidate claims into registry | Admin only |

#### **Server → Client Responses**
Defined in `VehicleClaim.RESP_*` constants:

| Response | Purpose |
|----------|---------|
| `claimSuccess` | Claim approved (includes claimData) |
| `claimFailed` | Claim denied (with reason code) |
| `releaseSuccess` | Release approved (includes `contested` flag if applicable) |
| `playerAdded` | Access granted (includes full claimData) |
| `playerRemoved` | Access revoked (includes full claimData) |
| `accessDenied` | Permission denied (with action and owner name) |
| `vehicleInfo` | Vehicle data response (deprecated) |
| `myClaims` | List of all player's claims from registry |
| `adminClearAllSuccess` | Admin clear completed (with statistics) |

### **Example: Claiming a Vehicle**

```lua
// 1. PLAYER OPENS MECHANICS WINDOW (V KEY)
ISVehicleMechanics.createChildren()
  → ISVehicleClaimInfoPanel embedded at bottom
  → Panel reads vehicle ModData, shows "Unclaimed" + "Claim" button

// 2. PLAYER CLICKS "CLAIM THIS VEHICLE"
ISVehicleClaimInfoPanel:onActionButton()
  → Creates ISClaimVehicleAction (timed action)
  → Action performs after ~2 seconds with Loot animation

// 3. TIMED ACTION COMPLETES (CLIENT)
ISClaimVehicleAction:perform()
  → sendClientCommand(player, "VehicleClaim", "claimVehicle", {
      vehicleHash = "VH0000000000",
      steamID = "76561198...",
      playerName = "Player"
    })

// 4. SERVER RECEIVES COMMAND
VehicleClaimServer.onClientCommand()
  → handleClaimVehicle(player, args)
    → VALIDATE steamID matches player ✓
    → VALIDATE player within 4 tiles ✓
    → VALIDATE vehicle not claimed (reads ModData) ✓
    → VALIDATE player under claim limit (uses registry count) ✓
    → initializeClaimData(vehicle, steamID, playerName)
    → Write to ModData + add to global registry
    → vehicle:transmitModData()

// 5. SERVER SENDS RESPONSE
sendServerCommand(player, "VehicleClaim", "claimSuccess", {
    vehicleHash = hash,
    claimData = {...}
})

// 6. CLIENT RECEIVES RESPONSE (EVENT-DRIVEN)
VehicleClaimClient.onClaimSuccess(args)
  → player:Say("Successfully claimed vehicle: VH0000000000")
  → triggerEvent("OnVehicleClaimChanged", vehicleHash, claimData)

// 7. ALL UI COMPONENTS REACT TO EVENT
ISVehicleClaimInfoPanel.onClaimChangedHandler()
  → self:updateInfo(claimData)  // Shows "Claimed", owner, release button

// 8. VEHICLE MODDATA SYNCED (background)
Vehicle ModData synced by game engine to all clients
  → Enforcement checks activate for other players
  → Context menus update for other players
```

---

## Data Storage

### **Vehicle ModData Structure**

Claim data is stored in each vehicle's ModData under the key `"VehicleClaimData"`:

```lua
vehicle:getModData()["VehicleClaimData"] = {
    ownerSteamID = "76561198XXXXXXXX",
    ownerName = "PlayerName",
    vehicleName = "Chevalier Dart",
    allowedPlayers = {
        ["76561198YYYYYYYY"] = "AllowedPlayer1",
        ["76561198ZZZZZZZZ"] = "AllowedPlayer2"
    },
    claimTimestamp = 12345,      -- Game minutes since start
    lastSeenTimestamp = 12346,   -- Updated on vehicle entry (5-minute debounce)
    vehicleHash = "VH0000000000" -- Persistent unique identifier
}
```

Additionally, the vehicle hash is stored at the top level of ModData for faster access:
```lua
vehicle:getModData()["vehicleHash"] = "VH0000000000"
```

**Persistence:** ModData is saved with the vehicle in the world save. Claims persist across server restarts.

**Sync:** Changes trigger `vehicle:transmitModData()`, which the game engine automatically broadcasts to all clients.

**Last Seen Debounce:** `updateLastSeen()` only writes to ModData if at least 5 minutes have passed since the last update, reducing unnecessary network traffic.

---

## Error Handling & Validation

### **Error Codes**
Defined in `VehicleClaim.ERR_*` constants:

| Error Code | Meaning | Trigger |
|------------|---------|---------|
| `vehicleNotFound` | Vehicle doesn't exist | Invalid vehicle hash |
| `alreadyClaimed` | Vehicle has owner | Claim attempt on owned vehicle |
| `notOwner` | Insufficient permissions | Non-owner tries to modify |
| `tooFar` | Out of range | Distance > 4 tiles |
| `playerNotFound` | Target player offline | Add player with invalid name |
| `claimLimitReached` | Max vehicles claimed | Exceeds sandbox limit |
| `notAdmin` | Admin privileges required | Non-admin tries admin command |
| `vehicleNotLoaded` | Vehicle not in loaded cells | Release/modify while vehicle is far |
| `vehicleNotClaimed` | Vehicle has no claim data | Release/contest unclaimed vehicle |
| `initializationFailed` | Claim setup error | Hash or ModData creation failed |

**Contest-Specific Errors:**
| Error | Meaning |
|-------|---------|
| `vehicleNotAbandoned` | Vehicle hasn't exceeded abandoned threshold (includes days remaining) |
| `cannotContestOwnVehicle` | Owner tried to contest their own vehicle |

### **Validation Layers**

#### **Layer 1: Client Pre-Check (UX)**
- Context menu checks claim state before showing options
- Mechanics UI shows appropriate buttons based on ownership and abandoned status
- Enforcement hooks prevent interactions without server round-trip

**Purpose:** Fast feedback to player
**Security:** Bypassable by modded clients (doesn't matter - server validates)

#### **Layer 2: Server Validation (Authority)**
- Every command re-validates all conditions
- Steam ID verification against requesting player
- Proximity checks (except for remote release)
- Ownership verification
- Claim limit enforcement (uses registry count, not cell scan)
- Abandoned threshold validation for contest commands

**Purpose:** Actual security
**Security:** Cannot be bypassed

#### **Layer 3: Response Handling (Feedback)**
- Client displays appropriate localized error messages
- UI updates based on actual server state via events
- Graceful degradation on failures

**Purpose:** User experience
**Security:** N/A (informational only)

---

## Sandbox Configuration

### **`sandbox-options.txt`**
Defines server-configurable settings:

```
option VehicleClaimSystem.MaxClaimsPerPlayer
{
    type = integer,
    min = 1,
    max = 20,
    default = 3,
    page = VehicleClaimSystem,
    translation = VehicleClaimSystem_MaxClaimsPerPlayer,
}

option VehicleClaimSystem.AbandonedDaysThreshold
{
    type = integer,
    min = 0,
    max = 90,
    default = 7,
    page = VehicleClaimSystem,
    translation = VehicleClaimSystem_AbandonedDaysThreshold,
}
```

**MaxClaimsPerPlayer:** Maximum number of vehicles a player can claim (default: 3, max: 20).
**AbandonedDaysThreshold:** Real-world days of inactivity before other players can contest the claim (default: 7, set to 0 to disable).

**Access in code:**
```lua
local maxClaims = SandboxVars.VehicleClaimSystem.MaxClaimsPerPlayer
local abandonedDays = SandboxVars.VehicleClaimSystem.AbandonedDaysThreshold
```

**Server Authority:** Only server reads sandbox vars for enforcement. Clients read for display purposes only.

---

## Security Summary

### **What Prevents Cheating?**

1. **Server-Side Validation**: Every state change validated by server
2. **Steam ID Verification**: Server checks player identity on every command
3. **ModData as Source of Truth**: Only server modifies ModData, clients receive sync
4. **Proximity Enforcement**: Server calculates distances, not client (4 tiles for most actions)
5. **No Client Trust**: Client requests are suggestions, server decides
6. **Read-Only Shared Code**: Shared utilities don't modify state
7. **Claim Limit Enforcement**: Server tracks and enforces via global registry count
8. **Vehicle Load Sync**: Stale claims auto-cleaned when vehicles load

### **What Can Modded Clients NOT Do?**

❌ Claim vehicles without server approval
❌ Bypass proximity checks
❌ Modify other players' vehicles
❌ Exceed claim limits
❌ Grant themselves access to others' vehicles
❌ Fake Steam IDs
❌ Modify synced ModData directly
❌ Skip abandoned vehicle threshold checks
❌ Execute admin commands without admin access

### **What Can Modded Clients Do?**

✅ See local UI earlier (cosmetic only)
✅ Send invalid requests (server rejects them)
✅ Skip client-side enforcement (server still blocks)

**Result:** Modded clients gain no actual advantage. All security is server-side.

---

## Key Design Patterns

### **1. Command-Response Pattern**
```
Client: sendClientCommand("claimVehicle", {data})
Server: validates → executes → sendServerCommand("claimSuccess", {result})
Client: receives response → triggers event → UI updates
```

### **2. Timed Actions**
```
Player initiates action → ISClaimVehicleAction queues
→ ~2 second delay with Loot animation
→ Action completes → sends server command
```

**Purpose:** Realistic timing, prevents spam, cancellable actions

### **3. ModData as Single Source of Truth**
```
Server: vehicle:getModData()[key] = value
Server: vehicle:transmitModData()
Game Engine: broadcasts to all clients automatically
Clients: read vehicle:getModData()[key] directly (no caching layer)
```

**Purpose:** Reliable state sync without manual network code or client-side cache staleness

### **4. Defensive Programming**
- Always check if player/vehicle exists before operations
- Validate Steam IDs match
- Re-check conditions on server even if client checked
- Graceful degradation on missing data
- `pcall()` wrapping for potentially missing methods (e.g., `container.getVehicle`)

### **5. Hook Pattern (Build 42 Compatible)**
```lua
-- Store original function
local original_isValid = ISUninstallVehiclePart.isValid

-- Replace with wrapped version
ISUninstallVehiclePart.isValid = function(self)
    if self.vehicle and not VehicleClaimEnforcement.hasAccess(self.character, self.vehicle) then
        self.character:Say(VehicleClaimEnforcement.getDenialMessage(self.vehicle))
        return false  -- Gracefully cancel action
    end
    return original_isValid(self)  -- Call original
end
```

**Purpose:** Intercept vanilla functions while preserving original behavior

### **6. Event-Driven UI Pattern**
```lua
-- Subscribe to custom events in panel initialization
Events.OnVehicleClaimChanged.Add(self.onClaimChangedHandler)

-- Event handler checks if event is for this vehicle
self.onClaimChangedHandler = function(vehicleHash, claimData)
    if currentHash == vehicleHash then
        self:updateInfo(claimData)  -- React to change
    end
end

-- Cleanup on panel close
Events.OnVehicleClaimChanged.Remove(self.onClaimChangedHandler)
```

**Purpose:** Reactive UI updates without polling or manual refresh loops

### **7. Vehicle Load Synchronization**
```lua
Events.OnSpawnVehicleStart.Add(function(vehicle)
    -- Check if vehicle has claim ModData but no registry entry
    -- If so, the claim was remotely removed - clear stale ModData
end)
```

**Purpose:** Ensure remote unclaims propagate to vehicle ModData when vehicles load

---

## Testing Checklist

### **Functionality**
- ✅ Can claim unclaimed vehicle within range (4 tiles)
- ✅ Cannot claim vehicle outside range
- ✅ Cannot claim already-claimed vehicle
- ✅ Cannot exceed claim limit (checked via registry)
- ✅ Can release own vehicle when nearby (timed action)
- ✅ Can release own vehicle remotely (from vehicle list panel)
- ✅ Cannot release other player's vehicle
- ✅ Can add/remove allowed players (proximity required)
- ✅ Allowed players can use vehicle
- ✅ Non-allowed players blocked from vehicle

### **Abandoned Vehicle Contest**
- ✅ Contest button appears when vehicle exceeds abandoned threshold
- ✅ Contest button hidden when vehicle is active
- ✅ Cannot contest own vehicle
- ✅ Server validates abandoned status independently
- ✅ Setting threshold to 0 makes all claimed vehicles contestable
- ✅ Time conversion: 16 in-game days = 1 real-world day

### **Admin Tools**
- ✅ Admin can see "Clear All Vehicle Claims" option
- ✅ Non-admins cannot see admin option
- ✅ Confirmation dialog prevents accidental clears
- ✅ Admin receives statistics after clear (claims, vehicles, players)
- ✅ Server rejects admin commands from non-admins

### **Security**
- ✅ Server validates all commands
- ✅ Steam ID mismatches rejected
- ✅ Proximity checked server-side for claims and modifications
- ✅ Claim limit enforced server-side (registry count)
- ✅ ModData changes require ownership
- ✅ Admin commands require admin access level

### **UI**
- ✅ Context menu shows correct options
- ✅ **Mechanics window (V key) shows embedded claim panel**
- ✅ **Claim panel updates instantly on claim/release/contest (event-driven)**
- ✅ **Can claim/release/contest directly from mechanics window**
- ✅ **Unclaiming and re-claiming works without reopening UI**
- ✅ Vehicle list shows all claimed vehicles (even unloaded)
- ✅ Vehicle list shows distance for loaded vehicles
- ✅ Management panel supports remote release for far/unloaded vehicles
- ✅ Error messages display properly in correct language
- ✅ "My Vehicles" option available from any right-click
- ✅ Vehicle hash displayed in mechanics panel

### **Enforcement (Build 42)**
- ✅ Cannot enter claimed vehicle (door blocking)
- ✅ Cannot open mechanics panel (V key blocked)
- ✅ Cannot access hood via E key
- ✅ Cannot install/uninstall parts
- ✅ Cannot repair parts
- ✅ Cannot siphon gas or refuel
- ✅ Cannot smash windows
- ✅ Cannot hotwire
- ✅ Cannot lock/unlock doors
- ✅ Cannot sleep in vehicle
- ✅ Cannot transfer items from trunk/containers
- ✅ Cannot attach trailer to claimed vehicle (rear attachment point check)
- ✅ Context menu stripped of all vehicle actions (except claim-related)
- ✅ Radial menu (gamepad) blocked for mechanics
- ✅ Vehicle containers auto-closed for unauthorized players

### **Vehicle Load Synchronization**
- ✅ Remotely unclaimed vehicles have ModData cleared on load
- ✅ Vehicle positions updated in registry on load
- ✅ No crash if vehicle has claim data but no hash

### **Global Registry**
- ✅ Vehicles appear in list even when far away (unloaded)
- ✅ Claim count accurate for all vehicles
- ✅ Last known position shows for unloaded vehicles
- ✅ Allowed players list synced in registry
- ✅ Registry persists across server restarts
- ✅ Registry updates on claim/release/access changes

### **Multi-Language**
- ✅ English text displays correctly
- ✅ Brazilian Portuguese text displays correctly
- ✅ Russian text displays correctly
- ✅ getText() resolves all translation keys
- ✅ Error messages localized (including abandoned vehicle messages)
- ✅ Sandbox options translated in all languages

---

## Build 42 API Notes

### **Important Classes**
These are the timed action classes used in Build 42:
- `ISOpenVehicleDoor` - Opening vehicle doors
- `ISInstallVehiclePart` - Installing parts
- `ISUninstallVehiclePart` - Removing parts
- `ISRepairVehiclePartAction` - Repairing parts
- `ISTakeGasFromVehicle` - Siphoning gas
- `ISAddGasFromPump` - Refueling from pump
- `ISVehicleMechanics` - Mechanics panel UI
- `ISInventoryTransferAction` - Item transfers (trunk access)

### **Vehicle Type**
In Build 42, use `BaseVehicle` instead of `IsoVehicle`:
```lua
local vehicleObj = instanceof(action.vehicle, "BaseVehicle") and action.vehicle
```

### **Deferred Hook Initialization**
Hooks must be initialized via `OnGameStart` event, not at load time:
```lua
Events.OnGameStart.Add(function()
    -- Initialize hooks here after all classes are loaded
    initializeHooks()
end)
```

### **Vehicle Spawn Hook**
Vehicle load synchronization uses `OnSpawnVehicleStart`:
```lua
Events.OnSpawnVehicleStart.Add(function(vehicle)
    syncVehicleClaimOnLoad(vehicle)
end)
```

---

## Future Expansion Ideas

- **Faction Integration**: Faction-wide vehicle pools
- **Key System**: Physical keys required for access
- **Break-In Mechanics**: Allow lockpicking with cooldown/alerts
- **Vehicle Insurance**: Pay in-game currency to protect claims
- **Claim Transfer**: Transfer ownership to another player

---

## Contributing

When modifying this system, remember:
1. **Never trust the client** - validate everything server-side
2. **Use ModData for persistence** - it's automatically saved and synced
3. **Follow command-response pattern** - keep client-server communication clear
4. **Test with multiple players** - ensure sync works correctly
5. **Log important events** - use `VehicleClaim.log()` for debugging
6. **Use `.isValid()` hooks** - never return nil from `.new()` constructors (except ISVehicleMechanics)
7. **Initialize hooks on OnGameStart** - ensure Build 42 classes are loaded first
8. **Update all three language files** - EN, PTBR, and RU translations
9. **Update the global registry** - keep registry in sync with ModData changes (allowed players, positions)
10. **Test remote unclaiming** - ensure vehicle load sync clears stale ModData

---

## Known Issues & Solutions

### **Problem: Returning nil from .new() breaks actions**
**Symptom:** After adding hooks, unrelated actions (like radio removal) stop working.

**Cause:** Returning `nil` from a `.new()` constructor breaks the game's action queue system because it expects a valid action object.

**Solution:** Hook `.isValid()` instead and return `false` to gracefully cancel:
```lua
-- ✅ Correct approach
ISUninstallVehiclePart.isValid = function(self)
    if not hasAccess(self.vehicle) then return false end
    return original(self)
end
```

**Exception:** `ISVehicleMechanics.new` returns `nil` to block the panel entirely, which is acceptable because it's a UI element, not a timed action.

### **Problem: Hooks not working on game start**
**Symptom:** Enforcement doesn't activate until reconnecting.

**Cause:** Hooks are being set before Build 42 classes are fully loaded.

**Solution:** Initialize all hooks in `OnGameStart` event handler.

### **Problem: Stale claims after remote unclaim**
**Symptom:** Vehicle still appears claimed after remote release until player gets close.

**Cause:** Vehicle ModData can only be cleared when the vehicle is loaded.

**Solution:** `syncVehicleClaimOnLoad()` runs on `OnSpawnVehicleStart` and checks registry. If claim is not in registry, ModData is cleared automatically.

### **Problem: Last seen updating too frequently**
**Symptom:** Excessive ModData transmissions when owner uses vehicle.

**Cause:** `updateLastSeen()` was called on every interaction.

**Solution:** 5-minute debounce - only updates if at least 5 minutes have passed since last update.

---

## License

This mod is provided as-is for Project Zomboid servers. Modify and distribute freely with attribution.