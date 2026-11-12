-- Scripts/main.lua
local ModName = "BoxDiagnostic"

print("\n[" .. ModName .. "] Loaded. Press F11 to dump box diagnostics.\n")

-- KEY FIX
local UEHelpers = require("UEHelpers.UEHelpers")

local keyA_FName = UEHelpers.FindOrAddFName("A")
local keyD_FName = UEHelpers.FindOrAddFName("D")

local keyA_FKey = { KeyName = keyA_FName }
local keyD_FKey = { KeyName = keyD_FName }

local inputErrorLogged = false
-- KEY FIX

-- Try several methods to get the BoxComponent from the actor
local function getBoxComponent(Actor)
    -- Method 1: direct property access (name was "Box" in the logs)
    local ok, comp = pcall(function() return Actor.Box end)
    if ok and comp and comp:IsValid() then return comp end
    
    -- Method 2: GetComponentByClass
    ok, comp = pcall(function()
        return Actor:GetComponentByClass(FindClass("BoxComponent"))
    end)
    if ok and comp and comp:IsValid() then return comp end
    
    -- Method 3: iterate all components
    ok, comp = pcall(function()
        local comps = Actor:GetComponents()
        if comps then
            for _, c in ipairs(comps) do
                if c:GetClass():GetFName():ToString() == "BoxComponent" then
                    return c
                end
            end
        end
        return nil
    end)
    if ok and comp then return comp end
    return nil
end

-- Try two methods to get scaled box extent
local function getBoxExtent(Comp)
    -- Method 1: UFUNCTION GetScaledBoxExtent
    local ok, extent = pcall(function() return Comp:GetScaledBoxExtent() end)
    if ok and extent and extent.X then return extent, "scaled" end
    
    -- Method 2: raw BoxExtent * component scale
    ok, extent = pcall(function()
        local e = Comp.BoxExtent
        local s = Comp:K2_GetComponentScale()
        return { X = e.X * s.X, Y = e.Y * s.Y, Z = e.Z * s.Z }
    end)
    if ok and extent and extent.X then return extent, "raw*scale" end
    
    return nil, "failed"
end

local function safeCall(fn, default)
    local ok, result = pcall(fn)
    if ok and result ~= nil then return result end
    return default
end

