local GOAL = "You act only when a player speaks to you. messages lists what they said. subgoals lists the jobs you added for this session. When they ask for a job that lasts beyond this reply, such as gathering wood or building a house, add a subgoal that states the job in one sentence, then call one game action. For wood, call gather. The objective must say the total number of logs wood_have should reach. Keep that subgoal until wood_have reaches it, or they tell you to stop. A nearby player does not cancel it. When the wood is done or they tell you to stop, complete that subgoal, then call follow, stay, or say. For a house or any other lasting job, call say after adding the subgoal, and do not complete it until the job is done or they tell you to stop. If they asked you to follow and no wood subgoal is active, call follow. If they asked you to explore or wander, call explore. If they asked you to stay or wait, call stay. If they asked you to break some other block, call dig. If they asked you to place a block, call place. Otherwise call say and answer them. You already walk, hop over blocks, and chop trees while a wood subgoal is active. While a house subgoal is active, you place the house yourself from planks in inventory."
local HEAR_LIMIT = 8
local MAP = 16
local REACH = MAP
local INV_SLOTS = 27
local inventory_view
local drive
local nearest_log
local wood_count
local close_enough
local break_at
local apply_subgoals
local pursue_house
local HEAR_RANGE = 16
local FOLLOW_RANGE = 16
local FOLLOW_STOP = 2.5
local WALK_SPEED = 2.4
local JUMP_SPEED = 5.2
local CLIMB = 8

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

local function body_clear(x, y, z)
	local feet = solid_at({x = x, y = y, z = z})
	local head = solid_at({x = x, y = y + 1, z = z})
	if feet == nil or head == nil then
		return false
	end
	return not feet and not head
end

local function passage_at(x, y, z)
	local ground = solid_at({x = x, y = y - 1, z = z})
	if ground == nil then
		return false
	end
	return body_clear(x, y, z) and ground
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

local function cardinal(dx, dz)
	if math.abs(dx) < 0.2 and math.abs(dz) < 0.2 then
		return 0, 0
	end
	if math.abs(dx) >= math.abs(dz) then
		return dx > 0 and 1 or -1, 0
	end
	return 0, dz > 0 and 1 or -1
end

local function step_open(stand, dx, dz)
	local dirx, dirz = cardinal(dx, dz)
	if dirx == 0 and dirz == 0 then
		return true
	end
	local ny = surface_y(stand.x + dirx, stand.z + dirz, stand.y)
	return ny ~= nil and math.abs(ny - stand.y) <= 1
end

local function can_jump(stand, dx, dz)
	local dirx, dirz = cardinal(dx, dz)
	if dirx == 0 and dirz == 0 then
		return false
	end
	if solid_at({x = stand.x + dirx, y = stand.y, z = stand.z + dirz}) ~= true then
		return false
	end
	return body_clear(stand.x, stand.y + 1, stand.z)
		and body_clear(stand.x + dirx, stand.y + 1, stand.z + dirz)
end

local MOVE_DIRS = {
	{1, 0}, {-1, 0}, {0, 1}, {0, -1},
	{1, 1}, {1, -1}, {-1, 1}, {-1, -1},
}

local function step_ok(stand, dx, dz, blocked)
	if dx == 0 and dz == 0 then
		return false
	end
	local nx = stand.x + dx
	local nz = stand.z + dz
	if blocked and blocked(nx, nz) then
		return false
	end
	local ny = surface_y(nx, nz, stand.y)
	if ny and math.abs(ny - stand.y) <= 1 then
		if dx ~= 0 and dz ~= 0 then
			local cross = math.max(stand.y, ny)
			if not body_clear(stand.x + dx, cross, stand.z) or not body_clear(stand.x, cross, stand.z + dz) then
				return false
			end
		end
		return true
	end
	return can_jump(stand, dx, dz)
end

local function steer(self, stand, tx, tz, blocked)
	local best_x, best_z, best_score
	for _, dir in ipairs(MOVE_DIRS) do
		if step_ok(stand, dir[1], dir[2], blocked) then
			local nx = stand.x + dir[1] + 0.5
			local nz = stand.z + dir[2] + 0.5
			local score = (nx - tx) * (nx - tx) + (nz - tz) * (nz - tz)
			if self._stuck then
				local vx = tx - (stand.x + 0.5)
				local vz = tz - (stand.z + 0.5)
				if dir[1] * vx + dir[2] * vz < 0 then
					score = score - 6
				end
			end
			if not best_score or score < best_score then
				best_score = score
				best_x, best_z = dir[1], dir[2]
			end
		end
	end
	if not best_x then
		return 0, 0
	end
	local length = math.sqrt(best_x * best_x + best_z * best_z)
	return best_x / length, best_z / length
end

local function grounded(pos, stand)
	if math.abs(pos.y - stand.y) > 0.25 then
		return false
	end
	return solid_at({x = stand.x, y = stand.y - 1, z = stand.z}) == true
end

