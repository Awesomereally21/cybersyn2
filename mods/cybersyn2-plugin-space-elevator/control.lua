local events = require("__cybersyn2__.lib.core.event")
local strace = require("__cybersyn2__.lib.core.strace")
local tlib = require("__cybersyn2__.lib.core.table")
local pos_lib = require("__cybersyn2__.lib.core.math.pos")

local pos_distsq = pos_lib.pos_distsq
local EMPTY = tlib.EMPTY_STRICT
local SE_ELEVATOR_ORBIT_SUFFIX = " ↓"
local SE_ELEVATOR_PLANET_SUFFIX = " ↑"
local SE_ELEVATOR_SUFFIX_LENGTH = #SE_ELEVATOR_ORBIT_SUFFIX
local ELEVATOR_NAME_PREFIX = "[img=entity/se-space-elevator]  "
local ELEVATOR_NAME_PREFIX_LENGTH = #ELEVATOR_NAME_PREFIX

strace.set_handler(strace.standard_log_handler)

require("storage")
require("elevators")

---@param stock LuaEntity
local function find_nearest_valid_elevator(
	topology_id,
	stock,
	from_surface_index,
	to_surface_index
)
	local from_elevators = storage.elevators_by_surface[from_surface_index]
		or EMPTY

	local best_elevator = nil
	local best_distance = math.huge
	for _, from_elevator in pairs(from_elevators) do
		local to_elevator = from_elevator.opposite_end
		local valid = true
		if
			(to_elevator.surface_index == to_surface_index)
			and to_elevator.stop
			and to_elevator.stop.valid
		then
			if (not from_elevator.stop) or not from_elevator.stop.valid then
				invalidate_elevator(from_elevator)
				valid = false
			end
			if (not to_elevator.stop) or not to_elevator.stop.valid then
				invalidate_elevator(to_elevator)
				valid = false
			end

			if valid then
				local distance = pos_distsq(stock.position, from_elevator.stop.position)
				if distance < best_distance then
					best_distance = distance
					best_elevator = from_elevator
				end
			else
				-- At least one elevator was invalidated.
			end
		end
	end
	return best_elevator
end

---@param delivery_id int64
---@param vehicle_id int64
---@param lua_train LuaTrain
---@param elevator CS2.SpaceElevatorPlugin.Elevator
---@param continuation_stop_name string Name of a station to continue to after elevator transit. This is needed so the train doesnt get stuck in the elevator.
local function transit_elevator(
	delivery_id,
	vehicle_id,
	lua_train,
	elevator,
	continuation_stop_name
)
	local lua_train_id = lua_train.id
	storage.trains[lua_train_id] = {
		id = lua_train_id,
		delivery_id = delivery_id,
		vehicle_id = vehicle_id,
		previous_group = lua_train.group,
	}

	lua_train.group = nil
	lua_train.schedule = {
		records = {
			{
				station = elevator.stop.backer_name,
			},
			{
				station = continuation_stop_name,
			},
		},
		current = 1,
	}
end

---@param previous_luatrain_id uint64
---@param new_luatrain LuaTrain
local function transit_complete(previous_luatrain_id, new_luatrain)
	local train_record = storage.trains[previous_luatrain_id]
	if not train_record then return end

	new_luatrain.schedule = nil
	new_luatrain.group = train_record.previous_group
	storage.trains[previous_luatrain_id] = nil

	remote.call(
		"cybersyn2",
		"route_plugin_handoff",
		train_record.delivery_id,
		new_luatrain
	)
end

--------------------------------------------------------------------------------
-- Topology plugins (v0.2.2+)
--
-- Each elevator connects a planet/moon to its orbit. We create one topology
-- per such pair, named "se-elevator:<planet_name>". Both the planet surface
-- and the orbit surface return the same topology ID, so the dispatcher sees
-- stations on both surfaces as reachable candidates.
--
-- Surfaces WITHOUT an elevator get nil (no override), so they keep their
-- default per-surface topology and remain isolated.
--------------------------------------------------------------------------------

---Cache: surface_index -> topology_id (or false if no elevator on surface)
local surface_topology_cache = {}

