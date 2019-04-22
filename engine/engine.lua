local ldb = require("lua-db")
local lfb
local sdl2fb
local time = require("time")
local input = require("lua-input")
local bump = require("bump")


-- the engine loads a stage, and is responisble for it's interactions with
-- input/output devices.
local Engine = {}


-- engine.new appends the engine infrastructure to the loaded stage, making the stage ready to run
function Engine.new(stage, config)

	-- create the output drawbuffer of required size
	local out_db = ldb.new(config.output.width, config.output.height)

	-- called when an input is received from a uinput keyboard
	local key_state = {}
	local input_callbacks = {}
	local function handle_uinput_keyboard_ev(ev)
		if ev.type == input.event_codes.EV_KEY then
			if input_callbacks[ev.code] then
				input_callbacks[ev.code](ev)
			end
			if ev.value ~= 0 then
				key_state[ev.code] = ev.value
			else
				key_state[ev.code] = nil
			end
		end
	end
	
	
	local sdl_to_uinput = {
		-- TODO
		["Left"] = input.event_codes.KEY_LEFT,
		["Right"] = input.event_codes.KEY_RIGHT,
		["Up"] = input.event_codes.KEY_UP,
		["Down"] = input.event_codes.KEY_DOWN,
		["Space"] = input.event_codes.KEY_SPACE,
		["Return"] = input.event_codes.KEY_ENTER
	}
	local function handle_sdl_event(ev)
		if ev.type == "keyup" then
			handle_uinput_keyboard_ev({
				type = input.event_codes.EV_KEY,
				code = sdl_to_uinput[ev.key],
				value = 0
			})
		elseif ev.type == "keydown" then
			handle_uinput_keyboard_ev({
				type = input.event_codes.EV_KEY,
				code = sdl_to_uinput[ev.key],
				value = 1
			})
		end
	end
	
	
	-- utillity function to add the content of the second table to the first
	local function t_merge(target, append)
		for k,v in ipairs(append) do
			table.insert(target, v)
		end
		return target
	end


	
	local input_devs = {}
	
	-- open input devices
	for k, input_dev_config in ipairs(config.input) do
		if input_dev_config.type == "keyboard" and input_dev_config.driver == "uinput" then
			local dev = assert(input.open(input_dev_config.dev, true))
			table.insert(input_devs, {dev, input_dev_config, handle_uinput_keyboard_ev})
		end
	end


	-- get upper-left coodinate of a centered box on the terminal
	local next_update = 0
	local center_x, center_y
	local function get_center(out_w, out_h)
		if time.realtime() >= next_update then
			local term_w,term_h = ldb.term.get_screen_size()
			local _center_x = math.floor((term_w - out_w) / 2)
			local _center_y = math.floor((term_h - out_h) / 2)
			if center_x == _center_x and center_y == _center_y then
				return _center_x, _center_y
			end
			center_x = _center_x
			center_y = _center_y
			
			-- only update screen size every 5s
			-- TODO: value from config
			next_update = time.realtime() + 5
		end
		return center_x, center_y
	end


	-- output a list of lines as returned by braile/blocks
	local function output_lines(lines, w, h)
		local cursor_x, cursor_y = 0,0
		if config.output.center then
			cursor_x, cursor_y = get_center(w, h)
		end
		for i, line in ipairs(lines) do
			io.write(ldb.term.set_cursor(cursor_x, cursor_y+i-1))
			io.write(line)
			io.write(ldb.term.reset_color())
			io.write("\n")
		end
		io.flush()
	end


	-- called with the final drawbuffer that should be scaled and displayed
	local _scaled_db
	local function scale_db(db)
		if config.output.scale then
			_scaled_db = _scaled_db or ldb.new(config.output.width * config.output.scale, config.output.height * config.output.scale)
			db:draw_to_drawbuffer(_scaled_db, 0, 0, 0, 0, db:width(), db:height(), config.output.scale)
			return _scaled_db
		end
		return db
	end


	-- final output to the terminal
	local function output_braile(db)
		local lines = ldb.braile.draw_db_precise(db, config.output.threshold, 45, true, config.output.bpp24)
		output_lines(lines, math.floor(out_db:width()/2), math.floor(out_db:height()/4))
	end


	-- final output to the terminal
	local function output_blocks(db)
		local lines = ldb.blocks.draw_db(db)
		output_lines(lines, out_db:width(), out_db:height())
	end


	-- final output to the sdl2 window
	local sdl_window
	local function output_sdl2(db)
		if sdl_window then
			sdl_window:draw_from_drawbuffer(db, 0, 0)
		end
	end


	-- final output to the framebuffer
	local fb_dev
	local fb_info
	local function output_fb(db)
		local center_x = math.floor((fb_info.xres-db:width()) / 2)
		local center_y = math.floor((fb_info.yres-db:height()) / 2)
		fb_dev:draw_from_drawbuffer(db, center_x, center_y)
	end


	-- create an appropriate output context
	local output
	local function open_output()
		if config.output.type == "braile" then
			output = output_braile
		elseif config.output.type == "blocks" then
			output = output_blocks
		elseif config.output.type:match("^fb=(.*)$") then
			lfb = require("lua-fb")
			fb_dev = lfb.new(config.output.type:match("^fb=(.*)$"))
			fb_info = fb_dev:get_varinfo()
			output = output_fb
		elseif config.output.type == "sdl2fb" then
			sdl2fb = require("sdl2fb")
			if not sdl_window then
				sdl_window = sdl2fb.new(config.output.width*config.output.scale, config.output.height*config.output.scale, "engine")
				print("new sdl_window", sdl_window)
			end
			output = output_sdl2
		else
			error("Unsupported output! Check config")
		end
	end


	-- load an image by file name(determine decoder automatically)
	local img_cache = {}
	function stage:load_img(file_path, width, height)
		if img_cache[file_path] then
			return img_cache[file_path]
		end
		local file_type = file_path:sub(-4)
		local db
		if file_type == ".bmp" then
			db = ldb.bitmap.decode_from_file_drawbuffer("img/" .. file_path)
		elseif file_type == ".ppm" then
			db = ldb.ppm.decode_from_file_drawbuffer("img/" .. file_path)
		elseif file_type == ".raw" then
			db = ldb.raw.decode_from_file_drawbuffer("img/" .. file_path, width, height)
		end
		return db
	end


	-- check each pixel for this color and set alpha of that pixel to 0
	function stage:apply_transparency_color(db, tr,tg,tb)
		db:pixel_function(function(x,y,r,g,b,a)
			if tr == r and tg == g and tb == b then
				return r,g,b,0
			end
			return r,g,b,a
		end)
	end


	-- crop the drawbuffer, returning a new drawbuffer of the specified with
	-- TODO: move to lua-db
	function stage:crop(db, xo, yo, width, height)
		local new_db = ldb.new(width, height)
		for y=0, height-1 do
			for x=0, width-1 do
				local r,g,b,a = db:get_pixel(x+xo,y+yo)
				new_db:set_pixel(x,y,r,g,b,a)
			end
		end
		return new_db
	end


	-- loads a font by it's filename
	-- TODO: move to lua-db
	function stage:load_font(font_name)
		local font_config = assert(config.fonts[font_name])
	
		local font_file = assert(io.open(font_config.bmp, "rb"))
		local font_str = font_file:read("*a")
		local font_db = ldb.bitmap.decode_from_string_drawbuffer(font_str)
		font_file:close()
		local font_header = ldb.bitmap.decode_header(font_str)

		-- create font
		local font = ldb.font.from_drawbuffer(font_db, font_config.char_w, font_config.char_h, font_config.alpha_color, font_config.scale)
		return font
	end
	
	
	-- create drawable tilelayers from a decoded tiled json map
	function stage:tilemap_from_tiled_json(map, tileset)
		local tilemap = {}
		local _self = self
		tilemap.tileset = assert(tileset)
		
		-- this will hold a list of drawbuffers that contain the layer data for each layer
		local tile_layers = {}
		local tile_layers_dirty = {}
		
		-- set the tile_id in the layer at x,y
		local function set_at(layer_db, x, y, tile_id)
			tile_layers_dirty[layer_db] = true
			layer_db:set_pixel(x, y, tile_id, 0, 0, 255 )
		end
		
		-- add a single layer from the JSON to the tile_layers
		local max_w, max_h = 0,0
		local function add_tile_layer(clayer)
			-- ignore invisible layer
			if not clayer.visible then
				return
			end
			-- create a drawbuffer that will store the tile data for faster access
			local layer_db = ldb.new(clayer.width*tileset.tile_w, clayer.height*tileset.tile_h)
			layer_db:clear(0,0,0,255)
			
			local i = 1
			-- copy tile data from json
			for y=1, clayer.height do
				for x=1, clayer.width do
					local ctileid = clayer.data[i]
					i = i + 1
					-- encode the tile id in the red channel of the drawbuffer
					set_at(layer_db, x-1, y-1, ctileid)
				end
			end
			
			max_w = math.max(max_w, clayer.width)
			max_h = math.max(max_h, clayer.height)
			
			tile_layers_dirty[layer_db] = true
			return layer_db
		end
		
		-- add each layer
		for i,layer in ipairs(map.layers) do
			local layer_db = add_tile_layer(layer)
			table.insert(tile_layers, layer_db)
		end
		tilemap.tiles_x = max_w
		tilemap.tiles_y = max_h
		
		tilemap.tile_layers = tile_layers
		
		local function add_collider(world_data, collision_class, x, y, world)
			if collision_class and (collision_class ~= "none") then
				local collider = {
					type = "collider",
					class = collision_class,
					x = x*tileset.tile_w,
					y = y*tileset.tile_h,
					w = tileset.tile_w,
					h = tileset.tile_h
				}
				table.insert(world_data, collider)
				if world then
					world.physics_world:add(collider, collider.x, collider.y, collider.w, collider.h)
				end
			end
		end
		
		function tilemap:set_at_layer(layer_db, x, y, tile_id, world)
			set_at(layer_db, x, y, tile_id)
			
			-- also update world_data
			if world then
				-- update colliders in world data
				local colliders = self:get_colliders_at(world.level.world_data, x, y)
								
				-- remove old colliders
				for i, collider in ipairs(colliders) do
					world.physics_world:remove(collider)
					table.remove(colliders, i)
				end
				
				-- recalculate new colliders
				local collision_class = world.level.world_data.collision_cb(tile_id)
				add_collider(world.level.world_data, collision_class, x, y, world)
				
				-- TODO: only remove+recalculate colliders if type changed
			end
		end
		
		-- replace the tile_id at x,y with new_tile_id
		function tilemap:replace_tileid_at(x, y, tile_id, new_tile_id, world)
			for i, layer_db in ipairs(self.tile_layers) do
				if tile_id == self:get_at_layer(layer_db, x, y) then
					self:set_at_layer(layer_db, x, y, new_tile_id, world)
				end
			end
		end
		
		-- return the tile id at the layerdb x,y
		function tilemap:get_at_layer(layer_db, x, y)
			local r,g,b,a = layer_db:get_pixel(x,y)
			return r
		end
		
		-- get the collider entries in the world data that match the coordinates
		function tilemap:get_colliders_at(world_data, x,y)
			local colliders = {}
			for i, collider in ipairs(world_data) do
				if (collider.x == x*tileset.tile_w) and (collider.y == y*tileset.tile_h) then
					table.insert(colliders, collider)
				end
			end
			return colliders
		end
		
		-- get the tile at x,y from each layer
		function tilemap:get_at(x,y)
			local tiles = {}
			for i, layer_db in ipairs(tile_layers) do
				local tileid = self:get_at_layer(layer_db, x, y)
				table.insert(tiles, tileid)
			end
			return tiles
		end
		
		-- draw a single layer starting at x,y
		function tilemap:draw_layer(target_db, layer_db, x, y, tile_subst_table)
			tile_layers_dirty[layer_db] = false
			-- the layer_db contains a pixel for each tile_id in the layer.
			for source_y=0, layer_db:height()-1 do
				for source_x=0, layer_db:width()-1 do
					
					local r,g,b,a = layer_db:get_pixel(source_x, source_y)
					if r ~= 0 then
						if tile_subst_table and tile_subst_table[r] then
							tileset.draw_tile(target_db, x+source_x*tileset.tile_w, y+source_y*tileset.tile_h, tile_subst_table[r])
						else
							tileset.draw_tile(target_db, x+source_x*tileset.tile_w, y+source_y*tileset.tile_h, r)
						end
					end
				end
			end
		end
		
		
		-- generate a world_data segment for a level from a layer_db
		function tilemap:generate_world_data_layer(layer_db, collision_cb)
			local world_data = {}
			
			for source_y=0, max_h-1 do
				local cline = {}
				for source_x=0, max_w-1 do
					local tile = self:get_at_layer(layer_db, source_x, source_y)
					local collision_class = collision_cb(tile, source_x, source_y)
					add_collider(world_data, collision_class, source_x, source_y)
				end
			end
			
			return world_data
		end
		
		
		-- calculate the collision rectangles from the tilemap and the collision map
		function tilemap:generate_level(collision_cb)
			local level = {
					spawn_x = 0,
					spawn_y = 0,
					spawn_velocity_x = 0,
					spawn_velocity_y = 0,
			}
			local world_data = {}

			for i, layer_db in ipairs(tile_layers) do
				t_merge(world_data, self:generate_world_data_layer(layer_db, collision_cb))
			end
			
			world_data.collision_cb = collision_cb
			level.world_data = world_data
			
			return level
		end
		
		-- draw all layers
		function tilemap:draw(target_db, x, y)
			for i,layer_db in ipairs(tile_layers) do
				self:draw_layer(target_db, layer_db, x, y)
			end
		end
		
		-- draw updates to a (new) buffer table
		function tilemap:draw_to_buffers(buffers, tile_subst_table)
			
			if self.dirty then
				for i,layer_db in ipairs(tile_layers) do
					tile_layers_dirty[layer_db] = true
				end
				self.dirty = false
			end
			
			local buffers = buffers or {}
			for i,layer_db in ipairs(tile_layers) do
				if (not buffers[i]) or tile_layers_dirty[layer_db] then
					local start = time.realtime()
					local target_db = ldb.new(max_w * tileset.tile_w, max_h * tileset.tile_h)
					target_db:clear(0,0,0,0)
					self:draw_layer(target_db, layer_db, 0,0, tile_subst_table)
					buffers[i] = target_db
					tile_layers_dirty[layer_db] = false
					break
					-- print("redraw took:", (time.realtime()-start)*1000)
				end
			end
		
			return buffers
		end
		
		return tilemap
	end
	
	
	-- load assets
	function stage:load_assets(assets)
		local assets_by_name = {}
		for i, asset in ipairs(assets) do
			assets_by_name[asset.name] = asset
			if asset.type == "img" then
				-- load img in the right format into a new drawbuffer
				local img_db
				if asset.file:sub(-4) == ".bmp" then
					img_db = ldb.bitmap.decode_from_file_drawbuffer("img/" .. asset.file)
				elseif asset.file:sub(-4) == ".ppm" then
					img_db = ldb.ppm.decode_from_file_drawbuffer("img/" .. asset.file)
				elseif asset.file:sub(-4) == ".raw" then
					local width = assert(asset.width)
					local height = assert(asset.height)
					local f = assert(io.open("img/" .. asset.file, "rb"))
					local c = f:read("*a")
					f:close()
					img_db = ldb.new(width, height)
					img_db:load_data(c)
				else
					print("Trying to load unknown image format using imlib2:", asset.file)
					img_db = ldb.imlib.from_file("img/" .. asset.file)
				end
				assert(img_db)
				if asset.apply_transparency_color then
					self:apply_transparency_color(img_db, unpack(asset.apply_transparency_color))
				end
				if asset.crop then
					img_db = self:crop(img_db, unpack(asset.crop))
				end
				
				asset.db = img_db
			elseif asset.type == "font" then
				-- get the font source drawbuffer by the assets by name
				local font_db = assert(assets_by_name[asset.db_name].db)
				local char_w = assert(tonumber(asset.char_w))
				local char_h = assert(tonumber(asset.char_h))
				
				asset.font = ldb.font.from_drawbuffer(font_db, char_w, char_h, nil, tonumber(asset.scale))
			elseif asset.type == "tileset" then
				-- load a tileset
				local tile_db = assert(assets_by_name[asset.db_name].db)
				local tile_w = assert(tonumber(asset.tile_w))
				local tile_h = assert(tonumber(asset.tile_h))
				
				local tileset = ldb.tileset.new(tile_db, tile_w, tile_h)
				
				asset.tileset = tileset
			elseif asset.type == "tiled_map" then
				-- check if file exists
				local json = require("cjson")
				local map_json_f = assert(io.open(asset.file, "rb"))
				local map = json.decode(map_json_f:read("*a"))
				map_json_f:close()
				local tileset = assert(assets_by_name[asset.tileset_name].tileset)
				asset.tileset = tileset
				asset.tilemap = self:tilemap_from_tiled_json(map, tileset)
				
			end
		end
		
		assets.by_name = assets_by_name
		return assets
	end


	-- check input devices, call appropriate callbacks
	function stage:_input()
		for i, input_dev in ipairs(input_devs) do
			local dev, config, handler = unpack(input_dev)
			local ev = dev:read()
			while ev do
				handler(ev, config)
				ev = dev:read()
			end
		end
		
		-- if we have a sdl2 window, check for events
		if sdl_window then
			local ev = sdl_window:pool_event()
			if ev and ev.type == "quit" then
				self.run = false
			elseif ev then
				handle_sdl_event(ev)
			end
		end
	end
	
	
	-- check if a key is pressed
	function stage:key_is_down(key)
		return key_state[key]
	end
	
	
	-- set or delete an input callback
	function stage:set_input_callback(key, callback)
		if callback then
			input_callbacks[key] = callback
		else
			input_callbacks[key] = nil
		end
	end
	
	
	-- run until the stage stops
	function stage:_loop()
		local last_update = time.realtime()
		while self.run do
			-- get delta time, call update callback
			local dt = time.realtime() - last_update
			last_update = time.realtime()
			
			local remaining_time = self.config.output.target_dt - dt
			if remaining_time > (3/1000) then
				time.sleep(remaining_time-(2/1000))
			end
			
			self:update(dt)
			
			self:_input()
			self:draw(out_db)
			
			-- scale drawbuffer if necesarry
			local scaled = scale_db(out_db)
			
			-- output updated buffer
			output(scaled)
			
			
		end
	end


	-- create a new world, including the physics handling
	function stage:new_world(level, player)
		local world = {}
		world.level = level
		
		-- store the physics world
		world.physics_world = bump.newWorld()
		
		-- add each collider from the level world data
		for i, entry in ipairs(level.world_data) do
			if entry.type == "collider" then
				world.physics_world:add(entry, entry.x, entry.y, entry.w, entry.h)
			end
		end
		
		-- add player collider
		world.physics_world:add(player, player.x+player.offset_x, player.y+player.offset_y, player.width, player.height)
		
		-- (debug) draw the colliders
		function world:draw(db, scroll_x, scroll_y)
			for i, entry in ipairs(level.world_data) do
				local screen_x, screen_y = entry.x + scroll_x, entry.y + scroll_y
				db:set_box(screen_x, screen_y, entry.w, entry.h, 0,255,0,255)
			end
		end
		
		-- add a collider to the world
		function world:add_entry(entry)
			world.physics_world:add(entry, entry.x, entry.y, entry.w, entry.h)
			table.insert(world_data, entry)
		end
		
		return world
	end


	-- start the stage, run the loop till termination
	function stage:start(_sdl_window)
		if _sdl_window then
			print("start: got old _sdl_window", _sdl_window)
			sdl_window = _sdl_window
		end
		
		open_output()
		
		stage.config = config
		self:init()
		self.run = true
		self:_loop()
		
		-- loop has terminated, call cleanup
		self:stop()
	end


	--stop the stage, making
	function stage:stop()
		self.run = false
		if sdl_window then
			-- sdl_window:close()
			-- sdl_window = nil
		end
		
		-- todo: clean up input and framebuffer as well for stage change
		
	end


	-- change the stage to another stage
	function stage:change_stage(new_stage_name, restart)
		-- stop the current stage
		self:stop()
		
		-- load the new stage and start it
		local new_stage = Engine.new(require(new_stage_name), config)
		new_stage:start(sdl_window)
		
		-- should we restart the starge if the new stage terminates?
		if restart then
			self:start(sdl_window)
		end
	end
	
	
	return stage
end

return Engine
