local PhysicsStepped = game:GetService("RunService").Heartbeat

local ObjectCache = require(script.ObjectCache)
local Signal = require(script.Signal)

local t_insert = table.insert

local CAST_TYPES = {
    Box = 1,
    Sphere = 2,
    Part = 3,
    None = 4
}

-- TODO : Throttling ProjectileCaster

--[=[
    @class ProjectileCast
]=]
local ProjectileCast = {}
ProjectileCast._notDirectory = true
ProjectileCast.CastType = CAST_TYPES

local ProjectileParams = {}

local ProjectileCaster = {}
ProjectileCaster.__index = ProjectileCaster

--[=[
    @interface ProjectilePhysicsInfo
    .Position Vector3,
    .Velocity Vector3,
    .Acceleration Vector3?,
    .Jerk Vector3?,
    .Terminal Vector3?,
    .Goal BasePart?, -- Expected to be for following a specific part.
    .Mass number?
    @within ProjectileCast

    General physics information expected for use in a PhysicsUpdateFunction
]=]
export type ProjectilePhysicsInfo = {
    Position : Vector3,
    Velocity : Vector3,
    Acceleration : Vector3?,
    Jerk : Vector3?,
    Terminal : Vector3?,
    Goal : BasePart?, -- Expected to be for following a specific part.
    Distance : number,
    Mass : number?
}

--[=[
    @interface ProjectileCastParams
    .ProjectileCache ObjectCache,
    .PhysicsFunction PhysicsUpdateFunction,
    .ObjectFunction ObjectUpdateFunction,
    .RaycastParams RaycastParams,
    .OverlapParams OverlapParams
    @within ProjectileCast

    Cast parameters for use in casting.
]=]
export type ProjectileCastParams = {
    ProjectileCache : ObjectCache,

    PhysicsFunction : PhysicsUpdateFunction,
    ObjectFunction : ObjectUpdateFunction,
    
    RaycastParams : RaycastParams,
    OverlapParams : OverlapParams
}

--[=[
    @interface ActiveCast
    .ParamsName string,
    .Instance BasePart | Model,
    .PhysicsInfo ProjectilePhysicsInfo,
    .RaycastParams RaycastParams,
    .OverlapParams OverlapParams ,
    .UserData table,
    .Time number,
    .Distance number,
    @within ProjectileCast

    Comprehensive data of a simulated cast.
]=]
export type ActiveCast = {
    ParamsName : string,
    Instance : BasePart | Model,
    PhysicsInfo : ProjectilePhysicsInfo,
    RaycastParams : RaycastParams,
    OverlapParams : OverlapParams ,

    UserData : table,
    Time : number,
    Distance : number,
}

--[=[
    @type PhysicsUpdateFunction  (physicsInfo : ProjectilePhysicsInfo, dt : number) -> nil
    @within ProjectileCast
    Updates the physics properties of the object during simulation
 ]=]
export type PhysicsUpdateFunction = (physicsInfo : ProjectilePhysicsInfo, dt : number) -> nil

--[=[
    @type ObjectUpdateFunction  (projectile : (BasePart | Model), physicsInfo : ProjectilePhysicsInfo, userData : table) -> CFrame
    @within ProjectileCast
    Updates the object orientation during simulation
    -- TODO : Add warning saying NOT to set the parts actual cframe !
]=]
export type ObjectUpdateFunction = (projectile : (BasePart | Model), physicsInfo : ProjectilePhysicsInfo, userData : table) -> CFrame

local min = math.min


function FullWipe(t)
    if not t then return end
    
    for i, v in pairs(t) do
        if typeof(v) == "Instance" then
            if v:IsA("Player") then
                continue
            end
            v:Destroy()
        elseif typeof(v) == "RBXScriptConnection" then
            v:Disconnect()
        elseif type(v) == "table" then
            if type(v.Destroy) == "function" then
                v:Destroy()
            else
                FullWipe(v)
            end
        end
    end
    
    table.clear(t)
    
    t = nil
