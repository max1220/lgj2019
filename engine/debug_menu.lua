local ldb = require("lua-db")


local function debug_menu_new(entrys)
	local menu = {}
	menu.select = 1
	
	menu.font = ldb.font.
	
	menu.width = 400
	menu.height = 
	menu.bg_color = {0.1, 0.1, 0.1, 1}
	menu.fg_color = {0.7, 0.1, 0.1, 1}
	menu.entrys = entrys or {}

	function menu:add_entry(title, callback)
		local entry = {
			title = title,
			callback = callback
		}
		table.insert(self.entrys, entry)
	end

	function menu:update(dt)
	
	end

	function menu:draw(db, x,y)
		db:clear(0,0,0,255)
		font:draw_string()
	end

	function menu:up()
		self.select = math.max(self.select-1, 1)
	end
	function menu:down()
		self.select = math.min(self.select+1, #self.entrys)
	end
	function menu:enter()
		local entry = assert(menu.entrys[self.select])
		if entry and entry.callback then
			entry:callback()
		end
	end

	return menu
end

return debug_menu_new
