# Third-party native code

## cgltf

- Upstream: <https://github.com/jkuhlmann/cgltf>
- Git submodule: `vendor/cgltf`, release tag `v1.15` at
  `360db1a95480fe102ae9c69b27c5d101167ff5ba`.
- License: MIT; full text at `vendor/cgltf/LICENSE`.
- Language: C99 single header, compiled once in `src/vendor.cpp`.

## ozz-animation

- Upstream: <https://github.com/guillaumeblanc/ozz-animation>
- Git submodule: `vendor/ozz-animation`, release tag `0.16.0` at
  `6cbdc790123aa4731d82e255df187b3a8a808256`.
- License: MIT; full text at `vendor/ozz-animation/LICENSE.md`.
- Language: C++17, linked statically into `animkit_core`.

Only the `ozz_base`, `ozz_animation`, `ozz_animation_offline`, and
`ozz_geometry` libraries are linked. The build turns off ozz's tools,
FBX and glTF importers, samples, howtos, and tests. AnimKit builds raw
skeletons and animations from cgltf data itself, so ozz's tinygltf-based
`gltf2ozz` tool is not used.

## stb_image

- Upstream: <https://github.com/nothings/stb>
- Git submodule: `vendor/stb` at `2c980bb59875b0d32144a71867fbdebb2f77cd20`.
- License: public domain or MIT, at the user's choice; text at the end of
  `vendor/stb/stb_image.h`.
- Only `stb_image.h` is compiled, restricted to PNG and JPEG
  (`STBI_ONLY_PNG`, `STBI_ONLY_JPEG`) in `src/vendor.cpp`.