local function DumpBoxes()
    local PC = FindFirstOf("PlayerController")
    if not PC or not PC.Pawn then
        print("[" .. ModName .. "] No PlayerController/Pawn.\n")
        return
    end
    local Eve = PC.Pawn
    local EveLoc = Eve:K2_GetActorLocation()
    local EveRot = Eve:K2_GetActorRotation()
    local EveYaw = EveRot.Yaw or 0
    local YawRad = math.rad(EveYaw)
    
    -- Compute forward and right vectors from Eve's yaw (avoiding GetActorForwardVector quirks)
    local FwdX = math.cos(YawRad)
    local FwdY = math.sin(YawRad)
    local RightX = -math.sin(YawRad)
    local RightY = math.cos(YawRad)
    
    print(string.format("\n[%s] ===== BOX DIAGNOSTIC =====\n", ModName))
    print(string.format("[%s] Eve: Loc=(%.1f, %.1f, %.1f) Yaw=%.1f\n", 
        ModName, EveLoc.X, EveLoc.Y, EveLoc.Z, EveYaw))
    
    local Boxes = FindAllOf("BP_ContainerTrain_Box_C")
    if not Boxes or #Boxes == 0 then
        print("[" .. ModName .. "] No BP_ContainerTrain_Box_C found.\n")
        return
    end
    
    print(string.format("[%s] Found %d box(es). Processing...\n", ModName, #Boxes))
    
    local results = {}
    for _, Box in ipairs(Boxes) do
        if Box and Box:IsValid() then
            local okL, BoxLoc = pcall(function() return Box:K2_GetActorLocation() end)
            local okR, BoxRot = pcall(function() return Box:K2_GetActorRotation() end)
            
            if okL and okR and BoxLoc and BoxRot then
                local dx = BoxLoc.X - EveLoc.X
                local dy = BoxLoc.Y - EveLoc.Y
                local dz = BoxLoc.Z - EveLoc.Z
                local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
                local fwd = dx * FwdX + dy * FwdY   -- how far ahead
                local lat = dx * RightX + dy * RightY -- left/right offset
                
                -- Box collision component
                local BoxComp = getBoxComponent(Box)
                local extent, extentMethod = nil, "n/a"
                local collProfile, collEnabled = "n/a", "n/a"
                
                if BoxComp then
                    extent, extentMethod = getBoxExtent(BoxComp)
                    collProfile = safeCall(function() 
                        return BoxComp:GetCollisionProfileName():ToString() 
                    end, "n/a")
                    collEnabled = safeCall(function() 
                        return tostring(BoxComp:GetCollisionEnabled()) 
                    end, "n/a")
                end
                
                -- StaticMesh bounds for visual cross-check
                local meshExtent, meshName = nil, "n/a"
                local okM, mesh = pcall(function()
                    return Box:GetComponentByClass(FindClass("StaticMeshComponent"))
                end)
                if okM and mesh and mesh:IsValid() then
                    meshName = safeCall(function() return mesh:GetFName():ToString() end, "?")
                    local okB, bounds = pcall(function() return mesh.Bounds end)
                    if okB and bounds and bounds.BoxExtent then
                        meshExtent = bounds.BoxExtent
                    end
                end
                
                table.insert(results, {
                    name = Box:GetFName():ToString(),
                    loc = BoxLoc, rot = BoxRot,
                    dist = dist, fwd = fwd, lat = lat, dz = dz,
                    extent = extent, extentMethod = extentMethod,
                    collProfile = collProfile, collEnabled = collEnabled,
                    meshName = meshName, meshExtent = meshExtent,
					nowInSector = inSector,
                })
            end
        end
    end
    
    -- Sort by forward distance (closest ahead first, furthest behind last)
    table.sort(results, function(a, b) return a.fwd < b.fwd end)
    
    for i, r in ipairs(results) do
        print(string.format("\n[%s] #%d | %s\n", ModName, i, r.name))
        print(string.format("[%s]   Dist=%.1f | Fwd=%.1f | Lat=%.1f | dZ=%.1f\n", 
            ModName, r.dist, r.fwd, r.lat, r.dz))
        print(string.format("[%s]   Loc=(%.1f, %.1f, %.1f) | Rot Yaw=%.2f Pitch=%.2f Roll=%.2f\n",
            ModName, r.loc.X, r.loc.Y, r.loc.Z, 
            r.rot.Yaw or 0, r.rot.Pitch or 0, r.rot.Roll or 0))
        
        if r.extent then
            print(string.format("[%s]   CollBoxExtent(%s)=(%.1f, %.1f, %.1f) => Full=(%.1f, %.1f, %.1f)\n",
                ModName, r.extentMethod, r.extent.X, r.extent.Y, r.extent.Z,
                r.extent.X*2, r.extent.Y*2, r.extent.Z*2))
        else
            print(string.format("[%s]   CollBoxExtent: FAILED (%s)\n", ModName, r.extentMethod))
        end
        
        if r.meshExtent then
            print(string.format("[%s]   MeshBounds(%s)=(%.1f, %.1f, %.1f)\n",
                ModName, r.meshName, r.meshExtent.X, r.meshExtent.Y, r.meshExtent.Z))
        end
        
        print(string.format("[%s]   Collision: Profile=%s | Enabled=%s\n",
            ModName, r.collProfile, r.collEnabled))
    end
    
    print(string.format("\n[%s] ===== END (%d boxes) =====\n", ModName, #results))
end

local function OnKeyPress()
    DumpBoxes()
end

-- ============================================================
-- EVE DIAGNOSTIC (bound to F9)
-- Appended to existing main.lua without touching BoxDiagnostic.
-- All functions prefixed with eve_ to avoid name conflicts.
-- ============================================================

local EVE_MOD = "EveDiag"

local function eve_vecStr(v)
    if v and v.X and v.Y and v.Z then
        return string.format("(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z)
    end
    return "nil"
end

local function eve_safeCall(obj, method, ...)
    if not obj then return nil end
    local args = {...}
    local ok, val = pcall(function() return obj[method](obj, table.unpack(args)) end)
    if ok then return val end
    return nil
end

local function eve_safeGet(obj, prop)
    if not obj then return nil end
    local ok, val = pcall(function() return obj[prop] end)
    if ok then return val end
    return nil
end

local function eve_dumpCapsule(comp, label)
    if not comp or not comp:IsValid() then
        print(string.format("[%s]   %s | NOT FOUND\n", EVE_MOD, label))
        return
    end
    local cls  = comp:GetClass():GetFName():ToString()
    local name = comp:GetFName():ToString()
    local r    = eve_safeCall(comp, "GetScaledCapsuleRadius")
    local hh   = eve_safeCall(comp, "GetScaledCapsuleHalfHeight")
    local loc  = eve_safeCall(comp, "K2_GetComponentLocation")
    print(string.format("[%s]   %s | %s | %s | R=%s HH=%s | Loc=%s\n",
        EVE_MOD, label, cls, name,
        r  and string.format("%.1f", r)  or "?",
        hh and string.format("%.1f", hh) or "?",
        eve_vecStr(loc)))
end

local function EveDump()
    local PC = FindFirstOf("PlayerController")
    if not PC or not PC.Pawn then
        print("[" .. EVE_MOD .. "] No Pawn.\n"); return
    end
    local Eve = PC.Pawn
    local eveName = Eve:GetFName():ToString()

    print(string.format("\n[%s] ===== EVE DIAGNOSTIC =====\n", EVE_MOD))
    print(string.format("[%s] Pawn: %s | Class: %s\n",
        EVE_MOD, eveName, Eve:GetClass():GetFName():ToString()))

    -- Transform
    local loc = eve_safeCall(Eve, "K2_GetActorLocation")
    local rot = eve_safeCall(Eve, "K2_GetActorRotation")
    print(string.format("[%s] Location: %s\n", EVE_MOD, eve_vecStr(loc)))
    if rot then
        print(string.format("[%s] Rotation: Yaw=%.2f Pitch=%.2f Roll=%.2f\n",
            EVE_MOD, rot.Yaw or 0, rot.Pitch or 0, rot.Roll or 0))
    end

    -- Velocity
    local vel = eve_safeCall(Eve, "GetVelocity") or eve_safeGet(Eve, "Velocity")
    if vel and vel.X then
        local speed = math.sqrt(vel.X*vel.X + vel.Y*vel.Y + vel.Z*vel.Z)
        print(string.format("[%s] Velocity: %s | Speed: %.2f\n",
            EVE_MOD, eve_vecStr(vel), speed))
    else
        print(string.format("[%s] Velocity: unavailable\n", EVE_MOD))
    end

    -- Root
    local root = eve_safeCall(Eve, "GetRootComponent") or eve_safeGet(Eve, "RootComponent")
    if root then
        print(string.format("[%s] Root: %s | %s\n",
            EVE_MOD, root:GetFName():ToString(), root:GetClass():GetFName():ToString()))
    end

    -- MovementComponent: try several class names
    local moveComp = eve_safeGet(Eve, "CharacterMovement")
    if not moveComp then
        moveComp = eve_safeCall(Eve, "GetComponentByClass", FindClass("CharacterMovementComponent"))
    end
    if not moveComp then
        moveComp = eve_safeCall(Eve, "GetComponentByClass", FindClass("SBCharacterMovementComponent"))
    end
    if moveComp and moveComp:IsValid() then
        print(string.format("[%s] MovementComponent: %s | %s\n",
            EVE_MOD, moveComp:GetFName():ToString(), moveComp:GetClass():GetFName():ToString()))
        local props = {
            "MaxWalkSpeed", "MaxAcceleration", "BrakingDecelerationWalking",
            "GroundFriction", "MaxFlySpeed", "JumpZVelocity", "AirControl",
            "bOrientRotationToMovement",
        }
        for _, p in ipairs(props) do
            local v = eve_safeGet(moveComp, p)
            if v ~= nil then
                print(string.format("[%s]   %s = %s\n", EVE_MOD, p, tostring(v)))
            end
        end
    else
        print(string.format("[%s] MovementComponent: NOT FOUND\n", EVE_MOD))
    end

    -- Named capsules
    print(string.format("[%s] --- Named Capsules ---\n", EVE_MOD))
    eve_dumpCapsule(eve_safeGet(Eve, "BodyCollision"),     "BodyCollision")
    eve_dumpCapsule(eve_safeGet(Eve, "EveAllBody_Evade"),  "EveAllBody_Evade")
    eve_dumpCapsule(eve_safeGet(Eve, "CollisionCylinder"), "CollisionCylinder")
    eve_dumpCapsule(eve_safeGet(Eve, "CollisionCapsule"),  "CollisionCapsule")

    -- All capsules owned by Eve (robust fallback)
    print(string.format("[%s] --- All CapsuleComponents owned by Eve ---\n", EVE_MOD))
    local ok, caps = pcall(function() return FindAllOf("CapsuleComponent") end)
    if ok and caps then
        for _, c in ipairs(caps) do
            if c and c:IsValid() then
                local okO, owner = pcall(function() return c:GetOwner() end)
                if okO and owner and owner:IsValid()
                   and owner:GetFName():ToString() == eveName then
                    local r  = eve_safeCall(c, "GetScaledCapsuleRadius")     or -1
                    local hh = eve_safeCall(c, "GetScaledCapsuleHalfHeight") or -1
                    print(string.format("[%s]   %s | R=%.1f HH=%.1f\n",
                        EVE_MOD, c:GetFName():ToString(), r, hh))
                end
            end
        end
    end

    -- Attachment (bike? vehicle?)
    local parent = eve_safeCall(Eve, "GetAttachParentActor")
    if parent and parent:IsValid() then
        print(string.format("[%s] Attached to: %s | %s\n",
            EVE_MOD, parent:GetFName():ToString(), parent:GetClass():GetFName():ToString()))
    else
        print(string.format("[%s] Attached to: nothing\n", EVE_MOD))
    end

    print(string.format("[%s] ===== END =====\n", EVE_MOD))
end


print("[" .. EVE_MOD .. "] Ready. Press F9 for Eve diagnostic.\n")
RegisterKeyBind(Key.F9, EveDump)
RegisterKeyBind(Key.F11, OnKeyPress)

-- ============================================================
-- EVE CONTINUOUS LOGGER V2 (bound to F8)
-- Logs Tube Coordinates (Theta, Rad, Fwd) and Input State.
-- ============================================================

local LOG_MOD = "EveLoggerV2"
local LOG_INTERVAL_MS  = 50    -- 20 Hz
local LOG_MAX_DURATION = 30    -- seconds

local logging_active      = false
local logging_start_time  = 0
local logging_count       = 0
local logging_last        = nil
local logging_last_eve    = nil
local loop_created        = false
local cached_spline       = nil

-- Vector Math
local function vec_sub(a, b) return {X=a.X-b.X, Y=a.Y-b.Y, Z=a.Z-b.Z} end
local function vec_dot(a, b) return a.X*b.X + a.Y*b.Y + a.Z*b.Z end
local function vec_len(a) return math.sqrt(a.X*a.X + a.Y*a.Y + a.Z*a.Z) end
local function vec_norm(a) 
    local l = vec_len(a)
    if l == 0 then return {X=0, Y=0, Z=0} end
    return {X=a.X/l, Y=a.Y/l, Z=a.Z/l} 
end
local function vec_cross(a, b)
    return {
        X = a.Y*b.Z - a.Z*b.Y,
        Y = a.Z*b.X - a.X*b.Z,
        Z = a.X*b.Y - a.Y*b.X
    }
end

local function log_safeCall(obj, method, ...)
    if not obj then return nil end
    local args = {...}
    local ok, val = pcall(function() return obj[method](obj, table.unpack(args)) end)
    if ok then return val end
    return nil
end

local function getSpline()
    if cached_spline and cached_spline:IsValid() then return cached_spline end
    local splines = FindAllOf("SplineComponent")
    if splines then
        for _, s in ipairs(splines) do
            if s and s:IsValid() then
                local owner = log_safeCall(s, "GetOwner")
                if owner and owner:IsValid() then
                    local cls = log_safeCall(owner, "GetClass")
                    if cls and log_safeCall(cls, "GetFName"):ToString() == "BP_HypertubeSpline_C" then
                        cached_spline = s
                        return s
                    end
                end
            end
        end
    end
    return nil
end

local function logTick()
    if not logging_active then return end
    local PC = FindFirstOf("PlayerController")
    if not PC or not PC.Pawn then return end
    local Eve = PC.Pawn
    if logging_last_eve ~= Eve then
        cached_spline = nil
        logging_last_eve = Eve
    end

    local loc = log_safeCall(Eve, "K2_GetActorLocation")
    local rot = log_safeCall(Eve, "K2_GetActorRotation")
    local vel = log_safeCall(Eve, "GetVelocity")
    if not (loc and rot and vel) then return end

    local speed = vec_len(vel)
    local now     = os.clock()
    local elapsed = now - logging_start_time
    
	-- Read Inputs
	local keyA = false
	local keyD = false

	local okA, resultA = pcall(function()
		return PC:IsInputKeyDown(keyA_FKey)
	end)

	local okD, resultD = pcall(function()
		return PC:IsInputKeyDown(keyD_FKey)
	end)

	if okA then
		keyA = resultA == true or resultA == 1
	end

	if okD then
		keyD = resultD == true or resultD == 1
	end

	if (not okA or not okD) and not inputErrorLogged then
		inputErrorLogged = true
		print("[INPUT ERROR] A: " .. tostring(resultA) .. "\n")
		print("[INPUT ERROR] D: " .. tostring(resultD) .. "\n")
	end

	local inA = keyA and "A:1" or "A:0"
	local inD = keyD and "D:1" or "D:0"

   -- Tube Space Math
    local spline = getSpline()
    local thetaStr, radStr, fwdStr = "n/a", "n/a", "n/a"
    
    if spline then
        local Center = log_safeCall(spline, "FindLocationClosestToWorldLocation", loc, 1)
        local Tan    = log_safeCall(spline, "FindTangentClosestToWorldLocation", loc, 1)
        local Up     = log_safeCall(spline, "FindUpVectorClosestToWorldLocation", loc, 1)
        
        if Center and Tan and Up then
            Tan = vec_norm(Tan)
            Up  = vec_norm(Up)
            local Right = vec_norm(vec_cross(Up, Tan))
            
            local V = vec_sub(loc, Center)
            local fwd = vec_dot(V, Tan)
            local radialVec = vec_sub(V, {X=Tan.X*fwd, Y=Tan.Y*fwd, Z=Tan.Z*fwd})
            local radDist = vec_len(radialVec)
            
            local x = vec_dot(radialVec, Right)
            local y = vec_dot(radialVec, Up)
            local theta = math.deg(math.atan(y, x))
            
            thetaStr = string.format("%7.1f", theta)
            radStr   = string.format("%6.1f", radDist)
            fwdStr   = string.format("%8.1f", fwd)
        end
    end

    logging_count = logging_count + 1
    
    -- Print one compact line per tick
    print(string.format("[%s] #%02d t=%.2f | %s %s | Spd=%.1f | Theta=%s | Rad=%s | Fwd=%s | Roll=%.1f\n",
        LOG_MOD, logging_count, elapsed, inA, inD, speed, thetaStr, radStr, fwdStr, rot.Roll or 0))

    if elapsed > LOG_MAX_DURATION then
        logging_active = false
        print(string.format("[%s] === AUTO-STOP after %.2fs ===\n", LOG_MOD, elapsed))
    end
end

local function logLoop()
    if logging_active then logTick() end
end

local function toggleLogger()
    if logging_active then
        logging_active = false
        print(string.format("[%s] === STOPPED. Samples=%d ===\n", LOG_MOD, logging_count))
    else
        logging_active      = true
        logging_start_time  = os.clock()
        logging_count       = 0
        logging_last_eve    = nil
        cached_spline       = nil
        print(string.format("[%s] === STARTED (interval=%dms) ===\n", LOG_MOD, LOG_INTERVAL_MS))
        if not loop_created then
            loop_created = true
            LoopAsync(LOG_INTERVAL_MS, logLoop)
        end
    end
end

RegisterKeyBind(Key.F8, toggleLogger)
print("[" .. LOG_MOD .. "] Ready. F8 = toggle continuous logger with Theta.\n")

-- ============================================================
-- CLASS DISCOVERY (bound to F7)
-- Shows all unique "interesting" actor classes in forward cone.
-- ============================================================

local CLS_MOD = "ClassDiscovery"

local function cls_safeCall(obj, method, ...)
    if not obj then return nil end
    local args = {...}
    local ok, val = pcall(function() return obj[method](obj, table.unpack(args)) end)
    if ok then return val end
    return nil
end

local function cls_isInteresting(ClassName)
    if not ClassName then return false end
    -- Skip pure noise
    if ClassName == "StaticMeshActor" or ClassName == "SkeletalMeshActor" then return false end
    if string.find(ClassName, "Light") then return false end
    if string.find(ClassName, "Reflection") then return false end
    if ClassName == "PlayerCameraManager" or ClassName == "AIController" then return false end
    if ClassName == "TargetPoint" or ClassName == "PlayerStart" then return false end
    if string.find(ClassName, "Volume") then return false end
    if string.find(ClassName, "Trigger") then return false end
    if string.find(ClassName, "Niagara") then return false end
    if string.find(ClassName, "Decal") then return false end
    if string.find(ClassName, "Occluder") then return false end
    if string.find(ClassName, "FootStep") then return false end
    -- Keep Blueprints, PhysicalObj, Dither, SBZoneEnv, etc.
    if string.find(ClassName, "_C$") then return true end
    if string.find(ClassName, "^PhysicalObj_") then return true end
    if string.find(ClassName, "^Dither") then return true end
    if string.find(ClassName, "^SBZoneEnv") then return true end
    return false
end

local function ClassScan()
    local PC = FindFirstOf("PlayerController")
    if not PC or not PC.Pawn then return end
    local Eve = PC.Pawn
    local EveLoc = cls_safeCall(Eve, "K2_GetActorLocation")
    local EveRot = cls_safeCall(Eve, "K2_GetActorRotation")
    if not (EveLoc and EveRot) then return end

    local YawRad = math.rad(EveRot.Yaw or 0)
    local FwdX, FwdY = math.cos(YawRad), math.sin(YawRad)
    local RightX, RightY = -math.sin(YawRad), math.cos(YawRad)
    local MaxDist = 15000

    print(string.format("\n[%s] ===== CLASS DISCOVERY =====\n", CLS_MOD))
    print(string.format("[%s] Eve=(%.1f,%.1f,%.1f) Yaw=%.1f\n",
        CLS_MOD, EveLoc.X, EveLoc.Y, EveLoc.Z, EveRot.Yaw or 0))

    local AllActors = FindAllOf("Actor")
    if not AllActors then return end

    local classes = {}
    local totalInspected = 0
    for _, actor in ipairs(AllActors) do
        if actor and actor:IsValid() then
            local ClassName = actor:GetClass():GetFName():ToString()
            if cls_isInteresting(ClassName) then
                local Loc = cls_safeCall(actor, "K2_GetActorLocation")
                if Loc and Loc.X then
                    local dx, dy, dz = Loc.X - EveLoc.X, Loc.Y - EveLoc.Y, Loc.Z - EveLoc.Z
                    local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
                    if dist > 0 and dist <= MaxDist then
                        local fwd = dx * FwdX + dy * FwdY
                        local lat = dx * RightX + dy * RightY
                        if (fwd / dist) > 0.3 then  -- forward ~140° cone
                            totalInspected = totalInspected + 1
                            if not classes[ClassName] then
                                classes[ClassName] = {
                                    count = 0,
                                    minFwd = fwd, maxFwd = fwd,
                                    minLat = lat, maxLat = lat,
                                }
                            end
                            local c = classes[ClassName]
                            c.count = c.count + 1
                            if fwd < c.minFwd then c.minFwd = fwd end
                            if fwd > c.maxFwd then c.maxFwd = fwd end
                            if lat < c.minLat then c.minLat = lat end
                            if lat > c.maxLat then c.maxLat = lat end
                        end
                    end
                end
            end
        end
    end

    local sorted = {}
    for cls, data in pairs(classes) do
        table.insert(sorted, {cls = cls, data = data})
    end
    table.sort(sorted, function(a, b) return a.data.minFwd < b.data.minFwd end)

    print(string.format("[%s] %d interesting actors, %d unique classes\n",
        CLS_MOD, totalInspected, #sorted))
    for i, entry in ipairs(sorted) do
        local c = entry.data
        print(string.format("[%s] %2d. %-42s | n=%-3d Fwd=[%7.1f..%7.1f] Lat=[%+7.1f..%+7.1f]\n",
            CLS_MOD, i, entry.cls, c.count, c.minFwd, c.maxFwd, c.minLat, c.maxLat))
    end
    print(string.format("[%s] ===== END =====\n", CLS_MOD))
end

RegisterKeyBind(Key.F7, ClassScan)
print("[ClassDiscovery] Ready. F7 = scan unique classes.\n")


-- ============================================================
-- HYPERTUBE SPLINE RESEARCH (bound to F5) - V2 (World Space Fix)
-- ============================================================

local SPL_MOD = "SplineResearch"

local function spl_safeCall(obj, method, ...)
    if not obj then return nil end
    local args = {...}
    local ok, val = pcall(function() return obj[method](obj, table.unpack(args)) end)
    if ok then return val end
    return nil
end

local function vecStr(v)
    if v and v.X and v.Y and v.Z then
        return string.format("(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z)
    end
    return "nil"
end

-- Normalize a vector to get pure direction
local function normalizeVec(v)
    if not v or not v.X then return nil end
    local len = math.sqrt(v.X*v.X + v.Y*v.Y + v.Z*v.Z)
    if len == 0 then return {X=0, Y=0, Z=0} end
    return {X = v.X/len, Y = v.Y/len, Z = v.Z/len}
end

local function SplineResearch()
    print(string.format("\n[%s] ===== SPLINE RESEARCH V2 =====\n", SPL_MOD))

    local PC = FindFirstOf("PlayerController")
    if not PC or not PC.Pawn then return end
    local Eve = PC.Pawn
    local EveLoc = spl_safeCall(Eve, "K2_GetActorLocation")
    if not EveLoc then return end
    print(string.format("[%s] Eve=(%.2f, %.2f, %.2f)\n", SPL_MOD, EveLoc.X, EveLoc.Y, EveLoc.Z))

    local okA, tubeActors = pcall(function() return FindAllOf("BP_HypertubeSpline_C") end)
    if not okA or not tubeActors or #tubeActors == 0 then return end
    
    local okS, allSplines = pcall(function() return FindAllOf("SplineComponent") end)
    if not okS or not allSplines then return end

    for _, spline in ipairs(allSplines) do
        if spline and spline:IsValid() then
            local okO, owner = pcall(function() return spline:GetOwner() end)
            if okO and owner and owner:IsValid() then
                local okC, ownerClass = pcall(function() return owner:GetClass():GetFName():ToString() end)
                
                if okC and ownerClass == "BP_HypertubeSpline_C" then
                    print(string.format("\n[%s] Processing Spline on Actor: %s\n", SPL_MOD, ownerClass))
                    
                    -- 1. Get Actor's World Location (To prove the offset)
                    local actorLoc = spl_safeCall(owner, "K2_GetActorLocation")
                    print(string.format("[%s]   Spline Actor Location: %s\n", SPL_MOD, vecStr(actorLoc)))

                    -- 2. Find closest point using WORLD space (1 = World)
                    -- This is much safer and faster than looping manually
                    local closestLoc = spl_safeCall(spline, "FindLocationClosestToWorldLocation", EveLoc, 1)
                    local closestTan = spl_safeCall(spline, "FindTangentClosestToWorldLocation", EveLoc, 1)
                    local closestUp  = spl_safeCall(spline, "FindUpVectorClosestToWorldLocation", EveLoc, 1)

                    if closestLoc and closestLoc.X then
                        local dx = closestLoc.X - EveLoc.X
                        local dy = closestLoc.Y - EveLoc.Y
                        local dz = closestLoc.Z - EveLoc.Z
                        local dist = math.sqrt(dx*dx + dy*dy + dz*dz)

                        print(string.format("[%s]   World Closest Loc: %s (Dist: %.1f)\n", SPL_MOD, vecStr(closestLoc), dist))
                        print(string.format("[%s]   World Tangent:     %s\n", SPL_MOD, vecStr(closestTan)))
                        print(string.format("[%s]   World UpVector:    %s\n", SPL_MOD, vecStr(closestUp)))
                        
                        -- Normalize tangent to see true direction
                        local normTan = normalizeVec(closestTan)
                        print(string.format("[%s]   Norm Tangent:      %s\n", SPL_MOD, vecStr(normTan)))
                    else
                        print(string.format("[%s]   FindClosestToWorldLocation failed. Trying manual fallback...\n", SPL_MOD))
                        -- Fallback: If FindClosest crashes, read point 0 in World space
                        local pt0 = spl_safeCall(spline, "GetLocationAtSplinePoint", 0, 1)
                        print(string.format("[%s]   Point 0 (World): %s\n", SPL_MOD, vecStr(pt0)))
                    end
                end
            end
        end
    end
    print(string.format("\n[%s] ===== END =====\n", SPL_MOD))
end

RegisterKeyBind(Key.F5, SplineResearch)
print("[SplineResearch] Ready (V2). F5 = investigate hypertube spline.\n")


-- ============================================================
-- HYPERTUBE ADVISOR V3 - Two-Stage Architecture (Corrected)
-- ============================================================

local ADV_MOD = "AdvisorV3"
local ADV_INTERVAL_MS = 50
local ADV_PREP_INTERVAL_MS = 100
local ADV_EVE_RADIUS = 95.0
local ADV_CRUISE_SPEED = 4500.0
local ADV_SAFETY_MARGIN = 15.0

local prep_state = 0 -- 0=Idle, 1=WaitTube, 2=Building, 3=Ready
local adv_active = false
local prep_loop_created = false
local adv_loop_created = false

local cached_spline = nil
local cached_PC = nil
local cached_Pawn = nil
local cached_targets = {} -- Array of {actor = Actor, box = BoxComponent}
local box_comp_class = nil

local t_prep_start = 0
local last_theta, last_time = nil, nil
local geom_diag_seen = {}
local local_geom_seen = {}
local spline_api_probe_done = false

-- Delayed Action Handle
local adv_loop_handle = nil

-- Profiling for immediate first tick and periodic ticks
local prof_enabled = false
local prof_first_tick_executed = false
local prof_tick_count = 0
local prof_periodic_durations = {}
local prof_T_f4_enter = 0
local prof_T_first_tick_start = 0
local prof_T_first_tick_end = 0
local prof_T_periodic_loop_start = 0
local prof_T_periodic_tick_start = 0

-- Profiling variables (for first Advisor launch only)
local prof_started = false
local prof_first_adv_loop = false
local prof_first_adv_tick = false
local prof_T0, prof_T1, prof_T2, prof_T3, prof_T4, prof_T5
local prof_subsequent_durations = {}


local function vec_sub(a, b) return {X=a.X-b.X, Y=a.Y-b.Y, Z=a.Z-b.Z} end
local function vec_dot(a, b) return a.X*b.X + a.Y*b.Y + a.Z*b.Z end
local function vec_len(a) return math.sqrt(a.X*a.X + a.Y*a.Y + a.Z*a.Z) end
local function vec_norm(a) 
    local l = vec_len(a)
    if l == 0 then return {X=0, Y=0, Z=0} end
    return {X=a.X/l, Y=a.Y/l, Z=a.Z/l} 
end
local function vec_cross(a, b) return { X = a.Y*b.Z - a.Z*b.Y, Y = a.Z*b.X - a.X*b.Z, Z = a.X*b.Y - a.Y*b.X } end
local function normAngle(a)
    while a > 180 do a = a - 360 end
    while a < -180 do a = a + 360 end
    return a
end
local function angleDiff(target, current) return normAngle(target - current) end
local function adv_safeCall(obj, method, ...)
    if not obj then return nil end
    local args = {...}
    local ok, val = pcall(function() return obj[method](obj, table.unpack(args)) end)
    if ok then return val end
    return nil
end

-- >>> HTS:LOCAL_BOX_FRAME:BEGIN >>>
-- Diagnostic: calculate Box geometry in its own local spline frame
local function adv_measureLocalBoxFrame(
		boxLoc, boxFwd, boxRight, boxUp, ext,
		eveTan, eveCenter, eveSplineDistance
	)
	
    local sCenter = adv_safeCall(
        cached_spline, "FindLocationClosestToWorldLocation", boxLoc, 1
    )

    local sTanRaw = adv_safeCall(
        cached_spline, "FindTangentClosestToWorldLocation", boxLoc, 1
    )

    local sUpRaw = adv_safeCall(
        cached_spline, "FindUpVectorClosestToWorldLocation", boxLoc, 1
    )

    if not (sCenter and sTanRaw and sUpRaw) then
        return nil, "Spline query failed"
    end
	
	-- Distance along spline for obstacle and Eve
	local boxSplineKey = adv_safeCall(
		cached_spline,
		"FindInputKeyClosestToWorldLocation",
		boxLoc
	)

	local boxSplineDistance = nil

	if type(boxSplineKey) == "number" then
		boxSplineDistance = adv_safeCall(
			cached_spline,
			"GetDistanceAlongSplineAtSplineInputKey",
			boxSplineKey
		)
	end

	local splineDelta = nil

	if type(boxSplineDistance) == "number"
	and type(eveSplineDistance) == "number" then
		splineDelta = boxSplineDistance - eveSplineDistance
	end

	-- Existing straight-line projection from Eve to obstacle center
	local eveTangentFwd = vec_dot(
		vec_sub(boxLoc, eveCenter),
		eveTan
	)

	local splineFwdError = nil

	if splineDelta ~= nil then
		splineFwdError = splineDelta - eveTangentFwd
	end
	
    local sTan = vec_norm(sTanRaw)
    local sUpRawNorm = vec_norm(sUpRaw)

    local rightRaw = vec_cross(sUpRawNorm, sTan)

    if vec_len(rightRaw) < 0.001 then
        return nil, "Degenerate spline frame"
    end

    local sRight = vec_norm(rightRaw)
    local sUp = vec_norm(vec_cross(sTan, sRight))

    local centerVec = vec_sub(boxLoc, sCenter)
    local centerFwd = vec_dot(centerVec, sTan)

    local centerRadVec = vec_sub(centerVec, {
        X = sTan.X * centerFwd,
        Y = sTan.Y * centerFwd,
        Z = sTan.Z * centerFwd
    })

    local centerRad = vec_len(centerRadVec)

    if centerRad < 1.0 then
        return nil, "Center radial distance too small"
    end

    local centerTheta = math.deg(math.atan(
        vec_dot(centerRadVec, sUp),
        vec_dot(centerRadVec, sRight)
    ))

    local minRad, maxRad = 999999, -999999
    local minDelta, maxDelta = 999999, -999999
    local minFwd, maxFwd = 999999, -999999

    for sx = -1, 1, 2 do
        for sy = -1, 1, 2 do
            for sz = -1, 1, 2 do

                local corner = {
                    X = boxLoc.X + boxFwd.X * ext.X * sx
                        + boxRight.X * ext.Y * sy
                        + boxUp.X * ext.Z * sz,

                    Y = boxLoc.Y + boxFwd.Y * ext.X * sx
                        + boxRight.Y * ext.Y * sy
                        + boxUp.Y * ext.Z * sz,

                    Z = boxLoc.Z + boxFwd.Z * ext.X * sx
                        + boxRight.Z * ext.Y * sy
                        + boxUp.Z * ext.Z * sz
                }

                local cv = vec_sub(corner, sCenter)
                local cf = vec_dot(cv, sTan)

                local rv = vec_sub(cv, {
                    X = sTan.X * cf,
                    Y = sTan.Y * cf,
                    Z = sTan.Z * cf
                })

                local rd = vec_len(rv)

                if rd < minRad then minRad = rd end
                if rd > maxRad then maxRad = rd end

                if cf < minFwd then minFwd = cf end
                if cf > maxFwd then maxFwd = cf end

                if rd > 1.0 then
                    local theta = math.deg(math.atan(
                        vec_dot(rv, sUp),
                        vec_dot(rv, sRight)
                    ))

                    local delta = angleDiff(theta, centerTheta)

                    if delta < minDelta then minDelta = delta end
                    if delta > maxDelta then maxDelta = delta end
                end

            end
        end
    end

    local tangentDot = vec_dot(eveTan, sTan)
    tangentDot = math.max(-1, math.min(1, tangentDot))

    local tangentDiff = math.deg(math.acos(tangentDot))

    return {
        centerAlong = centerFwd,
        splineOffset = vec_len(centerVec),
		boxSplineDistance = boxSplineDistance,
		splineDelta = splineDelta,
		eveTangentFwd = eveTangentFwd,
		splineFwdError = splineFwdError,
        radCenter = centerRad,
        radMin = minRad,
        radMax = maxRad,
        thetaCenter = centerTheta,
        thetaMin = normAngle(centerTheta + minDelta),
        thetaMax = normAngle(centerTheta + maxDelta),
        sectorSpan = maxDelta - minDelta,
        cornerFwdMin = minFwd,
        cornerFwdMax = maxFwd,
        tangentDiff = tangentDiff
    }

end
-- <<< HTS:LOCAL_BOX_FRAME:END <<<

-- >>> HTS:PREP_INDEX:BEGIN >>>
-- ==========================================
-- STAGE A: PREPARATION (F3)
-- ==========================================
local cached_Eve = nil
local prep_heartbeat = 0

local function prep_tick()
    if prep_state == 1 then
        -- === STATE 1: Wait for tube entry ===
        if not cached_Eve or not cached_Eve:IsValid() then
            local PC = FindFirstOf("PlayerController")
            if PC and PC.Pawn then
                cached_Eve = PC.Pawn
            end
        end
        if not cached_Eve then return end
        
        local eveName = cached_Eve:GetFName():ToString()
        
        local caps = FindAllOf("CapsuleComponent")
        if not caps then return end
        
        local inTube = false
        local foundEveCapsule = false
        local debugRadius = 0
        
        for _, c in ipairs(caps) do
            if c and c:IsValid() then
                local okN, capName = pcall(function() return c:GetFName():ToString() end)
                if okN and capName == "CollisionCylinder" then
                    local owner = c:GetOwner()
                    if owner and owner:IsValid() then
                        local okON, oName = pcall(function() return owner:GetFName():ToString() end)
                        if okON and oName == eveName then
                            foundEveCapsule = true
                            local r = adv_safeCall(c, "GetScaledCapsuleRadius")
                            if r then
                                debugRadius = r
                                if r > 70 then inTube = true end
                            end
                            break
                        end
                    end
                end
            end
        end
        
        prep_heartbeat = prep_heartbeat + 1
        if prep_heartbeat % 30 == 0 then
            print(string.format("[%s] PREP HEARTBEAT #%d: foundEve=%s, CylR=%.1f, inTube=%s\n",
                ADV_MOD, prep_heartbeat, tostring(foundEveCapsule), debugRadius, tostring(inTube)))
        end
        
        if inTube then
            local delay = (os.clock() - t_prep_start) * 1000.0
            print(string.format("[%s] TUBE DETECTED (Delay: %.2f ms). Building Index...\n", ADV_MOD, delay))
            prep_state = 2
        end
        
    elseif prep_state == 2 then
        -- === STATE 2: Build Index (was missing in my previous message) ===
        local t_start = os.clock()
        cached_PC = FindFirstOf("PlayerController")
        if cached_PC then cached_Pawn = cached_PC.Pawn end
        
        -- Find Spline
        local splines = FindAllOf("SplineComponent")
        if splines then
            for _, s in ipairs(splines) do
                if s and s:IsValid() then
                    local owner = adv_safeCall(s, "GetOwner")
                    if owner and owner:IsValid() then
                        local cls = adv_safeCall(owner, "GetClass")
                        if cls and adv_safeCall(cls, "GetFName"):ToString() == "BP_HypertubeSpline_C" then
                            cached_spline = s; break
                        end
                    end
                end
            end
        end
        
        -- Find all BoxComponents (the slow part)
        local boxIndex = {}
        local t_box_start = os.clock()
        local boxes = FindAllOf("BoxComponent")
        local t_box_end = os.clock()
        
        if boxes then
            for _, b in ipairs(boxes) do
                if b and b:IsValid() then
                    local o = b:GetOwner()
                    if o and o:IsValid() then
                        boxIndex[o:GetFName():ToString()] = b
                    end
                end
            end
        end
        
        -- Find Targets
        cached_targets = {}
        local t_actor_start = os.clock()
        local actors = {}
        local b_actors = FindAllOf("BP_ContainerTrain_Box_C")
        local s_actors = FindAllOf("BP_DM_SE03_Sign_C")
        local t_actor_end = os.clock()
        
        local seen = {}
        if b_actors then for _, a in ipairs(b_actors) do table.insert(actors, a) end end
        if s_actors then for _, a in ipairs(s_actors) do table.insert(actors, a) end end
        
        for _, a in ipairs(actors) do
            if a and a:IsValid() then
                local name = a:GetFName():ToString()
                local comp = boxIndex[name]
                if comp and comp:IsValid() and not seen[name] then
                    seen[name] = true
                    table.insert(cached_targets, {actor = a, box = comp})
                end
            end
        end
        
        local total_time = (os.clock() - t_start) * 1000.0
        print(string.format("[%s] INDEX READY. Total: %.2f ms\n", ADV_MOD, total_time))
        print(string.format("[%s]   - FindAllOf(BoxComponent): %.2f ms\n", ADV_MOD, (t_box_end-t_box_start)*1000))
        print(string.format("[%s]   - Find Targets (Boxes+Signs): %.2f ms\n", ADV_MOD, (t_actor_end-t_actor_start)*1000))
        print(string.format("[%s]   - Cached valid targets: %d\n", ADV_MOD, #cached_targets))
        
        prep_state = 3
    end
end

local function prep_loop()
    if prep_state == 1 or prep_state == 2 then prep_tick() end
end
-- <<< HTS:PREP_INDEX:END <<<

-- ==========================================
-- STAGE B: ADVISOR (F4)
-- ==========================================
local iso_noop_logged = false
local function adv_tick()
    -- Profiling: T3 at the very start of the first adv_tick (before guard)
    if prof_enabled and prof_first_adv_tick then
        prof_T3 = os.clock()
        prof_first_adv_tick = false
    end
    
    if not adv_active or prep_state ~= 3 then return end
	
	-- TEMP ISOLATION TEST: no UObject access, no calculations
    if not iso_noop_logged then
        iso_noop_logged = true
        print(string.format(
            "[%s] [ISO] adv_tick entered. Targets=%d. Pre-target test.\n",
            ADV_MOD, #cached_targets
        ))
    end


    local tick_start = os.clock()
    
    if not cached_Pawn or not cached_Pawn:IsValid() or not cached_spline or not cached_spline:IsValid() then return end
    
    local EveLoc = adv_safeCall(cached_Pawn, "K2_GetActorLocation")
    if not EveLoc then return end
	
	-- >>> HTS:SPLINE_API_PROBE:BEGIN >>>
	-- TEMP: inspect spline distance API availability
	if not spline_api_probe_done then
		spline_api_probe_done = true

		local okDirect, directValue = pcall(function()
			return cached_spline:GetDistanceAlongSplineAtLocation(EveLoc, 1)
		end)

		local okKey, inputKey = pcall(function()
			return cached_spline:FindInputKeyClosestToWorldLocation(EveLoc)
		end)

		local okPoint, pointDistance = false, nil
		local okInputDistance, inputDistance = false, nil
		local okInputLoc, inputLocation = false, nil

		if okKey and type(inputKey) == "number" then
			local pointIndex = math.floor(inputKey)

			okPoint, pointDistance = pcall(function()
				return cached_spline:GetDistanceAlongSplineAtSplinePoint(pointIndex)
			end)
			
			okInputDistance, inputDistance = pcall(function()
				return cached_spline:GetDistanceAlongSplineAtSplineInputKey(inputKey)
			end)

			okInputLoc, inputLocation = pcall(function()
				return cached_spline:GetLocationAtSplineInputKey(inputKey, 1)
			end)
		end

		local okCount, pointCount = pcall(function()
			return cached_spline:GetNumberOfSplinePoints()
		end)

		local okLength, splineLength = pcall(function()
			return cached_spline:GetSplineLength()
		end)

		local function probeText(ok, value)
			return (ok and "OK: " or "ERR: ") .. tostring(value)
		end

		print(string.format(
			"[%s] [SPLINE-API-PROBE] Direct=%s | InputKey=%s | PointDistance=%s | InputDistance=%s | LocationAtKey=%s | PointCount=%s | SplineLength=%s\n",
			ADV_MOD,
			probeText(okDirect, directValue),
			probeText(okKey, inputKey),
			probeText(okPoint, pointDistance),
			probeText(okInputDistance, inputDistance),
			probeText(okInputLoc, inputLocation),
			probeText(okCount, pointCount),
			probeText(okLength, splineLength)
		))
	end
	
	-- <<< HTS:SPLINE_API_PROBE:END <<<
	
	-- >>> HTS:EVE_SPLINE_DISTANCE:BEGIN >>>
	local eveSplineKey = adv_safeCall(
		cached_spline,
		"FindInputKeyClosestToWorldLocation",
		EveLoc
	)

	local eveSplineDistance = nil

	if type(eveSplineKey) == "number" then
		eveSplineDistance = adv_safeCall(
			cached_spline,
			"GetDistanceAlongSplineAtSplineInputKey",
			eveSplineKey
		)
	end
	-- <<< HTS:EVE_SPLINE_DISTANCE:END <<<
    
	-- >>> HTS:EVE_FRAME_OMEGA:BEGIN >>>
    local Center = adv_safeCall(cached_spline, "FindLocationClosestToWorldLocation", EveLoc, 1)
    local Tan = adv_safeCall(cached_spline, "FindTangentClosestToWorldLocation", EveLoc, 1)
    local Up = adv_safeCall(cached_spline, "FindUpVectorClosestToWorldLocation", EveLoc, 1)
    if not (Center and Tan and Up) then return end
    
    Tan = vec_norm(Tan); Up = vec_norm(Up)
    local Right = vec_norm(vec_cross(Up, Tan))
    
    local eVec = vec_sub(EveLoc, Center)
    local eFwd = vec_dot(eVec, Tan)
    local eRadVec = vec_sub(eVec, {X=Tan.X*eFwd, Y=Tan.Y*eFwd, Z=Tan.Z*eFwd})
    local eTheta = math.deg(math.atan(vec_dot(eRadVec, Up), vec_dot(eRadVec, Right)))
    

	local now_clock = os.clock()

	local omega = 0
	if last_theta and last_time then
		local dt = now_clock - last_time
		if dt > 0 then
			omega = angleDiff(eTheta, last_theta) / dt
		end
	end

	last_theta = eTheta
	last_time = now_clock
	-- <<< HTS:EVE_FRAME_OMEGA:END <<<
    
	
	-- >>> HTS:OBSTACLE_SCAN:BEGIN >>>
    local closestObs = nil
	local minDist = 6000.0
	local localGeomBudget = 3

	for _, entry in ipairs(cached_targets) do
        local actor = entry.actor
        local box = entry.box
        if actor:IsValid() and box:IsValid() then
		local boxLoc = adv_safeCall(box, "K2_GetComponentLocation")
		local ext = adv_safeCall(box, "GetScaledBoxExtent")

			if boxLoc and ext then
				local aFwd = adv_safeCall(box, "GetForwardVector")
				local aRight = adv_safeCall(box, "GetRightVector")
				local aUp = adv_safeCall(box, "GetUpVector")
                
				-- >>> HTS:LOCAL_GEOM_AUDIT:BEGIN >>>
				-- TEMP: obstacle-local spline geometry audit
				if localGeomBudget > 0 then

					local objectName = actor:GetFName():ToString()

					if not local_geom_seen[objectName] then

						local_geom_seen[objectName] = true
						localGeomBudget = localGeomBudget - 1

						local m, err = adv_measureLocalBoxFrame(
							boxLoc, aFwd, aRight, aUp, ext,
							Tan, Center, eveSplineDistance
						)

						if m then
							
							local eveSText = eveSplineDistance
								and string.format("%.1f", eveSplineDistance)
								or "NA"

							local boxSText = m.boxSplineDistance
								and string.format("%.1f", m.boxSplineDistance)
								or "NA"

							local splineDeltaText = m.splineDelta
								and string.format("%.1f", m.splineDelta)
								or "NA"

							local splineErrorText = m.splineFwdError
								and string.format("%.1f", m.splineFwdError)
								or "NA"

							print(string.format(
								"[%s] [LOCAL-GEOM] %s | SplineOffset=%.1f | CenterAlong=%.1f | RadCenter=%.1f | RadCorners=[%.1f..%.1f] | ThetaCenter=%.1f | LocalSector=[%.1f..%.1f] Span=%.1f | TangentDiff=%.1f deg | EveS=%s | BoxS=%s | SplineDelta=%s | EveTangentFwd=%.1f | DeltaError=%s\n",
								ADV_MOD,
								objectName,
								m.splineOffset,
								m.centerAlong,
								m.radCenter,
								m.radMin,
								m.radMax,
								m.thetaCenter,
								m.thetaMin,
								m.thetaMax,
								m.sectorSpan,
								m.tangentDiff,
								eveSText,
								boxSText,
								splineDeltaText,
								m.eveTangentFwd,
								splineErrorText
							))

						else

							print(string.format(
								"[%s] [LOCAL-GEOM-FAIL] %s: %s\n",
								ADV_MOD, objectName, tostring(err)
							))

						end
					end
				end
				-- <<< HTS:LOCAL_GEOM_AUDIT:END <<<
				
				-- >>> HTS:OBSTACLE_GEOMETRY:BEGIN >>>
                local cCenterVec = vec_sub(boxLoc, Center)
                local cCenterFwd = vec_dot(cCenterVec, Tan)
				local cCenterRad = vec_len(vec_sub(cCenterVec, {
					X = Tan.X * cCenterFwd,
					Y = Tan.Y * cCenterFwd,
					Z = Tan.Z * cCenterFwd
				}))
                local cThetaCenter = math.deg(math.atan(vec_dot(vec_sub(cCenterVec, {X=Tan.X*cCenterFwd, Y=Tan.Y*cCenterFwd, Z=Tan.Z*cCenterFwd}), Up), vec_dot(vec_sub(cCenterVec, {X=Tan.X*cCenterFwd, Y=Tan.Y*cCenterFwd, Z=Tan.Z*cCenterFwd}), Right)))
                
                local minFwd, maxFwd = 999999, -999999
				local minDelta, maxDelta = 999999, -999999
				local minRad, maxRad = 999999, -999999
                
                for sx = -1, 1, 2 do for sy = -1, 1, 2 do for sz = -1, 1, 2 do
                    local corner = {
                        X = boxLoc.X + (aFwd.X*ext.X*sx) + (aRight.X*ext.Y*sy) + (aUp.X*ext.Z*sz),
                        Y = boxLoc.Y + (aFwd.Y*ext.X*sx) + (aRight.Y*ext.Y*sy) + (aUp.Y*ext.Z*sz),
                        Z = boxLoc.Z + (aFwd.Z*ext.X*sx) + (aRight.Z*ext.Y*sy) + (aUp.Z*ext.Z*sz)
                    }
                    local cVec = vec_sub(corner, Center)
                    local cFwd = vec_dot(cVec, Tan)
					local cRadVec = vec_sub(cVec, {X=Tan.X*cFwd, Y=Tan.Y*cFwd, Z=Tan.Z*cFwd})
					local cRadDist = vec_len(cRadVec)

					if cRadDist < minRad then minRad = cRadDist end
					if cRadDist > maxRad then maxRad = cRadDist end

					local cTheta = math.deg(math.atan(vec_dot(cRadVec, Up), vec_dot(cRadVec, Right)))
                    local delta = angleDiff(cTheta, cThetaCenter)
                    
                    if cFwd < minFwd then minFwd = cFwd end
                    if cFwd > maxFwd then maxFwd = cFwd end
                    if delta < minDelta then minDelta = delta end
                    if delta > maxDelta then maxDelta = delta end
                end end end
                
                local minTheta = normAngle(cThetaCenter + minDelta)
                local maxTheta = normAngle(cThetaCenter + maxDelta)
				-- <<< HTS:OBSTACLE_GEOMETRY:END <<<
				
                local effectiveFwd = minFwd - ADV_EVE_RADIUS
                
                if effectiveFwd > 0 and effectiveFwd < minDist then
                    local function isAngleInSector(angle, min, max)
                        local a = (angle + 360) % 360; local m = (min + 360) % 360; local x = (max + 360) % 360
                        if m <= x then return a >= m and a <= x else return a >= m or a <= x end
                    end
                    
                    local inSector = isAngleInSector(eTheta, minTheta, maxTheta)
                    local ttc = effectiveFwd / ADV_CRUISE_SPEED
                    local predTheta = normAngle(eTheta + (omega * ttc))
                    local predInSector = isAngleInSector(predTheta, minTheta, maxTheta)
                    
                    if inSector or predInSector then
						-- TEMP: compare Actor transform with BoxComponent transform
						local actorLoc = adv_safeCall(actor, "K2_GetActorLocation")
						local actorFwd = adv_safeCall(actor, "GetActorForwardVector")
						local actorRight = adv_safeCall(actor, "GetActorRightVector")
						local actorUp = adv_safeCall(actor, "GetActorUpVector")

						local actorBoxOffset = -1
						local actorBoxFwdDiff = -1
						local actorBoxRightDiff = -1
						local actorBoxUpDiff = -1

						local actorBoxOffsetFwd = -1
						local actorBoxOffsetRight = -1
						local actorBoxOffsetUp = -1

						if actorLoc then
							local offsetVec = vec_sub(boxLoc, actorLoc)
							actorBoxOffset = vec_len(offsetVec)

							if actorFwd and actorRight and actorUp then
								actorBoxOffsetFwd = vec_dot(offsetVec, actorFwd)
								actorBoxOffsetRight = vec_dot(offsetVec, actorRight)
								actorBoxOffsetUp = vec_dot(offsetVec, actorUp)
							end
						end

						local function axisDiffDeg(v1, v2)
							if not v1 or not v2 then return -1 end
							local d = math.abs(vec_dot(v1, v2))
							if d > 1 then d = 1 end
							return math.deg(math.acos(d))
						end

						actorBoxFwdDiff = axisDiffDeg(actorFwd, aFwd)
						actorBoxRightDiff = axisDiffDeg(actorRight, aRight)
						actorBoxUpDiff = axisDiffDeg(actorUp, aUp)
					
                        local distToMin = math.abs(angleDiff(minTheta, eTheta))
                        local distToMax = math.abs(angleDiff(maxTheta, eTheta))
                        local targetTheta
                        if distToMin < distToMax then targetTheta = normAngle(minTheta - ADV_SAFETY_MARGIN)
                        else targetTheta = normAngle(maxTheta + ADV_SAFETY_MARGIN) end
                        local reqDelta = angleDiff(targetTheta, eTheta)
                        local direction = reqDelta < 0 and "A (Left)" or "D (Right)"
                        
                        closestObs = {
                            name = actor:GetFName():ToString(), cls = adv_safeCall(actor:GetClass(), "GetFName"):ToString(), 
                            dist = effectiveFwd, ttc = ttc, minTheta = minTheta, maxTheta = maxTheta,
                            targetTheta = targetTheta, reqDelta = reqDelta, direction = direction,
							predTheta = predTheta, predDanger = predInSector, nowInSector = inSector,
							sectorSpan = maxDelta - minDelta,
							actorBoxOffset = actorBoxOffset,
							actorBoxFwdDiff = actorBoxFwdDiff,
							actorBoxRightDiff = actorBoxRightDiff,
							actorBoxUpDiff = actorBoxUpDiff,
							actorBoxOffsetFwd = actorBoxOffsetFwd,
							actorBoxOffsetRight = actorBoxOffsetRight,
							actorBoxOffsetUp = actorBoxOffsetUp,
							centerRad = cCenterRad,
							radMin = minRad,
							radMax = maxRad
                        }
                        minDist = effectiveFwd
                    end
                end
            end
        end
    end
    -- <<< HTS:OBSTACLE_SCAN:END <<<
	
	
    -- Profiling: T4 before output
    if prof_enabled then
        prof_T4 = os.clock()
    end
	
    -- >>> HTS:ADVISOR_OUTPUT:BEGIN >>>
    if closestObs then
	        if not geom_diag_seen[closestObs.name] then
            geom_diag_seen[closestObs.name] = true

            print(string.format(
				"[%s] [GEOM-AUDIT] %s | SectorSpan=%.1f deg | RadCenter=%.1f | RadCorners=[%.1f..%.1f] | ActorBoxOffset=%.2f | AxisDiff F/R/U=%.2f/%.2f/%.2f deg | OffsetLocal F/R/U=%.2f/%.2f/%.2f\n",
                ADV_MOD,
                closestObs.name,
                closestObs.sectorSpan,
                closestObs.centerRad,
                closestObs.radMin,
                closestObs.radMax,
				closestObs.actorBoxOffset,
                closestObs.actorBoxFwdDiff,
                closestObs.actorBoxRightDiff,
                closestObs.actorBoxUpDiff,
				closestObs.actorBoxOffsetFwd,
				closestObs.actorBoxOffsetRight,
				closestObs.actorBoxOffsetUp
            ))
			end
        local status = "[SAFE-APPROACHING]"
        if closestObs.nowInSector and closestObs.predDanger then status = "[DANGER-INSIDE]"
        elseif closestObs.nowInSector and not closestObs.predDanger then status = "[IN-SECTOR-EXITING]"
        elseif not closestObs.nowInSector and closestObs.predDanger then status = "[WILL-ENTER]" end
        
        print(string.format("\n[%s] %s %s | Dist=%.0f | TTC=%.2fs\n", ADV_MOD, status, closestObs.cls, closestObs.dist, closestObs.ttc))
        print(string.format("[%s]    EveTheta=%.1f | Sector=[%.1f..%.1f]\n", ADV_MOD, eTheta, closestObs.minTheta, closestObs.maxTheta))
        print(string.format("[%s]    Omega=%.1f deg/s | PredTheta=%.1f\n", ADV_MOD, omega, closestObs.predTheta))
        print(string.format("[%s]    REQ: Theta=%.1f (Delta=%.1f) -> Hold %s\n", ADV_MOD, closestObs.targetTheta, closestObs.reqDelta, closestObs.direction))
    end
    -- <<< HTS:ADVISOR_OUTPUT:END <<<
	
    -- Profiling: T5 after output and summary for first tick
    if prof_enabled then
        prof_T5 = os.clock()
        if prof_tick_count == 0 then
            local T0 = prof_T0 or 0
            local T1 = prof_T1 or 0
            local T2 = prof_T2 or 0
            local T3 = prof_T3 or 0
            local T4 = prof_T4 or 0
            local T5 = prof_T5 or 0
            print(string.format("\n[PROF] ===== FIRST ADVISOR TICK PROFILING =====\n"))
            print(string.format("[PROF] T0=%.4f T1=%.4f T2=%.4f T3=%.4f T4=%.4f T5=%.4f\n", T0, T1, T2, T3, T4, T5))
            print(string.format("[PROF] T1-T0 (prep before LoopAsync): %.2f ms\n", (T1-T0)*1000))
            print(string.format("[PROF] T2-T1 (delay to first callback): %.2f ms\n", (T2-T1)*1000))
            print(string.format("[PROF] T3-T2 (delay inside callback to tick start): %.2f ms\n", (T3-T2)*1000))
            print(string.format("[PROF] T4-T3 (computation time): %.2f ms\n", (T4-T3)*1000))
            print(string.format("[PROF] T5-T4 (logging time): %.2f ms\n", (T5-T4)*1000))
            print(string.format("[PROF] Total first tick (T5-T3): %.2f ms\n", (T5-T3)*1000))
            print(string.format("[PROF] ==========================================\n"))
        else
            local dur = (prof_T5 - tick_start) * 1000
            table.insert(prof_subsequent_durations, dur)
            if #prof_subsequent_durations <= 5 then
                print(string.format("[PROF] Subsequent tick #%d duration: %.2f ms\n", #prof_subsequent_durations, dur))
            end
            if #prof_subsequent_durations >= 5 then
                prof_enabled = false
                print(string.format("[PROF] Profiling complete (first tick + 5 subsequent).\n"))
            end
        end
        prof_tick_count = prof_tick_count + 1
    end
end

-- ==========================================
-- TOGGLES
-- ==========================================
-- >>> HTS:INPUT_HANDLERS:BEGIN >>>
local function toggle_prep()
    if prep_state == 0 then
        -- Start preparation
        prep_state = 1
		geom_diag_seen = {}
		local_geom_seen = {}
        t_prep_start = os.clock()
        print(string.format("[%s] === PREP STARTED (F3). Waiting for tube entry... ===\n", ADV_MOD))
        if not prep_loop_created then
            prep_loop_created = true
            LoopAsync(ADV_PREP_INTERVAL_MS, prep_loop)
        end
    else
        -- Full stop and clear
        prep_state = 0
        adv_active = false
        
        -- Cancel the periodic Advisor loop (if running)
        if adv_loop_handle then
            CancelDelayedAction(adv_loop_handle)
            adv_loop_handle = nil
        end
        
        cached_targets = {}
        cached_spline = nil
        print(string.format("[%s] === PREP STOPPED & CLEARED ===\n", ADV_MOD))
    end
end




local function toggle_adv()
    if prep_state ~= 3 then
        print(string.format("[%s] ERROR: Index not ready. Press F3 first.\n", ADV_MOD))
        return
    end

    if adv_active then
        adv_active = false
        print(string.format("[%s] === ADVISOR STOPPED ===\n", ADV_MOD))
    else
        adv_active = true
        last_theta = nil
        last_time = nil

        print(string.format("[%s] === ADVISOR STARTED (NO-OP TEST) ===\n", ADV_MOD))

        if not adv_loop_created then
            adv_loop_created = true

            LoopAsync(ADV_INTERVAL_MS, function()
                if not adv_active then return end
                adv_tick()
            end)
        end
    end
end





RegisterKeyBind(Key.F3, toggle_prep)
RegisterKeyBind(Key.MULTIPLY, toggle_adv)
-- <<< HTS:INPUT_HANDLERS:END <<<
print("[AdvisorV3] Ready. F3 = Prep, F4 = Advisor.\n")
