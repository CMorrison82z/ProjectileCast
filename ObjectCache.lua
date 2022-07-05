-----------------------------------------------------------
-------------------- MODULE DEFINITION --------------------
-----------------------------------------------------------

local ObjectCacheStatic = {}
ObjectCacheStatic.__index = ObjectCacheStatic
ObjectCacheStatic.__type = "ObjectCache" -- For compatibility with TypeMarshaller

-- TYPE DEFINITION: Object Cache Instance
export type ObjectCache = {
	Open: {[number]: BasePart | Model},
	InUse: {[number]: BasePart | Model},
	CurrentCacheParent: Instance,
	Template: BasePart | Model,
	ExpansionSize: number
}

local objectProperties = {
	"Transparency",
	"Size",
	"Material",
	"Color",
	"Reflectance"
}

-----------------------------------------------------------
----------------------- STATIC DATA -----------------------
-----------------------------------------------------------					

-- A CFrame that's really far away. Ideally. You are free to change this as needed.
local CF_REALLY_FAR_AWAY = CFrame.new(0, 10e8, 0)

local DEFAULT_CACHE_NAME = "_%sObjectCache"

-- Format params: methodName, ctorName
local ERR_NOT_INSTANCE = "Cannot statically invoke method '%s' - It is an instance method. Call it on an instance of this class created via %s"

-- Format params: paramName, expectedType, actualType
local ERR_INVALID_TYPE = "Invalid type for parameter '%s' (Expected %s, got %s)"

-----------------------------------------------------------
------------------------ UTILITIES ------------------------
-----------------------------------------------------------

--Similar to assert but warns instead of errors.
local function assertwarn(requirement: boolean, messageIfNotMet: string)
	if requirement == false then
		warn(messageIfNotMet)
	end
end

--Dupes a object from the template.
local function MakeFromTemplate(self, template: BasePart | Model, currentCacheParent: Instance): BasePart | Model
	local object: BasePart | Model = template:Clone()
	-- ^ Ignore W000 type mismatch between Instance and BasePart. False alert.
	
	object:PivotTo(CF_REALLY_FAR_AWAY)
	
	-- TODO : Further generalize for other instances ("Decals" for example) that can be reset on Return...
	
	if self._objectType == "BasePart" then
		local selfTemplate = {}
		
		for _, propName in ipairs(objectProperties) do
			selfTemplate[propName] = object[propName]
		end
		
		self._selfTemplate[object] = selfTemplate
	else
		local selfTemplate = {}
		
		for _, bp in ipairs(object:GetDescendants()) do
			if not bp:IsA("BasePart") then continue end
			
			local bpTemplate = {}
			
			for _, propName in ipairs(objectProperties) do
				bpTemplate[propName] = bp[propName]
			end
			
			selfTemplate[bp] = bpTemplate
		end
		
		self._selfTemplate[object] = selfTemplate
	end
	
	object.Parent = currentCacheParent
	
	return object
end

function ObjectCacheStatic.new(template: BasePart | Model, numPrecreatedObjects: number?, currentCacheParent: Instance?): ObjectCache
	numPrecreatedObjects = numPrecreatedObjects or 5
	
	if not currentCacheParent then
		currentCacheParent = Instance.new("Folder")
		currentCacheParent.Name = DEFAULT_CACHE_NAME:format(template.Name)
		currentCacheParent.Parent = workspace
	else
		assert(currentCacheParent.Parent == workspace, "Cache parent is not a member of workspace")
	end
	
	--PrecreatedParts value.
	--Same thing. Ensure it's a number, ensure it's not negative, warn if it's really huge or 0.
	assert(numPrecreatedObjects > 0, "PrecreatedObjects can not be negative!")
	assertwarn(numPrecreatedObjects ~= 0, "PrecreatedObjects is 0! This may have adverse effects when initially using the cache.")
	assertwarn(template.Archivable, "The template's Archivable property has been set to false, which prevents it from being cloned. It will temporarily be set to true.")
	
	local oldArchivable = template.Archivable
	template.Archivable = true
	local newTemplate: BasePart | Model = template:Clone()
	-- ^ Ignore W000 type mismatch between Instance and BasePart. False alert.
	
	template.Archivable = oldArchivable
	template = newTemplate
	
	local object: ObjectCache = {
		Open = {},
		InUse = {},
		CurrentCacheParent = currentCacheParent,
		Template = template,
		ExpansionSize = 10,
		_selfTemplate = {}, -- To reset a returned object to its original properties
		_objectType = template:IsA("BasePart") and "BasePart" or "Model"
	}
	
	setmetatable(object, ObjectCacheStatic)
	
	-- Below: Ignore type mismatch nil | number and the nil | Instance mismatch on the table.insert line.
	for _ = 1, numPrecreatedObjects do
		table.insert(object.Open, MakeFromTemplate(object, template, object.CurrentCacheParent))
	end
	object.Template.Parent = nil
	
	return object
	-- ^ Ignore mismatch here too
