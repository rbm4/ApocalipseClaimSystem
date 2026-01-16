# ApocalipseClaimSystem - Vehicle Claim System

## Technical Documentation

A secure, server-authoritative vehicle ownership system for Project Zomboid multiplayer servers.

### Build Compatibility
**Tested and compatible with:** Project Zomboid Build 42.13.1

### Multi-Language Support
The system supports multiple languages with automatic detection:
- **Brazilian Portuguese (PT)** - Primary language (baseline)
- **English (EN)** - Secondary language

Translation files: `media/lua/shared/Translate/PT/UI_PT.txt` and `media/lua/shared/Translate/EN/UI_EN.txt`

## Overview

This mod implements a robust vehicle claiming system with proper client-server architecture, preventing cheating through server-side validation and providing a clean UI for vehicle management.

---

## Architecture Philosophy

### **Server-Authoritative Design**
All critical operations (claiming, releasing, access control) are validated and executed **exclusively on the server**. Clients send requests, but the server has final authority over all state changes.

### **Anti-Cheat Measures**
- **Steam ID Verification**: Server validates that the requesting player's Steam ID matches the command
- **Proximity Checks**: Server verifies player is within range before allowing claim actions
- **Ownership Validation**: All modifications require proof of ownership or admin privileges
- **ModData Sync**: Vehicle claim state is stored in vehicle ModData and synchronized by the game engine
- **Client-Side Enforcement**: Comprehensive hooks block unauthorized interactions locally

---

## Quick File Reference

```
Contents/mods/ApocalipseClaimSystem/42.13.1/
├── mod.info
├── media/
│   └── lua/
│       ├── shared/
│       │   ├── VehicleClaim_Shared.lua          # Constants, utilities, claim counting
│       │   └── Translate/
│       │       ├── PT/UI_PT.txt                 # Portuguese translations
│       │       └── EN/UI_EN.txt                 # English translations
│       ├── server/
│       │   └── VehicleClaim_ServerCommands.lua  # Server-side validation & state changes
│       └── client/
           ├── VehicleClaim_ClientCommands.lua  # Server response handling & local cache updates
           ├── VehicleClaim_ContextMenu.lua     # Right-click menu integration
           ├── VehicleClaim_Enforcement.lua     # ⭐ Build 42 interaction blocking
           ├── VehicleClaim_MechanicsUI.lua     # ⭐ Embedded claim UI in mechanics window
│           ├── VehicleClaim_PlayerMenu.lua      # "Meus Veículos" self-menu option
│           └── ui/
│               ├── ISVehicleClaimPanel.lua      # Single vehicle management
│               └── ISVehicleClaimListPanel.lua  # All claimed vehicles list
└── common/
    └── sandbox-options.txt                      # MaxClaimsPerPlayer setting
```

---

## File Structure & Responsibilities

### **📁 Shared Files** (`media/lua/shared/`)
Loaded on both client and server. Contains constants, utilities, and validation helpers.

#### **`VehicleClaim_Shared.lua`**
**Purpose:** Common functionality and constants available to both client and server.

**Key Responsibilities:**
- Define all command/response constants
- Define ModData keys for vehicle storage
- Provide utility functions: `isClaimed()`, `hasAccess()`, `getOwnerID()`, etc.
- Calculate distances and validate proximity
- Read sandbox configuration
- Count player claims and enforce limits
- **Manage local client cache** (`VehicleClaim.claimDataCache`) for performance

**Caching System:**
- Client maintains local cache indexed by vehicle hash
- Cache populated from server events (authoritative source)
- Cache prevents redundant ModData reads
- Event-driven invalidation ensures consistency

**Security Note:** All functions here are read-only or local calculations. No state mutations occur in shared code.

---

### **📁 Translation Files** (`media/lua/shared/Translate/`)

#### **`PT/UI_PT.txt`** (Portuguese - Primary)
Contains all UI strings in Brazilian Portuguese as the baseline language.

#### **`EN/UI_EN.txt`** (English - Secondary)
Contains all UI strings translated to English.

