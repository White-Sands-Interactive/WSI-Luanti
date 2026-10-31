local GOAL = "You are a Mineclonia villager. Greet nearby players, stay near them, and take short walks. When messages lists something a player said, answer that player with say. terrain is the 32 by 32 map, 16 blocks in each direction. A cell with dy can be reached. A cell with player names who is standing there. Choose one of those cells as a goal and call path(dx, dz). That finds the route and walks it. Do not dig or place nodes."
local MOVE_LIMIT = 16
local HEAR_LIMIT = 8
local CLIMB = 8
local PATH_LIMIT = 128
local WALK_SPEED = 2.4
local ARRIVE_DISTANCE = 0.3
local STEP_TIMEOUT_US = 2000000

local function now_us()
	return core.get_us_time()
end

local function flat_distance(pos, target)
	local dx = pos.x - target.x
	local dz = pos.z - target.z
	return math.sqrt(dx * dx + dz * dz)
end

local function solid_at(pos)
	local node = core.get_node(pos)
	if node.name == "ignore" then
		return nil
	end
	local def = core.registered_nodes[node.name]
	if not def then
		return true
	end
	return def.walkable == true
end

local function stand_node(pos)
	local node = {
		x = math.floor(pos.x + 0.5),
		y = math.floor(pos.y + 0.01),
		z = math.floor(pos.z + 0.5),
	}
	-- The collision box rests slightly inside the ground node. That node is
	-- the floor, and the body occupies the air just above it.
	if solid_at(node) then
		node.y = node.y + 1
	end
	return node
end

local NEIGHBORS = {
	{1, 0}, {-1, 0}, {0, 1}, {0, -1},
	{1, 1}, {1, -1}, {-1, 1}, {-1, -1},
}

local function node_name(pos)
	return core.get_node(pos).name
end

local function cell_key(dx, dz)
	return dx + MOVE_LIMIT + (dz + MOVE_LIMIT) * (MOVE_LIMIT * 2 + 1)
end

local function passage_at(x, y, z)
	local feet = solid_at({x = x, y = y, z = z})
	local head = solid_at({x = x, y = y + 1, z = z})
	local ground = solid_at({x = x, y = y - 1, z = z})
	if feet == nil or head == nil or ground == nil then
		return false
	end
	return not feet and not head and ground
end

local function surface_y(x, z, hint)
	local best = nil
	local best_dist = nil
	for offset = -CLIMB, CLIMB do
		local y = hint + offset
		if passage_at(x, y, z) then
			local dist = math.abs(offset)
			if not best_dist or dist < best_dist then
				best = y
				best_dist = dist
			end
		end
	end
	return best
end

local function body_clear(x, y, z)
	local feet = solid_at({x = x, y = y, z = z})
	local head = solid_at({x = x, y = y + 1, z = z})
	if feet == nil or head == nil then
		return false
	end
	return not feet and not head
end

local function step_destination(x, z, y, dx, dz)
	local ny = surface_y(x + dx, z + dz, y)
	if not ny or math.abs(ny - y) > 1 then
		return nil
	end
	if dx ~= 0 and dz ~= 0 then
		local cross = math.max(y, ny)
		if not body_clear(x + dx, cross, z) or not body_clear(x, cross, z + dz) then
			return nil
		end
	end
	return ny
end