end

local CAST_FUNCTION_NAME = "Launch%s"
local CACHE_FOLDER_NAME  = "_%sPartCache"

local INITIAL_CACHE_SIZE = 100

local ProjectileCasters ={}

--[=[
    Creates and returns a new ProjectileCaster .
]=]
function ProjectileCast.new()
    local steppedEvent = Instance.new("BindableEvent")

    local caster = {
        CastType = CAST_TYPES.Box,
        -- Precision =	PRECISION_OPTIONS.Medium,
        MaxTime = 60,
        MaxDistance = 10000,
        Throttling = 0,
        Active = true,
        OnlyBaseParts = false,
        
        ActiveCasts = {},
        FrozenCasts = {},

        Hit = Signal.new(),	
        Overlapped = Signal.new(),
        Destroying = Signal.new(),
        Stepped =steppedEvent.Event,

        _stepped = steppedEvent,

        _throttleCount = 0
    }

    table.insert(ProjectileCasters, caster)

    return setmetatable(caster, ProjectileCaster)
end

--[=[
    Creates and adds a new set of ProjectileCastParams
]=]
function ProjectileCast:NewCastParams(projectilePrefab : (BasePart | Model)?,  physicsUpdateFunction : PhysicsUpdateFunction?, objectUpdateFunction : ObjectUpdateFunction?) : ProjectileCastParams
    -- new projectile info : cache, default cast type, raycast/spatial params, updateFunction.
    
    local pCache;
    local rcp : RaycastParams = RaycastParams.new()
    local olp : OverlapParams = OverlapParams.new()

    if projectilePrefab then
        local cacheName = CACHE_FOLDER_NAME:format(projectilePrefab.Name)

        local cacheParent = Instance.new("Folder")
        cacheParent.Name = cacheName
        cacheParent.Parent = workspace
        
        local projectileTemplate = projectilePrefab:Clone()

        if projectileTemplate.ClassName == "Model" then
            for index, value in ipairs(projectileTemplate:GetDescendants()) do
                if not value:IsA("BasePart") then
                     continue
                end

                value.CanCollide = false
                value.Anchored = true
                value.CanTouch = false
            end
        else
            projectileTemplate.CanCollide = false
            projectileTemplate.Anchored = true
            projectileTemplate.CanTouch = false
        end

        pCache = ObjectCache.new(projectileTemplate, INITIAL_CACHE_SIZE, cacheParent)

        rcp.FilterDescendantsInstances = {cacheParent}
        olp.FilterDescendantsInstances = {cacheParent}
    end
    
    local projectileCastParams = {
        ProjectileCache = pCache,

        PhysicsFunction = physicsUpdateFunction or function (physicsInfo, dt)
            local v0 = physicsInfo.Velocity
            local x0 = physicsInfo.Position
            local a0 = physicsInfo.Acceleration
    
            physicsInfo.Velocity = v0 + a0 * dt
            physicsInfo.Position = x0 + v0 * dt + a0 * (dt ^ 2 / 2)
        end, -- Default to gravity
        ObjectFunction = projectilePrefab and (objectUpdateFunction or function (projectile, physicsInfo, userData)
            return CFrame.lookAt(physicsInfo.Position, physicsInfo.Position + physicsInfo.Velocity)
        end), -- Default to align along trajectory
        
        RaycastParams = rcp,
        OverlapParams = olp
    }

   ProjectileParams[projectilePrefab.Name] = projectileCastParams

    return projectileCastParams
end

--[=[
    Useful for getting the Params used for an ActiveCast.ProjectileCaster. Sample usage "ActiveCast.ParamsName"
]=]
function ProjectileCast:GetParams(paramsName : string)
    assert(self.Hit, "Function only available for an instance of ProjectileCast")

    return ProjectileParams[paramsName]
end