**Translation Keys Used:**
| Key | Purpose |
|-----|---------|
| `UI_VehicleClaim_Title` | Panel title |
| `UI_VehicleClaim_Owner` | Owner label |
| `UI_VehicleClaim_AllowedPlayers` | Allowed players section |
| `UI_VehicleClaim_AddPlayer` | Add player button |
| `UI_VehicleClaim_RemovePlayer` | Remove player button |
| `UI_VehicleClaim_Release` | Release claim button |
| `UI_VehicleClaim_Close` | Close button |
| `UI_VehicleClaim_NoAccess` | Access denied message |
| `UI_VehicleClaim_ClaimSuccess` | Claim success message |
| `UI_VehicleClaim_ReleaseSuccess` | Release success message |
| `UI_VehicleClaim_LimitReached` | Claim limit error |
| `UI_VehicleClaim_MyVehicles` | My vehicles menu |
| `UI_VehicleClaim_Manage` | Manage button |

---

### **📁 Server Files** (`media/lua/server/`)
Server-only code with authority over all state changes.

#### **`VehicleClaim_ServerCommands.lua`**
**Purpose:** Authoritative command processor and state manager.

**Key Responsibilities:**
- **Receive client commands** via `onClientCommand()`
- **Validate all requests**:
  - Verify Steam ID matches requesting player
  - Check proximity (player within 5 tiles of vehicle)
  - Validate ownership for protected actions
  - Enforce claim limits
- **Execute state changes**:
  - Update global registry (ModData) as authoritative source
  - Sync vehicle ModData from registry
  - Add/remove allowed players
  - Release claims
- **Send responses** back to clients with claim data from registry
- **Broadcast changes** via `vehicle:transmitModData()`

**Data Flow (Registry-Authoritative):**
```
Global Registry (Server ModData) → Server Response Events → Client Cache → UI
                                         ↓
                                  Vehicle ModData (sync layer)
```

**Security Flow:**
```
Client Request → Server Validates → Execute if Valid → Update Registry → Sync to Clients
                        ↓
                   (Reject if invalid)
```

**Anti-Cheat Implementation:**
- Every command checks `VehicleClaim.getPlayerSteamID(player)` against `args.steamID`
- Proximity verified server-side using `VehicleClaim.isWithinRange()`
- Ownership checked before allowing modifications
- Claim limit validated before new claims

---

### **📁 Client Files** (`media/lua/client/`)
Client-side UI, context menus, and action queueing.

#### **`VehicleClaim_ContextMenu.lua`**
**Purpose:** Right-click context menu integration for vehicles.

**Responsibilities:**
- Detect vehicle under cursor (with fallback spatial search)
- Show appropriate menu options based on claim state
- Queue timed actions for claiming/releasing
- Open management panels

**Security Note:** Only **initiates requests**. Does not modify state directly.

#### **`VehicleClaim_MechanicsUI.lua`** ⭐ (Event-Driven Integration)
**Purpose:** Embed claim info and controls directly in the vehicle mechanics window.

**Architecture:**
- Hooks `ISVehicleMechanics.createChildren()` to inject claim panel
- Panel positioned at bottom of mechanics window
- **Event-driven updates** - no polling or manual refresh needed
- Subscribes to custom events for reactive UI updates

**Panel Features:**
- Real-time claim status display (owner, last seen, access level)
- Quick action buttons (Claim/Release) with timed actions
- Manage access button for owners
- Vehicle hash display for identification

**Event Subscriptions:**
```lua
Events.OnVehicleClaimChanged.Add(handler)      -- Reacts to claims
Events.OnVehicleClaimReleased.Add(handler)     -- Reacts to releases  
Events.OnVehicleClaimAccessChanged.Add(handler)-- Reacts to access changes
Events.OnVehicleInfoReceived.Add(handler)      -- Reacts to info queries
```

**Event Handler Pattern:**
```lua
self.onClaimChangedHandler = function(vehicleHash, claimData)
    if currentHash == vehicleHash then
        self:updateInfo(claimData)  -- Update UI with fresh data
    end
end
```

**Benefits:**
- ✅ No manual refresh loops
- ✅ Instant updates when claim state changes
- ✅ Minimal network traffic (event-driven)
- ✅ Consistent with mechanics window workflow
- ✅ Cache updated immediately when events fire

