--!strict
--[[
	TableUtil
	Deep copy / reconcile / freeze helpers used by the data layer and Config.
]]

local TableUtil = {}

function TableUtil.DeepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in value :: any do
		copy[TableUtil.DeepCopy(key)] = TableUtil.DeepCopy(child)
	end
	return (copy :: any) :: T
end

-- Fills in any keys missing from `target` with copies from `template`
-- (recursively for nested tables). Existing values are never overwritten.
function TableUtil.Reconcile(target: { [any]: any }, template: { [any]: any })
	for key, templateValue in template do
		local current = target[key]
		if current == nil then
			target[key] = TableUtil.DeepCopy(templateValue)
		elseif type(current) == "table" and type(templateValue) == "table" then
			TableUtil.Reconcile(current, templateValue)
		end
	end
end

-- Recursively freezes a table so Config/Data definitions can't be mutated at runtime.
function TableUtil.DeepFreeze<T>(value: T): T
	if type(value) ~= "table" or table.isfrozen(value :: any) then
		return value
	end
	for _, child in value :: any do
		if type(child) == "table" then
			TableUtil.DeepFreeze(child)
		end
	end
	return table.freeze(value :: any) :: any
end

function TableUtil.Count(value: { [any]: any }): number
	local count = 0
	for _ in value do
		count += 1
	end
	return count
end

function TableUtil.Keys<K>(value: { [K]: any }): { K }
	local keys = {}
	for key in value do
		table.insert(keys, key)
	end
	return keys
end

-- Walks a path of string keys; returns nil if any step is missing.
function TableUtil.GetPath(root: { [any]: any }, path: { string }): any
	local node: any = root
	for _, key in path do
		if type(node) ~= "table" then
			return nil
		end
		node = node[key]
	end
	return node
end

-- Sets a value at a path, creating intermediate tables. Returns false if blocked by a non-table.
function TableUtil.SetPath(root: { [any]: any }, path: { string }, value: any): boolean
	local node: any = root
	for index = 1, #path - 1 do
		local key = path[index]
		local nextNode = node[key]
		if nextNode == nil then
			nextNode = {}
			node[key] = nextNode
		elseif type(nextNode) ~= "table" then
			return false
		end
		node = nextNode
	end
	node[path[#path]] = value
	return true
end

return TableUtil
