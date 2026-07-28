# XiOne cross-build

Hermetic Bazel cross-build of AAMP for the Sky XiOne (armv7 NEON hard-float,
glibc 2.35, new C++11 string ABI). Produces the nine shared libraries the device
needs, and publishes them as release tarballs for downstream consumers.

This sits **alongside** the CMake build. CMake remains the interface RDK
maintains and the only supported way to build AAMP for a host; Bazel exists here
only to drive that same CMake build reproducibly for one target, so CI can
publish artifacts with no device and no developer machine in the loop.

## Building

The target only builds for the XiOne, so you must pass the platform:

```sh
bazel build //:aamp --platforms=//bazel/platforms:xione
```

Outputs land in `bazel-bin/aamp/lib/`.

### Why the bare command fails

`//:aamp` is `target_compatible_with = ["//bazel/constraints:xione-stb"]` — it is
*incompatible* with your host platform, so naming it explicitly without the flag
fails at analysis:

```
ERROR: Target //:aamp is incompatible and cannot be built, but was explicitly requested.
```

That is expected, not a broken build. In a wildcard (`bazel build //...`) Bazel
**skips** incompatible targets instead of failing, so the heavy cross-build never
runs by accident and `//...` stays green with no `manual` tag needed.

### Host requirements

Linux x86_64. The Bootlin cross-compiler ships x86_64 host binaries only, so
`exec_compatible_with` pins linux + x86_64 — an arm64 Mac cannot be the exec
host. Also needs a host `pkg-config`, and `ln` for the sysroot's multiarch
symlinks. Notably it does **not** need host binutils: Bazel unwraps the `.deb`
containers itself, and ELF32 ARM objects are read with the cross `nm` from the
Bootlin toolchain.

## What gets built

Nine `.so`s, all ELF32 ARM hard-float:

| Library | Notes |
|---|---|
| `libaamp.so` | The player |
| `libaampjsbindings.so` | JS bindings, needs the WPE/JSC stub |
| `libplayergstinterface.so` | `middleware/` |
| `libplayerfbinterface.so` | `middleware/externals/` |
| `libplayerlogmanager.so` | `middleware/playerLogManager/` |
| `libplayerjsonobject.so` | `middleware/playerJsonObject/` |
| `libbaseconversion.so` | `middleware/baseConversion/` |
| `libmetrics.so` | `support/aampmetrics` |
| `libsubtec.so` | `subtec/` |

**All nine are required.** With `CMAKE_INBUILT_AAMP_DEPENDENCIES=ON` this branch
builds `middleware/` and `support/` as separate shared libraries, and
`libaamp.so` carries a `DT_NEEDED` on five of them. Shipping only `libaamp.so`
and `libaampjsbindings.so` produces a library that cannot load, because the
device's stock AAMP predates this split and does not provide them. This differs
from the older `xione-release` line, where the middleware was absorbed into a
monolithic `libaamp.so`.

## Design

**Consume the existing CMake build via `rules_foreign_cc`** — do not rewrite it
in native `cc_library` rules. AAMP is a large, upstream-tracking codebase, and
its CMake build (with `CMAKE_INBUILT_AAMP_DEPENDENCIES=ON` pulling in
`middleware/`, `support/aampabr`, `support/aampmetrics`, `tsb/`) is the interface
RDK maintains. Re-expressing it in Bazel rules would diverge and rot on every
upstream merge.

The `cmake()` target in `//BUILD.bazel` passes `cmake/xione-armhf.cmake` as
`CMAKE_TOOLCHAIN_FILE`, points `XIONE_TOOLCHAIN_DIR` / `XIONE_SYSROOT` at the
Bootlin toolchain and the merged sysroot, and reproduces
`scripts/build-xione.sh`'s flags. `install = False` (the project's
`cmake --install` pulls unbuilt test binaries); a `postfix_script` stages the
nine `.so`s.

The dependency closure is documented next to each piece:

- `//third_party/xione_sysroot` — the **no-harvest** deb sysroot
- `//third_party/bootlin` — the cross toolchain and `cc_toolchain`
- `//third_party/jsc` — the WPE/JSC link stub
- `//third_party/ethanlog` — the EthanLog build
- `//third_party/libdash` — the libdash cross-build