--[=[
    Creates and adds a new cast to the simulation.
]=]
function ProjectileCaster:Cast(initialInfo : ProjectilePhysicsInfo, castParamsName : string, filterType : Enum.RaycastFilterType?, filterDescendantsInstances : {Instance}?, replacesFilterList : boolean?) : ActiveCast -- Returns id of the cast.
    assert(self.Hit, "Function only available for an instance of ProjectileCast")

    assert(initialInfo.Position and (initialInfo.Velocity or initialInfo.Terminal), "Inadequate projectile physics info.")

    local castParams = ProjectileParams[castParamsName]
    local oriRCP = castParams.RaycastParams

    assert(castParams, "No cast params of name '" .. castParamsName .. "'")
    assert(self.OnlyBaseParts and castParams.ProjectileCache.Template:IsA("BasePart"), "Attempt to create cast params for ProjectileCast set to 'OnlyBaseParts'")

     local rcp : RaycastParams = RaycastParams.new()
     local olp : OverlapParams = OverlapParams.new() 

     rcp.FilterType = filterType or oriRCP.FilterType
     olp.FilterType = filterType or oriRCP.FilterType

     filterDescendantsInstances = filterDescendantsInstances or {}

     if not replacesFilterList then
        for index, value in ipairs(oriRCP.FilterDescendantsInstances) do
            table.insert(filterDescendantsInstances, value)
        end
     end
    
     rcp.FilterDescendantsInstances = filterDescendantsInstances
    olp.FilterDescendantsInstances = filterDescendantsInstances

    local activeCast = {
        ParamsName = castParamsName,
        Instance = castParams.ProjectileCache and castParams.ProjectileCache:GetObject(),
        PhysicsInfo = initialInfo,
        RaycastParams = rcp,
        OverlapParams =olp ,

        UserData = {},
        Time = 0,
        Distance = 0,
    }

    table.insert(self.ActiveCasts, activeCast)

    return activeCast
end

--[=[
   Removes the active cast from the ProjectileCaster's simulation and allows the Roblox physics engine to simulate it.

    :::note
    The object being simulated is _returned to the ProjectileCache_. A new object is cloned and parented to workspace.
    The object has its velocity and angular velocity inherited from PhysicsInfo via [BasePart:ApplyImpulse] and [BasePart:ApplyAngularImpulse]
    The object is made CanCollide and Un-anchored.
    :::
]=]
function ProjectileCaster:ReleaseToEngine(activeCast : ActiveCast)
    assert(self.Hit, "Function only available for an instance of ProjectileCast")
    
    local projectile = activeCast.Instance:Clone()

    local physicsInfo = table.clone(activeCast.PhysicsInfo)

    self:DestroyCast(activeCast)

    -- prepare for engine simulation :
    projectile.Parent = workspace

    if projectile.ClassName == "Model" then
        local uniqueAssemblies = {}

        for index, value : BasePart in ipairs(projectile:GetChildren()) do
            value.Anchored = false
            value.CanCollide = true

            if table.find(uniqueAssemblies, value.AssemblyRootPart) then
                continue
            end

            table.insert(uniqueAssemblies, value.AssemblyRootPart)
        end

        for index, value : BasePart in ipairs(uniqueAssemblies) do
            value.AssemblyRootPart:ApplyImpulse(physicsInfo.Velocity * value.AssemblyMass)
            value.AssemblyRootPart:ApplyAngularImpulse((physicsInfo.AngularVelocity and physicsInfo.AngularVelocity or Vector3.zero) * value.AssemblyMass)
        end
    else
        projectile.Anchored = false
        projectile.CanCollide = true
        projectile.AssemblyRootPart:ApplyImpulse(physicsInfo.Velocity * projectile.AssemblyMass)
        projectile.AssemblyRootPart:ApplyAngularImpulse((physicsInfo.AngularVelocity and physicsInfo.AngularVelocity or Vector3.zero) * projectile.AssemblyMass)
    end
    
    
    return projectile
end

