return {
	output = {
		type = "sdl2fb", -- braile, blocks, sdl2fb, fb=/dev/fb0
		bpp24 = true, -- for braile/blocks: output in 24bpp or in 216-colors
		threshold = 30, -- for braile: set the threshold value for a pixel to be drawn using braile character
		center = false,
		width = 160,
		height = 120,
		scale = 5, -- required width, height will double
		target_dt = 1/60, -- if the FPS is higher than this, insert some sleeps to reduce the CPU load
		always_night = false -- Night mode
	},
	input = {},
	fonts = {
		cga8 = {
			bmp = "fonts/cga8.bmp",
			char_w = 8,
			char_h = 8,
			alpha_color = {0,0,0},
			scale = 1
		},
		cga8_lg = {
			bmp = "fonts/cga8.bmp",
			char_w = 8,
			char_h = 8,
			alpha_color = {0,0,0},
			scale = 2
		},
	},
}
