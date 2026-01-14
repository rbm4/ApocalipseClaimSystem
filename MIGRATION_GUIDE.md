# Vehicle Claim System - Migration Guide

## Overview
This guide explains the automatic migration system for upgrading from the old version (stable) to the new version with Global Registry Management.

## What Changed?

### Old System (Stable)
- Claims were **only** stored in vehicle ModData
- No global registry tracking
- Could lose track of claims when vehicles unload

### New System
- Claims stored in **both** vehicle ModData AND global registry
- Global registry provides persistent tracking of all claims
- Better performance for counting claims and listing owned vehicles

## Automatic Migration

The new system includes **automatic consolidation** that runs:

1. **On Server Start** - Scans all loaded vehicles after a 5-second delay
2. **Every 10 Minutes** - Periodic scan to catch newly loaded vehicles
3. **Manual Trigger** - Admins can force consolidation via context menu

### How It Works

The consolidation process:
1. Scans all loaded vehicles in the cell
2. Checks if vehicle has claim data in ModData
3. If claim exists but is NOT in global registry → adds it
4. Preserves all claim information:
   - Owner Steam ID
   - Owner Name
   - Claim timestamp
   - Last seen timestamp
   - Vehicle position
   - Allowed players list

### What Gets Migrated

✅ Vehicle ownership (ownerSteamID, ownerName)  
✅ Claim timestamps  
✅ Last seen timestamps  
✅ Vehicle positions  
✅ Allowed players list  

## Admin Manual Consolidation

Admins can manually trigger consolidation:

1. Right-click anywhere in the game world
2. Click "My Vehicles" → see your normal vehicle list
3. Look for **[Admin] Consolidate Claims** option
4. Click it to scan and migrate all claims

The system will:
- Scan all loaded vehicles
- Add orphaned claims to registry
- Show result message with count

## Technical Details

### Files Modified

- `VehicleClaim_ServerCommands.lua` - Added consolidation functions
- `VehicleClaim_Shared.lua` - Added admin command constants
- `VehicleClaim_ClientCommands.lua` - Added response handler
- `VehicleClaim_PlayerMenu.lua` - Added admin menu option

### Key Functions

```lua
-- Server-side
consolidateClaimsToRegistry() -- Main migration function
onEveryTenMinutes()           -- Periodic check
handleConsolidateClaims()     -- Admin command handler

-- Client-side  
onConsolidateClaims()         -- Admin menu trigger
onConsolidateResult()         -- Result display
```

## Upgrading Your Server

### Step 1: Backup
```
1. Stop your server
2. Backup your save folder
3. Backup your mod folder
```

### Step 2: Replace Files
```
1. Remove old mod version from server
2. Copy new mod version to server
3. Restart server
```

### Step 3: Verify Migration
```
1. Wait 5-10 seconds after server start
2. Check server logs for consolidation messages:
   "[Server Started] Running initial claim consolidation..."
   "[Consolidation] Consolidated X claims into global registry"
3. Test claiming/releasing vehicles
```

### Step 4: Admin Check (Optional)
```
1. Join as admin
2. Right-click → [Admin] Consolidate Claims
3. Verify message shows number of claims found
```

## Troubleshooting

### Claims Not Showing Up?

**Problem:** Old claims aren't appearing in "My Vehicles"  
**Solution:** 
1. Drive/interact with the vehicle (loads it into cell)
2. Wait 10 minutes for periodic scan
3. Or use admin consolidation command

### Vehicles Far Away?

**Problem:** Claimed vehicles are in unloaded areas  
**Solution:**
- The registry stores last known position
- Vehicles will be added to registry when their chunk loads
- They'll appear in "My Vehicles" list with coordinates

### Fresh Start?

**Problem:** Want to clear all claims and start over  
**Solution:**
```lua
-- In server console or admin tools:
-- Clear the global registry (this removes all claims)
ModData.remove("VehicleClaimRegistry")
```

## Verification

Check if migration was successful:

1. **Server Logs** - Look for consolidation messages
2. **My Vehicles Panel** - Should show all your old claims
3. **Claim Count** - Should match your previous vehicle count
4. **Vehicle Access** - All enforcement should work correctly

## Performance

The consolidation is **lightweight**:
- Only scans loaded vehicles (not entire map)
- Runs once on startup + every 10 minutes
- No impact on regular gameplay
- Skip duplicate checks (won't re-add existing entries)

## Need Help?

If you encounter issues:
1. Check server logs for error messages
2. Verify vehicle is loaded in cell
3. Try manual admin consolidation
4. Check vehicle ModData still has claim info
