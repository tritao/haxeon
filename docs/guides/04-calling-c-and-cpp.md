# Calling a C or C++ library

Haxeon calls C and C++ code directly, without glue code you write by hand. You point it at a header; it reads the
header with Clang, writes a typed description of the library's functions and records (an HXI interface), and turns
that into Haxe functions and types you call like any other. The library itself is built with your own C and C++
toolchain through CMake, as part of the project's build.

In this guide you wrap a tiny C library and a small C++ class in a project and call them from Haxe. The finished
project is in [examples/04-calling-c-and-cpp/geometry-demo](examples/04-calling-c-and-cpp/geometry-demo/). It builds
and runs on Linux.

You need the C and C++ toolchain and CMake that [Get started](00-get-started.md) installs (`haxeon doctor` checks them),
and Clang as `clang` on `PATH` for the importer.

## The project

```
geometry-demo/
  haxeon.toml
  native/
    CMakeLists.txt          builds libgeometry
    geometry.c
    shapes.cpp
    include/geometry.h      the C API
    include/shapes.hpp      the C++ API
  ffi/
    geometry.ffi.json       how to import geometry.h
    shapes.ffi.json         how to import shapes.hpp
    geometry.hxmap          Haxe names for the C API
  src/Main.hx
```

Start with a program and add the directories:

```sh
haxeon create geometry-demo --template console
cd geometry-demo
mkdir -p native/include ffi
```

## The C library

The header is ordinary C. Three annotations, defined as macros at the top, tell the importer what C syntax cannot say:

```c
/* Annotations the Haxeon importer reads; a C compiler ignores them. */
#define GEO_HANDLE __attribute__((annotate("hxi:handle")))
#define GEO_HANDLE_DESTROY(symbol) __attribute__((annotate("hxi:handle_destroy")))
#define GEO_OWNED __attribute__((annotate("hxi:owned")))

/* Text passed as UTF-8. The importer maps this typedef, and only this one, to a Haxe String. */
typedef const char *hxi_utf8;

typedef struct geo_point {
	double x;
	double y;
} geo_point;

/* The distance between two points. */
double geo_distance(const geo_point *a, const geo_point *b);

/* Moves `point` by (dx, dy) in place. */
void geo_translate(geo_point *point, double dx, double dy);

/* The number of bytes in `text` before its terminating zero. */
int32_t geo_text_length(hxi_utf8 text);

/* A path the library keeps: a list of points, named by a handle. Zero is no path. */
typedef uint32_t geo_path GEO_HANDLE GEO_HANDLE_DESTROY(geo_path_destroy);

/* A new, empty path, or zero when no more paths fit. The caller destroys it. */
geo_path geo_path_create(void) GEO_OWNED;

/* Adds a copy of `point` to the end of `path`. */
void geo_path_add(geo_path path, const geo_point *point);

/* The length of the line through the path's points, in order. */
double geo_path_length(geo_path path);

void geo_path_destroy(geo_path path);
```

- A `char *` could be text in any encoding, owned by anyone, so the importer maps only the `hxi_utf8` typedef to a
  Haxe `String`.
- `geo_path` is a handle: a 32-bit number that names something the library owns. `GEO_HANDLE_DESTROY` names the function
  that releases one, and `GEO_OWNED` on `geo_path_create` says the caller owns the handle it returns.

The implementation, `native/geometry.c`, is plain C; copy it from the example project.

## Building the library

The library is a CMake project. A shared library is what Haxe code calls into at run time:

```cmake
cmake_minimum_required(VERSION 3.21)
project(geometry LANGUAGES C CXX)

add_library(geometry SHARED geometry.c shapes.cpp)
target_include_directories(geometry PUBLIC include)
target_compile_features(geometry PRIVATE cxx_std_20)
if(NOT WIN32)
  target_link_libraries(geometry PRIVATE m)
endif()
```

The `[native.cmake]` section of `haxeon.toml` tells the build where that project is, which target to build, and which
shared library it makes:

```toml
[native.cmake]
source = "native"
target = "geometry"
library = "geometry"
```

`library` is the name without the platform's prefix and suffix: `libgeometry.so` on Linux, `libgeometry.dylib` on macOS,
`geometry.dll` on Windows. `haxeon build` configures and builds the project with your toolchain, keeps the build between
runs, and puts the library where `haxeon run` finds it. For a library of a few files, `[native]` with `sources` and
`includeDirs` compiles them without a CMake project of your own; [MANIFEST.md](../reference/MANIFEST.md) lists both
forms.

## Importing the header

An import recipe says which header to read and what to call the result:

```json
{
  "version": 1,
  "name": "geometry",
  "language": "c",
  "header": "../native/include/geometry.h",
  "includes": ["../native/include"],
  "library": "geometry",
  "interface": "Geometry"
}
```

Paths in a recipe are relative to the recipe file. `library` is the shared library the functions are in, the one
`[native.cmake]` builds. `interface` names the Haxe module the functions land in. List the recipe in `haxeon.toml`:

```toml
[ffi]
imports = ["ffi/geometry.ffi.json", "ffi/shapes.ffi.json"]
projections = ["ffi/geometry.hxmap"]
```

The build runs the import whenever the recipe or the headers change. The result is plain text, so you can read what the
importer understood: it is at `build/host/native/geometry-demo/ffi/geometry/geometry.hxi`.

