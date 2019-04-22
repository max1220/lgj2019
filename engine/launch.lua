#!/usr/bin/env luajit
--package.path = "./?.lua;./?/init.lua;" .. package.path
--package.cpath = "./?.so;" .. package.cpath

local engine = require("engine")
local config = require("config")

-- load the entry point from the config
local entry = require("menu")
local inst = engine.new(entry, config)

-- start the instance
inst:start()