local function nearest_player(pos)
	local best = nil
	local best_dist = nil
	for _, player in ipairs(core.get_connected_players()) do
		local player_pos = player:get_pos()
		if player_pos then
			local dist = flat_distance(pos, player_pos)
			if dist <= FOLLOW_RANGE and (not best_dist or dist < best_dist) then
				best = player_pos
				best_dist = dist
			end
		end
	end
	return best, best_dist
end

local function new_wander(self)
	local angle = math.random() * math.pi * 2
	self._wander = {x = -math.sin(angle), z = math.cos(angle)}
	self._wander_left = 3 + math.random() * 4
end

local function wander_heading(self, dtime, stand)
	if not self._wander then
		new_wander(self)
	end
	self._wander_left = self._wander_left - dtime
	local heading = self._wander
	local dirx, dirz = cardinal(heading.x, heading.z)
	if dirx == 0 and dirz == 0 then
		dirx, dirz = 0, 1
	end
	if self._wander_left > 0 and step_ok(stand, dirx, dirz) then
		return dirx, dirz
	end
	for _, dir in ipairs(MOVE_DIRS) do
		if step_ok(stand, dir[1], dir[2]) then
			self._wander = {x = dir[1], z = dir[2]}
			self._wander_left = 2 + math.random() * 2
			return dir[1], dir[2]
		end
	end
	return 0, 0
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

local function behave(self, dtime)
	local pos = self.object:get_pos()
	if not pos then
		return
	end
	local stand = stand_node(pos)
	local mode = self._mode or "follow"
	local hx, hz = 0, 0
	local face = nil
	if mode == "stay" then
		face = nil
	elseif mode == "gather" then
		local need = self._wood_need
		if need and wood_count(self) >= need then
			local have = wood_count(self)
			local subgoal = self._wood_subgoal
			self._mode = "stay"
			self._wood_done = tostring(subgoal or "") .. "\0" .. (self._wood_objective or "")
			self._wood_at = nil
			drive(self, pos, stand, 0, 0)
			if self._agent and not self._turn_pending then
				core.log("action", "WSI Villager wood goal complete: " .. have .. " logs, subgoal " .. tostring(subgoal or ""))
				self._turn_pending = true
				core.wsi_turn(self._agent)
			end
			return
		end
		local now = core.get_us_time()
		if self._wood_skip and now >= (self._wood_skip_until or 0) then
			self._wood_skip = nil
		end
		local block = nearest_log(stand, self._wood_skip)
		if block and close_enough(stand, block) then
			if now >= (self._chop_after or 0) then
				self._chop_after = now + 450000
				local ok = pcall(break_at, self, block)
				self._wood_at = nil
				if not ok then
					self._wood_skip = block
					self._wood_skip_until = now + 3000000
				else
					self._wood_skip = nil
				end
			end
			local fx = (block.x + 0.5) - pos.x
			local fz = (block.z + 0.5) - pos.z
			drive(self, pos, stand, 0, 0)
			if fx ~= 0 or fz ~= 0 then
				self.object:set_yaw(core.dir_to_yaw(vector.new(fx, 0, fz)))
			end
			return
		end
		if block then
			hx, hz = steer(self, stand, block.x + 0.5, block.z + 0.5)
			face = vector.new((block.x + 0.5) - pos.x, 0, (block.z + 0.5) - pos.z)
		else
			hx, hz = wander_heading(self, dtime, stand)
			face = vector.new(hx, 0, hz)
		end
	elseif mode == "build" then
		pursue_house(self, dtime, pos, stand)
		return
	elseif mode == "explore" then
		hx, hz = wander_heading(self, dtime, stand)
		face = vector.new(hx, 0, hz)
	else
		local target, dist = nearest_player(pos)
		if target and dist > FOLLOW_STOP then
			hx, hz = steer(self, stand, target.x, target.z)
			face = vector.new(target.x - pos.x, 0, target.z - pos.z)
		elseif target then
			face = vector.new(target.x - pos.x, 0, target.z - pos.z)
		else
			hx, hz = wander_heading(self, dtime, stand)
			face = vector.new(hx, 0, hz)
		end
	end

	drive(self, pos, stand, hx, hz)
	if hx == 0 and hz == 0 and face and (face.x ~= 0 or face.z ~= 0) then
		self.object:set_yaw(core.dir_to_yaw(face))
	end
end

function drive(self, pos, stand, hx, hz)
	local vel = self.object:get_velocity() or vector.zero()
	local vy = vel.y
	local now = core.get_us_time()
	if grounded(pos, stand) then
		if (hx ~= 0 or hz ~= 0) and can_jump(stand, hx, hz) and now >= (self._jump_after or 0) then
			vy = JUMP_SPEED
			self._jump_after = now + 700000
		else
			vy = 0
		end
	end
	if hx ~= 0 or hz ~= 0 then
		if not self._mark_at or now - self._mark_at > 600000 then
			local moved = math.abs(pos.x - (self._mark_x or pos.x)) + math.abs(pos.z - (self._mark_z or pos.z))
			self._stuck = self._mark_at and moved < 0.25
			self._mark_at = now
			self._mark_x = pos.x
			self._mark_z = pos.z
		end
	else
		self._stuck = false
	end
	self.object:set_velocity(vector.new(hx * WALK_SPEED, vy, hz * WALK_SPEED))
	set_moving(self, hx ~= 0 or hz ~= 0)
	if hx ~= 0 or hz ~= 0 then
		self.object:set_yaw(core.dir_to_yaw(vector.new(hx, 0, hz)))
	end