**Security Note:** Panel reads from local cache, which is populated by event-driven server responses.

**Vehicle Detection Logic:**
1. Check if clicked object is `IsoVehicle` (direct click)
2. If not found, search clicked square for nearest vehicle
3. Use distance-based selection to find closest vehicle within 5 tiles
4. Verify player proximity before showing menu

#### **`VehicleClaim_ClientCommands.lua`**
**Purpose:** Handle server responses and update local UI with event-driven architecture.

**Responsibilities:**
- Process server command responses
- **Update local cache** with authoritative server data
- **Trigger custom events** for reactive UI updates:
  - `OnVehicleClaimChanged` - Vehicle claimed or modified
  - `OnVehicleClaimReleased` - Vehicle unclaimed
  - `OnVehicleClaimAccessChanged` - Access list modified
  - `OnVehicleInfoReceived` - Vehicle info query response
- Display notifications to player
- Handle success/failure messages with localized text

**Event-Driven Architecture:**
When server sends claim data, the handler:
1. Updates `VehicleClaim.claimDataCache[vehicleHash]` with fresh data
2. Triggers corresponding custom event
3. All subscribed UI components react automatically

**Important:** This file **receives** data from server but never modifies vehicle state locally.

#### **`VehicleClaim_Enforcement.lua`** ⭐ (Build 42.13.1 Rewritten)
**Purpose:** Comprehensive client-side interaction blocking for claimed vehicles.

