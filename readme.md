# ApocalipseClaimSystem - Vehicle Claim System

## Technical Documentation

A secure, server-authoritative vehicle ownership system for Project Zomboid multiplayer servers.

### Build Compatibility
The repository contains versioned mod folders for Project Zomboid 42.13.1, 42.14, 42.15, 42.17, and 42.19. Validate the specific folder against the game build before deployment; the security changes documented below currently target the `42.19` folder.

### Multi-Language Support
The system supports multiple languages with automatic detection:
- **English (EN)** - Full UI and sandbox translations
- **Brazilian Portuguese (PTBR)** - Full UI and sandbox translations
- **Russian (RU)** - Full UI and sandbox translations

Translation files are located in `media/lua/shared/Translate/<LANG>/` with both `UI_<LANG>.txt` and `Sandbox_<LANG>.txt` per language.

## Overview

This mod implements vehicle claims, access lists, remote release, abandoned-claim contests, and client UI. The client-side hooks improve feedback and convenience; authorization decisions for sensitive operations are made by the server using its global claim registry.

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
Clients provide UI and timed actions, then send requests. The server validates identity, proximity, ownership, access, and abandonment before changing the registry. Vehicle `ModData` carries a client-visible mirror of claim data; it is not authoritative for sensitive server decisions.

### **Security Model and Known Network Risk**
- **Registry authority:** the server's `VehicleClaimRegistry` stores owner, allowed players, last-seen time, and last-known coordinates. Sensitive authorization and contest checks use these server-side entries.
- **Vehicle ModData is a mirror:** the game network path can accept client-sent object ModData. A modified client may alter or remove vehicle claim data locally and transmit it; a client-side UI or enforcement hook is not a security boundary.
- **Canonical repair:** server Lua rebuilds the loaded vehicle's claim mirror from its registry entry on load, entry, and rotating occupancy checks. Server decisions do not rely on the received owner/access fields.
- **Unclaim security:** nearby timed release and remote release both route to the registry-authorized release handler. A sender must match the owner Steam ID in the registry. Admin status does not bypass owner-only release.
- **Contest security:** contest uses registry owner and last-seen values, checks server-side proximity using loaded vehicle coordinates or registry coordinates, and removes a claim through the same registry release routine.
- **Occupancy enforcement:** the server checks access when the entry event fires and checks one online player per server `OnTick` using a rotating index. Each tick does bounded work; a player is revisited within at most one pass through the online-player list. Unauthorized occupants are ejected and counted in memory; the third strike kills the player. Admins retain the vehicle-operation exemption, determined from the server-side player's current `getAccessLevel()` rather than a client-supplied or separately cached admin list.
- **Client enforcement is UX only:** modified clients can remove the mod's client-side blocking. Server validation is still required for actual protection.
- **Remaining limitation:** Lua reconciliation repairs ModData after the game packet has been parsed; it does not block the vanilla client-to-server modData packet itself. Preventing that write at its source would require a Java patch for the exact game build. In the meantime, all sensitive mod decisions will continue using registry state.

#### Decompiled Network Evidence (42.21.0)

Analyzing the game's source code from 42.21.0 decompiled source shows the following object-ModData route:

1. Client-side `IsoObject.transmitModData()` sends an `ObjectModData` packet.
2. `ObjectModDataPacket.parse()` resolves the target object and loads the received table into that object's ModData.
3. `MovingObject` resolves vehicle objects by vehicle ID; the packet's consistency check confirms that the object resolves, not that the sender owns the vehicle.
4. Server packet processing relays the received manipulated object state to relevant clients.

Because vehicles are `IsoObject` instances, this provides a plausible route for a modified client to overwrite its server-side vehicle claim modData mirror. Removing the mod's client-side entry block is a separate, trivial bypass: it disables only local behavior. The prior direct-release and occupancy design could then be fooled if it trusted the resulting vehicle ModData. Current Lua checks instead consult the registry now.

