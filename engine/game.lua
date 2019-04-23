local input = require("lua-input") -- for event codes, TODO: put in mapping file
local ldb = require("lua-db")
local time = require("time")

-- the structure that holds all the callbacks
local game = {}

local font
local width, height
local engine
local fps
local player
local scroll_x, scroll_y = 0,0
local max_scroll_y = 0
local min_scroll_y = 0
local max_scroll_x = 0
local min_scroll_x = 0
local scroll_speed = 50
local world
local tileset
local assets
local tilemap_db
local tilemap_fg_db
local background_color = {175,230,245,255}
local time_remaining = 300
local clevel
local tilemap
local tilemap_buffers
local tile_subst_table = {} -- for animations etc.
local night = false
local stars
local clouds
local time_remaining_str
local enemies
local turrets
local spawner



-- initialize colliders table, assigning tile_ids to collision classes
local colliders = {}
local ground_colliders = {}
for i=0, 50 do -- first 51 tileids are ground
	table.insert(ground_colliders, i)
end
for _, v in ipairs({56,57,58,64,65,66,76, 104, 105, 106, 112,113,114, 120,121,122}) do -- add extra ground tiles
	table.insert(ground_colliders, v)
end
for k,v in ipairs(ground_colliders) do
	colliders[v+1] = "ground"
end

colliders[73] = "cloud"
colliders[74] = "cloud"
colliders[75] = "cloud"
colliders[69] = "box"
colliders[81] = "spawner"
colliders[82] = "bouncer"
colliders[83] = "cloud"
colliders[84] = "cloud"
colliders[86] = "live"
colliders[89] = "goal"
colliders[97] = "goal"
colliders[108] = "coin"
colliders[99] = "enemy"
colliders[100] = "turret"
local animations = {
	--[[{
		dt = 2/3,
		source = 87,
		frames = {118},
		layer = 1,
		ctime = 0
	}]]
}


-- return the screen coordinates for the given world coordinates
local function world_to_screen_coords(world_x, world_y)
	-- TODO: use scroll to calculate
	return math.floor(world_x+scroll_x), math.floor(world_y+scroll_y)
end


-- draw the player on the drawbuffer
local function draw_player(db)
	local player_tileset = assets.by_name.char_tiles.tileset
	local tile_id = 0
	
	-- select correct frame
	-- TODO: animation
	if player.velocity_x == 0 then
		if player.dir == "right" then
			tile_id = 2
		elseif player.dir == "left" then
			tile_id = 1
		end
	else
		if player.dir == "right" then
			tile_id = 4
		elseif player.dir == "left" then
			tile_id = 3
		end
	end
	
	if (player.velocity_x ~= 0) and (player.is_on_ground) and (player.runtime*2 % 1) > 0.5 then
		tile_id = tile_id + 4
	end
	
	
	local screen_x, screen_y = world_to_screen_coords(player.x, player.y)
	screen_x = screen_x - player.offset_x
	screen_y = screen_y - player.offset_y
	
	player_tileset.draw_tile(db, screen_x, screen_y, tile_id)
end


-- create a bullet from the player, towards x,y
local bullets = {}
local function player_shoot(dx,dy)
	local bullet = {
		x = player.x,
		y = player.y + 16,
		w = 1,
		h = 1,
		dx = dx,
		dy = dy,
		speed = 100,
		gravity = 4
	}
	
	if dx > 0 then
		bullet.x = bullet.x + player.width + 5
	else
		bullet.x = bullet.x - 5
	end
	
	world.physics_world:add(bullet, bullet.x, bullet.y, bullet.w, bullet.h)
	table.insert(bullets, bullet)
	
	player.can_shoot = false
	player.last_shoot = 0
end


-- called when the player should die to respawn/reset and return to menu
local function player_die()
	if player.lives > 0 then
		player.lives = player.lives - 1
		engine.config._clives = player.lives
		player.x = player.spawn_x
		player.y = player.spawn_y
		player.velocity_x = 0
		player.velocity_y = 0
		player.runtime = 0
		player.coins = 0
		time_remaining = 300
		world.physics_world:update(player, player.x, player.y)
	else
		engine.config._ccoins = nil
		engine.config._clives = nil
		engine:change_stage("menu")
	end 
end