--[=[
    :::danger
    NOT YET IMPLEMENTED !
]=]
function ProjectileCaster:RetrieveFromEngine(instance : Instance, params : ProjectileCastParams)
    assert(self.Hit, "Function only available for an instance of ProjectileCast")

    -- check parent of instance if it matches am objectCache container.
    -- make and initialize caster data.

    physicsInfo = {
        Position = instance:GetPivot().Position,
        Velocity = instance.AssemblyLinearVelocity
    }

    activeCast.PhysicsInfo = physicsInfo
end

--[=[
    Cleans up a cast.
    :::danger
    The '_fromIndex' parameter is expected to be used internally only !
    :::
]=]
function ProjectileCaster:DestroyCast(activeCast : ActiveCast, _fromIndex : number?)
    assert(self.Hit, "Function only available for an instance of ProjectileCast")

    _fromIndex = _fromIndex or  table.find(self.ActiveCasts, activeCast)

    local sourceTable;

    if _fromIndex then
        sourceTable = self.ActiveCasts
    else
        _fromIndex = table.find(self.FrozenCasts, activeCast)
        sourceTable = self.FrozenCasts
    end

    if not _fromIndex then return warn("Cast not available") end

    self.Destroying:Fire(activeCast)

    sourceTable[_fromIndex], sourceTable[#sourceTable] = sourceTable[#sourceTable], nil

    -- Return object to its cache :
    if activeCast.Instance then
        local projectileCache = ProjectileParams[activeCast.ParamsName] and ProjectileParams[activeCast.ParamsName].ProjectileCache

        if projectileCache then
            projectileCache:ReturnObject(activeCast.Instance)

            activeCast.Instance = nil -- must save it from the FullWipe.
        else
            activeCast.Instance:Destroy()
        end
    end
    
    FullWipe(activeCast)
end

--[=[
    Stops simulation of the cast, but the ActiveCast still exists.
]=]
function  ProjectileCaster:FreezeCast(activeCast : ActiveCast)
    assert(self.Hit, "Function only available for an instance of ProjectileCast")

    local activeCasts = self.ActiveCasts
    local ind = table.find(activeCasts, activeCast) 

    if not ind then return warn("Cast not active") end

    -- swap-pop
    activeCasts[ind], activeCasts[#activeCasts] = activeCasts[#activeCasts], nil
    table.insert(self.FrozenCasts, activeCast)
end

--[=[
    Resumes a frozen cast.
]=]
function  ProjectileCaster:ResumeCast(activeCast : ActiveCast)
    assert(self.Hit, "Function only available for an instance of ProjectileCast")

    local frozenCasts = self.FrozenCasts
    local ind = table.find(frozenCasts, activeCast) 

    if not ind then return warn("Cast not frozen") end

        -- swap-pop
    frozenCasts[ind], frozenCasts[#frozenCasts] = frozenCasts[#frozenCasts], nil
    table.insert(self.ActiveCasts, activeCast)
end

--[=[
   From an instance, retrieves the full ActiveCast associated with that instance
]=]
function ProjectileCaster:GetCastFromInstance(instance : (BasePart | Model))
    assert(self.Hit, "Function only available for an instance of ProjectileCast")

    for index, value in ipairs(self.ActiveCasts) do
        if value.Instance == instance then
            return value
        end
    end

    for index, value in ipairs(self.FrozenCasts) do
        if value.Instance == instance then
            return value
        end
    end
end

PhysicsStepped:Connect(function(deltaTime)
    for i = 1, #ProjectileCasters do
        local projectileCaster = ProjectileCasters[i]

        local throttling = projectileCaster.Throttling + 1
        local throttledDeltaTime = throttling * deltaTime

        if ((throttling % 1) ~= 0) or throttling <= 0 then warn("Throttling must be a positive whole number. Skipping cycle") continue end
        if not projectileCaster.Active then continue end
        
        local activeCasts = projectileCaster.ActiveCasts
        local castType = projectileCaster.CastType
        local onlyBaseParts = projectileCaster.OnlyBaseParts

        local partList, cframeList;

        if onlyBaseParts then
            partList, cframeList = {}, {}
        end

        local hitEvent =projectileCaster.Hit
        local overlappedEvent =projectileCaster.Overlapped
        local steppedEvent =projectileCaster._stepped

        projectileCaster._throttleCount = (projectileCaster._throttleCount % throttling)

        local loadSize = math.floor(#activeCasts / throttling)
        local remainder = #activeCasts % throttling

        local i =  projectileCaster._throttleCount * loadSize + 1
        
        while i <=  (projectileCaster._throttleCount == 0 and (loadSize + remainder) or (projectileCaster._throttleCount + 1) * loadSize) do
            local activeCast = activeCasts[i]

            if not activeCast then
                break
            end

            if projectileCaster.MaxTime < activeCast.Time then
                projectileCaster:DestroyCast(activeCast)

                activeCast = activeCasts[i] -- DestroyCast does a pop swap, so just get the same index again.
            end

            if not activeCast then continue end -- if it is the last one in the loop, activeCast will still be nil

            if projectileCaster.MaxDistance < activeCast.Distance then
                projectileCaster:DestroyCast(activeCast)

                activeCast = activeCasts[i] -- DestroyCast does a pop swap, so just get the same index again.
            end

            if not activeCast then continue end -- if it is the last one in the loop, activeCast will still be nil

            local physicsInfo = activeCast.PhysicsInfo
            local castParams = ProjectileParams[activeCast.ParamsName]
            local instance = activeCast.Instance
            local userData = activeCast.UserData

            local lastPoint = physicsInfo.Position

            activeCast.Time += deltaTime
            _ = castParams.PhysicsFunction and castParams.PhysicsFunction(physicsInfo, deltaTime)
            local nCFrame = (castParams.ObjectFunction and activeCast.Instance) and castParams.ObjectFunction(instance, physicsInfo, userData)

            local nextPoint = physicsInfo.Position

            activeCast.Distance += (nextPoint - lastPoint) .Magnitude

            local rcr = workspace:Raycast(lastPoint, nextPoint - lastPoint, activeCast.RaycastParams)

            if castType then
                local hitParts;

                if castType == 1 then
                    if instance.ClassName == "Model" then
                        local o, s = instance:GetBoundingBox()

                        hitParts = workspace:GetPartBoundsInBox(o, s, activeCast.OverlapParams)
                    else
                        hitParts = workspace:GetPartBoundsInBox(instance.CFrame, instance.Size, activeCast.OverlapParams)
                    end
                elseif castType == 2 then
                    if instance.ClassName == "Model" then
                        local ori, size = instance:GetBoundingBox()
                    
                        hitParts = workspace:GetPartBoundsInRadius(ori.Position, size.Magnitude, activeCast.OverlapParams)
                    else
                        hitParts = workspace:GetPartBoundsInBox(instance.Position, instance.Size.Magnitude, activeCast.OverlapParams)
                    end
                else
                    hitParts = workspace:GetPartsInPart(instance, activeCast.OverlapParams)
                end
                
                if #hitParts > 0 then
                    overlappedEvent:Fire(hitParts, activeCast)
                end
            end

            if rcr then
                -- If it hit's something, the point it hit will be closer than that of nextPoint.

                local distanceCorrection = (rcr.Position - lastPoint).Magnitude

                activeCast.Distance -= distanceCorrection

                hitEvent:Fire(rcr, activeCast)
            end

            if onlyBaseParts then
                t_insert(partList, instance)
                t_insert(cframeList, nCFrame)
            else
                instance:PivotTo(nCFrame)
            end

            i += 1
        end -- end of active cast loop

        if onlyBaseParts then
            workspace:BulkMoveTo(partList, cframeList, Enum.BulkMoveMode.FireCFrameChanged)
        end

        steppedEvent:Fire()
    end -- end of projectileCaster loop
end)

return ProjectileCast