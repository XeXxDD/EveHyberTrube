-- Scripts/main.lua
local ModName = "BoxDiagnostic"

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
		eveTan, eveUp, eveTheta, eveCenter, eveSplineDistance
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


    -- TEMP: compare spline frames using shortest tangent alignment
    local minRotTwist = nil

    if eveTan and eveUp then

        local eTan = vec_norm(eveTan)

        -- Make Eve Up perpendicular to Eve Tangent
        local eUpProjection = vec_sub(eveUp, {
            X = eTan.X * vec_dot(eveUp, eTan),
            Y = eTan.Y * vec_dot(eveUp, eTan),
            Z = eTan.Z * vec_dot(eveUp, eTan)
        })

        if vec_len(eUpProjection) > 0.001 then

            local eUp = vec_norm(eUpProjection)

            local alignmentDot = vec_dot(eTan, sTan)
            alignmentDot = math.max(-1, math.min(1, alignmentDot))

            local axisRaw = vec_cross(eTan, sTan)
            local sinAngle = vec_len(axisRaw)

            local transportedUp = nil

            if sinAngle < 0.000001 then

                if alignmentDot > 0 then
                    transportedUp = eUp
                end

            else

                local axis = vec_norm(axisRaw)
                local axisCrossUp = vec_cross(axis, eUp)
                local axisDotUp = vec_dot(axis, eUp)

                transportedUp = {
                    X = eUp.X * alignmentDot
                        + axisCrossUp.X * sinAngle
                        + axis.X * axisDotUp * (1 - alignmentDot),

                    Y = eUp.Y * alignmentDot
                        + axisCrossUp.Y * sinAngle
                        + axis.Y * axisDotUp * (1 - alignmentDot),

                    Z = eUp.Z * alignmentDot
                        + axisCrossUp.Z * sinAngle
                        + axis.Z * axisDotUp * (1 - alignmentDot)
                }
            end

            if transportedUp then

                -- Re-orthogonalize against obstacle tangent
                local proj = vec_dot(transportedUp, sTan)

                transportedUp = vec_sub(transportedUp, {
                    X = sTan.X * proj,
                    Y = sTan.Y * proj,
                    Z = sTan.Z * proj
                })

                if vec_len(transportedUp) > 0.001 then

                    transportedUp = vec_norm(transportedUp)

                    local transportedRight = vec_norm(
                        vec_cross(transportedUp, sTan)
                    )

                    transportedUp = vec_norm(
                        vec_cross(sTan, transportedRight)
                    )

                    local twistSin = vec_dot(
                        vec_cross(transportedUp, sUp),
                        sTan
                    )

                    local twistCos = vec_dot(transportedUp, sUp)
                    twistCos = math.max(-1, math.min(1, twistCos))

                    minRotTwist = math.deg(
                        math.atan(twistSin, twistCos)
                    )
                end
            end
        end
    end


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
	
	local localThetaMin = normAngle(centerTheta + minDelta)
	local localThetaMax = normAngle(centerTheta + maxDelta)

	local thetaCenterMinRot = nil
	local thetaMinMinRot = nil
	local thetaMaxMinRot = nil
	local deltaThetaEveMinRot = nil

	if minRotTwist ~= nil then
		thetaCenterMinRot = normAngle(centerTheta + minRotTwist)
		thetaMinMinRot = normAngle(localThetaMin + minRotTwist)
		thetaMaxMinRot = normAngle(localThetaMax + minRotTwist)

		if eveTheta ~= nil then
			deltaThetaEveMinRot = angleDiff(
				thetaCenterMinRot, eveTheta
			)
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
		tangentDiff = tangentDiff,
		minRotTwist = minRotTwist,
		thetaCenterMinRot = thetaCenterMinRot,
		thetaMinMinRot = thetaMinMinRot,
		thetaMaxMinRot = thetaMaxMinRot,
		deltaThetaEveMinRot = deltaThetaEveMinRot
    }

end
-- <<< HTS:LOCAL_BOX_FRAME:END <<<

-- >>> HTS:PREP_INDEX:BEGIN >>>
-- ==========================================
-- STAGE A: PREPARATION (F3)
-- ==========================================

-- >>> HTS:VISUAL_ASSET_CACHE:BEGIN >>>

local HTS_VISUAL_ASSETS = {
    attempted = false,
    pending = false,
    ready = false,

    actorClass = nil,
    cubeMesh = nil,
    baseMaterial = nil
}

local function hts_visual_asset_isValid(obj)
    if not obj then return false end

    local ok, result = pcall(function()
        return obj:IsValid()
    end)

    return ok and result == true
end


local function hts_preload_visual_assets()

    if HTS_VISUAL_ASSETS.ready then
        return true
    end

    if HTS_VISUAL_ASSETS.pending then
        return false
    end

    if HTS_VISUAL_ASSETS.attempted then
        return false
    end

    -- Prevent duplicate requests.
    HTS_VISUAL_ASSETS.attempted = true
    HTS_VISUAL_ASSETS.pending = true

    print("[HTS-ASSETS] Queueing preload on game thread.\n")

    local queueOK, queueErr = pcall(function()

        ExecuteInGameThread(function()

            local stage = "StaticMeshActor"
            local tStart = os.clock()

            local loadOK, loadErr = pcall(function()

                HTS_VISUAL_ASSETS.actorClass =
                    StaticFindObject(
                        "/Script/Engine.StaticMeshActor"
                    )

                if not hts_visual_asset_isValid(
                    HTS_VISUAL_ASSETS.actorClass
                ) then
                    error("StaticMeshActor class unavailable")
                end

                stage = "Cube.Cube"

                HTS_VISUAL_ASSETS.cubeMesh =
                    LoadAsset(
                        "/Engine/BasicShapes/Cube.Cube"
                    )

                if not hts_visual_asset_isValid(
                    HTS_VISUAL_ASSETS.cubeMesh
                ) then
                    error("Cube mesh unavailable")
                end

				stage = "EmissiveMeshMaterial"

				local engine = FindFirstOf("Engine")

				if not hts_visual_asset_isValid(engine) then
					error("UEngine instance unavailable")
				end

				HTS_VISUAL_ASSETS.baseMaterial =
					engine.EmissiveMeshMaterial

				if not hts_visual_asset_isValid(
					HTS_VISUAL_ASSETS.baseMaterial
				) then
					error("EmissiveMeshMaterial unavailable")
				end

				print(
					"[HTS-ASSETS] EmissiveMeshMaterial ready: " ..
					HTS_VISUAL_ASSETS.baseMaterial:GetFullName() .. "\n"
				)

            end)

            -- Game-thread callback has finished.
            HTS_VISUAL_ASSETS.pending = false

            if not loadOK then

                HTS_VISUAL_ASSETS.error =
                    stage .. ": " .. tostring(loadErr)

                print(
                    "[HTS-ASSETS] PRELOAD FAILED: " ..
                    HTS_VISUAL_ASSETS.error .. "\n"
                )

                return
            end

            HTS_VISUAL_ASSETS.ready = true
            HTS_VISUAL_ASSETS.error = nil

            print(string.format(
                "[HTS-ASSETS] PRELOAD COMPLETE in %.2f ms\n",
                (os.clock() - tStart) * 1000.0
            ))

            print("[HTS-ASSETS] StaticMeshActor ready.\n")
            print("[HTS-ASSETS] Cube mesh ready.\n")
            print("[HTS-ASSETS] EmissiveMeshMaterial ready.\n")

        end)

    end)

    if not queueOK then

        HTS_VISUAL_ASSETS.pending = false

        HTS_VISUAL_ASSETS.error =
            "ExecuteInGameThread: " .. tostring(queueErr)

        print(
            "[HTS-ASSETS] QUEUE FAILED: " ..
            HTS_VISUAL_ASSETS.error .. "\n"
        )

    end

    return false