-- collision filter
local function colission_filter(item, other)
	-- print("colission_filter(item, other)", item, other)
	if other.class == "cloud" then
		-- print("cloud")
		return "cross"
	elseif other.class == "live" then
		return "cross"
	elseif other.class == "coin" then
		return "cross"
	elseif other.class == "enemy" then
		return "cross"
	elseif other.class == "none" then
		return "cross"
	end
	
	return "slide"
end


-- load the next level
local function load_next_level()
	
	engine.config._clives = player.lives
	engine.config._ccoins = player.coins


	if engine.config._clevel == "map" then
		engine.config._clevel = "map2"
		engine:change_stage("game")
	elseif engine.config._clevel == "map2" then
		engine.config._clevel = "map3"
		engine:change_stage("game")
	elseif engine.config._clevel == "map3" then
		engine.config._clevel = "map4"
		engine:change_stage("game")
	else
		engine.config.output.always_night = true
		engine.config._clevel = nil
		engine.config._ccoins = nil
		engine.config._clives = nil
		engine:change_stage("menu")
	end
end


local function remove_enemy(enemy)
	world.physics_world:remove(enemy)
	for i, _enemy in ipairs(enemies) do
		if enemy == _enemy then
			table.remove(enemies, i)
		end
	end
end


local function update_enemies(dt)
	for i, enemy in ipairs(enemies) do
		local target_enemy_x = enemy.x + dt*enemy.speed*(enemy.dir=="left" and -1 or 1)
		local target_enemy_y = enemy.y + 1
		local new_enemy_x, new_enemy_y, cols, cols_len = world.physics_world:move(enemy, target_enemy_x, target_enemy_y)
		
		enemy.runtime = enemy.runtime + dt
		
		if (new_enemy_x ~= target_enemy_x) then
			if enemy.dir == "left" then
				enemy.dir = "right"
			else
				enemy.dir = "left"
			end
		elseif new_enemy_y == target_enemy_y then
			-- we can go down, turn back!
			if enemy.dir == "left" then
				enemy.dir = "right"
			else
				enemy.dir = "left"
			end
			world.physics_world:update(enemy, enemy.x+(enemy.dir=="left" and -3 or 3), enemy.y)
		end
		
		for i=1, cols_len do
			local col = cols[i]
			if col.other.player then
				print("enemy collided with player")
			end
		end
		
		enemy.x, enemy.y = new_enemy_x, new_enemy_y
	end
end


local function draw_enemies(db)
	for i, enemy in ipairs(enemies) do
		local tile_id
		if enemy.dir == "left" then
			tile_id = 1
		elseif enemy.dir == "right" then
			tile_id = 3
		end
		if enemy.runtime % 1 > 0.5 then
			tile_id = tile_id + 1
		end
		local screen_x, screen_y = world_to_screen_coords(enemy.x, enemy.y)
		assets.by_name.enemies.tileset.draw_tile(db, screen_x, screen_y, tile_id)
	end
end


local function add_enemy(x,y)
	print("add_enemy(x,y)", x, y)
	local enemy = {
		hp = 1,
		x = x,
		y = y,
		w = 8,
		h = 8,
		dir = "left",
		speed = 10,
		class = "enemy",
		runtime = 0
	}
	local tile_ids = tilemap:get_at(x/8, y/8)
	local target_block
	for i, tile_id in ipairs(tile_ids) do
		
	end
	
	tilemap:replace_tileid_at(x/8, y/8, 99, 0, world)
	
	enemy.target_block = target_block
	world.physics_world:add(enemy, enemy.x, enemy.y, enemy.w, enemy.h)
	table.insert(enemies, enemy)
end


local spawner_i
local function add_spawner(x,y)
	print("add_spawner(x,y)",x,y)
	local spawner = {
		spawnrate = 10,
		ctime = 0,
		spawn_x = x + 4,
		spawn_y = y + 16
	}
	
	table.insert(spawners, spawner)
end


local turret_i = 1
local function add_turret(x,y)
	print("add_turret(x,y)",x,y)
	local turret = {
		firerate = 3,
		ctime = 0,
		spawn_x = x - 3,
		spawn_y = y +4,
		dx = -1
	}
	
	-- add delay between different turrets
	turret.ctime = (turret.ctime + (turret_i/10)) % turret.firerate
	turret_i = turret_i + 1
	
	table.insert(turrets, turret)
end