```hxi
interface Geometry @target("x86_64-linux-gnu") @library("geometry") {
	extern fn geo_distance(a: ptr<const<geo_point>>, b: ptr<const<geo_point>>) -> f64;
	extern fn geo_path_add(path: geo_path, point: ptr<const<geo_point>>) -> void;
	extern fn geo_path_create() -> geo_path @owned;
	...
	struct geo_point {
		x: f64;
		y: f64;
	}
	handle geo_path : u32 @destroy("geo_path_destroy");
}
```

A record's size and field offsets follow from its fields by the C rules for the target you build for, and the importer
checks them against Clang's, so a record has the layout the C code expects. A declaration the importer cannot bind safely (a variadic function, for one) is an error that names it, not a
guessed binding. `haxeon ffi import` runs the same import by hand, for a header outside a project:

```sh
haxeon ffi import --target=x86_64-linux-gnu --include=native/include --library=geometry --interface=Geometry --output=build/geometry.hxi native/include/geometry.h
```

## Haxe names

Without more, the Haxe functions keep their C names (`Geometry.geo_distance`). A projection map renames them for Haxe
without changing what is called:

```json
{
  "interface": "Geometry",
  "functionPrefix": "geo_",
  "functionCase": "camel",
  "typeNames": {
    "geo_point": "Point",
    "geo_path": "Path"
  }
}
```

`geo_path_create` becomes `Geometry.pathCreate` and `geo_point` becomes `Point`.

## Calling it

Import the interface's module, and call:

```haxe
import Circle;
import Geometry;

function main() {
	// Numbers and records: a Point is the C struct geo_point, laid out as C lays it out.
	var origin = new Point();
	var corner = new Point();
	corner.x = 3.0;
	corner.y = 4.0;
	Sys.println('distance: ${Geometry.distance(origin, corner)}');

	// A pointer parameter lets C change the record in place.
	Geometry.translate(corner, 1.0, 1.0);
	Sys.println('moved to: ${corner.x}, ${corner.y}');

	// Strings cross as UTF-8.
	Sys.println('bytes in "héllo": ${Geometry.textLength("héllo")}');

	// An owned handle: close() calls geo_path_destroy once, however often it is called.
	var path = Geometry.pathCreate();
	Geometry.pathAdd(path.borrow(), origin);
	Geometry.pathAdd(path.borrow(), corner);
	Sys.println('path length: ${Geometry.pathLength(path.borrow())}');
	path.close();
```

- `new Point()` makes a zeroed `geo_point` in memory Haxe manages. The `x` and `y` properties read and write its
  fields at the offsets C uses. Passed where C takes `geo_point *`, it is passed by address, so `geo_translate` changes it.
- A `String` argument is converted to UTF-8 for the length of the call.
- `pathCreate` returns an owner of the handle. `borrow()` gives the plain handle that the other functions take, and
  `close()` destroys it. Closing twice is harmless.

## A C++ class

C++ goes through the same importer, for a deliberate subset: classes, namespaces, enums and functions that need no
adapter code, selected by name. The class in `native/include/shapes.hpp`:

```cpp
namespace shapes {

class Circle {
public:
	explicit Circle(double radius) noexcept;
	~Circle() noexcept;

	double area() const noexcept;
	void scale(double factor) noexcept;

private:
	double radius_;
};

} // namespace shapes
```

Its recipe selects the class, asks for its constructor and destructor (`cxxLifetimes`), and for a Haxe class that wraps it
(`projection`):

```json
{
  "version": 1,
  "name": "shapes",
  "language": "c++",
  "profile": "direct",
  "header": "../native/include/shapes.hpp",
  "includes": ["../native/include"],
  "std": "c++20",
  "library": "geometry",
  "interface": "Shapes",
  "select": ["shapes::Circle"],
  "cxxLifetimes": true,
  "projection": true
}
```

The `direct` profile calls the compiled C++ functions themselves, so every method must be `noexcept`. For methods that
can throw, leave out `profile` and set `"cxxThunks": true`: the build then generates and compiles small C++ wrappers
that turn an exception into a Haxe exception.
The generated `Circle` class has `create()` for the constructor, the methods, and `close()` for the destructor:

```haxe
	// A C++ class: create() runs its constructor, close() its destructor.
	var circle = Circle.create(1.0);
	circle.scale(2.0);
	Sys.println('circle area: ${circle.area()}');
	circle.close();
}
```

## Run it

```sh
haxeon run
```

```text title="Output"
distance: 5
moved to: 4, 5
bytes in "héllo": 6
path length: 6.4031242374328485
circle area: 12.566370614359172
```

Change `geometry.c` and run again: the build recompiles the library, and a changed header is imported again.

## In a package

To share bindings between projects, put the same `[native.cmake]` and `[ffi]` sections in a package (a project without
an `entry`) and depend on it with `{ path = "../geometry" }` or from a registry. The first-party packages, `ui` among
them, are packaged this way. An app's runner builds every package's CMake project into the app's build, and its libraries
land beside the executable ([Shipping](05-shipping.md)). An app's runner builds only `[native.cmake]` packages, not
`[native]` with `sources`.

## Reference

- [C_HEADER_FFI.md](../reference/C_HEADER_FFI.md): the importer, the recipe and projection-map fields, the annotations
  (out-parameters, arrays, callbacks, byte buffers, spans), and the C++ profiles.
- [NATIVE_MEMORY.md](../reference/NATIVE_MEMORY.md): records declared in Haxe with a C layout (`@:value @:repr("C")`),
  raw pointers (`RawPtr<T>`) and arenas (`NativeArena`) for memory you manage yourself.
- [MANIFEST.md](../reference/MANIFEST.md): the `native` and `ffi` sections.
