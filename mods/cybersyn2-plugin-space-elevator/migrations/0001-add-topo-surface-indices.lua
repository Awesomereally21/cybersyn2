-- Map topology names to their surfaces via elevator data
local topo_surfaces = {}

for surface_index, elevators in pairs(storage.elevators_by_surface) do
	for _, elevator in pairs(elevators) do
		if elevator.stop and elevator.stop.valid and elevator.opposite_end.stop then
			local zone = remote.call(
				"space-exploration",
				"get_zone_from_surface_index",
				{ surface_index = surface_index }
			)
			local topo_name
			if zone then
				if zone.type == "orbit" and zone.parent_index then
					local parent = remote.call(
						"space-exploration",
						"get_zone_from_zone_index",
						{ zone_index = zone.parent_index }
					)
					topo_name = parent and parent.name or zone.name
				else
					topo_name = zone.name
				end
			end
			if topo_name then
				local full_name = "se-elevator:" .. topo_name
				if not topo_surfaces[full_name] then
					topo_surfaces[full_name] = {}
				end
				local planet = surface_index
				local orbit = elevator.opposite_end.surface_index
				topo_surfaces[full_name][planet] = true
				topo_surfaces[full_name][orbit] = true
			end
		end
	end
end

-- Update existing topologies with their surface indices via remote API
for topo_name, surface_set in pairs(topo_surfaces) do
	local topo_id = remote.call("cybersyn2", "get_topology_id", topo_name)
	if topo_id then
		local surfaces = {}
		for surface_index in pairs(surface_set) do
			table.insert(surfaces, surface_index)
		end
		remote.call("cybersyn2", "set_topology_surface_indices", topo_id, surfaces)
	end
end
