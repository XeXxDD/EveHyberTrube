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
            "[%s] [ISO] adv_tick entered. Targets=%d. No-op mode.\n",
            ADV_MOD, #cached_targets
        ))
    end
    return
    
    local tick_start = os.clock()  -- for subsequent ticks (first tick uses T3)
    
    if not cached_Pawn or not cached_Pawn:IsValid() or not cached_spline or not cached_spline:IsValid() then return end
    
    local EveLoc = adv_safeCall(cached_Pawn, "K2_GetActorLocation")
    if not EveLoc then return end
    
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
    
    local omega = 0
    if last_theta and last_time then
        local dt = os.clock() - last_time
        if dt > 0 then omega = angleDiff(eTheta, last_theta) / dt end
    end
    last_theta = eTheta; last_time = os.clock()
    
    local closestObs = nil
    local minDist = 6000.0
    
    for _, entry in ipairs(cached_targets) do
        local actor = entry.actor
        local box = entry.box
        if actor:IsValid() and box:IsValid() then
            local loc = adv_safeCall(actor, "K2_GetActorLocation")
            local ext = adv_safeCall(box, "GetScaledBoxExtent")
            
            if loc and ext then
                local aFwd = adv_safeCall(actor, "GetActorForwardVector")
                local aRight = adv_safeCall(actor, "GetActorRightVector")
                local aUp = adv_safeCall(actor, "GetActorUpVector")
                
                local cCenterVec = vec_sub(loc, Center)
                local cCenterFwd = vec_dot(cCenterVec, Tan)
                local cThetaCenter = math.deg(math.atan(vec_dot(vec_sub(cCenterVec, {X=Tan.X*cCenterFwd, Y=Tan.Y*cCenterFwd, Z=Tan.Z*cCenterFwd}), Up), vec_dot(vec_sub(cCenterVec, {X=Tan.X*cCenterFwd, Y=Tan.Y*cCenterFwd, Z=Tan.Z*cCenterFwd}), Right)))
                
                local minFwd, maxFwd = 999999, -999999
                local minDelta, maxDelta = 999999, -999999
                
                for sx = -1, 1, 2 do for sy = -1, 1, 2 do for sz = -1, 1, 2 do
                    local corner = {
                        X = loc.X + (aFwd.X*ext.X*sx) + (aRight.X*ext.Y*sy) + (aUp.X*ext.Z*sz),
                        Y = loc.Y + (aFwd.Y*ext.X*sx) + (aRight.Y*ext.Y*sy) + (aUp.Y*ext.Z*sz),
                        Z = loc.Z + (aFwd.Z*ext.X*sx) + (aRight.Z*ext.Y*sy) + (aUp.Z*ext.Z*sz)
                    }
                    local cVec = vec_sub(corner, Center)
                    local cFwd = vec_dot(cVec, Tan)
                    local cRadVec = vec_sub(cVec, {X=Tan.X*cFwd, Y=Tan.Y*cFwd, Z=Tan.Z*cFwd})
                    local cTheta = math.deg(math.atan(vec_dot(cRadVec, Up), vec_dot(cRadVec, Right)))
                    local delta = angleDiff(cTheta, cThetaCenter)
                    
                    if cFwd < minFwd then minFwd = cFwd end
                    if cFwd > maxFwd then maxFwd = cFwd end
                    if delta < minDelta then minDelta = delta end
                    if delta > maxDelta then maxDelta = delta end
                end end end
                
                local minTheta = normAngle(cThetaCenter + minDelta)
                local maxTheta = normAngle(cThetaCenter + maxDelta)
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
                            predTheta = predTheta, predDanger = predInSector, nowInSector = inSector
                        }
                        minDist = effectiveFwd
                    end
                end
            end
        end
    end
    
    -- Profiling: T4 before output
    if prof_enabled then
        prof_T4 = os.clock()
    end
    
    if closestObs then
        local status = "[SAFE-APPROACHING]"
        if closestObs.nowInSector and closestObs.predDanger then status = "[DANGER-INSIDE]"
        elseif closestObs.nowInSector and not closestObs.predDanger then status = "[IN-SECTOR-EXITING]"
        elseif not closestObs.nowInSector and closestObs.predDanger then status = "[WILL-ENTER]" end
        
        print(string.format("\n[%s] %s %s | Dist=%.0f | TTC=%.2fs\n", ADV_MOD, status, closestObs.cls, closestObs.dist, closestObs.ttc))
        print(string.format("[%s]    EveTheta=%.1f | Sector=[%.1f..%.1f]\n", ADV_MOD, eTheta, closestObs.minTheta, closestObs.maxTheta))
        print(string.format("[%s]    Omega=%.1f deg/s | PredTheta=%.1f\n", ADV_MOD, omega, closestObs.predTheta))
        print(string.format("[%s]    REQ: Theta=%.1f (Delta=%.1f) -> Hold %s\n", ADV_MOD, closestObs.targetTheta, closestObs.reqDelta, closestObs.direction))
    end
    
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
local function toggle_prep()
    if prep_state == 0 then
        -- Start preparation
        prep_state = 1
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

        print(string.format("[%s] === ADVISOR STARTED (F4 to stop) ===\n", ADV_MOD))

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
RegisterKeyBind(Key.F4, toggle_adv)
print("[AdvisorV3] Ready. F3 = Prep, F4 = Advisor.\n")
