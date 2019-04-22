#!/bin/bash
cp -vr /home/max/stuff/engine/ .

cp -vr /home/max/stuff/lua-db .

cp -vr /home/max/stuff/lua-input .

cp -vu /home/max/stuff/lua-sdl2fb/sdl2fb.so .

cp -vu /home/max/stuff/lua-time/time.so .

cp -vu /home/max/stuff/cjson.so .

cp -vu /home/max/stuff/minilinux/buildroot/output/images/bzImage .

tar --exclude-vcs -cf ../lgj2019.tar ../lgj2019

cp ../lgj2019.tar .
