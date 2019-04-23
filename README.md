# lgj2019
Release files for the Linux Game Jam 2019 for my game, [robohobo](https://max1220.itch.io/robohobo)




# Usage
For basic usage on a normal system, just make sure you have luajit and SDL2
installed, and run:

	./launch_sdl.sh

You might also need to install liblua5.1-0, depending on your distribution.

You should see a SDL2 window open, with the game ready to play!

For the more advanced output modes, you might need extra permissions(for opening
/dev/input/event -devices, to get real keyboard events. You may also need the
launch script, and edit the default input device if your does not match.
The just run:

	./launch_braile.sh

You should see your terminal rendering the game in colored braile characters.
Because the game reads input events on such a low level, you
don't even need to have the terminal open or focused for it to register your
inputs. Keep that in mind.
