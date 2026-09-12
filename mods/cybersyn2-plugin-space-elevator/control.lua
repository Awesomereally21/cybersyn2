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

---@param schedule LuaSchedule
local function clear_temp_records(schedule)
	local count = schedule.get_record_count()
	if not count then return end
	for i = count, 1, -1 do
		local rec = schedule.get_record({ schedule_index = i })
		if rec and rec.temporary then
			schedule.remove_record({ schedule_index = i })
		end
	end
end

---@param schedule LuaSchedule
---@param station_name string
---@return uint32? index Index the record was added at
local function add_temp_station(schedule, station_name)
	local count = schedule.get_record_count() or 0
	local index = count > 0 and count or 1
	-- Mirror core `add_temp_record`: insert before the depot (which lives
	-- at the end) so order becomes [..., new_temp, depot]. Callers add
	-- elevator first, continuation second => [elevator, continuation, depot].
	return schedule.add_record({
		station = station_name,
		temporary = true,
		index = { schedule_index = index },
	})
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
		continuation_stop_name = continuation_stop_name,
		elevator_stop_name = elevator.stop.backer_name,
	}

	-- Never touch `lua_train.group` or the legacy `schedule=` setter: both
	-- drop the train from its Factorio group (and a later `schedule=`
	-- fallback would erase the group again). Temporary records are per-train
	-- and preserve the group/depot schedule, exactly like core
	-- `Train:schedule()` does.
	local ok, schedule = pcall(function() return lua_train.get_schedule() end)
	if not ok or not schedule then
		strace.warn("transit_elevator: no schedule for delivery", delivery_id)
		return
	end
	local ok2, err = pcall(function()
		local elevator_idx =
			add_temp_station(schedule, elevator.stop.backer_name)
		add_temp_station(schedule, continuation_stop_name)
		if elevator_idx then schedule.go_to_station(elevator_idx) end
	end)
	if not ok2 then
		strace.warn("transit_elevator: failed to add temp records", err)
	end
end

---@param previous_luatrain_id uint64
---@param new_luatrain LuaTrain
local function transit_complete(previous_luatrain_id, new_luatrain)
	local train_record = storage.trains[previous_luatrain_id]
	if not train_record then
		strace.warn(
			"transit_complete: no tracked train for previous id",
			previous_luatrain_id
		)
		return
	end
	-- Remove from tracking first so a second/duplicate event can't
	-- double-handoff the same delivery.
	storage.trains[previous_luatrain_id] = nil

	if not new_luatrain or not new_luatrain.valid then
		strace.warn(
			"transit_complete: new train invalid for delivery",
			train_record.delivery_id
		)
		-- Hand back without a train so CS2 can fail/recover the
		-- delivery instead of leaving it volatile forever.
		remote.call(
			"cybersyn2",
			"route_plugin_handoff",
			train_record.delivery_id,
			nil
		)
		return
	end

	-- The elevator leg was added as temporary records (group-preserving),
	-- so just strip temps and leave the depot (group) schedule behind. That
	-- leaves exactly the `only_depot` state core `Train:schedule()` expects
	-- for the async `goto_to`/`goto_from`. Never assign `schedule=` or
	-- `group=` here: both drop/replace the group and are the reason trains
	-- came back groupless/empty.
	pcall(function()
		local schedule = new_luatrain.get_schedule()
		if schedule then clear_temp_records(schedule) end
	end)

	-- Backward compat: trains dispatched by the old implementation used the
	-- legacy `group=nil + schedule=[elevator, continuation]` (non-temp)
	-- rewrite, so stripping temps alone leaves those stale non-temp records
	-- behind (and the train groupless). Remove them by name, then rejoin the
	-- saved group once to restore the depot. New-method trains never hit
	-- this branch (their elevator leg was temp-only and the group is intact).
	pcall(function()
		local schedule = new_luatrain.get_schedule()
		if not schedule then return end
		local elevator_name = train_record.elevator_stop_name
		local continuation_name = train_record.continuation_stop_name
		local count = schedule.get_record_count() or 0
		for i = count, 1, -1 do
			local rec = schedule.get_record({ schedule_index = i })
			if rec and not rec.temporary and rec.station then
				if rec.station == elevator_name or rec.station == continuation_name then
					schedule.remove_record({ schedule_index = i })
				end
			end
		end
		local group_now = nil
		pcall(function() group_now = new_luatrain.group end)
		if (not group_now) and train_record.previous_group then
			new_luatrain.group = train_record.previous_group
		end
	end)

	-- Never leave the train schedule-less. Normally stripping temps leaves
	-- the depot record. If the group itself has no depot (0 records), add
	-- the continuation as a *temporary* record so the group is preserved
	-- and the train still has orders while we wait for the async CS2
	-- re-schedule.
	local record_count = 0
	local ok, schedule = pcall(function() return new_luatrain.get_schedule() end)
	if ok and schedule then
		local ok2, count =
			pcall(function() return schedule.get_record_count() end)
		if ok2 and type(count) == "number" then record_count = count end
	end
	if record_count == 0 then
		local fallback = train_record.continuation_stop_name
		strace.warn(
			"transit_complete: empty schedule after stripping temps, falling back to",
			fallback,
			"for delivery",
			train_record.delivery_id
		)
		if fallback then
			pcall(function()
				local sched = new_luatrain.get_schedule()
				if sched then add_temp_station(sched, fallback) end
			end)
		end
	end

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

	-- SE provides the old train id as a number and the new train as a
	-- LuaTrain object, but field names have varied across SE versions and
	-- differ from vanilla `on_train_created` (`old_train_id_1`). Accept all
	-- known variants so we never silently drop the handoff (which would
	-- leave the delivery volatile and the train unmanaged).
	---@type LuaTrain?
	local lua_train = event.train or event.new_train or event.created_train
	local previous_luatrain_id = event.old_train_id_1
		or event.old_train_id
		or event.old_id
		or event.train_id
	if not previous_luatrain_id or not lua_train then
		strace.warn("on_train_teleport_finished: unrecognized event shape", event)
		return
	end
	transit_complete(previous_luatrain_id, lua_train)