**Architecture:**
- Hooks are initialized via `OnGameStart` event to ensure all Build 42 classes are loaded
- Uses `.isValid()` method hooks instead of `.new()` constructor hooks
- Central `hasAccess()` function determines authorization

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
--   • Vehicle is not claimed
--   • Player is the owner (Steam ID match)
--   • Player is in allowed players list
--   • Player is an admin (isAdmin())
```

**Hooks Implemented:**

| Hook Function | Target | Purpose |
|--------------|--------|---------|
| `hookVehicleEntry` | `ISVehicleMenu.onEnter` | Block entering claimed vehicles |
| `hookMechanicsPanel` | `ISVehicleMechanics.new` | Block V key mechanics panel |
| `hookVehiclePartActions` | `ISInstallVehiclePart.isValid`, `ISUninstallVehiclePart.isValid`, `ISRepairVehiclePartAction.isValid` | Block part install/uninstall/repair |
| `hookGasActions` | `ISTakeGasFromVehicle.isValid`, `ISAddGasFromPump.isValid` | Block gas siphon/refuel |
| `hookTimedActions` | `ISBaseTimedAction.isValid`, `.perform` | Generic timed action blocking |
| `hookInventoryTransfer` | `ISInventoryTransferAction.isValid` | Block trunk access |
| `hookSmashWindow` | `ISVehicleMenu.onSmashWindow` | Block window smashing |
| `hookSiphonGas` | `ISVehicleMenu.onSiphonGas` | Block gas siphon menu |
| `hookHotwire` | `ISVehicleMenu.onHotwire` | Block hotwiring |
| `hookLockDoors` | `onLockDoor`, `onUnlockDoor` | Block lock/unlock |
| `hookSleepInVehicle` | `ISVehicleMenu.onSleep` | Block sleeping in vehicle |
| `hookTowTrailer` | `ISVehicleMenu.onAttachTrailer`, `onDetachTrailer` | Block towing/trailer attach |
| `onFillWorldObjectContextMenu` | Event handler | Strip ALL context menu options except claim |
| `onKeyPressed` | Event handler | Block V key for mechanics panel |
| `onKeyPressedInteract` | Event handler | Block E key for hood interaction |

**Key Event Handlers:**
- `OnFillWorldObjectContextMenu` - Intercepts context menu before display
- `OnKeyPressed` - Intercepts V key before mechanics panel opens
- `OnKeyStarted` - Intercepts E key before hood interaction starts
- `OnGameStart` - Initializes all hooks after game loads

**Security Note:** Client-side enforcement is **UX only**. Server still validates all actions. Modded clients cannot bypass server checks, they just won't see the blocking UI.

---

### **📁 Client UI Files** (`media/lua/client/ui/`)
ISUI-based panels for vehicle management.

#### **`ISVehicleClaimPanel.lua`**
**Purpose:** Management panel for a single vehicle.

**Features:**
- Display vehicle owner and claim info
- List allowed players with scrolling list
- Add/remove player access
- Release claim (with confirmation dialog)
- Works from any distance (no movement restriction)
- Auto-refresh on server response via panel registry

**Height:** 440px to accommodate all UI elements

**Data Flow:**
- Reads claim data from vehicle ModData (synced by server)
- Sends modification requests to server via `sendClientCommand()`
- Refreshes on server response via `VehicleClaimPanelRegistry`

#### **`ISVehicleClaimListPanel.lua`**
**Purpose:** List all vehicles claimed by the current player.

**Features:**
- Shows ALL player's vehicles, even when not loaded (far away)
- Display claim count vs. limit (e.g., "3 / 5 veículos")
- Loaded vehicles show distance, unloaded show last known coordinates
- Quick access to individual vehicle management via "Gerenciar" button
- Auto-refresh every 5 seconds
- Unloaded vehicles highlighted in yellow

**Data Source:** Server-side Global Claim Registry (not local cell scan)

**Why Global Registry?**
- Vehicles outside loaded area don't exist in `cell:getVehicles()`
- Server maintains a persistent registry of ALL claims
- Client requests claim list from server, not local scan
- Allows players to see and manage vehicles across the entire map

#### **`VehicleClaim_PlayerMenu.lua`**
**Purpose:** Add "Meus Veículos" option to player self-menu.

**Functionality:**
- Adds right-click option on self to open vehicle list
- Entry point for vehicle management

---

## Event-Driven UI Architecture

### **Custom Events**
The system uses LuaEventManager custom events for reactive UI updates:

| Event | Trigger | Parameters | Purpose |
|-------|---------|------------|----------|
| `OnVehicleClaimChanged` | Vehicle claimed or modified | `vehicleHash`, `claimData` | Update UI to show new owner/access |
| `OnVehicleClaimReleased` | Vehicle unclaimed | `vehicleHash`, `nil` | Update UI to show available |
| `OnVehicleClaimAccessChanged` | Access list modified | `vehicleHash`, `claimData` | Update UI to show new access list |
| `OnVehicleInfoReceived` | Info query response | `vehicleHash`, `claimData` | Populate UI with vehicle data |

### **Event Flow**
```
1. Server sends response with claim data from registry
2. Client handler receives response
3. Client updates local cache with fresh data
4. Client triggers custom event
5. All subscribed UI components receive event
6. Each component checks if event is for their vehicle
7. Matching components update immediately
```

### **Benefits**
- ✅ **No Polling:** UI doesn't spam server with requests
- ✅ **Instant Updates:** Changes propagate immediately
- ✅ **Consistent Data:** All UI reads from same cached source
- ✅ **Minimal Traffic:** Server sends data only when changed
- ✅ **Scalable:** Adding new UI components just subscribes to events

### **Cache Synchronization**
When events deliver claim data, the handler updates the cache:
```lua
VehicleClaim.claimDataCache[vehicleHash] = {
    data = claimData,  -- Fresh from server registry
    timestamp = os.time()
}
```

This ensures `isClaimed()`, `hasAccess()`, and other utility functions read correct data from cache instead of stale vehicle ModData.

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
        ["vehicleID"] = {
            vehicleID = 12345,
            ownerSteamID = "76561198...",
            ownerName = "PlayerName",
            vehicleName = "Chevalier Dart",
            x = 10234,
            y = 8567,
            claimTime = 12345
        }
    }
}
```

### **Synchronization**
- Server updates registry on claim/release
- Clients request their claims via `CMD_REQUEST_MY_CLAIMS`
- Server responds with `RESP_MY_CLAIMS` containing all player's claims
- Vehicle list panel uses this data instead of local cell scan

