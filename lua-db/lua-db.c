#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <math.h>

#include <stdint.h>
#include <fcntl.h>
#include <string.h>

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#include "lua.h"
#include "lauxlib.h"

#include "lua-db.h"


#define VERSION "2.0"

#define LUA_T_PUSH_S_N(S, N) lua_pushstring(L, S); lua_pushnumber(L, N); lua_settable(L, -3);
#define LUA_T_PUSH_S_I(S, N) lua_pushstring(L, S); lua_pushinteger(L, N); lua_settable(L, -3);
#define LUA_T_PUSH_S_S(S, S2) lua_pushstring(L, S); lua_pushstring(L, S2); lua_settable(L, -3);
#define LUA_T_PUSH_S_CF(S, CF) lua_pushstring(L, S); lua_pushcfunction(L, CF); lua_settable(L, -3);


static int ldb_tostring(lua_State *L) {
	// return a string with info about the drawbuffer to Lua
	drawbuffer_t *db;
	CHECK_DB(L, 1, db)

	lua_pushfstring(L, "Drawbuffer: %dx%d", db->w, db->h);

	return 1;
}

static int ldb_width(lua_State *L) {
	// return the width of a drawbuffer to Lua
	drawbuffer_t *db;
	CHECK_DB(L, 1, db)

	lua_pushinteger(L, db->w);

	return 1;
}

static int ldb_height(lua_State *L) {
	// return the height of a drawbuffer to Lua
	drawbuffer_t *db;
	CHECK_DB(L, 1, db)

	lua_pushinteger(L, db->h);

	return 1;
}

static int ldb_bytelen(lua_State *L) {
	// return length of pixel data in bytes to Lua
	drawbuffer_t *db;
	CHECK_DB(L, 1, db)

	lua_pushinteger(L, db->len);

	return 1;
}

static int ldb_dump_data(lua_State *L) {
	// dump the pixel data from the drawbuffer as lua string.
	// keep in mind that \000 in Lua strings is valid, and this function
	// will return such strings if a pixel color value is 0.
	// Pixel format if r,g,b,a(left-to-right, top-to-bottom), see lua-db.h
	drawbuffer_t *db;
	CHECK_DB(L, 1, db)

	lua_pushlstring(L, (char *) db->data, db->len);

	return 1;
}

static int ldb_load_data(lua_State *L) {
	// Load a string containing data for this drawbuffer.
	// Format see ldb_dump_data. Must str must be w*h*4 characters long.
	drawbuffer_t *db;
	CHECK_DB(L, 1, db)
	
	size_t str_len = 0;
	const char* str = lua_tolstring(L, 2, &str_len);
	
	if (str_len == db->len) {	
		for (size_t i=0; i<(str_len/4); i++) {
			db->data[i] = (pixel_t) { str[i*4], str[i*4+1], str[i*4+2], str[i*4+3] };
		}
		lua_pushboolean(L, 1);
		return 1;
	}
	lua_pushnil(L);
	lua_pushstring(L, "Invalid length");
	
	return 2;
}

static int ldb_close(lua_State *L) {
	// close an instance of a drawbuffer, calling free() on the allocated
	// memory, if needed. Automatically called by the Lua GC
	drawbuffer_t *db;
	CHECK_DB(L, 1, db)

// we only need to free if the data is not in the userdata object itself
#ifndef ENABLE_DATA_IN_USERDATA
	free(db->data);
#endif

	return 0;
}

static int ldb_clear(lua_State *L) {
	// clear the drawbuffer in a uniform color
	drawbuffer_t *db = (drawbuffer_t *)lua_touserdata(L, 1);
	CHECK_DB(L, 1, db)

	int r = lua_tointeger(L, 2);
	int g = lua_tointeger(L, 3);
	int b = lua_tointeger(L, 4);
	int a = lua_tointeger(L, 5);

	if ( (r < 0) || (g < 0) || (b < 0) || (a < 0) || (r > 255) || (g > 255) || (b > 255) || (a > 255) ) {
		lua_pushnil(L);
		lua_pushstring(L, "invalid r,g,b,a value");
		return 2;
	}
	
	// fast path for clear in uniform color
	if ((r==g)&&(g==b)&&(b==a)) {
		memset(db->data, r, db->len);
		lua_pushboolean(L, 1);
		return 1;
	}

	for (int y = 0; y < db->h; y=y+1) {
		for (int x = 0; x < db->w; x=x+1) {
				db->data[y*db->w+x] = (pixel_t) {.r=r, .g=g, .b=b, .a=a};
		}
	}

	lua_pushboolean(L, 1);
	return 1;
}