end

local function get_se_event_id(name)
	-- Standard SE API, e.g. `remote.call("space-exploration",
	-- "get_on_train_teleport_finished_event", {})`. Arg shape varies by SE
	-- version, so try both.
	local ok, id = pcall(remote.call, "space-exploration", name, {})
	if ok and type(id) == "number" then return id end
	ok, id = pcall(remote.call, "space-exploration", name)
	if ok and type(id) == "number" then return id end
	return nil
end

local function bind_se_events()
	if not remote.interfaces["space-exploration"] then return end
	strace.info(
		"Space Exploration mod detected; initializing cybersyn2-plugin-space-elevator."
	)

	-- NOTE: `defines.events.se_on_train_teleport_*` never exists. SE exposes
	-- custom event IDs via its remote interface; those IDs must be fetched
	-- at runtime and bound with `script.on_event` (see e.g.
	-- Train-Control-Signals, train-limit-linter). Binding to a nil
	-- `defines.events` entry silently never fires, which strands deliveries
	-- in `plugin_handoff` and leaves trains unmanaged.
	local started_id = get_se_event_id("get_on_train_teleport_started_event")
	local finished_id = get_se_event_id("get_on_train_teleport_finished_event")
	-- Legacy fallback for very old SE, if it ever set defines entries.
	if not started_id
		and defines.events
		and defines.events.se_on_train_teleport_started
	then
		started_id = defines.events.se_on_train_teleport_started
	end
	if not finished_id
		and defines.events
		and defines.events.se_on_train_teleport_finished
	then
		finished_id = defines.events.se_on_train_teleport_finished
	end

	if finished_id then
		-- `events.bind` must be called unconditionally at load time, but
		-- these IDs are only known conditionally at runtime, so bind with
		-- the raw API like other SE integrations do.
		script.on_event(finished_id, on_train_teleport_finished)
	else
		strace.warn("SE teleport finished event ID not found; elevator handoff disabled")
	end
	if started_id then
		script.on_event(started_id, on_train_teleport_started)
	else
		strace.warn("SE teleport started event ID not found")
	end
end

events.bind("on_init", bind_se_events)
events.bind("on_load", bind_se_events)
events.bind("on_configuration_changed", bind_se_events)