-- Breadth-first search over one-block steps. goal_dx nil explores the whole map.
local function search(stand, goal_dx, goal_dz)
	local parent = {}
	parent[cell_key(0, 0)] = {y = stand.y}
	local queue = {{dx = 0, dz = 0, y = stand.y}}
	local head = 1
	local found = goal_dx == nil
	while head <= #queue do
		local node = queue[head]
		head = head + 1
		if goal_dx and node.dx == goal_dx and node.dz == goal_dz then
			found = true
			break
		end
		for _, dir in ipairs(NEIGHBORS) do
			local ndx = node.dx + dir[1]
			local ndz = node.dz + dir[2]
			if math.abs(ndx) <= MOVE_LIMIT and math.abs(ndz) <= MOVE_LIMIT then
				local key = cell_key(ndx, ndz)
				if not parent[key] then
					local ny = step_destination(stand.x + node.dx, stand.z + node.dz, node.y, dir[1], dir[2])
					if ny then
						parent[key] = {
							sdx = dir[1],
							sdz = dir[2],
							prev = cell_key(node.dx, node.dz),
							y = ny,
						}
						queue[#queue + 1] = {dx = ndx, dz = ndz, y = ny}
					end
				end
			end
		end
	end
	return parent, found
end

local function terrain_around(stand, people)
	local parent = search(stand)
	local cells = {}
	for dz = -MOVE_LIMIT, MOVE_LIMIT do
		for dx = -MOVE_LIMIT, MOVE_LIMIT do
			local key = cell_key(dx, dz)
			local who = people[key]
			if dx ~= 0 or dz ~= 0 or who then
				local info = parent[key]
				local cell
				if info then
					cell = {dx = dx, dz = dz, dy = info.y - stand.y}
				elseif dx ~= 0 or dz ~= 0 then
					local blocked = node_name({x = stand.x + dx, y = stand.y, z = stand.z + dz})
					cell = {dx = dx, dz = dz, blocked = blocked}
				end
				if cell and who then
					cell.player = who
				end
				if cell then
					cells[#cells + 1] = cell
				end
			end
		end
	end
	return cells
end

local function find_path(stand, dx, dz)
	if type(dx) ~= "number" or type(dz) ~= "number" then
		error("dx and dz are required")
	end
	dx = math.floor(dx)
	dz = math.floor(dz)
	if dx == 0 and dz == 0 then
		error("pick a cell other than where you stand")
	end
	if math.abs(dx) > MOVE_LIMIT or math.abs(dz) > MOVE_LIMIT then
		error("goal is outside the map")
	end
	local parent, found = search(stand, dx, dz)
	if not found then
		error("no path there")
	end
	local steps = {}
	local key = cell_key(dx, dz)
	while parent[key] and parent[key].sdx do
		table.insert(steps, 1, {dx = parent[key].sdx, dz = parent[key].sdz})
		key = parent[key].prev
	end
	if #steps == 0 or #steps > PATH_LIMIT then
		error("no path there")
	end
	return steps
end

local function set_moving(self, moving)
	if self._moving == moving then
		return
	end
	self._moving = moving
	if moving then
		self.object:set_animation({x = 0, y = 40}, 35, 0, true)
	else
		self.object:set_animation({x = 0, y = 0}, 0, 0, false)
	end
end

local function see(self)
	local pos = self.object:get_pos()
	if not pos then
		error("villager is gone")
	end
	local stand = stand_node(pos)
	local ground_pos = {x = stand.x, y = stand.y - 1, z = stand.z}
	local players = {}
	local people = {}
	for _, player in ipairs(core.get_connected_players()) do
		local player_pos = player:get_pos()
		if player_pos then
			local feet = stand_node(player_pos)
			local dx = feet.x - stand.x
			local dz = feet.z - stand.z
			if math.abs(dx) <= MOVE_LIMIT and math.abs(dz) <= MOVE_LIMIT then
				local name = player:get_player_name()
				players[#players + 1] = {
					name = name,
					x = player_pos.x,
					y = player_pos.y,
					z = player_pos.z,
				}
				local key = cell_key(dx, dz)
				if people[key] then
					people[key] = people[key] .. ", " .. name
				else
					people[key] = name
				end
			end
		end
	end
	local messages = self._heard or {}
	self._heard = {}
	return {
		x = pos.x,
		y = pos.y,
		z = pos.z,
		yaw = math.deg(self.object:get_yaw() or 0),
		ground = core.get_node(ground_pos).name,
		players = players,
		messages = messages,
		terrain = terrain_around(stand, people),
	}
end

local function say(self, text)
	if type(text) ~= "string" or text == "" then
		error("text is required")
	end
	if #text > 160 then
		error("message is too long")
	end
	core.chat_send_all("<Villager> " .. text)
	return {ok = true}
end

local function turn_yaw(self, degrees)
	if type(degrees) ~= "number" then
		error("degrees is required")
	end
	self.object:set_yaw(math.rad(degrees))
	return {yaw = degrees}
end

local move

local function path_to(self, dx, dz)
	if self._move then
		return move(self)
	end
	local pos = self.object:get_pos()
	if not pos then
		error("villager is gone")
	end
	return move(self, find_path(stand_node(pos), dx, dz))
end

local function check_steps(steps)
	if type(steps) ~= "table" or #steps == 0 then
		error("steps are required")
	end
	if #steps > PATH_LIMIT then
		error("path is too long")
	end
	local clean = {}
	for i = 1, #steps do
		local step = steps[i]
		if type(step) ~= "table" or type(step.dx) ~= "number" or type(step.dz) ~= "number" then
			error("each step needs dx and dz")
		end
		local dx = math.floor(step.dx)
		local dz = math.floor(step.dz)
		if math.abs(dx) > 1 or math.abs(dz) > 1 or (dx == 0 and dz == 0) then
			error("each step must be one block")
		end
		clean[i] = {dx = dx, dz = dz}
	end
	return clean
end

local function aim_step(self, plan, dx, dz)
	local pos = self.object:get_pos()
	if not pos then
		return false
	end
	local stand = stand_node(pos)
	if not step_destination(stand.x, stand.z, stand.y, dx, dz) then
		return false
	end
	plan.target = {x = stand.x + dx + 0.5, z = stand.z + dz + 0.5}
	plan.deadline = now_us() + STEP_TIMEOUT_US
	plan.done = false
	self.object:set_yaw(core.dir_to_yaw(vector.new(dx, 0, dz)))
	set_moving(self, true)
	return true
end

function move(self, steps)
	local pos = self.object:get_pos()
	if not pos then
		error("villager is gone")
	end
	local walking = self._move
	if walking then
		local arrived = flat_distance(pos, walking.target) < ARRIVE_DISTANCE
		if not arrived and now_us() <= walking.deadline then
			return {_pending = true}
		end
		if not arrived then
			self._move = nil
			set_moving(self, false)
			self.object:set_velocity(vector.new(0, 0, 0))
			error("could not reach that spot")
		end
		if walking.next > #walking.steps then
			self._move = nil
			set_moving(self, false)
			self.object:set_velocity(vector.new(0, 0, 0))
			local landed = self.object:get_pos() or pos
			return {x = landed.x, z = landed.z}
		end
		local step = walking.steps[walking.next]
		walking.next = walking.next + 1
		if not aim_step(self, walking, step.dx, step.dz) then
			self._move = nil
			set_moving(self, false)
			error("cannot walk there")
		end
		return {_pending = true}
	end
	local clean = check_steps(steps)
	local plan = {steps = clean, next = 2, done = false}
	self._move = plan
	if not aim_step(self, plan, clean[1].dx, clean[1].dz) then
		self._move = nil
		set_moving(self, false)
		error("cannot walk there")
	end
	return {_pending = true}
end

local function start_agent(self)
	local ok, id = pcall(core.wsi_start, {
		name = "Villager",
		goal = GOAL,
		see = function()
			return see(self)
		end,
		actions = {
			{
				name = "path",
				description = "Walk to a goal on the terrain map. dx and dz are the goal offset, at most 16. Positive dx is east and positive dz is north.",
				params = {
					{name = "dx", type = "integer"},
					{name = "dz", type = "integer"},
				},
				run = function(dx, dz)
					return path_to(self, dx, dz)
				end,
			},
			{
				name = "move",
				description = "Walk a path of one-block steps returned by path. steps is that list.",
				params = {
					{name = "steps", type = "array"},
				},
				run = function(steps)
					return move(self, steps)
				end,
			},
			{
				name = "say",
				description = "Speak one short line in chat. Use this to answer a player.",
				params = {
					{name = "text", type = "string"},
				},
				run = function(text)
					return say(self, text)
				end,
			},
			{
				name = "turn_yaw",
				description = "Face a direction in degrees. 0 faces north and 90 faces west.",
				params = {
					{name = "degrees", type = "integer"},
				},
				run = function(degrees)
					return turn_yaw(self, degrees)
				end,
			},
		},
	})
	if not ok then
		self._start_error = tostring(id)
		core.log("error", "wsi_npc: " .. self._start_error)
		return
	end
	self._agent = id
end

core.register_entity("wsi_npc:villager", {
	initial_properties = {
		visual = "mesh",
		mesh = "mobs_mc_villager.b3d",
		textures = {"mobs_mc_villager.png"},
		visual_size = {x = 1, y = 1},
		collisionbox = {-0.25, 0.05, -0.25, 0.25, 1.90, 0.25},
		selectionbox = {-0.25, 0.0, -0.25, 0.25, 1.90, 0.25},
		physical = true,
		collide_with_objects = true,
		stepheight = 1.1,
		nametag = "Villager",
		nametag_color = "#FFFFFF",
	},
	_hp = 20,
	_agent = nil,
	_move = nil,
	_moving = false,

	on_activate = function(self, staticdata)
		self._heard = {}
		self.object:set_acceleration(vector.new(0, -9.81, 0))
		start_agent(self)
		if self._start_error and staticdata ~= "" then
			core.after(0, function()
				if self.object then
					self.object:remove()
				end
			end)
		end
	end,

	on_deactivate = function(self)
		local id = self._agent
		self._agent = nil
		if id then
			core.wsi_stop(id)
		end
	end,

	on_step = function(self)
		local walking = self._move
		if not walking then
			set_moving(self, false)
			return
		end
		local pos = self.object:get_pos()
		if not pos then
			return
		end
		local dx = walking.target.x - pos.x
		local dz = walking.target.z - pos.z
		local dist = math.sqrt(dx * dx + dz * dz)
		if dist < ARRIVE_DISTANCE or now_us() > walking.deadline then
			walking.done = true
			return
		end
		self.object:set_velocity(vector.new(dx / dist * WALK_SPEED, 0, dz / dist * WALK_SPEED))
		self.object:set_yaw(core.dir_to_yaw(vector.new(dx, 0, dz)))
		set_moving(self, true)
	end,

	on_punch = function(self, _puncher, time_from_last_punch)
		if time_from_last_punch < 0.45 then
			return
		end
		self._hp = self._hp - 4
		if self._hp <= 0 then
			self.object:remove()
		end
	end,

	get_staticdata = function(self)
		if self._start_error then
			return ""
		end
		return "1"
	end,
})

core.register_chatcommand("wsi", {
	description = "Spawn a WSI villager next to you",
	privs = {server = true},
	func = function(name)
		local player = core.get_player_by_name(name)
		if not player then
			return false, "No such player"
		end
		local pos = player:get_pos()
		local dir = player:get_look_dir()
		pos.x = pos.x + dir.x * 2
		pos.z = pos.z + dir.z * 2
		local obj = core.add_entity(pos, "wsi_npc:villager")
		if not obj then
			return false, "Could not spawn the villager"
		end
		local ent = obj:get_luaentity()
		if ent and ent._start_error then
			local err = ent._start_error
			obj:remove()
			return false, err
		end
		if obj then
			local player_pos = player:get_pos()
			obj:set_yaw(core.dir_to_yaw(vector.subtract(player_pos, pos)))
		end
		return true, "Villager spawned"
	end,
})

core.register_on_chat_message(function(name, message)
	if message == "" or message:sub(1, 1) == "/" then
		return
	end
	if #message > 160 then
		message = message:sub(1, 160)
	end
	local player = core.get_player_by_name(name)
	local player_pos = player and player:get_pos()
	if not player_pos then
		return
	end
	for _, ent in pairs(core.luaentities) do
		if ent.name == "wsi_npc:villager" and ent.object then
			local pos = ent.object:get_pos()
			if pos and math.abs(pos.x - player_pos.x) <= MOVE_LIMIT and math.abs(pos.z - player_pos.z) <= MOVE_LIMIT then
				local heard = ent._heard
				if not heard then
					heard = {}
					ent._heard = heard
				end
				heard[#heard + 1] = {name = name, text = message}
				while #heard > HEAR_LIMIT do
					table.remove(heard, 1)
				end
			end
		end
	end
end)