-- update the tile_subst_table with the current animation frames
local function update_animations(dt)
	for i, animation in ipairs(animations) do
		animation.ctime = animation.ctime + dt
		local frame_c = #animation.frames+1
		local frame_i = math.floor((animation.ctime/(frame_c*animation.dt))*frame_c + 1)
		local target_frame
		if frame_i > (#animation.frames+1) then
			animation.ctime = 0
		elseif frame_i <= #animation.frames then
			target_frame = animation.frames[frame_i]
		end
		
		if target_frame ~= tile_subst_table[animation.source] then
			tilemap.dirty = true
			tile_subst_table[animation.source] = target_frame
		end	
		
		-- print("animation", frame_i, frame_c, animation.frames[frame_i])
	end
	
end


-- update player position etc. based on physics
local function update_player(dt)

	player.last_shoot = player.last_shoot + dt
	player.can_shoot = player.last_shoot >= player.firerate

	if engine:key_is_down(input.event_codes.KEY_UP) then
		if player.is_on_ground then
			player.velocity_y = -player.jump_height
		end
	end
	if engine:key_is_down(input.event_codes.KEY_LEFT) then
		player.velocity_x = -player.speed_x
		player.dir = "left"
	end
	if engine:key_is_down(input.event_codes.KEY_RIGHT) then
		player.velocity_x = player.speed_x
		player.dir = "right"
	end
	if engine:key_is_down(input.event_codes.KEY_SPACE) then
		if player.can_shoot then
			if player.dir == "right" then
				player_shoot(1, 0)
			elseif player.dir == "left" then
				player_shoot(-1, 0)
			end
		end
	end
	
	if engine:key_is_down(input.event_codes.KEY_F) then
		--local tilemap = tilemap
		--local x = math.floor(player.x/8)+2
		--local y = math.floor(player.y/8)
		--tilemap:set_at_layer(tilemap.tile_layers[1], x, y, 99, world)
		--tilemap:set_at_layer(tilemap.tile_layers[1], x, y, 99)
	end
	
	
	-- Apply gravity
	player.velocity_y = player.velocity_y + (player.gravity * dt)
	
	
	-- apply fricton
	if player.is_on_ground then
		player.velocity_x = player.velocity_x - player.velocity_x*player.friction_ground*dt
	else
		player.velocity_x = player.velocity_x - player.velocity_x*player.friction_air*dt
		--player.velocity_x = player.velocity_x * player.friction_ground
	end
	
	if math.abs(player.velocity_x) < 0.01 then
		player.velocity_x = 0
	end
	
	if math.abs(player.velocity_y) > 0.01 then
		player.is_on_ground = false
	end
	if player.velocity_y ~= 0 then
		player.is_on_ground = false
	end
	
	
	if player.velocity_x ~= 0 or player.velocity_y ~= 0 then
		local cols, cols_len
		player.x, player.y, cols, cols_len = world.physics_world:move(player, player.x + player.velocity_x * dt, player.y + player.velocity_y * dt, colission_filter)
		for i=1, cols_len do
			local col = cols[i]
			local skip = false
			if col.other.class == "cloud" then
				-- print("cloud")
				player.velocity_y = player.velocity_y + 10*dt
				player.is_on_ground = true
				skip = true
			elseif col.other.class == "box" then
				if col.normal.y and col.normal.y == 1 then
					player.velocity_y = 0
					local x = col.other.x/assets.by_name.tileset.tileset.tile_w
					local y = col.other.y/assets.by_name.tileset.tileset.tile_h
					tilemap:replace_tileid_at(x, y, 69, 77, world)
					player.coins = player.coins + 5
					if player.coins >= 100 then
						player.coins = 0
						player.lives = math.min(player.lives+1, 10)
					end
				end
			elseif col.other.class == "live" then
				local x = col.other.x/assets.by_name.tileset.tileset.tile_w
				local y = col.other.y/assets.by_name.tileset.tileset.tile_h
				player.lives = math.min(player.lives+1, 10)
				tilemap:replace_tileid_at(x, y, 86, 0, world)
				skip = true
			elseif col.other.class == "coin" then
				local x = col.other.x/assets.by_name.tileset.tileset.tile_w
				local y = col.other.y/assets.by_name.tileset.tileset.tile_h
				player.coins = player.coins+1
				if player.coins >= 100 then
					player.coins = 0
					player.lives = math.min(player.lives+1, 10)
				end
				tilemap:replace_tileid_at(x, y, 108, 0, world)
				skip = true
			elseif col.other.class == "bouncer" then
				player.velocity_y = -80
				player.is_on_ground = false
				skip = true
			elseif col.other.class == "goal" then
				load_next_level()
			elseif col.other.class == "enemy" then
				player_die()
			end
			
			if not skip then
				if col.normal and col.normal.y == -1 then -- player landed on ground
					player.is_on_ground = true
					player.velocity_y = 0
				elseif col.normal and col.normal.y == 1 then -- collided with top, remove velocity
					player.velocity_y = 0
				end
			end
				
			-- print(("col.other = %s, col.type = %s, col.normal = %d,%d"):format(col.other, col.type, col.normal.x, col.normal.y))
		end
	end
	
end


local function update_spawners(dt)
	for i, spawner in ipairs(spawners) do
		spawner.ctime = spawner.ctime + dt
		if spawner.ctime >= spawner.spawnrate then
			-- spawn a new enemy
			add_enemy(spawner.spawn_x, spawner.spawn_y)
			spawner.ctime = 0
		end
	end
end

local function update_turrets(dt)
	for i, turret in ipairs(turrets) do
		turret.ctime = turret.ctime + dt
		if turret.ctime >= turret.firerate then
			-- add a bullet
			local bullet = {
				x = turret.spawn_x,
				y = turret.spawn_y,
				w = 1,
				h = 1,
				dx = turret.dx,
				dy = 0,
				speed = 100,
				gravity = 0
			}
			world.physics_world:add(bullet, bullet.x, bullet.y, bullet.w, bullet.h)
			table.insert(bullets, bullet)
			turret.ctime = 0
		end
	end
end


-- update bullet positions, handle collisions
local function update_bullets(dt)
	for i, bullet in ipairs(bullets) do
		local cols, cols_len
		local new_x = bullet.x + bullet.dx*bullet.speed*dt
		local new_y = bullet.y + bullet.dy*bullet.speed*dt+dt*bullet.gravity
		bullet.x, bullet.y, cols, cols_len = world.physics_world:move(bullet, new_x, new_y, colission_filter)
		for j=1, cols_len do
			local col = cols[j]
			
			if col.other.class == "enemy" then
				print("bullet hit enemy")
				remove_enemy(col.other)
			end
			
			player.can_shoot = true
			table.remove(bullets, i)
			world.physics_world:remove(bullet)
			return
		end
	end
end


-- draw bullets and bullet trails
local function draw_bullets(db)
	for i, bullet in ipairs(bullets) do
		local screen_x, screen_y = world_to_screen_coords(bullet.x, bullet.y)
		local last_x, last_y = world_to_screen_coords(bullet.x - (bullet.dx*bullet.speed)*0.05, bullet.y - (bullet.dy*bullet.speed + bullet.gravity)*0.05)
		db:set_line(screen_x, screen_y, last_x, last_y, unpack(bullet.trail or {64, 64, 64, 255}))
		db:set_pixel(screen_x, screen_y,  unpack(bullet.color or {255, 127, 0, 255}))
	end
end


local function generate_clouds(could_count, level_width)
	local clouds = {}
	for i=1, could_count do
		table.insert(clouds, {
			x = math.random(0, level_width*2),
			y = math.random(0, 30),
			tile_id = math.random(1, 4)
		})
	end
	return clouds
end


local function generate_stars(star_count, level_width)
	local stars = {}
	for i=1, star_count do
		table.insert(stars, {
			x = math.random(0, level_width*16),
			y = math.random(0, 100),
			brightness = 1/math.random(1, 4)
		})
	end
	return stars
end


local function draw_bg(db)
	local r,g,b,a = unpack(background_color)
	db:clear(r,g,b,a)
	
	if night then
		
		db:clear(0,0,0,255)
		
		-- draw stars
		for i, star in ipairs(stars) do
			local b = math.floor(255*star.brightness)
			db:set_pixel(math.floor(star.x+scroll_x/16), math.floor(star.y+scroll_y/128), b,b,b, 255)
		end
		
	else
		
		-- draw bottom indicator
		local scroll_pct = ((-scroll_y) / height) * 16
		local bar_h = math.floor(scroll_pct)
		for i=0, 8 do
			db:set_rectangle(0, height-(8-i)*bar_h, width, bar_h, r-5*i,g-5*i,b-5*i,a)
		end
		
		-- draw clouds
		for i, cloud in ipairs(clouds) do
			assets.by_name.clouds_tiles.tileset.draw_tile(db, cloud.x+scroll_x/2, cloud.y+scroll_y/8, cloud.tile_id, 2)
		end
	
	end
end


local function spawn_player(spawn_x, spawn_y)
	player = {
		x = spawn_x,
		y = spawn_y,
		spawn_x = spawn_x,
		spawn_y = spawn_y,
		width = 10,
		height = 24,
		offset_x = 1,
		offset_y = 0,
		can_shoot = true,
		last_shoot = 0,
		firerate = 0.33,
		velocity_y = 0,
		velocity_x = 0,
		speed_x = 40,
		dir = "right",
		jump_height = 64,
		runtime = 0,
		hp = 5,
		lives = engine.config._clives or 1,
		gravity = 55,
		coins = 0,
		friction_air = 5.01,
		friction_ground = 20,
	}
end


-- load the tilemap
local enemy_coords
local spawner_coords
local turret_coords
local function load_tilemap()
	-- create tilemap_db that contains the rendered tilemap.
	-- TODO: create 2 tilemap layers, to draw below/above the player
	local tilemap = assets.by_name[engine.config._clevel].tilemap
	
	--tilemap_db = ldb.new(tilemap.tiles_x * tilemap.tileset.tile_w, tilemap.tiles_y * tilemap.tileset.tile_h)
	--tilemap_fg_db = ldb.new(tilemap.tiles_x * tilemap.tileset.tile_w, tilemap.tiles_y * tilemap.tileset.tile_h)
	
	
	
	-- adjust min_scroll_y to tilemap height
	min_scroll_y = -tilemap.tiles_y*tilemap.tileset.tile_h
	
	-- create the level data
	local level = tilemap:generate_level(function(tileid, x, y)
		if tileid == 0 or colliders[tileid] == "none" then
			return
		end
		if colliders[tileid] == "enemy" then
			table.insert(enemy_coords, {x,y})
			return "enemy"
		elseif colliders[tileid] == "spawner" then
			table.insert(spawner_coords, {x,y})
			return "spawner"
		elseif colliders[tileid] == "turret" then
			table.insert(turret_coords, {x,y})
			return "turret"
		end
		return colliders[tileid] or "none"
	end)
	
	-- initialize the player for the level
	spawn_player(level.spawn_x, level.spawn_y)
	
	-- create the world, including physics, for the level and player
	world = engine:new_world(level, player)
	tilemap_buffers = tilemap:draw_to_buffers(tilemap_buffers)
end


-- called when the calculations should be done
function game:update(dt)
	fps = 1/dt
	
	dt = dt * self.config.speed
	
	update_player(dt)
	scroll_x = math.min(-(player.x) + (width/2), 0)
	-- scroll_x = math.min((player.x) , 0)
	scroll_y = math.max(math.min(-(player.y) + (height/2), 0), min_scroll_y+height)
	
	player.runtime = player.runtime + dt
	
	update_bullets(dt)
	update_spawners(dt)
	update_turrets(dt)
	
	-- redraw tilemap buffer if needed(costly, but needed on tilechange)
	update_animations(dt)
	tilemap_buffers = tilemap:draw_to_buffers(tilemap_buffers, tile_subst_table)
	
	time_remaining = time_remaining - dt
	local remaining_min = math.floor(time_remaining/60)
	local remaining_secs = math.floor(time_remaining%60)
	time_remaining_str = ("%3d:%.2d"):format(remaining_min, remaining_secs)
	
	update_enemies(dt)
	
	if player.y > -min_scroll_y+player.height then
		player_die()
	end
	if time_remaining <= 0 then
		player_die()
	end

	-- print("\n\n\n#player.bullets:" .. #bullets .. "     ")
	-- print(("fps: %.1d    dt: %dms"):format(fps, dt*1000))
end


-- called when the image is about to be drawn with the output drawbuffer
function game:draw(db)
	-- draw background
	draw_bg(db)
	
	
	
	-- draw world
	local screen_x, screen_y = world_to_screen_coords(0,0)
	for i=1, #tilemap_buffers - 1 do
		tilemap_buffers[i]:draw_to_drawbuffer(db, 0,0, -screen_x, -screen_y, width, height)
	end
	--tilemap_db:draw_to_drawbuffer(db, 0,0, -scroll_x, -scroll_y, width, height)
	
	-- draw player
	draw_player(db)
	
	-- draw enemies
	draw_enemies(db)
	
	-- draw bullets
	draw_bullets(db)
	
	--tilemap_fg_db:draw_to_drawbuffer(db, 0,0, -scroll_x, -scroll_y, width, height)
	tilemap_buffers[#tilemap_buffers]:draw_to_drawbuffer(db, 0,0, -screen_x, -screen_y, width, height)
	
	-- draw the physics world(debug!)
	-- world:draw(db, scroll_x, -scroll_y)
	
	-- draw ui ontop
	font:draw_string(db, (" x%.2d"):format(player.lives), 0, 0)
	font:draw_string(db, (" x%.2d"):format(player.coins), 0, 9)
	assets.by_name.tileset.tileset.draw_tile(db, 0,-1, 86)
	assets.by_name.tileset.tileset.draw_tile(db, 0,8, 108)
	
	font:draw_string(db, time_remaining_str, width-48, 0)
	font:draw_string(db, (" %3d"):format(fps), width-32, 9)
end


-- called once when this scene is loaded
function game:init()
	font = self:load_font("cga8")
	
	engine = self
	
	width = self.config.output.width
	height = self.config.output.height
	
	self.config._clevel = self.config._clevel or "map"


	enemies = {}
	turrets = {}
	spawners = {}
	bullets = {}
	enemy_coords = {}
	spawner_coords = {}
	turret_coords = {}


	-- load required assets into an asset table
	assets = self:load_assets({
		-- source images for tilesets, fonts
		{
			name = "char_img",
			type = "img",
			file = "char.raw",
			width = 48,
			height = 48
		},
		{
			name = "clouds_img",
			type = "img",
			file = "clouds.raw",
			width = 64,
			height = 16
		},
		{
			name = "tileset_img",
			type = "img",
			file = "tileset2.raw",
			width = 64,
			height = 128
		},
		{
			name = "enemies_img",
			type = "img",
			file = "enemies.raw",
			width = 64,
			height = 16
		},
		{
			name = "cga8_img",
			type = "img",
			file = "cga8.bmp",
			apply_transparency_color = {255,255,255}
		},
		
		-- tilesets
		{
			name = "clouds_tiles",
			type = "tileset",
			db_name = "clouds_img",
			tile_w = 16,
			tile_h = 16
		},
		{
			name = "char_tiles",
			type = "tileset",
			db_name = "char_img",
			tile_w = 12,
			tile_h = 24
		},
		{
			name = "tileset",
			type = "tileset",
			db_name = "tileset_img",
			tile_w = 8,
			tile_h = 8
		},
		{
			name = "enemies",
			type = "tileset",
			db_name = "enemies_img",
			tile_w = 8,
			tile_h = 8
		},
		
		-- fonts
		{
			name = "cga8",
			type = "font",
			db_name = "cga8_img",
			char_w = 8,
			char_h = 8
		},
		
		
		
		
		-- maps
		{
			name = "map",
			type = "tiled_map",
			tileset_name = "tileset",
			file = "img/test_map_2.json"
		
		},
		{
			name = "map2",
			type = "tiled_map",
			tileset_name = "tileset",
			file = "img/test_map_3.json"
		},
		{
			name = "map3",
			type = "tiled_map",
			tileset_name = "tileset",
			file = "img/test_map_4.json"
		},
		{
			name = "map4",
			type = "tiled_map",
			tileset_name = "tileset",
			file = "img/test_map_5.json"
		}
		
	})
	
	night = self.config.output.always_night
	
	tilemap = assets.by_name[engine.config._clevel].tilemap
	load_tilemap()
	
	player.lives = self.config._clives or player.lives
	player.coins = self.config._ccoins or player.coins
	
	stars = generate_stars(1000, tilemap.tiles_x*tilemap.tileset.tile_w)
	clouds = generate_clouds(15, tilemap.tiles_x*tilemap.tileset.tile_w)
	
	
	
	for i,enemy_coord in ipairs(enemy_coords) do
		add_enemy(enemy_coord[1]*8, enemy_coord[2]*8)
	end
	for i,spawner_coord in ipairs(spawner_coords) do
		add_spawner(spawner_coord[1]*8, spawner_coord[2]*8)
	end
	for i,turret_coord in ipairs(turret_coords) do
		add_turret(turret_coord[1]*8, turret_coord[2]*8)
	end
	
	tilemap.dirty = true
end


return game
