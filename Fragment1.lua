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
                        X = loc.X + (aFwd.X*ext.X*sx) + (aRight.X*ext.Y*sy) + (aUp.X*ext.Z*sz),
                        Y = loc.Y + (aFwd.Y*ext.X*sx) + (aRight.Y*ext.Y*sy) + (aUp.Y*ext.Z*sz),
                        Z = loc.Z + (aFwd.Z*ext.X*sx) + (aRight.Z*ext.Y*sy) + (aUp.Z*ext.Z*sz)
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
							predTheta = predTheta, predDanger = predInSector, nowInSector = inSector,
							sectorSpan = maxDelta - minDelta,
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
    
    -- Profiling: T4 before output
    if prof_enabled then
        prof_T4 = os.clock()
    end
    
    if closestObs then
	        if not geom_diag_seen[closestObs.name] then
            geom_diag_seen[closestObs.name] = true

            print(string.format(
                "[%s] [GEOM-AUDIT] %s | SectorSpan=%.1f deg | RadCenter=%.1f | RadCorners=[%.1f..%.1f] (Eve frame)\n",
                ADV_MOD,
                closestObs.name,
                closestObs.sectorSpan,
                closestObs.centerRad,
                closestObs.radMin,
                closestObs.radMax
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
