# Circuit Run

A desktop Haxeon maze-chase sample inspired by the small Sokol-based game
[pacman.zig](https://github.com/floooh/pacman.zig). Circuit Run uses its own
maze and draws every tile and actor from colored rectangles in one GPU draw
call. The GLSL files in `src/shaders/` are embedded at compile time.
NativeKit supplies the window, keyboard events, and GPU backend.

From the repository root on Linux with an X11 display and OpenGL 3.3:

```sh
scripts/haxeon run --project packages/gpu/examples/circuit-run/haxeon.json
```

If the launcher reports a stale HashLink runtime, run `scripts/build-native.sh`
from the repository root and retry.

Use the arrow keys to steer the teal runner. Collect every node while avoiding
the pink drone, which follows the shortest open route to you. The board turns
green when you clear it and burgundy when the drone catches you. Press **R** to
restart, **M** to toggle sound, or **Esc** to quit. The Haxeon UI strip above
the maze shows the node count and round result, with buttons for sound and
restart.

NativeKit Audio plays short synthesized cues when you collect a node, get
caught, or clear the maze. The sample generates the clips at startup and can
continue silently if the playback device is unavailable.

The project manifest builds NativeKit with GPU and audio support and Haxeon UI
through CMake. It uses
the checkout's Haxeon compiler and HashLink runtime. See the
[GPU package setup](../../README.md) for NativeKit checkout instructions.

The game advances in fixed 120 Hz steps and accepts buffered turns at tile
centers. NativeKit schedules rendering through the window's frame clock.