static int ldb_pixel_function(lua_State *L) {
	// call a Lua function for each pixel in the drawbuffer,
	// setting the pixel to the return value of the Lua function.
	drawbuffer_t *db;
	CHECK_DB(L, 1, db)

	int x,y;
	pixel_t p;

	for (y=0; y<db->h; y=y+1) {
		for (x=0; x<db->w; x=x+1) {
			p = db->data[y*db->w+x];

			// duplicate function
			lua_pushvalue(L, 2);

			// push 6 function arguments
			lua_pushinteger(L, x);
			lua_pushinteger(L, y);
			lua_pushinteger(L, p.r);
			lua_pushinteger(L, p.g);
			lua_pushinteger(L, p.b);
			lua_pushinteger(L, p.a);

			// execute
			if (lua_pcall(L, 6, 4, 0)) {
				return luaL_error(L, "pixel function failed!\n");
			}

			// update p
			p.a = lua_tointeger(L, -1);
			p.b = lua_tointeger(L, -2);
			p.g = lua_tointeger(L, -3);
			p.r = lua_tointeger(L, -4);

			// remove arguments
			lua_pop(L, 4);

			// Write back to buffer
			db->data[y*db->w+x] = p;
		}
	}

	lua_pushboolean(L, 1);
	return 1;
}

static int ldb_draw_to_drawbuffer(lua_State *L) {
	// draws a drawbuffer to another drawbuffer
	drawbuffer_t *origin_db;
	CHECK_DB(L, 1, origin_db)

	drawbuffer_t *target_db;
	CHECK_DB(L, 2, target_db)

	int target_x = lua_tointeger(L, 3);
	int target_y = lua_tointeger(L, 4);

	int origin_x = lua_tointeger(L, 5);
	int origin_y = lua_tointeger(L, 6);

	int w = lua_tointeger(L, 7);
	int h = lua_tointeger(L, 8);
	
	int scale = lua_tointeger(L, 9);

	int cx;
	int cy;
	int sx;
	int sy;
	
	pixel_t p;


	if (scale <= 1) {
		// draw unscaled
		for (cy=0; cy < h; cy=cy+1) {
			for (cx=0; cx < w; cx=cx+1) {
				p = DB_GET_PX(origin_db, (cx+origin_x), (cy+origin_y))
				if (p.a > 0) {
					// draw unscaled
					DB_SET_PX(target_db, (cx+target_x), (cy+target_y), p)
				}
			}
		}
		
	} else {
		// draw scaled
		for (cy=0; cy < h; cy=cy+1) {
			for (cx=0; cx < w; cx=cx+1) {
				p = DB_GET_PX(origin_db, (cx+origin_x), (cy+origin_y))
				if (p.a > 0) {
					p = DB_GET_PX(origin_db, (cx+origin_x), (cy+origin_y))
					for (sy=0; sy < scale; sy=sy+1) {
						for (sx=0; sx < scale; sx=sx+1) {
							DB_SET_PX(target_db, (cx*scale+sx+target_x), (cy*scale+sy+target_y), p)
						}
					}
				}
			}
		}
		
	}

	lua_pushboolean(L, 1);
	return 1;
}

static int ldb_get_pixel(lua_State *L) {
	// return the r,g,b,a values for the pixel at x,y in the drawbuffer
	drawbuffer_t *db;
	CHECK_DB(L, 1, db)

	int x = lua_tointeger(L, 2);
	int y = lua_tointeger(L, 3);

	pixel_t p = DB_GET_PX(db, x,y);

	lua_pushinteger(L, p.r);
	lua_pushinteger(L, p.g);
	lua_pushinteger(L, p.b);
	lua_pushinteger(L, p.a);

	return 4;
}