These decompiled packet findings are specifically from game build 42.21.0, while this mod folder is `42.19`. Confirm packet behavior against the exact target game build before treating the packet analysis as version-certified. The Lua registry-authority change itself does not stop vanilla from parsing that packet. These changes are aimed to make the mod immune to data corruption from clients trying to tamper with the authenticity of the data in the Vechicle's modData.

---

## Quick File Reference

```
Contents/mods/ApocalipseClaimSystem/42.19/
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
- Provide client/UI utility functions: `isClaimed()`, `hasAccess()`, `getOwnerID()`, `getOwnerName()`, `getAllowedPlayers()`, etc. Server command authorization uses registry-backed helpers instead of trusting these vehicle-ModData reads.
- **Vehicle hash system**: `getOrCreateVehicleHash()` / `getVehicleHash()` - persistent unique vehicle identification
- Calculate distances and validate proximity (`CLAIM_DISTANCE = 8.0` tiles)
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
- `getClaimData()` reads the local vehicle ModData mirror for client display and interaction affordances.
- This mirror can be changed by client-originated game networking, so it must not authorize server operations.
- The server registry is the authorization source for server command handlers and vehicle occupancy enforcement.

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
  - Check proximity (player within 8 tiles of vehicle)
  - Validate ownership for protected actions
  - Enforce claim limits (using global registry for accurate count)
- **Execute state changes**:
  - Update the server global claim registry as authoritative claim state
  - Rebuild vehicle ModData from that registry as a client-facing mirror
  - Add/remove allowed players
  - Release claims (local and remote)
  - Contest abandoned vehicle claims
  - Admin-level bulk operations
- **Send responses** back to clients with claim data
- **Broadcast mirror changes** to nearby players through `syncVehicleModData` server commands
- **Synchronize on vehicle load, entry, and rotating occupancy checks** - rebuilds loaded claim ModData from registry data
- **Use registry state** for release, contest, access-list changes, occupancy, and other sensitive validations

**Command Handlers:**

| Handler | Command | Purpose |
|---------|---------|---------|
| `handleClaimVehicle` | `claimVehicle` | Claim an unclaimed vehicle (proximity required) |
| `handleReleaseClaimRemote` | `releaseClaimRemote` | Registry-authorized owner release from any distance; used by nearby and remote UI flows |
| `handleContestClaim` | `contestClaim` | Contest an abandoned registry claim (server-side proximity required) |
| `handleAddPlayer` | `addAllowedPlayer` | Grant access to another player (proximity required) |
| `handleRemovePlayer` | `removeAllowedPlayer` | Revoke player access (proximity required) |
| `handleRequestInfo` | `requestVehicleInfo` | Deprecated - clients read ModData directly |
| `handleRequestMyClaims` | `requestMyClaims` | Get all player's claims from global registry |
| `handleAdminClearAllClaims` | `adminClearAllClaims` | Admin: clear ALL claims server-wide |
| `handleConsolidateClaims` | `consolidateClaims` | Admin: consolidate claims into registry |

**Vehicle Load Synchronization:**
```
Vehicle spawns/loads → syncVehicleClaimOnLoad()
  → Find registry entry using server-known vehicle/hash association
    → In registry: restore canonical claim fields and update position
    → NOT in registry: clear stale claim fields from the mirror

Vehicle entry / rotating online-player check on `OnTick`
  → Read owner and allow-list from registry
  → Repair altered vehicle claim fields
  → Allow owner/allowed/admin, otherwise eject and count strike
```

The rotating check examines one player per server tick rather than traversing the whole online-player list each tick. With `N` online players, a player is revisited within approximately `N` server ticks. The entry event remains a best-effort fast path; the rotating check is the Lua-side backstop for persistent unauthorized occupancy. It cannot guarantee detecting a player who enters and exits entirely between that player's checks.

**Data Flow:**
```
Server Global Claim Registry → server authorization and canonical claim mirror
        ↓                                ↓
      responses/events                 nearby mirror sync → client UI
