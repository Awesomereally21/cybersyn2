local cs2_data = data.raw["mod-data"]["cybersyn2"].data

-- Route plugin (reachable veto + cross-surface routing)
cs2_data.route_plugins["space-elevator"] = {
	reachable_callback = {
		"cybersyn2-plugin-space-elevator",
		"reachable_callback",
	},
	route_callback = { "cybersyn2-plugin-space-elevator", "route_callback" },
}

-- Topology plugins (v0.2.2+): merge elevator-connected surfaces into one topology
cs2_data.node_topology_plugins[#cs2_data.node_topology_plugins + 1] = {
	"cybersyn2-plugin-space-elevator",
	"node_topology_callback",
}
cs2_data.vehicle_topology_plugins[#cs2_data.vehicle_topology_plugins + 1] = {
	"cybersyn2-plugin-space-elevator",
	"vehicle_topology_callback",
}