static int ldb_set_pixel(lua_State *L) {
	// set the pixel at x,y to r,g,b,a in the drawbuffer
	drawbuffer_t *db;
	CHECK_DB(L, 1, db)

	int x = lua_tointeger(L, 2);
	int y = lua_tointeger(L, 3);
	int r = lua_tointeger(L, 4);
	int g = lua_tointeger(L, 5);
	int b = lua_tointeger(L, 6);
	int a = lua_tointeger(L, 7);

	if ( (r < 0) || (g < 0) || (b < 0) || (a < 0) || (r > 255) || (g > 255) || (b > 255) || (a > 255) ) {
		lua_pushnil(L);
		lua_pushstring(L, "invalid r,g,b,a value");
		return 2;
	}
	

	pixel_t p = {.r=r, .g=g, .b=b, .a=a};

	DB_SET_PX(db, x,y,p)

	lua_pushboolean(L, 1);
	return 1;
}

static int ldb_set_rect(lua_State *L) {
	// fill the rectangle x,y,w,h in the drawbuffer with the color r,g,b,a
	drawbuffer_t *db;
	CHECK_DB(L, 1, db)

	int x = lua_tointeger(L, 2);
	int y = lua_tointeger(L, 3);
	int w = lua_tointeger(L, 4);
	int h = lua_tointeger(L, 5);
	int r = lua_tointeger(L, 6);
	int g = lua_tointeger(L, 7);
	int b = lua_tointeger(L, 8);
	int a = lua_tointeger(L, 9);

	if ( (r < 0) || (g < 0) || (b < 0) || (a < 0) || (r > 255) || (g > 255) || (b > 255) || (a > 255) ) {
		lua_pushnil(L);
		lua_pushstring(L, "invalid r,g,b,a value");
		return 2;
	}

	int cx;
	int cy;

	pixel_t p = {.r=r, .g=g, .b=b, .a=a};

	for (cy=y; cy < y+h; cy=cy+1) {
		for (cx=x; cx < x+w; cx=cx+1) {
			DB_SET_PX(db, cx, cy, p)
		}
	}

	lua_pushboolean(L, 1);
	return 1;
}

static int ldb_set_box(lua_State *L) {
	// draw the outline of the rectangle x,y,w,h with r,g,b,a on the drawbuffer
	drawbuffer_t *db;
	CHECK_DB(L, 1, db)

	int x = lua_tointeger(L, 2);
	int y = lua_tointeger(L, 3);
	int w = lua_tointeger(L, 4);
	int h = lua_tointeger(L, 5);
	int r = lua_tointeger(L, 6);
	int g = lua_tointeger(L, 7);
	int b = lua_tointeger(L, 8);
	int a = lua_tointeger(L, 9);

	if ( (r < 0) || (g < 0) || (b < 0) || (a < 0) || (r > 255) || (g > 255) || (b > 255) || (a > 255) ) {
		lua_pushnil(L);
		lua_pushstring(L, "invalid r,g,b,a value");
		return 2;
	}

	pixel_t p = {.r=r, .g=g, .b=b, .a=a};

	for (int cy=y; cy < y+h-1; cy=cy+1) {
		DB_SET_PX(db, x, cy, p)
		DB_SET_PX(db, (x+w-1), cy, p)
	}
	for (int cx=x; cx < x+w; cx=cx+1) {
		DB_SET_PX(db, cx, y, p)
		DB_SET_PX(db, cx, (y+h-1), p)
	}

	lua_pushboolean(L, 1);
	return 1;
}