---Get or create the elevator topology for a given surface.
---Returns nil if this surface has no valid elevators.
---@param surface_index uint32
---@return Id? topology_id
local function get_topology_for_surface(surface_index)
	local cached = surface_topology_cache[surface_index]
	if cached == false then return nil end
	if cached then return cached end

	-- Check if this surface has elevators
	local surface_elevators = storage.elevators_by_surface[surface_index]
	if not surface_elevators then
		surface_topology_cache[surface_index] = false
		return nil
	end

	-- Find any valid elevator to determine the pair name
	for _, elevator in pairs(surface_elevators) do
		if is_elevator_valid(elevator) then
			-- Use the planet-side surface name as the topology key.
			-- Both sides of an elevator share the same topology.
			local planet_surface_index = elevator.surface_index
			local orbit_surface_index = elevator.opposite_end.surface_index

			-- Determine which side is the planet by checking SE zone type.
			-- The planet name is more stable; query it from the surface itself.
			local zone = remote.call(
				"space-exploration",
				"get_zone_from_surface_index",
				{ surface_index = surface_index }
			)
			local topo_name
			if zone then
				if zone.type == "orbit" and zone.parent_index then
					-- We're on the orbit side; get parent planet name
					local parent = remote.call(
						"space-exploration",
						"get_zone_from_zone_index",
						{ zone_index = zone.parent_index }
					)
					topo_name = parent and parent.name or zone.name
				else
					-- We're on the planet/moon side
					topo_name = zone.name
				end
			end

			if not topo_name then
				-- Fallback: use a combined name from both surface indices
				topo_name = planet_surface_index .. "-" .. orbit_surface_index
			end

			local full_name = "se-elevator:" .. topo_name
			local topo_id =
				remote.call("cybersyn2", "get_or_create_topology", full_name, {
					-- surface indices so manager can select correct topology by default
					planet_surface_index,
					orbit_surface_index
				})
			-- Cache for both sides of this pair
			surface_topology_cache[planet_surface_index] = topo_id
			surface_topology_cache[orbit_surface_index] = topo_id
			return topo_id
		end
	end

	surface_topology_cache[surface_index] = false
	return nil
end

---Invalidate the topology cache (called on elevator rebuild).
function _G.invalidate_topology_cache() surface_topology_cache = {} end

remote.add_interface("cybersyn2-plugin-space-elevator", {
	["node_topology_callback"] =
		---@param node_id Id
		---@param train_stop LuaEntity?
		---@return Id? topology_id
		function(node_id, train_stop)
			if not train_stop or not train_stop.valid then return nil end
			return get_topology_for_surface(train_stop.surface_index)
		end,
	["vehicle_topology_callback"] =
		---@param vehicle_id Id
		---@param lua_train LuaTrain?
		---@return Id? topology_id
		function(vehicle_id, lua_train)
			if not lua_train or not lua_train.valid then return nil end
			local stock = lua_train.front_stock
			if not stock then return nil end
			return get_topology_for_surface(stock.surface_index)
		end,
	["reachable_callback"] =
		---@param from_stop LuaEntity
		function(
			train_id,
			from_id,
			to_id,
			train_stock,
			train_home_surface_index,
			from_stop,
			to_stop
		)
			-- Returns truthy to veto reachability.

			-- Train must be on its home surface, and the from_Stop must also
			-- be on that surface.
			if train_stock.surface_index ~= train_home_surface_index then
				return true
			end
			if train_home_surface_index ~= from_stop.surface_index then
				return true
			end
		end,
	["route_callback"] =
		---@param luatrain LuaTrain?
		---@param train_stock LuaEntity?
		---@param stop_entity LuaEntity?
		function(
			delivery_id,
			direction,
			topology_id,
			cstrain_id,
			luatrain,
			train_stock,
			train_home_surface_index,
			stop_id,
			stop_entity
		)
			-- Return truthy to set the train as belonging to this plugin, falsy to ignore.
			if (not luatrain) or not train_stock then return false end

			if direction == "pickup" then
				-- Pick up must be on train's home surface.
				-- Verify this for debugging.
				return false
			elseif direction == "dropoff" then
				if not stop_entity then return false end
				if train_stock.surface_index == stop_entity.surface_index then
					-- Same surface, no special routing.
					return false
				end
				-- Different surface, need to transit via elevator.
				local elevator = find_nearest_valid_elevator(
					topology_id,
					train_stock,
					train_stock.surface_index,
					stop_entity.surface_index
				)
				if not elevator then return false end
				transit_elevator(
					delivery_id,
					cstrain_id,
					luatrain,
					elevator,
					stop_entity.backer_name
				)
				return true
			elseif direction == "complete" then
				if train_stock.surface_index == train_home_surface_index then
					-- Train already at home, no routing needed.
					return false
				end
				-- Train not at home, transit elevator.
				local elevator = find_nearest_valid_elevator(
					topology_id,
					train_stock,
					train_stock.surface_index,
					train_home_surface_index
				)
				if not elevator then return false end
				transit_elevator(
					delivery_id,
					cstrain_id,
					luatrain,
					elevator,
					elevator.opposite_end.stop.backer_name
				)
				return true
			end
		end,
})

local function on_train_teleport_started(event)
	strace.debug("on_train_teleport_started", event)
end

local function on_train_teleport_finished(event)
	strace.debug("on_train_teleport_finished", event)

	---@type LuaTrain
	local lua_train = event.train
	local previous_luatrain_id = event.old_train_id_1
	transit_complete(previous_luatrain_id, lua_train)
end

local function bind_se_events()
	if not remote.interfaces["space-exploration"] then return end
	strace.info(
		"Space Exploration mod detected; initializing cybersyn2-plugin-space-elevator."
	)

	events.bind(
		defines.events.se_on_train_teleport_finished,
		on_train_teleport_finished
	)
	events.bind(
		defines.events.se_on_train_teleport_started,
		on_train_teleport_started
	)
end

events.bind("on_init", bind_se_events)
events.bind("on_load", bind_se_events)