```

**Server-Side Event Registration:**
- `Events.OnClientCommand.Add()` - command router
- `Events.OnSpawnVehicleStart.Add()` - vehicle load synchronization
- `Events.OnEnterVehicle.Add()` - registry-backed vehicle entry enforcement
- `Events.OnTick.Add()` - rotating registry-backed occupancy check, one online player per server tick

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

**Security Note:** Timed actions are a client-side UX delay, not authorization. Completing the nearby release action sends `releaseClaimRemote`; the server checks registry ownership.

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
  - **Owner**: "Release Claim" + "Manage Access" buttons
  - **Admin/moderator**: vehicle operation exemption; server does not grant them owner-only release authority. Some client panels may still display a release control to admins, but the server rejects it unless they own the registry claim.
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

**Security Note:** The panel may read the local vehicle ModData mirror for immediate display. This is not authoritative; the server uses its registry when approving actions.

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
- Reads local vehicle ModData for client display; this state can be tampered with and is not authoritative

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
-   • Vehicle has no claim data in its local mirror
-   • Vehicle appears unclaimed in its local mirror
-   • Player appears as owner or allowed in the local mirror
-   • Player appears as an admin or moderator
-- This helper is for client UX only; server authorization uses VehicleClaimRegistry.
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

**Security Note:** Client-side enforcement is **UX only** and can be removed or bypassed by a modified client. Server Lua independently checks access on vehicle entry and checks one online player per server `OnTick` through a rotating scan. Server protection must not depend on these local hooks.

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
  - **Nearby vehicle**: Timed action sends the same registry-authorized `releaseClaimRemote` request
  - **Far/unloaded vehicle**: Remote release via `releaseClaimRemote` command
- Event-driven auto-refresh via `OnVehicleClaimAccessChanged` and `OnVehicleClaimReleased`
- Works with both loaded vehicles (from context menu) and unloaded vehicles (from list panel with cached data)

**Panel Size:** 400x500px with move-with-mouse support

**Data Flow:**
- Reads the local ModData mirror for loaded-vehicle display and cached server claim data for unloaded vehicles
- Treats local ownership and access information as UI state only
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
6. Matching components update from server responses and the local mirror
```

### **Benefits**
- ✅ **No Polling:** UI doesn't spam server with requests
- ✅ **Instant Updates:** Changes propagate immediately
- ✅ **Consistent Data:** UI reads local mirror and server responses; authorization uses registry state
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
            lastSeen = 12346,
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
- **Vehicle load sync**: When vehicles load, server rebuilds the claim mirror from the registry or clears unregistered claim fields
- **Entry and occupancy sync**: Entry checks and a rotating one-player-per-server-`OnTick` scan validate access from registry data and repair altered mirrors

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
6. Server validates owner and abandonment from registry data, then releases through the shared registry release routine

Contest proximity uses the loaded vehicle position when available, or the registry's last-known coordinates when it is unloaded. The configured distance is 8 tiles. Last-seen is recorded in the server registry and copied into the vehicle mirror for display.

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
- Sender Steam ID matches the player
- Registry contains the claim
- Player is not the registry owner
- Server-side distance is within the configured 8-tile radius, using loaded vehicle coordinates or last-known registry coordinates
- Registry last-seen time meets the abandoned threshold
- On success, the contest uses the same registry removal and mirror cleanup routine as owner release

---

## Client-Server Communication Flow

### **Command Types**

#### **Client → Server Commands**
Defined in `VehicleClaim.CMD_*` constants:

