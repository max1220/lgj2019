#!/bin/bash
CWD=$(pwd)
export LUA_PATH="$CWD/?.lua;$CWD/?/init.lua;$CWD/engine/?.lua"
export LUA_CPATH="$CWD/?.so"

cd engine
./launch_braile.lua
