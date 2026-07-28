# third_party/xione_sysroot

The **no-harvest** XiOne sysroot for the AAMP cross-build. It is assembled
entirely from pinned Debian armhf `.deb`s (via the `deb_sysroot` repo rule) plus
the Bootlin toolchain's glibc — **no device SSH harvest, no proprietary
binaries, no frozen S3 tarball**. The repo rule *is* the hermetic realisation of
what the AAMP fork's `build-xione-sysroot.sh` did imperatively.

- `xione-debs.json` — the pinned deb manifest (URL + sha256, from
  `snapshot.debian.org`) consumed by `//bazel/repo_rules:deb_sysroot.bzl`.
- `sysroot.BUILD.bazel` — overlay `BUILD` for the fetched `@xione_sysroot` repo.
- `BUILD.bazel` — `assemble_sysroot` targets (`base_sysroot`, `aamp_sysroot`)
  that merge the deb tree + Bootlin glibc + built `//third_party/ethanlog`,
  `//third_party/jsc`, and libdash into the single `XIONE_SYSROOT` dir.

## Why no harvest

The fork's build harvested runtime `.so`s off a live device over SSH, including
proprietary Sky/RDK libs. The goal here is to **harvest nothing**: satisfy each
dependency from a pinned deb, an in-tree build, upstream source, or a link stub,
and only fall back to harvesting where a no-harvest build genuinely fails. It
never did — so the SSH step and `add-wpe-to-sysroot.sh` are gone, and the
licensing question of redistributing device binaries is moot.

| Dependency class | How it is satisfied |
|---|---|
| Open-source libs (gstreamer, glib, libxml2, cjson, openssl, curl, uuid, systemd, zlib, icu) | Pinned Debian armhf `.deb`s — headers, `.pc`, and link-time `.so` |
| `libethanlog.so.3` | Built from upstream source — `//third_party/ethanlog` |
| `libabr`/`libmetrics`/`libsubtec`/player interfaces | Built in-tree by AAMP (`CMAKE_INBUILT_AAMP_DEPENDENCIES=ON`, `EXTERNAL_PLAYER_INTERFACE` off) |
| WPEWebKit / JSC (jsbindings only) | Freestanding link stub — `//third_party/jsc` |
| libdash | Cross-built (`//third_party/libdash`, see its README) and staged into the sysroot |

## The deb `.so` is a link-time stand-in only

The deb `.so`s are **never shipped or run** — at runtime the loader binds to the
*device's* copy. The linker records `DT_NEEDED` as the bare soname
(`libcurl.so.4`, not `…so.4.8.0`), so:

- The deb's own glibc version is irrelevant (a bookworm `.so` links fine against
  a device at glibc 2.35), which is exactly why harvesting for soname-exactness
  is unnecessary.
- **The one real matching rule: pin deb version ≤ device version.** The linker
  resolves symbol *references* from the deb `.so`; if the deb exports a symbol
  the older device lib lacks, you get a runtime "symbol not found". gstreamer is
  pinned from bullseye (`1.18.4` ≤ device `1.18.5`) precisely for this — bookworm's
  `1.22` is too new. Re-check any lib whose deb is newer than the device (curl was
  the one to verify).
- **Durability:** pins come from `snapshot.debian.org` (version + date), not
  `ftp.debian.org/.../pool`, which drops superseded versions.
- **Fallback:** for any lib where version-matching is awkward, a generated ELF
  symbol stub (as used for WPE/JSC) is fully hermetic and sidesteps matching —
  at the cost of losing the deb's real headers/`.pc`, so debs stay the default.

## Configure scope (the shopping list)

AAMP's own configure was run out-of-Bazel against an **empty** sysroot with the
production flags (`CMAKE_INBUILT_AAMP_DEPENDENCIES=ON`, `CMAKE_SYSTEMD_JOURNAL=ON`,
`CMAKE_USE_ETHAN_LOG=ON`, `CMAKE_WPEWEBKIT_JSBINDINGS=ON`,
`CMAKE_TELEMETRY_2_0_REQUIRED=OFF`, `CMAKE_BUILD_KOTLIN_ENABLED=OFF`) to derive
the authoritative dependency set:

- **Direct at configure time** (`pkg_check_modules`, aborts if absent — an empty
  stub `.pc` with the right `Version` is enough to *pass configure*):
  `gstreamer-1.0` (`>=1.18.0`), `gstreamer-app-1.0`, `gstreamer-video-1.0`,
  `libxml-2.0`, `openssl`, `libcjson`, `uuid`, `libcurl`, `libdash`,
  `wpe-webkit-1.1` (jsbindings; satisfied by `//third_party/jsc`), and `EthanLog`
  via `find_package` (satisfied by `//third_party/ethanlog`).