### **Benefits**
- ✅ See all vehicles regardless of distance
- ✅ Track vehicle last known position
- ✅ Accurate claim count even with unloaded vehicles
- ✅ Works across server restarts (persisted in ModData)

---

## Client-Server Communication Flow

### **Command Types**

#### **Client → Server Commands**
Defined in `VehicleClaim.CMD_*` constants:

| Command | Purpose | Validation Required |
|---------|---------|-------------------|
| `claimVehicle` | Request to claim a vehicle | Proximity, not already claimed, under limit |
| `releaseClaim` | Release ownership | Ownership or admin |
| `addAllowedPlayer` | Grant access to player | Ownership or admin |
| `removeAllowedPlayer` | Revoke access | Ownership or admin |
| `requestVehicleInfo` | Query vehicle details | None (read-only) |
| `requestMyClaims` | Get all player's claims from registry | Steam ID verification |

#### **Server → Client Responses**
Defined in `VehicleClaim.RESP_*` constants:

| Response | Purpose |
|----------|---------|
| `claimSuccess` | Claim approved |
| `claimFailed` | Claim denied (with reason) |
| `releaseSuccess` | Release approved |
| `playerAdded` | Access granted |
| `playerRemoved` | Access revoked |
| `accessDenied` | Permission denied |
| `vehicleInfo` | Vehicle data response |
| `myClaims` | List of all player's claims from registry |

### **Example: Claiming a Vehicle**

```lua
// 1. PLAYER RIGHT-CLICKS VEHICLE
VehicleClaimMenu.onFillWorldObjectContextMenu()
  → Shows "Claim Vehicle" option

// 2. PLAYER CLICKS "CLAIM VEHICLE"
VehicleClaimMenu.onClaimVehicle()
  → Creates ISClaimVehicleAction (timed action)
  → Action performs after ~2 seconds

// 3. TIMED ACTION COMPLETES (CLIENT)
ISClaimVehicleAction:perform()
  → sendClientCommand(player, "VehicleClaim", "claimVehicle", {
      vehicleID = 12345,
      steamID = "76561198...",
      playerName = "Player"
    })

// 4. SERVER RECEIVES COMMAND
VehicleClaimServer.onClientCommand()
  → handleClaimVehicle(player, args)
    → VALIDATE steamID matches player ✓
    → VALIDATE player within range ✓
    → VALIDATE vehicle not claimed ✓
    → VALIDATE player under claim limit ✓
    → initializeClaimData(vehicle, steamID, playerName)
    → vehicle:transmitModData() // Syncs to all clients

// 5. SERVER SENDS RESPONSE WITH CLAIM DATA FROM REGISTRY
sendServerCommand(player, "VehicleClaim", "claimSuccess", {
    vehicleHash = hash,
    claimData = {...}  // Fresh from global registry
})

// 6. CLIENT RECEIVES RESPONSE (EVENT-DRIVEN)
VehicleClaimClient.onServerCommand()
  → VehicleClaimClient.onClaimSuccess(args)
    // Update local cache with authoritative server data
    → VehicleClaim.claimDataCache[vehicleHash] = {
        data = args.claimData,
        timestamp = os.time()
      }
    // Trigger custom event for reactive UI
    → triggerEvent("OnVehicleClaimChanged", vehicleHash, claimData)
    → player:Say("Successfully claimed Vehicle")

// 7. ALL UI COMPONENTS REACT TO EVENT
ISVehicleClaimInfoPanel.onClaimChangedHandler()
  → self:updateInfo(claimData)  // Updates immediately with event data
  
ISVehicleClaimPanel.eventHandler()
  → Refreshes if open

// 8. VEHICLE MODDATA SYNCED (background)
Vehicle ModData synced by game engine to all clients
  → Enforcement checks activate
  → Context menus update
```

---

## Data Storage

### **Vehicle ModData Structure**

Claim data is stored in each vehicle's ModData under the key `"VehicleClaimData"`:

```lua
vehicle:getModData()["VehicleClaimData"] = {
    ownerSteamID = "76561198XXXXXXXX",
    ownerName = "PlayerName",
    allowedPlayers = {
        ["76561198YYYYYYYY"] = "AllowedPlayer1",
        ["76561198ZZZZZZZZ"] = "AllowedPlayer2"
    },
    claimTimestamp = 12345,  -- Game minutes since start
    lastSeenTimestamp = 12346
}
```