| Command | Purpose | Validation Required |
|---------|---------|-------------------|
| `claimVehicle` | Request to claim a vehicle | Proximity, not already claimed, under limit |
| `releaseClaimRemote` | Release ownership (any distance; also used after nearby timed action) | Owner Steam ID in registry |
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
    → VALIDATE player within 8 tiles ✓
    → VALIDATE vehicle not claimed (server registry) ✓
    → VALIDATE player under claim limit (uses registry count) ✓
    → initializeClaimData(vehicle, steamID, playerName)
    → Add claim to server registry
    → Rebuild vehicle ModData mirror from registry
    → Broadcast mirror to nearby clients

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

// 8. VEHICLE CLAIM MIRROR SYNCED
Server broadcasts canonical claim mirror to nearby clients
  → Client UI and local enforcement refresh
  → Server remains authoritative even if a client later tampers with its mirror
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

**Persistence:** The server registry is stored in global ModData and is the claim record used by server authorization. Vehicle ModData is also saved with the vehicle, but is only a mirror and can be overwritten by network updates.

**Sync:** The server rebuilds the mirror from registry data when it detects drift and sends `syncVehicleModData` commands to nearby online players. The mod does not rely on client-to-server `transmitModData()` as a trusted claim update path.

**Last Seen Debounce:** `updateLastSeen()` updates the server registry at most once per five game minutes and then synchronizes the mirror if needed, reducing unnecessary network traffic.

---

## Error Handling & Validation

### **Error Codes**
Defined in `VehicleClaim.ERR_*` constants:

| Error Code | Meaning | Trigger |
|------------|---------|---------|
| `vehicleNotFound` | Vehicle doesn't exist | Invalid vehicle hash |
| `alreadyClaimed` | Vehicle has owner | Claim attempt on owned vehicle |
| `notOwner` | Insufficient permissions | Non-owner tries to modify |
| `tooFar` | Out of range | Distance > 8 tiles |
| `playerNotFound` | Target player offline | Add player with invalid name |
| `claimLimitReached` | Max vehicles claimed | Exceeds sandbox limit |
| `notAdmin` | Admin privileges required | Non-admin tries admin command |
| `vehicleNotLoaded` | Vehicle not in loaded cells | Operation requires the loaded vehicle object |
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
**Security:** Fully bypassable by a modified client; these checks are presentation and convenience only.

#### **Layer 2: Server Validation (Authority)**
- Every command re-validates all conditions
- Steam ID verification against requesting player
- Proximity checks (except for remote release)
- Ownership verification
- Claim limit enforcement (uses registry count, not cell scan)
- Abandoned threshold validation for contest commands

**Purpose:** Actual security
**Security:** Client requests cannot choose the authenticated player object or override registry authorization. The server's vanilla vehicle-ModData receive path is a separate mutable-state risk; the mod mitigates its claim impact by using the registry and repairing the mirror, but does not block that Java packet path.

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

### **What Prevents or Mitigates Exploits?**

1. **Registry-backed authorization:** owner Steam ID, allowed-player list, claim timestamps, and stored coordinates come from the server's claim registry, not client-synchronized vehicle claim fields.
2. **Sender verification:** commands compare the supplied Steam ID against the server's player object.
3. **Server-calculated range:** claim and access-management distances are calculated by the server using an 8-tile configured radius. Remote owner release has no proximity requirement.
4. **Owner-only release:** `releaseClaimRemote` is the release command and validates the registry owner; neither admin level nor vehicle ModData substitutes for registry ownership.
5. **Registry-backed contest:** the server validates non-owner status, configured abandonment age, and proximity from loaded vehicle coordinates or registry coordinates, then uses the shared release operation.
6. **Mirror repair:** on load, entry, and the rotating occupancy scan, the server restores registered claims and removes unregistered claim data from loaded vehicles. A server-retained vehicle/hash association helps locate a claim if client ModData is altered after the server has associated that vehicle.
7. **Server occupancy enforcement:** the entry event is a best-effort fast path; `OnTick` checks one online player per tick in rotation against registry ownership/access, repairs the mirror, and ejects unauthorized occupants. Strikes are held in server memory and the third strike kills the player. Admins remain exempt from vehicle-operation restrictions. The scan bounds repeated-check cost, but may not observe an entry that begins and ends between checks.
8. **Server-side claim limits:** claim counts are calculated from registry entries, including unloaded vehicles.