- **Transitive at build/link**, pulled by the real deb `.pc`s' `Requires`:
  `glib-2.0`, `gobject-2.0`, `gio-2.0`, `gstreamer-base-1.0`, `zlib`. These must
  ship in the real sysroot even though the empty-stub configure never named them.
- **`libsystemd` — link-only, no `.pc` check:** hardcoded `-lsystemd` gated on
  `CMAKE_SYSTEMD_JOURNAL`. Sysroot needs `libsystemd.so`.
- **Not reached under these flags** (no sysroot entry): `gl` (OpenGL), `glew`,
  `gtest`, `gmock`, and glib/gobject as *direct* deps — renderer/test components
  not built for `libaamp` + `libaampjsbindings`.

`xione-debs.json` pins the 9 direct `-dev` debs, their full transitive `.pc`
closure (glib/gobject/gio/gstbase, pcre2/ffi/orc/unwind/dw/elf/lzma), `libsystemd`,
zlib, and icu — 34 debs in total.

## Sysroot bridges (baked into `deb_sysroot` / `assemble_sysroot`)

The Bootlin gcc is **not multiarch-aware** and its `ld` mishandles absolute
linker-script paths, so the merged tree carries several fixes so builds need no
extra flags:

- **Relocatable ld scripts.** Bootlin's `ld` does not prepend the active
  `--sysroot` to a linker script's absolute `GROUP` paths, so
  `GROUP ( /lib/libc.so.6 … )` escaped to the host x86_64 libc. The glibc ld
  scripts are rewritten to `=`-prefixed paths (in the Bootlin fetch `patch_cmds`
  and in `assemble_sysroot`) so `ld` prepends whichever sysroot is active.
- **Multiarch `-L` / include bridge.** `--sysroot` only searches
  `<sysroot>/usr/lib` and `/lib`, not the `arm-linux-gnueabihf` multiarch subdir
  where the libs live. The multiarch `-L` is force-appended in the CMake
  toolchain file; `usr/include/arm-linux-gnueabihf/*` is mirrored into
  `usr/include` so bare `#include <curl/curl.h>` resolves.
- **`libz.so` symlink** in `usr/lib` — CMake `FindZLIB` searches `<sysroot>/usr/lib`,
  not the multiarch subdir.
- **`libpthreads.so` linker-script alias** — AAMP's `find_package(Threads)` emits
  the misspelled `-lpthreads`; aliased sysroot-side rather than patching the sources.
- **icu** (`libicu-dev`/`libicu72`) — bookworm's libxml2 is ICU-enabled, so
  `libxml/encoding.h` pulls `unicode/ucnv.h` at compile time (invisible to
  configure).

Every *functional* fix stays sysroot/toolchain-side, so the AAMP sources are
untouched — only `cmake/` gained the cross-toolchain file and `FindEthanLog.cmake`.

## Gating

`base_sysroot`/`aamp_sysroot` and the `deb_sysroot` fetch are
`target_compatible_with = ["//bazel/constraints:xione-stb"]`, so a host
`bazel build //...` skips them as incompatible and the 36-package deb fetch only
happens under `--platforms=//bazel/platforms:xione`.

## Alternatives — `rules_distroless` (not adopted)

The repo already uses `rules_distroless` (`@rules_distroless//apt`), which fetches
and extracts Debian `.deb`s hermetically with a resolver-generated lockfile — no
host `ar`, no hand-maintained `xione-debs.json`. It was prototyped as a
replacement and **worked mechanically** (an `apt.yaml` of the ~18 `-dev` packages
resolved the full armhf closure and extracted with no host tools).

It was **not adopted** because its per-package targets are **transitive** — they
carry each package's entire runtime `Depends` closure (`libcurl4-openssl-dev` → 32
layers, `libglib2.0-dev` → 73), which unavoidably pulls Debian's own **glibc/gcc**
(`libc6-dev`, `libstdc++6`, …) into the sysroot. Those Debian glibc 2.36 headers
then clash with the **Bootlin glibc 2.35** the cross-toolchain owns (e.g.
`'__wmemcpy_chk' was not declared`), breaking the libdash compile. `rules_distroless`
is built for OCI images, where the full closure is what you want; a cross-compile
sysroot is the opposite — the toolchain owns libc/libstdc++, so the deb set must be
a **curated, libc-excluded subset**, which is exactly what `deb_sysroot`'s
hand-picked, non-transitive manifest encodes. Making distroless fit would mean
re-deriving that leaf set by hand for no net maintenance win.

The custom rule's one-time cost — a host `ar` — has since been removed: Bazel's own
extractor unwraps the `.deb` container, so `deb_sysroot` needs no binutils at all.
That removes the last argument distroless had here.