**Persistence:** ModData is saved with the vehicle in the world save. Claims persist across server restarts.

**Sync:** Changes trigger `vehicle:transmitModData()`, which the game engine automatically broadcasts to all clients.

---

## Error Handling & Validation

### **Error Codes**
Defined in `VehicleClaim.ERR_*` constants:

| Error Code | Meaning | Trigger |
|------------|---------|---------|
| `vehicleNotFound` | Vehicle doesn't exist | Invalid vehicle ID |
| `alreadyClaimed` | Vehicle has owner | Claim attempt on owned vehicle |
| `notOwner` | Insufficient permissions | Non-owner tries to modify |
| `tooFar` | Out of range | Distance > 5 tiles |
| `playerNotFound` | Target player offline | Add player with invalid name |
| `claimLimitReached` | Max vehicles claimed | Exceeds sandbox limit |

### **Validation Layers**

#### **Layer 1: Client Pre-Check (UX)**
- Context menu checks claim state before showing options
- UI validates input before sending commands
- Enforcement prevents interactions without server round-trip

**Purpose:** Fast feedback to player
**Security:** Bypassable by modded clients (doesn't matter - server validates)

#### **Layer 2: Server Validation (Authority)**
- Every command re-validates all conditions
- Steam ID verification
- Proximity checks
- Ownership verification
- Claim limit enforcement

**Purpose:** Actual security
**Security:** Cannot be bypassed

#### **Layer 3: Response Handling (Feedback)**
- Client displays appropriate error messages
- UI updates based on actual server state
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
    max = 50,
    default = 5,
    page = VehicleClaimSystem,
    translation = VehicleClaimSystem_MaxClaimsPerPlayer,
}
```

**Access in code:**
```lua
local maxClaims = SandboxVars.VehicleClaimSystem.MaxClaimsPerPlayer
```

**Server Authority:** Only server reads sandbox vars. Clients cannot modify or override limits.

---

## Security Summary

### **What Prevents Cheating?**

1. **Server-Side Validation**: Every state change validated by server
2. **Steam ID Verification**: Server checks player identity
3. **ModData Authority**: Only server modifies ModData, clients receive sync
4. **Proximity Enforcement**: Server calculates distances, not client
5. **No Client Trust**: Client requests are suggestions, server decides
6. **Read-Only Shared Code**: Shared utilities don't modify state
7. **Claim Limit Enforcement**: Server tracks and enforces per-player limits

### **What Can Modded Clients NOT Do?**

❌ Claim vehicles without server approval  
❌ Bypass proximity checks  
❌ Modify other players' vehicles  
❌ Exceed claim limits  
❌ Grant themselves access to others' vehicles  
❌ Fake Steam IDs  
❌ Modify synced ModData directly

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
Client: receives response → updates UI
```

### **2. Timed Actions**
```
Player initiates action → ISClaimVehicleAction queues
→ ~2 second delay with animation
→ Action completes → sends server command
```

**Purpose:** Realistic timing, prevents spam, cancellable actions

### **3. ModData Synchronization**
```
Server: vehicle:getModData()[key] = value
Server: vehicle:transmitModData()
Game Engine: broadcasts to all clients automatically
Clients: read vehicle:getModData()[key]
```

**Purpose:** Reliable state sync without manual network code

### **4. Defensive Programming**
- Always check if player/vehicle exists before operations
- Validate Steam IDs match
- Re-check conditions on server even if client checked
- Graceful degradation on missing data

### **5. Hook Pattern (Build 42 Compatible)**
```lua
-- Store original function
local original_isValid = ISUninstallVehiclePart.isValid

-- Replace with wrapped version
ISUninstallVehiclePart.isValid = function(self)
    if self.vehicle and not VehicleClaimEnforcement.hasAccess(player, self.vehicle) then
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
        self:updateInfo(claimData)  // React to change
    end
end

-- Cleanup on panel close
Events.OnVehicleClaimChanged.Remove(self.onClaimChangedHandler)
```

