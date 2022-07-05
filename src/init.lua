local PhysicsStepped = game:GetService("RunService").Heartbeat

local ObjectCache = require(script.ObjectCache)
local Signal = require(script.Signal)

local CAST_TYPES = {
	Box = 1,
	Sphere = 2,
	Part = 3,
	None = 4
}

-- local PRECISION_OPTIONS = {
-- 	Low = 50,
-- 	Medium = 100,
-- 	High = 300,
-- 	Ultra = 1000
-- }

--[=[ 
	@type ProjectilePhysicsInfo {
	Position : Vector3,
	Velocity : Vector3,
	Acceleration : Vector3?,
	Jerk : Vector3?,
	Terminal : Vector3?,
	Goal : BasePart?, -- Expected to be for following a specific part.
	Distance : number,
	Mass : number?
	@within ProjectileCast
}
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
export type PhysicsUpdateFunction = (physicsInfo : ProjectilePhysicsInfo, dt : number) -> nil
export type ObjectUpdateFunction = (projectile : (BasePart | Model), physicsInfo : ProjectilePhysicsInfo, userData : table) -> nil

local min = math.min

---
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
----

local CAST_FUNCTION_NAME = "Launch%s"
local CACHE_FOLDER_NAME  = "_%sPartCache"

local INITIAL_CACHE_SIZE = 100

local ProjectileCasters ={}

--[=[
    @class ProjectileCast

   Creates ProjectileCasters.
]=]
local ProjectileCast = {}
ProjectileCast.__index = ProjectileCast
ProjectileCast._notDirectory = true
ProjectileCast.CastType = CAST_TYPES
-- ProjectileCast.PrecisionOption = PRECISION_OPTIONS

--[=[
    Creates a new projectile caster.

    @param name string -- The name of the ProjectileCaster
    @return ProjectileCaster -- Used for casting projectiles.
]=]
function ProjectileCast.new(name : string)
	local steppedEvent = Instance.new("BindableEvent")

	local caster = {
		CastType = CAST_TYPES.Box,
		-- Precision =	PRECISION_OPTIONS.Medium,
		MaxTime = 60,
		MaxDistance = 10000,
		Active = true,
		
		ActiveCasts = {},
		FrozenCasts = {},
		ProjectileParams = {},

		Hit = Signal.new(),	
		Overlapped = Signal.new(),
		Destroying = Signal.new(),
		Stepped =steppedEvent.Event,

		_stepped = steppedEvent
	}

	table.insert(ProjectileCasters, caster)

	return setmetatable(caster, ProjectileCast)
end

--[=[
    Creates a new cast.

    @param initialInfo ProjectilePhysicsInfo -- Initial physics information of the projectile.
    @param castParamsName string --Name of the cast params to use. (Must be created before using Cast)
    @param filterType Enum.RaycastFilterType? -- If you want to override the RaycastParams of the CastParams
    @param filterDescendantsInstances {Instance}? -- Instances to filter from casts
    @param replacesFilterList boolean? -- Whether or not the filtered descendants are added onto, or replace the default filter list.
    @return ActiveCast -- The active cast being simulated.
]=]
function ProjectileCast:Cast(initialInfo : ProjectilePhysicsInfo, castParamsName : string, filterType : Enum.RaycastFilterType?, filterDescendantsInstances : {Instance}?, replacesFilterList : boolean?) -- Returns id of the cast.
	assert(self.Hit, "Function only available for an instance of ProjectileCast")

	assert(initialInfo.Position and (initialInfo.Velocity or initialInfo.Terminal), "Inadequate projectile physics info.")

	local castParams = self.ProjectileParams[castParamsName]
	local oriRCP = castParams.RaycastParams

	assert(castParams, "No cast params of name '" .. castParamsName .. "'")

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

function ProjectileCast:NewCastParams(projectilePrefab : (BasePart | Model)?,  physicsUpdateFunction : PhysicsUpdateFunction?, objectUpdateFunction : ObjectUpdateFunction?) 
	assert(self.Hit, "Function only available for an instance of ProjectileCast")

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
			projectile:PivotTo(CFrame.lookAt(physicsInfo.Position, physicsInfo.Position + physicsInfo.Velocity))
		end), -- Default to align along trajectory
		
		RaycastParams = rcp,
		OverlapParams = olp
	}

	self.ProjectileParams[projectilePrefab.Name] = projectileCastParams

	return projectileCastParams