static int ldb_set_line(lua_State *L) {
	// draw a line from x0,y0 to x1,y1 in r,g,b,a on the drawbuffer
	drawbuffer_t *db;
	CHECK_DB(L, 1, db)

	int x0 = lua_tointeger(L, 2);
	int y0 = lua_tointeger(L, 3);
	int x1 = lua_tointeger(L, 4);
	int y1 = lua_tointeger(L, 5);

	int r = lua_tointeger(L, 6);
	int g = lua_tointeger(L, 7);
	int b = lua_tointeger(L, 8);
	int a = lua_tointeger(L, 9);

	if ( (r < 0) || (g < 0) || (b < 0) || (a < 0) || (r > 255) || (g > 255) || (b > 255) || (a > 255) ) {
		lua_pushnil(L);
		lua_pushstring(L, "invalid r,g,b,a value");
		return 2;
	}


	pixel_t p = {.r=r, .g=g, .b=b, .a=a};

	int dx = abs(x1-x0), sx = x0<x1 ? 1 : -1;
	int dy = abs(y1-y0), sy = y0<y1 ? 1 : -1;
	int err = (dx>dy ? dx : -dy)/2, e2;

	while(1) {
		DB_SET_PX(db, x0, y0, p)
		if (x0==x1 && y0==y1) {
			break;
		}
		e2 = err;
		if (e2 >-dx) {
			err -= dy;
			x0 += sx;
		}
		if (e2 < dy) {
			err += dx;
			y0 += sy;
		}
	}

	lua_pushboolean(L, 1);
	return 1;
}



static int l_new(lua_State *L) {
	// create a new drawbuffer instance of the specified width, height
	uint16_t w = lua_tointeger(L, 1);
	uint16_t h = lua_tointeger(L, 2);
	uint32_t len = w * h * sizeof(pixel_t);

	// see lua-db.h
	drawbuffer_t *db;

	// we can store the pixel data in a memory region allocated with
	// malloc, or store it directly in userdata memory. If we allocate
	// memory using malloc, we also need to free() it later. See ldb_close()
#ifdef ENABLE_DATA_IN_USERDATA
	// allocate a userdata with enough space for the pixel data
	db = (drawbuffer_t *)lua_newuserdata(L, sizeof(drawbuffer_t) + len);
	// db->data = (pixel_t *) db+len;
	// pixel data is at the end of the struct
	db->data = (pixel_t *) db + sizeof(*db);
#else
	db = (drawbuffer_t *)lua_newuserdata(L, sizeof(drawbuffer_t));
	db->data = (pixel_t *) malloc(len);
#endif

	db->w = w;
	db->h = h;
	db->len = len;


	if (db->data == NULL) {
		lua_pushnil(L);
		lua_pushstring(L, "Can't allocate memory!");
		return 2;
	}

	// this creates or pushes the metatable for a drawbuffer on the Lua
	// stack. Keep in mind that all drawbuffers have the same metatable,
	// so directly putting strings/numbers etc. in this table for each
	// drawbuffer does not work.
	if (luaL_newmetatable(L, "drawbuffer")) {

		lua_pushstring(L, "__index");
		lua_newtable(L);

		LUA_T_PUSH_S_CF("width", ldb_width)
		LUA_T_PUSH_S_CF("height", ldb_height)
		LUA_T_PUSH_S_CF("bytes_len", ldb_bytelen)

		LUA_T_PUSH_S_CF("get_pixel", ldb_get_pixel)
		LUA_T_PUSH_S_CF("set_pixel", ldb_set_pixel)
		LUA_T_PUSH_S_CF("set_rectangle", ldb_set_rect)
		LUA_T_PUSH_S_CF("set_box", ldb_set_box)
		LUA_T_PUSH_S_CF("set_line", ldb_set_line)
		LUA_T_PUSH_S_CF("clear", ldb_clear)
		LUA_T_PUSH_S_CF("draw_to_drawbuffer", ldb_draw_to_drawbuffer)
		LUA_T_PUSH_S_CF("pixel_function", ldb_pixel_function)
		LUA_T_PUSH_S_CF("close", ldb_close)
		LUA_T_PUSH_S_CF("dump_data", ldb_dump_data)
		LUA_T_PUSH_S_CF("load_data", ldb_load_data)

		lua_settable(L, -3);

		LUA_T_PUSH_S_CF("__gc", ldb_close)
		LUA_T_PUSH_S_CF("__tostring", ldb_tostring)
	}

	lua_setmetatable(L, -2);

	return 1;
}



// this handles the call to require("lua-db.lua_db").
// Lua removes the lua-prefix, and replaced non-ascii chars with _.
LUALIB_API int luaopen_db_lua_db(lua_State *L) {
	lua_newtable(L);

	LUA_T_PUSH_S_S("version", VERSION)
	LUA_T_PUSH_S_CF("new", l_new)

	return 1;
}