**Known limitation:** The vanilla game can parse a client-sent object ModData packet into the server-side object before mod Lua can repair it. These Lua changes do not intercept or reject that packet. Sensitive mod decisions avoid trusting those mutable claim fields; blocking the write itself requires a Java patch targeting the exact game build. The mod's `42.19` implementation should not be assumed compatible with a different game's networking implementation without validation.

### **What Can Modded Clients NOT Do?**

❌ Claim vehicles without server approval
❌ Bypass proximity checks
❌ Modify other players' vehicles
❌ Exceed claim limits
❌ Grant themselves access to others' vehicles
❌ Fake Steam IDs
❌ Skip abandoned vehicle threshold checks
❌ Execute admin commands without admin access

### **What Can Modded Clients Do?**

✅ See local UI earlier (cosmetic only)
✅ Send invalid requests (server rejects them)
✅ Remove or bypass client-side enforcement and alter their local vehicle ModData mirror; server registry checks and rotating occupancy enforcement are intended to preserve the claim's authorization

**Important:** A client can send altered object ModData through the game networking path. The mod treats this as untrusted mirror state, but Lua does not block the underlying packet. The server registry and rotating repair reduce the impact; runtime testing and, for packet-level prevention, a build-matched Java patch remain necessary.

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

### **3. Registry Authority and ModData Mirror**
```
Server: validate and mutate VehicleClaimRegistry
Server: rebuild vehicle claim ModData from registry when needed
Server: broadcast the canonical mirror to nearby clients
Clients: read the mirror for display and immediate local UX
Server: never use client-updatable claim fields as sensitive authorization
```

**Purpose:** Keep UI state convenient while ensuring claim ownership and access decisions use server-held data.

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
    -- Rebuild registered claims from trusted registry state.
    -- Clear claim fields when the registry has no corresponding claim.
end)
```

**Purpose:** Ensure remote unclaims propagate to vehicle ModData when vehicles load

---

## Testing Checklist

The checklist below describes expected behavior, not a record of tests run for the latest security changes. Run these multiplayer regression cases on the exact target build before deployment.

### **Functionality**
- ✅ Can claim unclaimed vehicle within range (8 tiles)
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
- ✅ Claim ownership and access checks use registry data rather than vehicle ModData
- ✅ Tampered claim fields are repaired from the registry on load, entry, and rotating one-player-per-tick occupancy scan
- ✅ Nearby timed release and remote release share the registry-authorized owner check
- ✅ Contest owner, abandonment, and release decisions use registry data
- ✅ Unauthorized occupants are ejected and strike-counted; the third strike triggers death
- ⚠️ Vanilla client-to-server object ModData packet itself is not blocked by mod Lua
- ☐ Modify/remove `VehicleClaimData` on a client and transmit vehicle ModData; server occupancy and release authorization must continue to use registry owner/access data
- ☐ Change the top-level client vehicle hash after the server has associated the loaded vehicle; confirm server reconciliation restores the known hash and claim mirror
- ☐ Enter an unauthorized claimed vehicle with client hooks removed; confirm server ejection at entry or within the periodic scan
- ☐ Repeat unauthorized occupancy detections three times; confirm third-strike punishment and verify strikes reset only after a server restart
- ☐ Attempt nearby and remote owner release with a non-owner and with an admin who is not the owner; confirm both are rejected
- ☐ Confirm a server-recognized admin/moderator can enter and operate another player's claimed vehicle without receiving occupancy strikes
- ☐ Contest an abandoned claim with the vehicle loaded and unloaded; confirm server registry timestamp and proximity validation
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