end

-- Gets a object from the cache, or creates one if no more are available.
function ObjectCacheStatic:GetObject(): BasePart | Model
	assert(getmetatable(self) == ObjectCacheStatic, ERR_NOT_INSTANCE:format("GetObject", "ObjectCache.new"))
	
	if #self.Open == 0 then
		warn("No objects available in the cache! Creating [" .. self.ExpansionSize .. "] new object instance(s) - this amount can be edited by changing the ExpansionSize property of the ObjectCache instance... (This cache now contains a grand total of " .. tostring(#self.Open + #self.InUse + self.ExpansionSize) .. " objects.)")
		for i = 1, self.ExpansionSize, 1 do
			table.insert(self.Open, MakeFromTemplate(self, self.Template, self.CurrentCacheParent))
		end
	end
	local object = self.Open[#self.Open]
	self.Open[#self.Open] = nil
	table.insert(self.InUse, object)
	return object
end

-- Returns a object to the cache.
function ObjectCacheStatic:ReturnObject(object: BasePart | Model)
	assert(getmetatable(self) == ObjectCacheStatic, ERR_NOT_INSTANCE:format("ReturnObject", "ObjectCache.new"))
	
	local index = table.find(self.InUse, object)
	
	if index ~= nil then
		table.remove(self.InUse, index)
		table.insert(self.Open, object)
		object:PivotTo(CF_REALLY_FAR_AWAY)
		
		if self._objectType == "BasePart" then
			for propName, propVal in pairs(self._selfTemplate[object]) do
				object[propName] = propVal
			end
		else
			for objectDescendant, descProperties in pairs(self._selfTemplate[object]) do
				for propName, propVal in pairs(descProperties) do
					objectDescendant[propName] = propVal
				end
			end
		end
	else
		error("Attempted to return object \"" .. object.Name .. "\" (" .. object:GetFullName() .. ") to the cache, but it's not in-use! Did you call this on the wrong object?")
	end
end

-- Adds numObjects more objects to the cache.
function ObjectCacheStatic:Expand(numObjects: number): ()
	assert(getmetatable(self) == ObjectCacheStatic, ERR_NOT_INSTANCE:format("Expand", "ObjectCache.new"))
	if numObjects == nil then
		numObjects = self.ExpansionSize
	end
	
	for i = 1, numObjects do
		table.insert(self.Open, MakeFromTemplate(self, self.Template, self.CurrentCacheParent))
	end
end

-- Destroys this cache entirely. Use this when you don't need this cache object anymore.
-- TODO : Revisit this, because this is a stupid method...
function ObjectCacheStatic:Dispose()
	assert(getmetatable(self) == ObjectCacheStatic, ERR_NOT_INSTANCE:format("Dispose", "ObjectCache.new"))
	
	for i = 1, #self.Open do
		self.Open[i]:Destroy()
	end
	for i = 1, #self.InUse do
		self.InUse[i]:Destroy()
	end
	
	self.Template:Destroy()
	self.Open = {}
	self.InUse = {}
	self.CurrentCacheParent = nil
	
	self.GetObject = nil
	self.ReturnObject = nil
	self.SetCacheParent = nil
	self.Expand = nil
	self.Dispose = nil
end

return ObjectCacheStatic