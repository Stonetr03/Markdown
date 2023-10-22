-- Stonetr03

function Create(InstanceName: string,Parent: Instance,Properties: table)
	local Object = Instance.new(InstanceName)
	if Parent then
		Object.Parent = Parent
	end

	if typeof(Properties) == "table" then
		for o,i in pairs(Properties) do
			Object[o] = i
		end
	end

	return Object
end

return Create
