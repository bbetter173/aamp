# third_party/ethanlog

EthanLog client library — the RDK/Sky container logging shim AAMP links against
when built with `CMAKE_USE_ETHAN_LOG=ON`. The source is **fetched from upstream
at fetch time** (no vendored copy); this package only carries the Bazel build.

## Why fetch it

The XiOne AAMP build previously harvested `libethanlog.so.3` off a live
device and hand-authored a stub `ethanlog.h`. Both are avoidable: the source
is public and tiny (one `.c`, one header, only libc/POSIX includes), so we
build it hermetically instead. This removes one device-harvested proprietary
binary and the header stub in a single step.

## Provenance

- **Upstream:** [`rdkcentral/Dobby`](https://github.com/rdkcentral/Dobby),
  `plugins/EthanLog/client/lib`
- **Commit:** `375caa0577dbdc712675b3bafb5fa126c4c7adc9`
- **License:** Apache-2.0 (Copyright 2020 Sky UK) — see file headers.

The two files are downloaded (sha256-pinned) by the `@ethanlog_src` repo rule
(`//bazel/repo_rules:ethanlog_src.bzl`, invoked in `//MODULE.bazel`) — nothing
is copied into this tree:

| `@ethanlog_src` target | Upstream path |
|---|---|
| `ethanlog.c` | `plugins/EthanLog/client/lib/source/ethanlog.c` |
| `include/ethanlog.h` | `plugins/EthanLog/client/lib/include/ethanlog.h` |

## Build contract

The output shared library **must** carry soname `libethanlog.so.3` — the
fork's `cmake/FindEthanLog.cmake` resolves the dependency via
`find_library(NAMES ethanlog libethanlog.so.3 libethanlog)`, and the runtime
device provides `libethanlog.so.3`. The built `.so` is staged into
`//third_party/xione_sysroot:aamp_sysroot` for that `find_library` to resolve.

## Build status / toolchain note

In the XiOne build, `libethanlog.so.3` is produced by the `cc_binary` here and
compiled + linked by the **registered Bootlin cc_toolchain**
(`//third_party/bootlin:xione_cc_toolchain`). The target is
`target_compatible_with [armv7, linux]`, so when it is pulled into
`//third_party/xione_sysroot:aamp_sysroot` under
`--platforms=//bazel/platforms:xione`, toolchain resolution selects Bootlin and
`gcc_toolchain_config` applies `--sysroot` (keeping the link off the host's
x86_64 libc). `ethanlog.c` is pure C over libc + raw syscalls, so the C++ ABI is
irrelevant. The resulting `.so` is an ELF32 ARM object, staged into the sysroot
for `cmake/FindEthanLog.cmake`. AAMP's own CMake does not compile ethanlog; it
only links against the staged `.so`.

`ethanlog.c` needs `-D_GNU_SOURCE` (set in `copts`) for `TEMP_FAILURE_RETRY` and
`SYS_gettid`. It is the only standalone `cc_*` target in this repo, so it is also
what exercises `gcc_toolchain_config`'s builtin-include-dir handling
(`//bazel/toolchain:gcc_toolchain.bzl`) — see that file's comments on
`-isystem` and `--sysroot`.

## Updating

Point `@ethanlog_src` at a new Dobby commit in `//MODULE.bazel` and refresh the
two `*_sha256` values (and the commit hash above). There is no local patching;
if a change is ever needed, it must go upstream or become a documented patch.