### No device in the build

`scripts/build-xione-sysroot.sh` (on `feat/xione-build-tooling`) assembles its
sysroot partly by harvesting ABI-exact `.so`s from a live XiOne over SSH. That
cannot run in CI and is not reproducible. `//third_party/xione_sysroot` replaces
it: headers, `.pc` files and link stand-in `.so`s come from 36 sha256-pinned
Debian armhf `.deb`s, with ethanlog and libdash built from pinned source and JSC
reduced to a generated link stub. No device, no proprietary binaries.

### Relationship to `scripts/build-xione.sh`

The `cache_entries` and `env` on the `cmake()` target mirror that script's
configure flags. It still works for local iteration inside the container; if you
change flags in one, mirror them in the other.

## Gotchas

**RPATH.** `rules_foreign_cc` bakes the build sandbox path into `DT_RPATH`. Left
unpatched, a bundled `libaampjsbindings.so` silently loads the *stock*
`/usr/lib/libaamp.so` and defeats the whole swap. `tools/release/stage_artifacts.sh`
runs `patchelf --set-rpath '$ORIGIN'` on every `.so`, so released tarballs are
already correct — build outputs straight out of `bazel-bin` are not.

**`JSC_INCDIR`.** Pre-seeded as a cache entry. `find_path()` cannot resolve it
under `CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY` because pkg-config already
returns a sysroot-absolute hint that then gets re-rooted. See the comment in
`//BUILD.bazel`.

**pkg-config is the host's.** Bootstrapping it from source builds a vendored
glib whose `goption.c` declares a variable named `bool` — a syntax error under
the C23 default of gcc >= 15. `PKG_CONFIG_SYSROOT_DIR` / `PKG_CONFIG_LIBDIR` pin
the host binary to the XiOne sysroot, so its own search defaults never
participate.

**Build cost.** `rules_foreign_cc` caches the whole CMake invocation as one
action, so any source change triggers a full AAMP rebuild. Expect ~20s warm,
minutes cold including fetches.

## Releasing

Tag `xione-v*` and push; `.github/workflows/xione-release.yml` builds, stages and
publishes a GitHub Release with the tarball and its sha256. See that workflow and
`tools/release/stage_artifacts.sh`.

Consumers pin the release tarball by URL + sha256 rather than building AAMP
themselves.

## On-device deploy

The box's kernel is aarch64 but its **RDK app userspace is 32-bit armv7**
(`/usr/lib/libaamp.so` is ELF32 `EM_ARM`) — this build matches; don't be misled
by `uname`. The rootfs is read-only squashfs, so libraries cannot be overwritten
in place; apps run as Dobby/OCI containers with their `.wgt` bind-mounted at
`/package`, and the swap works per-widget.

Swap recipe for `com.comcast.ripa` (the AAMP-hosting integrated player):

1. Stage the ripa widget dist into a build dir.
2. Copy the released `usr/lib/*.so` into the widget's `usr/lib/`. RPATH is
   already `$ORIGIN` if they came from a release tarball.
3. Add env `LIBAAMPJSBINDINGS_LIBRARY_PATH=/package/usr/lib/libaampjsbindings.so`.
4. Rezip the `.wgt` (files at archive root) and install.

**Software-catalogue sync purges dev apps.** The box periodically runs a softcat
sync that uninstalls any dev-installed app not in the remote catalogue and
deletes its metadata; afterwards reinstall succeeds (200) but launch fails ("not
found in catalogue"). Before deploying, over the `/settings` WebSocket JSON-RPC
endpoint (`ws://<ip>:8090/settings`) set `softcatdisableremoveapps=true` and
`softcatdisablefetch=true`, then (re)install; revert when done.

Verify load: `grep libaamp /proc/<WPEWebProcess-pid>/maps` shows
`/package/usr/lib/libaamp.so`, and `sha256sum` through
`/proc/<pid>/root/package/…` matches the shipped bytes. Verify playback:
`journalctl | grep integratedplayer.giveStatus` shows `state:"PLAYING"` with
`currentPositionSeconds` advancing.