end

local STEP_DIRS = {
	{1, 0}, {-1, 0}, {0, 1}, {0, -1},
	{1, 1}, {1, -1}, {-1, 1}, {-1, -1},
}

local function map_key(dx, dz)
	return dx + MAP + (dz + MAP) * (MAP * 2 + 1)
end

function close_enough(stand, block)
	if stand.x == block.x and stand.z == block.z and (block.y == stand.y or block.y == stand.y + 1) then
		return false
	end
	return math.abs(stand.x - block.x) <= 1
		and math.abs(stand.z - block.z) <= 1
		and math.abs(stand.y - block.y) <= 8
end

local function step_dest(x, z, y, dx, dz)
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

local function path_to_block(stand, block)
	if close_enough(stand, block) then
		return {}
	end
	local parent = {}
	local start_key = map_key(0, 0)
	parent[start_key] = {y = stand.y}
	local queue = {{dx = 0, dz = 0, y = stand.y}}
	local head = 1
	local found = nil
	while head <= #queue do
		local node = queue[head]
		head = head + 1
		local here = {x = stand.x + node.dx, y = node.y, z = stand.z + node.dz}
		if close_enough(here, block) then
			found = node
			break
		end
		for _, dir in ipairs(STEP_DIRS) do
			local ndx = node.dx + dir[1]
			local ndz = node.dz + dir[2]
			if math.abs(ndx) <= MAP and math.abs(ndz) <= MAP then
				local key = map_key(ndx, ndz)
				if not parent[key] then
					local ny = step_dest(here.x, here.z, node.y, dir[1], dir[2])
					if ny then
						parent[key] = {
							prev = map_key(node.dx, node.dz),
							y = ny,
							dx = ndx,
							dz = ndz,
						}
						queue[#queue + 1] = {dx = ndx, dz = ndz, y = ny}
					end
				end
			end
		end
	end
	if not found then
		return nil
	end
	local steps = {}
	local key = map_key(found.dx, found.dz)
	while key ~= start_key do
		local info = parent[key]
		steps[#steps + 1] = {x = stand.x + info.dx, y = info.y, z = stand.z + info.dz}
		key = info.prev
	end
	local ordered = {}
	for i = #steps, 1, -1 do
		ordered[#ordered + 1] = steps[i]
	end
	return ordered
end

local function is_log(name, def)
	local groups = def.groups or {}
	if (groups.tree or 0) > 0 or (groups.bamboo_tree or 0) > 0 then
		return true
	end
	return name:find("log", 1, true) ~= nil or name:find("hyphae", 1, true) ~= nil
end

local function visible_wood(stand)
	local found = {}
	for dz = -MAP, MAP do
		for dx = -MAP, MAP do
			local x = stand.x + dx
			local z = stand.z + dz
			for dy = -2, 12 do
				local pos = {x = x, y = stand.y + dy, z = z}
				local name = core.get_node(pos).name
				if name ~= "air" and name ~= "ignore" then
					local def = core.registered_nodes[name]
					if def and is_log(name, def) then
						found[#found + 1] = {
							dx = dx,
							dy = dy,
							dz = dz,
							node = name,
							dist = math.abs(dx) + math.abs(dy) + math.abs(dz),
						}
					end
				end
			end
		end
	end
	table.sort(found, function(a, b)
		return a.dist < b.dist
	end)
	local listed = {}
	local limit = math.min(48, #found)
	for i = 1, limit do
		local entry = found[i]
		listed[i] = {dx = entry.dx, dy = entry.dy, dz = entry.dz, node = entry.node}
	end
	return listed
end

function nearest_log(stand, skip)
	local best = nil
	local best_dist = nil
	for dz = -MAP, MAP do
		for dx = -MAP, MAP do
			local x = stand.x + dx
			local z = stand.z + dz
			for dy = -2, 12 do
				local pos = {x = x, y = stand.y + dy, z = z}
				local name = core.get_node(pos).name
				if name ~= "air" and name ~= "ignore" then
					local def = core.registered_nodes[name]
					if def and is_log(name, def)
						and not (skip and skip.x == pos.x and skip.y == pos.y and skip.z == pos.z) then
						local dist = (dx * dx + dz * dz) * 1000 + (dy + 2)
						if not best_dist or dist < best_dist then
							best = pos
							best_dist = dist
						end
					end
				end
			end
		end
	end
	return best
end

local function advance_task(self)
	local task = self._task
	local pos = self.object:get_pos()
	if not pos then
		return
	end
	local stand = stand_node(pos)
	if close_enough(stand, task.block) then
		task.arrived = true
		drive(self, pos, stand, 0, 0)
		return
	end
	local step = task.steps[task.next]
	if not step then
		task.failed = "no path there"
		drive(self, pos, stand, 0, 0)
		return
	end
	local dx = (step.x + 0.5) - pos.x
	local dz = (step.z + 0.5) - pos.z
	local dist = math.sqrt(dx * dx + dz * dz)
	if dist < 0.5 and math.abs(stand.y - step.y) <= 1 then
		task.next = task.next + 1
		return advance_task(self)
	end
	if dist < 0.001 then
		drive(self, pos, stand, 0, 0)
		return
	end
	drive(self, pos, stand, dx / dist, dz / dist)
end

local function see(self)
	local pos = self.object:get_pos()
	if not pos then
		error("villager is gone")
	end
	local players = {}
	for _, player in ipairs(core.get_connected_players()) do
		local player_pos = player:get_pos()
		if player_pos and flat_distance(pos, player_pos) <= HEAR_RANGE then
			players[#players + 1] = {
				name = player:get_player_name(),
				x = player_pos.x,
				y = player_pos.y,
				z = player_pos.z,
			}
		end
	end
	self._turn_pending = false
	local messages = self._heard or {}
	self._heard = {}
	return {
		x = pos.x,
		y = pos.y,
		z = pos.z,
		yaw = math.deg(self.object:get_yaw() or 0),
		mode = self._mode or "follow",
		players = players,
		messages = messages,
		inventory = inventory_view(self),
		wood = visible_wood(stand_node(pos)),
		wood_have = wood_count(self),
		wood_need = self._wood_need,
		subgoals = self._agent and core.wsi_subgoals(self._agent) or {},
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

local function set_mode(self, mode, wood_need)
	self._mode = mode
	self._wander = nil
	self._task = nil
	self._wood_at = nil
	if mode == "gather" then
		if wood_need then
			self._wood_need = wood_need
		end
	else
		self._wood_need = nil
	end
	return {mode = mode, wood_have = wood_count(self), wood_need = self._wood_need}
end

local next_inv_id = 0

local function inventory_name(self)
	return "wsi_villager:" .. self._inv_id
end

local function ensure_inventory(self)
	if not self._inv_id then
		next_inv_id = next_inv_id + 1
		self._inv_id = tostring(os.time()) .. "_" .. next_inv_id
	end
	local inv = core.get_inventory({type = "detached", name = inventory_name(self)})
	if inv then
		self._inv = inv
		return inv
	end
	inv = core.create_detached_inventory(inventory_name(self), {
		allow_move = function(_, _, _, _, _, count)
			return count
		end,
		allow_put = function(_, _, _, stack)
			return stack:get_count()
		end,
		allow_take = function(_, _, _, stack)
			return stack:get_count()
		end,
	})
	inv:set_size("main", INV_SLOTS)
	self._inv = inv
	return inv
end

local function restore_inventory(self, saved)
	local inv = ensure_inventory(self)
	if type(saved) ~= "table" then
		return
	end
	for _, entry in ipairs(saved) do
		if type(entry) == "table" and type(entry.slot) == "number" and type(entry.item) == "string" then
			local slot = math.floor(entry.slot)
			if slot >= 1 and slot <= INV_SLOTS then
				inv:set_stack("main", slot, ItemStack(entry.item))
			end
		end
	end
end

local function saved_inventory(self)
	local inv = self._inv
	if not inv then
		return {}
	end
	local saved = {}
	for slot = 1, INV_SLOTS do
		local stack = inv:get_stack("main", slot)
		if not stack:is_empty() then
			saved[#saved + 1] = {slot = slot, item = stack:to_string()}
		end
	end
	return saved
end

function inventory_view(self)
	local items = {}
	for _, entry in ipairs(saved_inventory(self)) do
		items[#items + 1] = entry.item
	end
	return items
end

local function show_inventory(self, player)
	local name = player:get_player_name()
	local detached = "detached:" .. inventory_name(self)
	local slots = ""
	if mcl_formspec and mcl_formspec.get_itemslot_bg_v4 then
		slots = mcl_formspec.get_itemslot_bg_v4(0.375, 0.75, 9, 3)
			.. mcl_formspec.get_itemslot_bg_v4(0.375, 5.1, 9, 3)
			.. mcl_formspec.get_itemslot_bg_v4(0.375, 9.05, 9, 1)
	end
	core.show_formspec(name, "wsi_npc:inventory", table.concat({
		"formspec_version[4]",
		"size[11.75,10.425]",
		"label[0.375,0.375;Villager]",
		slots,
		"list[" .. detached .. ";main;0.375,0.75;9,3;]",
		"label[0.375,4.7;Inventory]",
		"list[current_player;main;0.375,5.1;9,3;9]",
		"list[current_player;main;0.375,9.05;9,1;]",
		"listring[" .. detached .. ";main]",
		"listring[current_player;main]",
	}))
end

local function offset_pos(self, dx, dy, dz, limit)
	if type(dx) ~= "number" or type(dy) ~= "number" or type(dz) ~= "number" then
		error("dx, dy, and dz are required")
	end
	dx = math.floor(dx)
	dy = math.floor(dy)
	dz = math.floor(dz)
	limit = limit or REACH
	if math.abs(dx) > limit or math.abs(dy) > limit or math.abs(dz) > limit then
		error("that block is out of reach")
	end
	local pos = self.object:get_pos()
	if not pos then
		error("villager is gone")
	end
	local stand = stand_node(pos)
	if dx == 0 and dz == 0 and (dy == 0 or dy == 1) then
		error("that is where you are standing")
	end
	return {
		x = stand.x + dx,
		y = stand.y + dy,
		z = stand.z + dz,
	}
end

local hand_name

local function hand_item()
	if hand_name then
		return ItemStack(hand_name)
	end
	for name, def in pairs(core.registered_nodes) do
		if name:sub(1, 13) == "mcl_meshhand:" and def._mcl_diggroups and def._mcl_diggroups.handy then
			hand_name = name
			return ItemStack(name)
		end
	end
	return ItemStack("")
end

local function tool_for(inv, groups)
	local best_stack = nil
	local best_index = nil
	local best_time = nil
	local function consider(stack, index)
		local def = stack:get_definition()
		local caps = def and def.tool_capabilities
		if not caps then
			return
		end
		local params = core.get_dig_params(groups, caps, stack:get_wear())
		if params.diggable and (not best_time or params.time < best_time) then
			best_stack = stack
			best_index = index
			best_time = params.time
		end
	end
	consider(hand_item(), nil)
	for slot = 1, INV_SLOTS do
		local stack = inv:get_stack("main", slot)
		if not stack:is_empty() then
			consider(stack, slot)
		end
	end
	return best_stack, best_index
end

function break_at(self, pos)
	local node = core.get_node(pos)
	if node.name == "air" or node.name == "ignore" then
		error("there is nothing there")
	end
	local def = core.registered_nodes[node.name]
	if not def or def.diggable == false or core.get_item_group(node.name, "unbreakable") > 0 then
		error("cannot break that")
	end
	if core.is_protected(pos, "") then
		error("that block is protected")
	end
	local groups = def.groups or {}
	local inv = ensure_inventory(self)
	local tool, tool_slot = tool_for(inv, groups)
	if not tool then
		error("you need a tool for that")
	end
	if def.can_dig and not def.can_dig(pos, self.object) then
		error("cannot break that")
	end
	local toolname = ""
	if tool_slot then
		toolname = tool:get_name()
	end
	local drops = core.get_node_drops(node, toolname)
	local oldmetadata = nil
	if def.after_dig_node then
		oldmetadata = core.get_meta(pos):to_table()
	end
	core.remove_node(pos)
	if def.sounds and def.sounds.dug then
		core.sound_play(def.sounds.dug, {pos = pos, gain = 0.5}, true)
	end
	if def.after_dig_node then
		pcall(def.after_dig_node, pos, node, oldmetadata, self.object)
	end
	for _, callback in ipairs(core.registered_on_dignodes) do
		pcall(callback, pos, node, self.object)
	end
	if tool_slot then
		local params = core.get_dig_params(groups, tool:get_tool_capabilities(), tool:get_wear())
		tool:add_wear(params.wear)
		inv:set_stack("main", tool_slot, tool)
	end
	local kept = {}
	for _, drop in ipairs(drops) do
		local stack = ItemStack(drop)
		if not stack:is_empty() then
			local left = inv:add_item("main", stack)
			if left:get_count() < stack:get_count() then
				kept[#kept + 1] = stack:to_string()
			end
			if not left:is_empty() then
				core.add_item(pos, left)
			end
		end
	end
	return {broke = node.name, drops = kept}
end

function wood_count(self)
	local inv = self._inv
	if not inv then
		return 0
	end
	local count = 0
	for slot = 1, INV_SLOTS do
		local stack = inv:get_stack("main", slot)
		if not stack:is_empty() then
			local name = stack:get_name()
			if core.get_item_group(name, "tree") > 0
				or core.get_item_group(name, "bamboo_tree") > 0
				or name:find("log", 1, true)
				or name:find("hyphae", 1, true) then
				count = count + stack:get_count()
			end
		end
	end
	return count
end

local function resume_dig(self)
	if not (self._task and self._task.kind == "dig") then
		return false
	end
	if self._task.failed then
		local err = self._task.failed
		self._task = nil
		error(err)
	end
	if not self._task.arrived then
		if core.get_us_time() > self._task.deadline then
			self._task = nil
			error("could not reach that block")
		end
		return true, {_pending = true}
	end
	local pos = self._task.block
	self._task = nil
	return true, break_at(self, pos)
end

local function travel_and_break(self, pos)
	local here = self.object:get_pos()
	if not here then
		error("villager is gone")
	end
	local stand = stand_node(here)
	if close_enough(stand, pos) then
		return break_at(self, pos)
	end
	local steps = path_to_block(stand, pos)
	if not steps then
		error("no path there")
	end
	self._task = {
		kind = "dig",
		block = pos,
		steps = steps,
		next = 1,
		arrived = false,
		deadline = core.get_us_time() + 45000000,
	}
	return {_pending = true}
end

local function gather_wood(self, wood_need)
	return set_mode(self, "gather", wood_need)
end

local function dig_block(self, dx, dy, dz)
	if self._mode == "gather" then
		return {mode = "gather", wood_have = wood_count(self), wood_need = self._wood_need}
	end
	local busy, result = resume_dig(self)
	if busy then
		return result
	end
	local pos = offset_pos(self, dx, dy, dz)
	local node = core.get_node(pos)
	if node.name == "air" or node.name == "ignore" then
		error("there is nothing there")
	end
	return travel_and_break(self, pos)
end

local function place_block(self, dx, dy, dz, item)
	if type(item) ~= "string" or item == "" then
		error("item is required")
	end
	local name = ItemStack(item):get_name()
	local def = core.registered_items[name]
	if not def or def.type ~= "node" then
		error("that is not a block")
	end
	local pos = offset_pos(self, dx, dy, dz, 4)
	local current = core.get_node(pos)
	local current_def = core.registered_nodes[current.name]
	if not current_def or not current_def.buildable_to then
		error("that spot is not empty")
	end
	if core.is_protected(pos, "") then
		error("that spot is protected")
	end
	local inv = ensure_inventory(self)
	if not inv:contains_item("main", ItemStack(name)) then
		error("you do not have that block")
	end
	local stack = ItemStack(name)
	local above = {x = pos.x, y = pos.y + 1, z = pos.z}
	local pointed = {type = "node", under = pos, above = above}
	local ok, leftover, placed = pcall(core.item_place_node, stack, self.object, pointed)
	if not ok or not placed then
		error("cannot place that there")
	end
	if leftover:get_count() < stack:get_count() then
		inv:remove_item("main", ItemStack(name))
	end
	return {placed = name, x = placed.x, y = placed.y, z = placed.z}
end

local function build_item(self)
	local inv = self._inv
	if not inv then
		return nil
	end
	local best_name = nil
	local best_count = 0
	local best_rank = nil
	for slot = 1, INV_SLOTS do
		local stack = inv:get_stack("main", slot)
		if not stack:is_empty() then
			local name = stack:get_name()
			local rank = nil
			if core.get_item_group(name, "wood") > 0 then
				rank = 1
			elseif core.get_item_group(name, "tree") > 0 or core.get_item_group(name, "bamboo_tree") > 0 then
				rank = 2
			end
			if rank and (not best_rank or rank < best_rank or (rank == best_rank and stack:get_count() > best_count)) then
				best_name = name
				best_count = stack:get_count()
				best_rank = rank
			end
		end
	end
	return best_name
end

local function place_at(self, pos, itemname)
	local node = core.get_node(pos)
	local def = core.registered_nodes[node.name]
	if node.name == "ignore" or not def or not def.buildable_to then
		return false
	end
	if core.is_protected(pos, "") then
		return false
	end
	local inv = ensure_inventory(self)
	if not inv:contains_item("main", ItemStack(itemname)) then
		return false
	end
	local stack = ItemStack(itemname)
	local under = {x = pos.x, y = pos.y - 1, z = pos.z}
	local pointed = {type = "node", under = under, above = pos}
	local ok, leftover, placed = pcall(core.item_place_node, stack, self.object, pointed)
	if not ok or not placed then
		return false
	end
	if leftover:get_count() < stack:get_count() then
		inv:remove_item("main", ItemStack(itemname))
	end
	return true
end

local function house_spots(origin)
	local spots = {}
	local function add(x, y, z)
		spots[#spots + 1] = {x = origin.x + x, y = origin.y + y, z = origin.z + z}
	end
	for dz = 0, 3 do
		for dx = 0, 3 do
			add(dx, 0, dz)
			local edge = dx == 0 or dx == 3 or dz == 0 or dz == 3
			local door = dx == 0 and dz == 1
			if edge and not door then
				add(dx, 1, dz)
				add(dx, 2, dz)
			end
			add(dx, 3, dz)
		end
	end
	return spots
end

local function finish_house(self, pos, stand, reason)
	local placed = self._house_placed or 0
	local subgoal = self._house_subgoal
	self._mode = "stay"
	self._house_done = tostring(subgoal or "") .. "\0" .. (self._house_objective or "")
	self._house_plan = nil
	if pos and stand then
		drive(self, pos, stand, 0, 0)
	end
	if self._agent and not self._turn_pending then
		core.log("action", "WSI Villager house " .. reason .. ": " .. placed .. " blocks, subgoal " .. tostring(subgoal or ""))
		self._turn_pending = true
		core.wsi_turn(self._agent)
	end
end

local PLACE_REACH = 3

local function house_inside(origin, x, z)
	local dx = x - origin.x
	local dz = z - origin.z
	return dx >= 0 and dx <= 3 and dz >= 0 and dz <= 3
end

local function house_blocked(origin)
	return function(x, z)
		local dx = x - origin.x
		local dz = z - origin.z
		if dx < 0 or dx > 3 or dz < 0 or dz > 3 then
			return false
		end
		local edge = dx == 0 or dx == 3 or dz == 0 or dz == 3
		local door = dx == 0 and dz == 1
		return edge and not door
	end
end

local function in_place_reach(stand, spot)
	return math.abs(stand.x - spot.x) <= PLACE_REACH
		and math.abs(stand.z - spot.z) <= PLACE_REACH
		and math.abs(stand.y - spot.y) <= PLACE_REACH
end

local function stance_for(stand, spot, origin)
	if not house_inside(origin, stand.x, stand.z) and in_place_reach(stand, spot) then
		return stand
	end
	local best = nil
	local best_dist = nil
	for dz = -4, 7 do
		for dx = -4, 7 do
			local x = origin.x + dx
			local z = origin.z + dz
			if not house_inside(origin, x, z) then
				local feet = surface_y(x, z, stand.y)
				if feet and in_place_reach({x = x, y = feet, z = z}, spot) then
					local dist = (x - stand.x) * (x - stand.x) + (z - stand.z) * (z - stand.z)
					if not best_dist or dist < best_dist then
						best = {x = x, y = feet, z = z}
						best_dist = dist
					end
				end
			end
		end
	end
	return best
end

function pursue_house(self, dtime, pos, stand)
	if not self._house_plan then
		self._house_origin = {x = stand.x + 3, y = stand.y, z = stand.z}
		self._house_plan = house_spots(self._house_origin)
		self._house_next = 1
		self._house_placed = 0
	end
	local origin = self._house_origin
	local blocked = house_blocked(origin)
	local item = build_item(self)
	if not item then
		finish_house(self, pos, stand, "stopped, out of blocks")
		return
	end
	while self._house_next <= #self._house_plan do
		local spot = self._house_plan[self._house_next]
		local node = core.get_node(spot)
		if node.name == item then
			self._house_next = self._house_next + 1
		else
			local def = core.registered_nodes[node.name]
			if node.name ~= "air" and (node.name == "ignore" or not def or not def.buildable_to) then
				self._house_next = self._house_next + 1
			else
				break
			end
		end
	end
	if self._house_next > #self._house_plan then
		finish_house(self, pos, stand, "complete")
		return
	end
	local spot = self._house_plan[self._house_next]
	if house_inside(origin, stand.x, stand.z) then
		local hx, hz = steer(self, stand, origin.x - 1 + 0.5, origin.z + 1 + 0.5, blocked)
		drive(self, pos, stand, hx, hz)
		return
	end
	local stance = stance_for(stand, spot, origin)
	if not stance then
		self._house_next = self._house_next + 1
		drive(self, pos, stand, 0, 0)
		return
	end
	if stance.x == stand.x and stance.z == stand.z then
		local now = core.get_us_time()
		if now >= (self._place_after or 0) then
			self._place_after = now + 450000
			if place_at(self, spot, item) then
				self._house_placed = (self._house_placed or 0) + 1
			end
			self._house_next = self._house_next + 1
		end
		local fx = (spot.x + 0.5) - pos.x
		local fz = (spot.z + 0.5) - pos.z
		drive(self, pos, stand, 0, 0)
		if fx ~= 0 or fz ~= 0 then
			self.object:set_yaw(core.dir_to_yaw(vector.new(fx, 0, fz)))
		end
		return
	end
	local hx, hz = steer(self, stand, stance.x + 0.5, stance.z + 0.5, blocked)
	drive(self, pos, stand, hx, hz)
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
				name = "follow",
				description = "Walk with the nearest player. Call this when they ask you to follow or come with them.",
				params = {},
				run = function()
					return set_mode(self, "follow")
				end,
			},
			{
				name = "explore",
				description = "Wander on your own. Call this when they ask you to explore or look around.",
				params = {},
				run = function()
					return set_mode(self, "explore")
				end,
			},
			{
				name = "stay",
				description = "Stand where you are. Call this when they ask you to stay or wait.",
				params = {},
				run = function()
					return set_mode(self, "stay")
				end,
			},
			{
				name = "gather",
				description = "Walk to logs and break them. Call this after adding a subgoal to collect wood. The chopping continues while that subgoal is active.",
				params = {},
				run = function()
					return gather_wood(self)
				end,
			},
			{
				name = "dig",
				description = "Walk to one block and break it. dx, dy, and dz are the offset from where you stand, at most 16. Positive dx is east, positive dy is up, and positive dz is north. Do not use this for wood; call gather.",
				params = {
					{name = "dx", type = "integer"},
					{name = "dy", type = "integer"},
					{name = "dz", type = "integer"},
				},
				run = function(dx, dy, dz)
					return dig_block(self, dx, dy, dz)
				end,
			},
			{
				name = "place",
				description = "Place one block from inventory into an empty spot within 4 of where you stand. item is the item name from inventory.",
				params = {
					{name = "dx", type = "integer"},
					{name = "dy", type = "integer"},
					{name = "dz", type = "integer"},
					{name = "item", type = "string"},
				},
				run = function(dx, dy, dz, item)
					return place_block(self, dx, dy, dz, item)
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
		stepheight = 0.6,
		nametag = "Villager",
		nametag_color = "#FFFFFF",
	},
	_hp = 20,
	_agent = nil,
	_moving = false,
	_mode = "follow",

	on_activate = function(self, staticdata)
		self._heard = {}
		self._mode = "follow"
		local saved_items = nil
		if type(staticdata) == "string" and staticdata:sub(1, 1) == "{" then
			local data = core.parse_json(staticdata)
			if type(data) == "table" then
				if type(data.mode) == "string" and data.mode ~= "gather" then
					self._mode = data.mode
				end
				if type(data.inv_id) == "string" and data.inv_id ~= "" then
					self._inv_id = data.inv_id
				end
				saved_items = data.items
			end
		end
		restore_inventory(self, saved_items)
		self.object:set_acceleration(vector.new(0, -9.81, 0))
		self.object:set_properties({infotext = "Villager\nRight-click for inventory"})
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
		if self._inv_id then
			core.remove_detached_inventory(inventory_name(self))
			self._inv = nil
		end
	end,

	on_step = function(self, dtime)
		apply_subgoals(self)
		if self._task then
			advance_task(self)
			return
		end
		behave(self, dtime)
	end,

	on_rightclick = function(self, clicker)
		if clicker and clicker:is_player() then
			show_inventory(self, clicker)
		end
	end,

	on_punch = function(self, _puncher, time_from_last_punch)
		if time_from_last_punch < 0.45 then
			return
		end
		self._hp = self._hp - 4
		if self._hp <= 0 then
			local pos = self.object:get_pos()
			if pos and self._inv then
				for slot = 1, INV_SLOTS do
					local stack = self._inv:get_stack("main", slot)
					if not stack:is_empty() then
						core.add_item(pos, stack)
					end
				end
			end
			self.object:remove()
		end
	end,

	get_staticdata = function(self)
		if self._start_error then
			return ""
		end
		return core.write_json({
			mode = self._mode or "follow",
			wood_need = self._wood_need,
			inv_id = self._inv_id,
			items = saved_inventory(self),
		})
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

local function has_word(text, word)
	local from = 1
	while true do
		local start_at, end_at = text:find(word, from, true)
		if not start_at then
			return false
		end
		local before = start_at == 1 or text:sub(start_at - 1, start_at - 1):match("%A")
		local after = end_at == #text or text:sub(end_at + 1, end_at + 1):match("%A")
		if before and after then
			return true
		end
		from = end_at + 1
	end
end

local function wood_subgoal(goals)
	if type(goals) ~= "table" then
		return nil
	end
	for _, goal in ipairs(goals) do
		local text = string.lower(goal.objective or "")
		local building = has_word(text, "build") or has_word(text, "house") or has_word(text, "construct")
		local material = has_word(text, "wood") or has_word(text, "log") or has_word(text, "logs")
			or has_word(text, "tree") or has_word(text, "trees")
		local collecting = has_word(text, "gather") or has_word(text, "collect") or has_word(text, "chop")
			or has_word(text, "cut")
		if material and collecting and not building then
			return goal, tonumber(text:match("(%d+)"))
		end
	end
end

local function house_subgoal(goals)
	if type(goals) ~= "table" then
		return nil
	end
	for _, goal in ipairs(goals) do
		local text = string.lower(goal.objective or "")
		if has_word(text, "build") or has_word(text, "house") or has_word(text, "construct") then
			return goal
		end
	end
end

function apply_subgoals(self)
	if not self._agent then
		return
	end
	local goals = core.wsi_subgoals(self._agent)
	local wood, need = wood_subgoal(goals)
	local house = house_subgoal(goals)
	if wood then
		local key = tostring(wood.id or "") .. "\0" .. (wood.objective or "")
		self._wood_subgoal = wood.id
		self._wood_objective = wood.objective or ""
		if self._wood_done ~= key then
			self._wood_done = nil
			if need then
				self._wood_need = need
			end
			if self._mode ~= "gather" then
				self._mode = "gather"
				self._wander = nil
				self._task = nil
				self._wood_at = nil
			end
			return
		end
	else
		if self._wood_subgoal and self._mode == "gather" then
			self._mode = "stay"
			self._wood_need = nil
			self._task = nil
		end
		self._wood_subgoal = nil
		self._wood_objective = nil
		self._wood_done = nil
	end
	if not house then
		if self._mode == "build" then
			self._mode = "stay"
			self._house_plan = nil
		end
		self._house_subgoal = nil
		self._house_objective = nil
		self._house_done = nil
		return
	end
	local key = tostring(house.id or "") .. "\0" .. (house.objective or "")
	if self._house_subgoal ~= house.id then
		self._house_plan = nil
	end
	self._house_subgoal = house.id
	self._house_objective = house.objective or ""
	if self._house_done == key then
		return
	end
	if self._mode ~= "build" then
		self._mode = "build"
		self._wander = nil
		self._task = nil
		self._house_plan = nil
	end
end

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
		if ent.name == "wsi_npc:villager" and ent.object and ent._agent then
			local pos = ent.object:get_pos()
			if pos and flat_distance(pos, player_pos) <= HEAR_RANGE then
				local heard = ent._heard
				if not heard then
					heard = {}
					ent._heard = heard
				end
				heard[#heard + 1] = {name = name, text = message}
				while #heard > HEAR_LIMIT do
					table.remove(heard, 1)
				end
				if not ent._turn_pending then
					ent._turn_pending = true
					core.wsi_turn(ent._agent)
				end
			end
		end
	end
end)