end


-- <<< HTS:VISUAL_ASSET_CACHE:END <<<

local cached_Eve = nil
local prep_heartbeat = 0

local function prep_tick()
	if not HTS_VISUAL_ASSETS.ready
	and not HTS_VISUAL_ASSETS.attempted then

		hts_preload_visual_assets()
		return
	end

	-- Wait until the game-thread preload callback finishes.
	if HTS_VISUAL_ASSETS.pending then
		return
	end
	
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
			"[%s] [SPLINE-API-PROBE] InputKey=%s | PointDistance=%s | InputDistance=%s | LocationAtKey=%s | PointCount=%s | SplineLength=%s\n",
			ADV_MOD,
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
							Tan, Up, eTheta, Center, eveSplineDistance
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
							
							local minRotTwistText = m.minRotTwist
								and string.format("%.1f", m.minRotTwist) or "NA"

							local thetaCenterMinRotText = m.thetaCenterMinRot
								and string.format("%.1f", m.thetaCenterMinRot) or "NA"

							local deltaThetaEveMinRotText = m.deltaThetaEveMinRot
								and string.format("%.1f", m.deltaThetaEveMinRot) or "NA"

							local thetaMinMinRotText = m.thetaMinMinRot
								and string.format("%.1f", m.thetaMinMinRot) or "NA"

							local thetaMaxMinRotText = m.thetaMaxMinRot
								and string.format("%.1f", m.thetaMaxMinRot) or "NA"
							
							print(string.format(
								"[%s] [LOCAL-GEOM] %s | SplineOffset=%.1f | CenterAlong=%.1f | RadCenter=%.1f | RadCorners=[%.1f..%.1f] | ThetaCenter=%.1f | LocalSector=[%.1f..%.1f] Span=%.1f | TangentDiff=%.1f deg | EveS=%s | BoxS=%s | SplineDelta=%s | EveTangentFwd=%.1f | DeltaError=%s | MinRotTwist=%s deg | ThetaCenterMinRot=%s | DeltaThetaEveMinRot=%s | SectorMinRot=[%s..%s]\n",
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
								splineErrorText,
								minRotTwistText,
								thetaCenterMinRotText,
								deltaThetaEveMinRotText,
								thetaMinMinRotText,
								thetaMaxMinRotText
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
        
		print(string.format("\n[%s] %s %s | Actor=%s | Dist=%.0f | TTC=%.2fs\n", ADV_MOD, status, closestObs.cls, closestObs.name, closestObs.dist, closestObs.ttc))
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
print("[AdvisorV3] Ready. F3 = Prep, NumPad * = Advisor.\n")

-- >>> HTS:F6_DUAL_MARKER:BEGIN >>>

local HTS_F6_DUAL_ACTORS = {}
local HTS_F6_DUAL_PENDING = false
local HTS_F6_DUAL_MOD = "HTS-F6-DUAL"

-- Temporary snapshot of the last selected target. This is local to F6;
-- it does not feed data into Advisor or change its decisions.
local HTS_F6_LAST_TARGET = nil

local HTS_F6_CONTROL_SCALE = 0.50
local HTS_F6_CONTROL_FORWARD = 2000.0
local HTS_F6_CONTROL_HEIGHT = 100.0

local HTS_F6_COLORS = {
    CONTROL_A = {
        R = 6.0, G = 0.0, B = 6.0, A = 1.0
    },

    TARGET_B = {
        R = 0.0, G = 6.0, B = 0.0, A = 1.0
    },

    CALIBRATION_C = {
        R = 0.0, G = 4.5, B = 6.0, A = 1.0
    }
}


local function hts_f6_dual_isValid(obj)
    if not obj then return false end
    local ok, result = pcall(function()
        return obj:IsValid()
    end)
    return ok and result == true
end

local function hts_f6_dual_vecText(v)
    if not v then return "n/a" end
    local ok, result = pcall(function()
        return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
    end)
    return ok and result or "<unreadable>"
end

-- Apply a colored Dynamic Material Instance.
local function hts_f6_dual_applyColor(
    meshComp, baseMaterial, color, instanceName
)
    local dynamicMaterial =
        meshComp:CreateDynamicMaterialInstance(
            0,
            baseMaterial,
            FName(instanceName)
        )

    if not hts_f6_dual_isValid(dynamicMaterial) then
        error("Dynamic Material Instance creation failed")
    end

    dynamicMaterial:SetVectorParameterValue(
        FName("Color"),
        color
    )

    meshComp:SetMaterial(0, dynamicMaterial)

    return dynamicMaterial
end

local function hts_f6_dual_getSplineDistance(spline, worldLoc)
    local okKey, inputKey = pcall(function()
        return spline:FindInputKeyClosestToWorldLocation(worldLoc)
    end)
    if not okKey or type(inputKey) ~= "number" then return nil end

    local okDistance, distance = pcall(function()
        return spline:GetDistanceAlongSplineAtSplineInputKey(inputKey)
    end)
    if not okDistance or type(distance) ~= "number" then return nil end
    return distance
end

local function hts_f6_dual_selectTarget(eveLoc)
    if prep_state ~= 3 then
        return nil, "F3_NOT_READY"
    end
    if not hts_f6_dual_isValid(cached_spline) then
        return nil, "SPLINE_INVALID"
    end
    if type(cached_targets) ~= "table" or #cached_targets == 0 then
        return nil, "TARGET_INDEX_EMPTY"
    end

    local eveSplineDistance = hts_f6_dual_getSplineDistance(cached_spline, eveLoc)
    if eveSplineDistance == nil then
        return nil, "EVE_SPLINE_DISTANCE_UNAVAILABLE"
    end

    local bestAhead = nil
    local bestAny = nil

    for _, entry in ipairs(cached_targets) do
        local actor = entry.actor
        local box = entry.box

        if hts_f6_dual_isValid(actor) and hts_f6_dual_isValid(box) then
            local boxLocOK, boxLoc = pcall(function()
                return box:K2_GetComponentLocation()
            end)

            if boxLocOK and boxLoc and boxLoc.X ~= nil and boxLoc.Y ~= nil and boxLoc.Z ~= nil then
                local dx = boxLoc.X - eveLoc.X
                local dy = boxLoc.Y - eveLoc.Y
                local dz = boxLoc.Z - eveLoc.Z
                local worldDistance = math.sqrt(dx * dx + dy * dy + dz * dz)

                local boxSplineDistance = hts_f6_dual_getSplineDistance(cached_spline, boxLoc)
                local splineDelta = nil
                if boxSplineDistance ~= nil then
                    splineDelta = boxSplineDistance - eveSplineDistance
                end

                local extent = nil
                pcall(function()
                    extent = box:GetScaledBoxExtent()
                end)

                local name = "<name-unavailable>"
                pcall(function()
                    name = actor:GetFName():ToString()
                end)

                local candidate = {
                    actor = actor,
                    box = box,
                    name = name,
                    boxLoc = {
                        X = boxLoc.X,
                        Y = boxLoc.Y,
                        Z = boxLoc.Z
                    },
                    extent = extent,
                    worldDistance = worldDistance,
                    splineDelta = splineDelta
                }

                if not bestAny or worldDistance < bestAny.worldDistance then
                    bestAny = candidate
                end

                -- For this test, prefer the closest obstacle ALONG THE SPLINE,
                -- not the nearest obstacle in straight-line 3D distance.
                if splineDelta ~= nil and splineDelta > 0.0 then
                    if not bestAhead
                        or splineDelta < bestAhead.splineDelta
                        or (splineDelta == bestAhead.splineDelta and worldDistance < bestAhead.worldDistance) then
                        bestAhead = candidate
                    end
                end
            end
        end
    end

    if bestAhead then
        bestAhead.selection = "NEAREST_FORWARD_BY_SPLINE"
        return bestAhead, nil
    end

    if bestAny then
        bestAny.selection = "FALLBACK_NEAREST_IN_WORLD (no positive spline delta)"
        return bestAny, nil
    end

    return nil, "NO_VALID_BOX_COMPONENT"
end

local function hts_f6_dual_spawnCube(
		world, actorClass, cubeMesh,
		baseMaterial, color,
		location, scale, label
	)
    local actor = nil
    local stage = "SpawnActor"

    local ok, err = pcall(function()
        local rotation = {
            Pitch = 0.0,
            Yaw = 0.0,
            Roll = 0.0
        }

        actor = world:SpawnActor(actorClass, location, rotation)
        if not hts_f6_dual_isValid(actor) then
            error("World:SpawnActor returned an invalid Actor")
        end

        stage = "GetStaticMeshComponent"
        local meshComp = actor.StaticMeshComponent
        if not hts_f6_dual_isValid(meshComp) then
            error("StaticMeshActor has no valid StaticMeshComponent")
        end

        stage = "SetMobility"
        meshComp:SetMobility(2) -- EComponentMobility::Movable

        stage = "SetStaticMesh"
        local meshResult = meshComp:SetStaticMesh(cubeMesh)
        if meshResult == false then
            error("SetStaticMesh returned false")
        end
		
		stage = "ApplyDynamicColor"
		hts_f6_dual_applyColor(
			meshComp,
			baseMaterial,
			color,
			"HTS_F6_" .. label
		)

        stage = "DisableCollision"
        meshComp:SetCollisionEnabled(0) -- ECollisionEnabled::NoCollision

        stage = "SetVisibility"
        meshComp:SetVisibility(true, true)
        actor:SetActorHiddenInGame(false)

        stage = "SetScale"
        actor:SetActorScale3D({
            X = scale,
            Y = scale,
            Z = scale
        })
    end)

    if not ok then
        if hts_f6_dual_isValid(actor) then
            pcall(function()
                actor:K2_DestroyActor()
            end)
        end
        return nil, string.format("%s: %s", stage, tostring(err))
    end

    -- Keep references alive so F6 can destroy all spawned markers later.
    table.insert(HTS_F6_DUAL_ACTORS, actor)

    local actualLoc = nil
    pcall(function()
        actualLoc = actor:K2_GetActorLocation()
    end)

    local actualScale = nil
    pcall(function()
        actualScale = actor:GetActorScale3D()
    end)

    print(string.format(
        "[%s] %s created. RequestedLoc=%s | ActualLoc=%s | RequestedScale=%.2f | ActualScale=%s\n",
        HTS_F6_DUAL_MOD,
        label,
        hts_f6_dual_vecText(location),
        hts_f6_dual_vecText(actualLoc),
        scale,
        hts_f6_dual_vecText(actualScale)
    ))

    return actor, nil
end

local function hts_f6_dual_copyVec(v)
    return { X = v.X, Y = v.Y, Z = v.Z }
end

local function hts_f6_dual_addScaled(center, axisA, amountA, axisB, amountB, axisC, amountC)
    return {
        X = center.X + axisA.X * amountA + axisB.X * amountB + axisC.X * amountC,
        Y = center.Y + axisA.Y * amountA + axisB.Y * amountB + axisC.Y * amountC,
        Z = center.Z + axisA.Z * amountA + axisB.Z * amountB + axisC.Z * amountC
    }
end

-- Spawn one thin cube whose local X axis follows the edge from pointA to pointB.
-- Engine BasicShapes/Cube has a 100-unit side, so scale X is edgeLength / 100.
local function hts_f6_dual_spawnEdge(
		world, actorClass, cubeMesh,
		baseMaterial, color,
		pointA, pointB, thickness, edgeLabel
	)
    local dx = pointB.X - pointA.X
    local dy = pointB.Y - pointA.Y
    local dz = pointB.Z - pointA.Z

    local horizontalLength = math.sqrt(dx * dx + dy * dy)
    local edgeLength = math.sqrt(
        dx * dx + dy * dy + dz * dz
    )

    if edgeLength < 0.1 then
        return nil, edgeLabel .. ": zero length"
    end

    -- Direction of local X axis.
    local yaw = math.deg(math.atan(dy, dx))
    local pitch = math.deg(math.atan(dz, horizontalLength))

    local midpoint = {
        X = (pointA.X + pointB.X) * 0.5,
        Y = (pointA.Y + pointB.Y) * 0.5,
        Z = (pointA.Z + pointB.Z) * 0.5
    }

    local desiredRotation = {
        Pitch = pitch,
        Yaw = yaw,
        Roll = 0.0
    }

    local identityRotation = {
        Pitch = 0.0,
        Yaw = 0.0,
        Roll = 0.0
    }

    local desiredScale = {
        X = edgeLength / 100.0,
        Y = thickness / 100.0,
        Z = thickness / 100.0
    }

    local edgeActor = nil
    local stage = "SpawnActor"

    local ok, err = pcall(function()

        -- Spawn with identity rotation.
        edgeActor = world:SpawnActor(
            actorClass,
            midpoint,
            identityRotation
        )

        if not hts_f6_dual_isValid(edgeActor) then
            error("SpawnActor returned invalid Actor")
        end

        stage = "StaticMeshComponent"

        local meshComp = edgeActor.StaticMeshComponent

        if not hts_f6_dual_isValid(meshComp) then
            error("Invalid StaticMeshComponent")
        end

        stage = "SetMobility"
        meshComp:SetMobility(2)

        stage = "SetStaticMesh"

        local meshResult = meshComp:SetStaticMesh(cubeMesh)

        if meshResult == false then
            error("SetStaticMesh returned false")
        end
		
		stage = "ApplyDynamicColor"
		hts_f6_dual_applyColor(
			meshComp,
			baseMaterial,
			color,
			"HTS_F6_" .. edgeLabel
		)

        stage = "DisableCollision"
        meshComp:SetCollisionEnabled(0)

        stage = "SetVisibility"
        meshComp:SetVisibility(true, true)
        edgeActor:SetActorHiddenInGame(false)

        -- Explicitly apply the calculated rotation.
        stage = "K2_SetActorRotation"

        local rotationResult =
            edgeActor:K2_SetActorRotation(
                desiredRotation,
                true
            )

        -- Set scale AFTER rotation.
        stage = "SetActorScale3D"

        edgeActor:SetActorScale3D(desiredScale)

        -- Read back actual transform.
        stage = "ReadbackTransform"

        local actualLoc = edgeActor:K2_GetActorLocation()
        local actualRot = edgeActor:K2_GetActorRotation()
        local actualScale = edgeActor:GetActorScale3D()

        if not actualLoc or not actualRot or not actualScale then
            error("Could not read back actual transform")
        end

        -- Calculate actual world direction of local X.
        local actualPitch = math.rad(actualRot.Pitch)
        local actualYaw = math.rad(actualRot.Yaw)

        local actualForward = {
            X = math.cos(actualPitch) * math.cos(actualYaw),
            Y = math.cos(actualPitch) * math.sin(actualYaw),
            Z = math.sin(actualPitch)
        }

        local expectedDirection = {
            X = dx / edgeLength,
            Y = dy / edgeLength,
            Z = dz / edgeLength
        }

        local alignmentDot =
            actualForward.X * expectedDirection.X +
            actualForward.Y * expectedDirection.Y +
            actualForward.Z * expectedDirection.Z

        print(string.format(
            "[%s] EDGE %s | RotationSet=%s | AlignDot=%.5f | ReqRot=(%.1f,%.1f,%.1f) | ActualRot=(%.1f,%.1f,%.1f) | ReqScale=%s | ActualScale=%s | Loc=%s\n",
            HTS_F6_DUAL_MOD,
            edgeLabel,
            tostring(rotationResult),
            alignmentDot,
            pitch, yaw, 0.0,
            actualRot.Pitch,
            actualRot.Yaw,
            actualRot.Roll,
            hts_f6_dual_vecText(desiredScale),
            hts_f6_dual_vecText(actualScale),
            hts_f6_dual_vecText(actualLoc)
        ))

        if alignmentDot < 0.995 then
            print(
                "[" .. HTS_F6_DUAL_MOD ..
                "] WARNING: Edge rotation alignment mismatch: " ..
                edgeLabel .. "\n"
            )
        end
    end)

    if not ok then
        if hts_f6_dual_isValid(edgeActor) then
            pcall(function()
                edgeActor:K2_DestroyActor()
            end)
        end

        return nil, edgeLabel ..
            " failed at " .. stage .. ": " .. tostring(err)
    end

    table.insert(HTS_F6_DUAL_ACTORS, edgeActor)

    return edgeActor, nil
end

-- Capture the selected BoxComponent's real world frame and create its 12-edge OBB.
local function hts_f6_dual_spawnBoxWireframe(
		world, actorClass, cubeMesh,
		baseMaterial, color, selected
	)
    local box = selected.box
    if not hts_f6_dual_isValid(box) then
        return false, "Selected BoxComponent is no longer valid"
    end

    local frameOK, frame = pcall(function()
        local location = box:K2_GetComponentLocation()
        local forward = box:GetForwardVector()
        local right = box:GetRightVector()
        local up = box:GetUpVector()
        local extent = box:GetScaledBoxExtent()

        if not location or not forward or not right or not up or not extent then
            error("BoxComponent frame returned nil data")
        end

        return {
            location = hts_f6_dual_copyVec(location),
            forward = hts_f6_dual_copyVec(forward),
            right = hts_f6_dual_copyVec(right),
            up = hts_f6_dual_copyVec(up),
            extent = hts_f6_dual_copyVec(extent)
        }
    end)

    if not frameOK then
        return false, "Could not read BoxComponent frame: " .. tostring(frame)
    end

    if frame.extent.X <= 0 or frame.extent.Y <= 0 or frame.extent.Z <= 0 then
        return false, "BoxComponent has a non-positive scaled extent"
    end

    -- Keep a snapshot of the exact selected target and its frame for later
    -- diagnostic features. Nothing here is passed to Advisor.
    HTS_F6_LAST_TARGET = {
        actor = selected.actor,
        box = selected.box,
        name = selected.name,
        location = hts_f6_dual_copyVec(frame.location),
        forward = hts_f6_dual_copyVec(frame.forward),
        right = hts_f6_dual_copyVec(frame.right),
        up = hts_f6_dual_copyVec(frame.up),
        extent = hts_f6_dual_copyVec(frame.extent),
        worldDistance = selected.worldDistance,
        splineDelta = selected.splineDelta
    }

    -- Place the centre line of each bar 8 cm outside the BoxComponent bounds.
    -- Bars are also 8 cm thick, so they should not be entirely buried in the mesh.
	local padding = 50.0
	local thickness = 18.0
    local displayExtent = {
        X = frame.extent.X + padding,
        Y = frame.extent.Y + padding,
        Z = frame.extent.Z + padding
    }

    local signs = { -1, 1 }
    local corners = {}
    for _, sx in ipairs(signs) do
        for _, sy in ipairs(signs) do
            for _, sz in ipairs(signs) do
                local key = tostring(sx) .. ":" .. tostring(sy) .. ":" .. tostring(sz)
                corners[key] = hts_f6_dual_addScaled(
                    frame.location,
                    frame.forward, displayExtent.X * sx,
                    frame.right, displayExtent.Y * sy,
                    frame.up, displayExtent.Z * sz
                )
            end
        end
    end

    local function corner(sx, sy, sz)
        return corners[tostring(sx) .. ":" .. tostring(sy) .. ":" .. tostring(sz)]
    end

    local actorCountBefore = #HTS_F6_DUAL_ACTORS
    local edgeCount = 0

    local function addEdge(a, b, label)
		local edgeActor, edgeErr = hts_f6_dual_spawnEdge(
			world, actorClass, cubeMesh,
			baseMaterial, color,
			a, b, thickness, label
		)
        if not edgeActor then
            -- Roll back only the edges created by this frame; keep CONTROL_A.
            for i = #HTS_F6_DUAL_ACTORS, actorCountBefore + 1, -1 do
                local partialActor = HTS_F6_DUAL_ACTORS[i]
                if hts_f6_dual_isValid(partialActor) then
                    pcall(function() partialActor:K2_DestroyActor() end)
                end
                table.remove(HTS_F6_DUAL_ACTORS, i)
            end
            return false, edgeErr
        end
        edgeCount = edgeCount + 1
        return true, nil
    end

    -- Four edges parallel to Box local X.
    for _, sy in ipairs(signs) do
        for _, sz in ipairs(signs) do
            local ok, err = addEdge(corner(-1, sy, sz), corner(1, sy, sz), "X-edge")
            if not ok then return false, err end
        end
    end

    -- Four edges parallel to Box local Y.
    for _, sx in ipairs(signs) do
        for _, sz in ipairs(signs) do
            local ok, err = addEdge(corner(sx, -1, sz), corner(sx, 1, sz), "Y-edge")
            if not ok then return false, err end
        end
    end

    -- Four edges parallel to Box local Z.
    for _, sx in ipairs(signs) do
        for _, sy in ipairs(signs) do
            local ok, err = addEdge(corner(sx, sy, -1), corner(sx, sy, 1), "Z-edge")
            if not ok then return false, err end
        end
    end

    print(string.format(
        "[%s] TARGET_B wireframe created. Actor=%s | Center=%s | ScaledExtent=%s | Edges=%d | Thickness=%.1f | Padding=%.1f\n",
        HTS_F6_DUAL_MOD,
        tostring(HTS_F6_LAST_TARGET.name),
        hts_f6_dual_vecText(frame.location),
        hts_f6_dual_vecText(frame.extent),
        edgeCount,
        thickness,
        padding
    ))

    return true, nil
end


-- >>> HTS:F6_CALIBRATION_WIREFRAME:BEGIN >>>

local function hts_f6_dual_spawnCalibrationWireframe(
		world, actorClass, cubeMesh,
		baseMaterial, center, source, color
	)
    if not source then
        return false, "No source BoxComponent frame"
    end

    -- Fixed 150 x 150 x 150 cm reference box.
    -- Its orientation matches the selected target's local axes.
    local half = {
        X = 75.0,
        Y = 75.0,
        Z = 75.0
    }

    local thickness = 12.0
	
	-- Calibration C must use WORLD axes only.
	local worldX = { X = 1.0, Y = 0.0, Z = 0.0 }
	local worldY = { X = 0.0, Y = 1.0, Z = 0.0 }
	local worldZ = { X = 0.0, Y = 0.0, Z = 1.0 }
	
    local signs = { -1, 1 }
    local corners = {}

    for _, sx in ipairs(signs) do
        for _, sy in ipairs(signs) do
            for _, sz in ipairs(signs) do
                local key = tostring(sx) .. ":" ..
                            tostring(sy) .. ":" .. tostring(sz)

				corners[key] = hts_f6_dual_addScaled(
					center,
					worldX, half.X * sx,
					worldY, half.Y * sy,
					worldZ, half.Z * sz
				)
            end
        end
    end

    local function corner(sx, sy, sz)
        return corners[
            tostring(sx) .. ":" ..
            tostring(sy) .. ":" ..
            tostring(sz)
        ]
    end

    local actorCountBefore = #HTS_F6_DUAL_ACTORS
    local edgeCount = 0

    local function addEdge(a, b, label)
		local actor, err = hts_f6_dual_spawnEdge(
			world,
			actorClass,
			cubeMesh,
			baseMaterial,
			color,
			a,
			b,
			thickness,
			label
		)

        if not actor then
            for i = #HTS_F6_DUAL_ACTORS,
                actorCountBefore + 1, -1 do

                local partial = HTS_F6_DUAL_ACTORS[i]

                if hts_f6_dual_isValid(partial) then
                    pcall(function()
                        partial:K2_DestroyActor()
                    end)
                end

                table.remove(HTS_F6_DUAL_ACTORS, i)
            end

            return false, err
        end

        edgeCount = edgeCount + 1
        return true
    end

    -- X edges
    for _, sy in ipairs(signs) do
        for _, sz in ipairs(signs) do
            local ok, err = addEdge(
                corner(-1, sy, sz),
                corner(1, sy, sz),
                "CAL-X"
            )
            if not ok then return false, err end
        end
    end

    -- Y edges
    for _, sx in ipairs(signs) do
        for _, sz in ipairs(signs) do
            local ok, err = addEdge(
                corner(sx, -1, sz),
                corner(sx, 1, sz),
                "CAL-Y"
            )
            if not ok then return false, err end
        end
    end

    -- Z edges
    for _, sx in ipairs(signs) do
        for _, sy in ipairs(signs) do
            local ok, err = addEdge(
                corner(sx, sy, -1),
                corner(sx, sy, 1),
                "CAL-Z"
            )
            if not ok then return false, err end
        end
    end

    print(string.format(
        "[%s] CALIBRATION_C created. Center=%s | HalfExtent=75 | Edges=%d | Thickness=%.1f\n",
        HTS_F6_DUAL_MOD,
        hts_f6_dual_vecText(center),
        edgeCount,
        thickness
    ))

    return true, nil
end

-- <<< HTS:F6_CALIBRATION_WIREFRAME:END <<<


local function hts_f6_dual_destroyAll()
    local destroyed = 0
    local failed = 0

    for _, actor in ipairs(HTS_F6_DUAL_ACTORS) do
        if hts_f6_dual_isValid(actor) then
            local ok = pcall(function()
                actor:K2_DestroyActor()
            end)
            if ok then
                destroyed = destroyed + 1
            else
                failed = failed + 1
            end
        end
    end

    HTS_F6_DUAL_ACTORS = {}
	HTS_F6_LAST_TARGET = nil
    print(string.format(
        "[%s] Cleanup complete. Destroyed=%d | Failed=%d\n",
        HTS_F6_DUAL_MOD,
        destroyed,
        failed
    ))
end

local function hts_f6_dual_toggle_game_thread()
    -- If any markers are present, F6 removes all of them.
    if #HTS_F6_DUAL_ACTORS > 0 then
        hts_f6_dual_destroyAll()
        return
    end

    local pawn = cached_Pawn
    local pc = nil

    if not hts_f6_dual_isValid(pawn) then
        pc = FindFirstOf("PlayerController")
        if hts_f6_dual_isValid(pc) then
            pawn = pc.Pawn
        end
    else
        pc = FindFirstOf("PlayerController")
    end

    if not hts_f6_dual_isValid(pawn) then
        print("[" .. HTS_F6_DUAL_MOD .. "] ERROR: Player Pawn not found.\n")
        return
    end

    if not hts_f6_dual_isValid(pc) then
        pc = FindFirstOf("PlayerController")
    end

    if not hts_f6_dual_isValid(pc) then
        print("[" .. HTS_F6_DUAL_MOD .. "] ERROR: PlayerController not found.\n")
        return
    end

    local world = nil
    local worldOK, worldResult = pcall(function()
        world = pawn:GetWorld()
    end)
    if not worldOK or not hts_f6_dual_isValid(world) then
        print("[" .. HTS_F6_DUAL_MOD .. "] ERROR: Could not resolve Pawn World.\n")
        return
    end

    -- Use resources preloaded by F3.
	if not HTS_VISUAL_ASSETS.ready then
		print(
			"[" .. HTS_F6_DUAL_MOD ..
			"] ERROR: Visual assets are not ready. Press F3 first. " ..
			tostring(HTS_VISUAL_ASSETS.error or "") .. "\n"
		)
		return
	end

	local actorClass = HTS_VISUAL_ASSETS.actorClass
	local cubeMesh = HTS_VISUAL_ASSETS.cubeMesh
	local baseMaterial = HTS_VISUAL_ASSETS.baseMaterial

	if not hts_f6_dual_isValid(actorClass)
	or not hts_f6_dual_isValid(cubeMesh)
	or not hts_f6_dual_isValid(baseMaterial) then

		print(
			"[" .. HTS_F6_DUAL_MOD ..
			"] ERROR: Cached visual asset became invalid.\n"
		)
		return
	end

	print(
		"[" .. HTS_F6_DUAL_MOD ..
		"] Using F3-preloaded visual assets.\n"
	)

    print("[" .. HTS_F6_DUAL_MOD .. "] Asset loaded. Spawning CONTROL marker A...\n")

    -- CONTROL A: reuse the same Pawn-relative placement that produced the first
    -- visibly successful cube in the previous test.
    local eveLoc = nil
    local eveRot = nil
    local pawnTransformOK, pawnTransformErr = pcall(function()
        eveLoc = pawn:K2_GetActorLocation()
        eveRot = pawn:K2_GetActorRotation()
    end)

    if not pawnTransformOK or not eveLoc or not eveRot then
        print("[" .. HTS_F6_DUAL_MOD .. "] ERROR: Could not read Pawn transform: " .. tostring(pawnTransformErr) .. "\n")
        return
    end

    local pitch = math.rad(eveRot.Pitch or 0.0)
    local yaw = math.rad(eveRot.Yaw or 0.0)
    local cosPitch = math.cos(pitch)
    local forward = {
        X = cosPitch * math.cos(yaw),
        Y = cosPitch * math.sin(yaw),
        Z = math.sin(pitch)
    }

	local controlLoc = {
		X = eveLoc.X + forward.X * HTS_F6_CONTROL_FORWARD,
		Y = eveLoc.Y + forward.Y * HTS_F6_CONTROL_FORWARD,
		Z = eveLoc.Z + forward.Z * HTS_F6_CONTROL_FORWARD
			+ HTS_F6_CONTROL_HEIGHT
	}

	local controlActor, controlErr = hts_f6_dual_spawnCube(
		world,
		actorClass,
		cubeMesh,
		baseMaterial,
		HTS_F6_COLORS.CONTROL_A,
		controlLoc,
		HTS_F6_CONTROL_SCALE,
		"CONTROL_A"
	)

    if not controlActor then
        print("[" .. HTS_F6_DUAL_MOD .. "] CONTROL_A ERROR: " .. tostring(controlErr) .. "\n")
        return
    end

    print(string.format(
        "[%s] CONTROL_A expected ahead of Eve by %.1f units.\n",
        HTS_F6_DUAL_MOD,
        HTS_F6_CONTROL_FORWARD
    ))

    -- TARGET B: select the nearest positive-distance BoxComponent along the
    -- spline. If F3/index is unavailable, keep CONTROL_A alive and report why.
    local selected, selectErr = hts_f6_dual_selectTarget(eveLoc)
    if not selected then
        print("[" .. HTS_F6_DUAL_MOD .. "] TARGET_B SKIPPED: " .. tostring(selectErr) .. ". CONTROL_A remains visible. Press F6 again to clean up.\n")
        return
    end

	local frameOK, frameErr =
		hts_f6_dual_spawnBoxWireframe(
			world,
			actorClass,
			cubeMesh,
			baseMaterial,
			HTS_F6_COLORS.TARGET_B,
			selected
		)

	if not frameOK then
		HTS_F6_LAST_TARGET = nil
		print("[" .. HTS_F6_DUAL_MOD .. "] TARGET_B WIREFRAME ERROR: " .. tostring(frameErr) .. ". CONTROL_A remains visible.\n")
		return
	end

	local calibrationOK, calibrationErr =
		hts_f6_dual_spawnCalibrationWireframe(
			world,
			actorClass,
			cubeMesh,
			baseMaterial,
			controlLoc,
			HTS_F6_LAST_TARGET,
			HTS_F6_COLORS.CALIBRATION_C
		)

	if not calibrationOK then
		print(
			"[" .. HTS_F6_DUAL_MOD ..
			"] CALIBRATION_C ERROR: " ..
			tostring(calibrationErr) .. "\n"
		)
	end

	print(string.format(
		"[%s] BOTH MARKERS SPAWNED. A=CONTROL (scale=%.2f) | B=TARGET_WIREFRAME (12 edges) | Target=%s\n",
		HTS_F6_DUAL_MOD,
		HTS_F6_CONTROL_SCALE,
		selected.name
	))
	print("[" .. HTS_F6_DUAL_MOD .. "] Press F6 again to destroy CONTROL_A and all 12 TARGET_B edges.\n")
end

local function hts_f6_dual_key()
    if HTS_F6_DUAL_PENDING then return end

    if type(ExecuteInGameThread) ~= "function" then
        print("[" .. HTS_F6_DUAL_MOD .. "] ERROR: ExecuteInGameThread unavailable.\n")
        return
    end

    HTS_F6_DUAL_PENDING = true

    local queueOK, queueErr = pcall(function()
        ExecuteInGameThread(function()
            local actionOK, actionErr = pcall(hts_f6_dual_toggle_game_thread)
            HTS_F6_DUAL_PENDING = false

            if not actionOK then
                print("[" .. HTS_F6_DUAL_MOD .. "] GAME THREAD ERROR: " .. tostring(actionErr) .. "\n")
            end
        end)
    end)

    if not queueOK then
        HTS_F6_DUAL_PENDING = false
        print("[" .. HTS_F6_DUAL_MOD .. "] QUEUE ERROR: " .. tostring(queueErr) .. "\n")
    end
end

RegisterKeyBind(Key.F6, hts_f6_dual_key)
print("[HTS-F6-DUAL] Ready. F6 = spawn/destroy CONTROL_A + TARGET_B. Run F3 for TARGET_B.\n")
-- <<< HTS:F6_DUAL_MARKER:END <<<



-- >>> HTS:F7_MATERIAL_TEST:BEGIN >>>

local HTS_F7_MAT_ACTOR = nil
local HTS_F7_MAT_PENDING = false

local function hts_f7_mat_isValid(obj)
    if not obj then return false end

    local ok, result = pcall(function()
        return obj:IsValid()
    end)

    return ok and result == true
end

local function hts_f7_mat_toggle_game_thread()

    -- Second press: destroy the test cube.
    if hts_f7_mat_isValid(HTS_F7_MAT_ACTOR) then

        local oldActor = HTS_F7_MAT_ACTOR
        HTS_F7_MAT_ACTOR = nil

        local ok, err = pcall(function()
            oldActor:K2_DestroyActor()
        end)

        if ok then
            print("[HTS-F7-MAT] Test cube destroyed.\n")
        else
            print("[HTS-F7-MAT] DESTROY ERROR: "
                .. tostring(err) .. "\n")
        end

        return
    end

    local spawnedActor = nil
    local stage = "PlayerController"

    local ok, err = pcall(function()

        local PC = FindFirstOf("PlayerController")

        if not hts_f7_mat_isValid(PC) then
            error("PlayerController not found")
        end

        local Pawn = PC.Pawn

        if not hts_f7_mat_isValid(Pawn) then
            error("Pawn not found")
        end

        stage = "GetWorld"

        local world = Pawn:GetWorld()

        if not hts_f7_mat_isValid(world) then
            error("World not found")
        end

        stage = "Find StaticMeshActor"

        local actorClass = StaticFindObject(
            "/Script/Engine.StaticMeshActor"
        )

        if not hts_f7_mat_isValid(actorClass) then
            error("StaticMeshActor class not found")
        end

        stage = "Load Cube"

        local cubeMesh = LoadAsset(
            "/Engine/BasicShapes/Cube.Cube"
        )

        if not hts_f7_mat_isValid(cubeMesh) then
            error("Cube asset not found")
        end

        print("[HTS-F7-MAT] Cube asset loaded.\n")

		stage = "Load EmissiveMeshMaterial"

		local baseMaterial = nil

		-- First try the material configured in UEngine.
		local engineOK, engineMaterial = pcall(function()
			local engine = FindFirstOf("Engine")

			if hts_f7_mat_isValid(engine) then
				return engine.EmissiveMeshMaterial
			end

			return nil
		end)

		if engineOK and hts_f7_mat_isValid(engineMaterial) then

			baseMaterial = engineMaterial

			print(
				"[HTS-F7-MAT] Using UEngine.EmissiveMeshMaterial: " ..
				baseMaterial:GetFullName() .. "\n"
			)

		else

			-- Fallback: load the standard Engine asset.
			baseMaterial = LoadAsset(
				"/Engine/EngineMaterials/EmissiveMeshMaterial.EmissiveMeshMaterial"
			)

		end

		if not hts_f7_mat_isValid(baseMaterial) then
			error("EmissiveMeshMaterial unavailable")
		end

		print(
			"[HTS-F7-MAT] Emissive material loaded: " ..
			baseMaterial:GetFullName() .. "\n"
		)

        stage = "Calculate spawn position"

        local pawnLoc = Pawn:K2_GetActorLocation()
        local pawnRot = Pawn:K2_GetActorRotation()

        if not pawnLoc or not pawnRot then
            error("Cannot read Pawn transform")
        end

        local pitch = math.rad(pawnRot.Pitch)
        local yaw = math.rad(pawnRot.Yaw)

        local cp = math.cos(pitch)

        local forward = {
            X = cp * math.cos(yaw),
            Y = cp * math.sin(yaw),
            Z = math.sin(pitch)
        }

        local spawnLoc = {
            X = pawnLoc.X + forward.X * 1000.0,
            Y = pawnLoc.Y + forward.Y * 1000.0,
            Z = pawnLoc.Z + forward.Z * 1000.0 + 60.0
        }

        local spawnRot = {
            Pitch = 0.0,
            Yaw = 0.0,
            Roll = 0.0
        }

        stage = "SpawnActor"

        spawnedActor = world:SpawnActor(
            actorClass,
            spawnLoc,
            spawnRot
        )

        if not hts_f7_mat_isValid(spawnedActor) then
            error("SpawnActor returned invalid Actor")
        end

        stage = "Get StaticMeshComponent"

        local meshComp = spawnedActor.StaticMeshComponent

        if not hts_f7_mat_isValid(meshComp) then
            error("StaticMeshComponent is invalid")
        end

        stage = "Set Mobility"

        meshComp:SetMobility(2)

        stage = "Set Cube Mesh"

        local meshResult = meshComp:SetStaticMesh(cubeMesh)

        if meshResult == false then
            error("SetStaticMesh returned false")
        end

        stage = "Disable Collision"

        meshComp:SetCollisionEnabled(0)

        stage = "Set Scale"

        local scale = {
            X = 1.5,
            Y = 1.5,
            Z = 1.5
        }

        spawnedActor:SetActorScale3D(scale)

        stage = "Set Visibility"

        meshComp:SetVisibility(true, true)
        spawnedActor:SetActorHiddenInGame(false)

        stage = "Create Dynamic Material Instance"

        local dynamicMaterial =
            meshComp:CreateDynamicMaterialInstance(
                0,
                baseMaterial,
                FName("HTS_F7_ColorProbe")
            )

        if not hts_f7_mat_isValid(dynamicMaterial) then
            error("CreateDynamicMaterialInstance returned invalid object")
        end

        print("[HTS-F7-MAT] Dynamic Material Instance created: "
            .. dynamicMaterial:GetFullName() .. "\n")

        stage = "Set Color Parameter"

		dynamicMaterial:SetVectorParameterValue(
			FName("Color"),
			{
				R = 6.0,
				G = 0.0,
				B = 6.0,
				A = 1.0
			}
		)

        print("[HTS-F7-MAT] Color parameter applied.\n")

        stage = "Assign Dynamic Material"

        meshComp:SetMaterial(0, dynamicMaterial)

        stage = "Verify Material"

        local readOK, appliedMaterial = pcall(function()
            return meshComp:GetMaterial(0)
        end)

        if readOK and hts_f7_mat_isValid(appliedMaterial) then
            print("[HTS-F7-MAT] Applied material: "
                .. appliedMaterial:GetFullName() .. "\n")
        else
            print("[HTS-F7-MAT] Material readback unavailable.\n")
        end

        stage = "Read Actual Transform"

        local actualLoc = spawnedActor:K2_GetActorLocation()
        local actualScale = spawnedActor:GetActorScale3D()

        print(string.format(
            "[HTS-F7-MAT] SUCCESS! Location=(%.1f, %.1f, %.1f) Scale=(%.2f, %.2f, %.2f)\n",
            actualLoc.X, actualLoc.Y, actualLoc.Z,
            actualScale.X, actualScale.Y, actualScale.Z
        ))

    end)

    if not ok then

        if hts_f7_mat_isValid(spawnedActor) then
            pcall(function()
                spawnedActor:K2_DestroyActor()
            end)
        end

        print(string.format(
            "[HTS-F7-MAT] ERROR at [%s]: %s\n",
            stage, tostring(err)
        ))

        return
    end

    HTS_F7_MAT_ACTOR = spawnedActor

    print("[HTS-F7-MAT] Press F7 again to destroy the cube.\n")
end

local function hts_f7_mat_key()

    if HTS_F7_MAT_PENDING then return end

    if type(ExecuteInGameThread) ~= "function" then
        print("[HTS-F7-MAT] ExecuteInGameThread unavailable.\n")
        return
    end

    HTS_F7_MAT_PENDING = true

    local ok, err = pcall(function()

        ExecuteInGameThread(function()

            local actionOK, actionErr = pcall(
                hts_f7_mat_toggle_game_thread
            )

            HTS_F7_MAT_PENDING = false

            if not actionOK then
                print("[HTS-F7-MAT] ERROR: "
                    .. tostring(actionErr) .. "\n")
            end
        end)
    end)

    if not ok then
        HTS_F7_MAT_PENDING = false

        print("[HTS-F7-MAT] QUEUE ERROR: "
            .. tostring(err) .. "\n")
    end
end

RegisterKeyBind(Key.F7, hts_f7_mat_key)

print("[HTS-F7-MAT] Ready. F7 = spawn/destroy colored cube.\n")

-- <<< HTS:F7_MATERIAL_TEST:END <<<