**Purpose:** Reactive UI updates without polling or manual refresh loops

**Benefits:**
- No periodic network requests
- Instant updates when state changes
- Minimal performance overhead
- Consistent data across all UI components

---

## Testing Checklist

### **Functionality**
- ✅ Can claim unclaimed vehicle within range
- ✅ Cannot claim vehicle outside range
- ✅ Cannot claim already-claimed vehicle
- ✅ Cannot exceed claim limit
- ✅ Can release own vehicle from any distance
- ✅ Cannot release other player's vehicle
- ✅ Can add/remove allowed players
- ✅ Allowed players can use vehicle
- ✅ Non-allowed players blocked from vehicle

### **Security**
- ✅ Server validates all commands
- ✅ Steam ID mismatches rejected
- ✅ Proximity checked server-side for claims
- ✅ Claim limit enforced server-side
- ✅ ModData changes require ownership

### **UI**
- ✅ Context menu shows correct options
- ✅ Management panel displays accurate data (440px height)
- ✅ **Mechanics window (V key) shows embedded claim panel**
- ✅ **Claim panel updates instantly on claim/release (event-driven)**
- ✅ **Can claim/release directly from mechanics window**
- ✅ **Unclaiming and re-claiming works without reopening UI**
- ✅ Vehicle list shows all claimed vehicles (even unloaded)
- ✅ Unloaded vehicles show in yellow with coordinates
- ✅ Error messages display properly in correct language
- ✅ "Meus Veículos" option available from self right-click

### **Enforcement (Build 42.13.1)**
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
- ✅ Cannot transfer items from trunk
- ✅ Cannot attach trailer to claimed vehicle
- ✅ Cannot detach trailer from claimed vehicle
- ✅ Context menu stripped of all vehicle actions (except claim)
- ✅ Radio removal works for allowed players

### **Global Registry**
- ✅ Vehicles appear in list even when far away (unloaded)
- ✅ Claim count accurate for all vehicles
- ✅ Last known position shows for unloaded vehicles
- ✅ Registry persists across server restarts
- ✅ Registry updates on claim/release

### **Multi-Language**
- ✅ Portuguese text displays correctly
- ✅ English text displays correctly
- ✅ getText() resolves all translation keys
- ✅ Error messages localized

---

## Build 42 API Notes

### **Important Classes**
These are the timed action classes used in Build 42.13.1:
- `ISOpenVehicleDoor` - Opening vehicle doors
- `ISInstallVehiclePart` - Installing parts
- `ISUninstallVehiclePart` - Removing parts
- `ISRepairVehiclePartAction` - Repairing parts
- `ISTakeGasFromVehicle` - Siphoning gas
- `ISAddGasFromPump` - Refueling from pump
- `ISVehicleMechanics` - Mechanics panel UI

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
    VehicleClaimEnforcement.initializeHooks()
end)
```

---

## Future Expansion Ideas

- **Decay System**: Unclaim vehicles after X days inactive
- **Shared Ownership**: Multiple owners per vehicle
- **Faction Integration**: Faction-wide vehicle pools
- **Key System**: Physical keys required for access
- **Break-In Mechanics**: Allow lockpicking with cooldown/alerts

---

## Contributing

When modifying this system, remember:
1. **Never trust the client** - validate everything server-side
2. **Use ModData for persistence** - it's automatically saved and synced
3. **Follow command-response pattern** - keep client-server communication clear
4. **Test with multiple players** - ensure sync works correctly
5. **Log important events** - use `VehicleClaim.log()` for debugging
6. **Use `.isValid()` hooks** - never return nil from `.new()` constructors
7. **Initialize hooks on OnGameStart** - ensure Build 42 classes are loaded first

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

### **Problem: Hooks not working on game start**
**Symptom:** Enforcement doesn't activate until reconnecting.

**Cause:** Hooks are being set before Build 42 classes are fully loaded.

**Solution:** Initialize all hooks in `OnGameStart` event handler.

---

## License

This mod is provided as-is for Project Zomboid servers. Modify and distribute freely with attribution.