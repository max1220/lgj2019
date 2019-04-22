#!/usr/bin/env luajit
local engine = require("engine")
local config = require("config")

-- load the entry point from the config
local entry = require("menu")
local inst = engine.new(entry, config)

-- start the instance
inst:start()