end


function ProjectileCast:ReleaseToEngine(activeCast)
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

-- Takes an object from the simulation and does a ProjectileCast
function ProjectileCast:RetrieveFromEngine(instance, funcName)
	assert(self.Hit, "Function only available for an instance of ProjectileCast")

	-- check parent of instance if it matches am objectCache container.
	-- make and initialize caster data.

	physicsInfo = {
		Position = instance:GetPivot().Position,
		Velocity = instance.AssemblyLinearVelocity
	}

	activeCast.PhysicsInfo = physicsInfo
end

-- The 'fromIndex' parameter is expected to be used internally to marginally speed up the process.
function ProjectileCast:DestroyCast(activeCast, fromIndex : number?)
	assert(self.Hit, "Function only available for an instance of ProjectileCast")

	fromIndex = fromIndex or  table.find(self.ActiveCasts, activeCast)

	local sourceTable;

	if fromIndex then
		sourceTable = self.ActiveCasts
	else
		fromIndex = table.find(self.FrozenCasts, activeCast)
		sourceTable = self.FrozenCasts
	end

	if not fromIndex then return warn("Cast not available") end

	self.Destroying:Fire(activeCast)

	sourceTable[fromIndex], sourceTable[#sourceTable] = sourceTable[#sourceTable], nil

	-- Return object to its cache :
	if activeCast.Instance then
		local projectileCache = self.ProjectileParams[activeCast.ParamsName] and  self.ProjectileParams[activeCast.ParamsName].ProjectileCache

		if projectileCache then
			projectileCache:ReturnObject(activeCast.Instance)

			activeCast.Instance = nil -- must save it from the FullWipe.
		else
			activeCast.Instance:Destroy()
		end
	end
	
	FullWipe(activeCast)
end

function  ProjectileCast:FreezeCast(activeCast)
	assert(self.Hit, "Function only available for an instance of ProjectileCast")

	local activeCasts = self.ActiveCasts
	local ind = table.find(activeCasts, activeCast) 

	if not ind then return warn("Cast not active") end

	-- swap-pop
	activeCasts[ind], activeCasts[#activeCasts] = activeCasts[#activeCasts], nil
	table.insert(self.FrozenCasts, activeCast)
end

function  ProjectileCast:ResumeCast(activeCast)
	assert(self.Hit, "Function only available for an instance of ProjectileCast")

	local frozenCasts = self.FrozenCasts
	local ind = table.find(frozenCasts, activeCast) 

	if not ind then return warn("Cast not frozen") end

		-- swap-pop
	frozenCasts[ind], frozenCasts[#frozenCasts] = frozenCasts[#frozenCasts], nil
	table.insert(self.ActiveCasts, activeCast)
end

function ProjectileCast:GetCastFromInstance(instance)
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

-- One possible way of getting the params is via ActiveCast.ParamsName
function ProjectileCast:GetParams(paramsName)
	assert(self.Hit, "Function only available for an instance of ProjectileCast")

	return self.ProjectileParams[paramsName]
end

PhysicsStepped:Connect(function(deltaTime)
	for i = 1, #ProjectileCasters do
		local projectileCaster = ProjectileCasters[i]

		if not projectileCaster.Active then continue end

		local projectileParams = projectileCaster.ProjectileParams
		local activeCasts = projectileCaster.ActiveCasts
		local castType = projectileCaster.CastType

		local hitEvent =projectileCaster.Hit
		local overlappedEvent =projectileCaster.Overlapped
		local steppedEvent =projectileCaster._stepped

		local i = 1
		
		while i <= #activeCasts do
			local activeCast = activeCasts[i]

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
			local castParams = projectileParams[activeCast.ParamsName]
			local instance = activeCast.Instance
			local userData = activeCast.UserData

			local lastPoint = physicsInfo.Position

			activeCast.Time += deltaTime
			_ = castParams.PhysicsFunction and castParams.PhysicsFunction(physicsInfo, deltaTime)
			_ = (castParams.ObjectFunction and activeCast.Instance) and castParams.ObjectFunction(instance, physicsInfo, userData)

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

			i += 1
		end -- end of active cast loop

		steppedEvent:Fire()
	end -- end of projectileCaster loop
end)

return ProjectileCast