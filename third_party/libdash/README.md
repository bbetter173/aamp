# third_party/libdash

Cross-build of **bitmovin libdash `stable_3_0` + the 12 RDK patches** for the
XiOne, via `rules_foreign_cc` driving libdash's own CMake. Produces `libdash.so`,
which AAMP links against (`#include "libdash/IMPD.h"`). Consumed by the AAMP
cross-build through the merged `//third_party/xione_sysroot:aamp_sysroot`.

- `BUILD.bazel` — the `cmake()` target.
- `libdash.BUILD.bazel` — overlay `BUILD` for the fetched `@libdash` source: a
  `filegroup` for the source tree plus header filegroups (`public_headers`,
  `source_headers`).

## Patches (sourced from the AAMP fork)

The 12 RDK patches originate in `meta-rdk-ext`
(`recipes-multimedia/libdash/libdash`, branch `rdk-next`) — the same set AAMP's
own `install_libdash.sh` applies. They are vendored in this repo under
`scripts/libdash-patches/`, and the `@libdash` `http_archive` in `//MODULE.bazel`
applies them from there at fetch time — so a hermetic build never has to clone
`meta-rdk-ext`. Bazel's built-in patch is stricter than GNU `patch` and rejects
the patches' fuzz/format, so the archive uses `patch_tool = "patch"`.

## Build specifics

- **Toolchain:** this repo's `cmake/xione-armhf.cmake`, against the
  base sysroot (deb tree + Bootlin glibc, `//third_party/xione_sysroot:base_sysroot`).
- **Ninja generator** — uses the registered hermetic ninja toolchain and avoids
  `rules_foreign_cc` bootstrapping GNU Make from source (which fails to compile
  against the host glibc headers).
- **`targets = ["dash"]` only** — libdash's install/default build also builds a
  test binary that needs libcap/libidn2 (not in the sysroot); building just the
  shared lib skips it.
- **`CMAKE_POLICY_VERSION_MINIMUM = 3.5`** — libdash's `cmake_minimum_required`
  predates CMake's supported floor.
- **`CPATH` multiarch bridge** — the Bootlin gcc is not multiarch-aware, so
  `--sysroot` doesn't search the `arm-linux-gnueabihf` subdir where `curl/curl.h`
  and friends live; `CPATH` adds it for both C and C++ without diverging the
  shared toolchain file.

## Header staging

libdash's `CMakeLists` only `install(TARGETS dash)` — it never installs headers.
So the `public_headers` (`libdash/include/*.h`) and `source_headers`
(`libdash/source/**/*.h`, which AAMP includes directly, e.g.
`libdash/xml/Node.h`) are staged into `aamp_sysroot` straight from the source
tree, preserving subdirectory structure, so AAMP's
`#include "libdash/IMPD.h"` resolves via the default sysroot include path.

## Gating

`target_compatible_with = ["//bazel/constraints:xione-stb"]` and `tags =
["manual"]` — it is only ever reached through `//:aamp`, so it
never enters a host `bazel build //...` wildcard.

## Updating

Bump the bitmovin `libdash` `http_archive` (url + sha256 + `strip_prefix`) in
`//MODULE.bazel`. To change the patch set, edit `scripts/libdash-patches/` and
update the `patches` list in `//MODULE.bazel` to match.
