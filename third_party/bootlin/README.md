# third_party/bootlin

The GNU cross-toolchain for the XiOne AAMP build: Bootlin
`armv7-eabihf--glibc--stable-2022.08-1` (gcc 11.3 / glibc 2.35, hard-float, new
C++11 string ABI). The tree is fetched by the `xione_bootlin_toolchain` repo rule
in `//MODULE.bazel` — `//bazel/repo_rules:bootlin_toolchain.bzl`, an
`http_archive` in all but name (URL + sha256) plus the ld-script fixup below —
with `toolchain.BUILD.bazel` overlaid into the fetched repo as its `BUILD` file.

Both targets here are tagged `manual`: each names a label inside the fetched repo,
so leaving them in wildcard expansion made `bazel build //...` fetch a ~500 MB
Linux-x86_64 archive on every host, macOS included, for targets that are skipped
as incompatible anyway.

- `BUILD.bazel` — an `alias` to the fetched tree and the `toolchain(...)`
  registration for `//bazel/platforms:xione`.
- `toolchain.BUILD.bazel` (in the fetched repo) — defines the `cc_toolchain`
  and its `gcc_toolchain_config` next to the toolchain's own `bin/` and `lib/`,
  because that config emits package-relative paths.

## Why Bootlin

AAMP's CMake build expects a specific GNU cross-toolchain
(`arm-buildroot-linux-gnueabihf`, gcc 11.3 / glibc 2.35 / new C++11 ABI) matched
to the device, and `cmake/xione-armhf.cmake` is written for it. This is the same
toolchain `scripts/setup-xione-container.sh` installs into the container build;
fetching it as a sha256-pinned `http_archive` is what lets the Bazel build run
with no container and no manual setup step.

**Linux-x86_64 exec only.** Bootlin ships x86_64 host binaries, so the cross
build cannot run on an arm64 Mac exec host — `exec_compatible_with` pins linux +
x86_64, and Mac devs go through CI or a Linux container (matching how
`scripts/build-xione.sh` works today).

## Why a registered `cc_toolchain` is required

`rules_foreign_cc`'s `cmake()` resolves `@bazel_tools//tools/cpp:toolchain_type`
for the target platform **at analysis time** — before CMake ever runs — so with
no `cc_toolchain` registered for `:xione`, `//:aamp` fails with
"no toolchain found". The CMake toolchain file does **not** substitute for it.
`register_toolchains("//third_party/bootlin:xione_cc_toolchain")` in
`//MODULE.bazel` provides it.

## `gcc_toolchain_config`

The `cc_toolchain` uses the config at `//bazel/toolchain:gcc_toolchain.bzl`.
Making it work for an external-repo toolchain needed three fixes:

- relative `cxx_builtin_include_directories` are prepended with the toolchain's
  `workspace_root` so they resolve under `external/<repo>/`;
- each builtin dir is also emitted as a relative `-isystem` flag, so the
  compiler reports headers via matching relative paths instead of
  sandbox-absolute ones (otherwise every system header trips "absolute path
  inclusion");
- `-no-canonical-prefixes` on **compile only** — the reason for it is entirely
  about how the compile step reports builtin header dirs, and adding it to the
  link action changed zig link outputs for no benefit (see the comment on
  `_NO_CANONICAL_FLAGS`); the Bootlin config adds gcc-only
  `-fno-canonical-system-headers` and an optional `--sysroot`.

## Relocatable ld scripts

Bootlin's `ld` does not prepend the active `--sysroot` to a linker script's
absolute `GROUP` paths (not even its own default sysroot), so
`GROUP ( /lib/libc.so.6 … )` escaped to the host x86_64 libc. The fetch rewrites
those paths to `=`-prefixed form, so `ld` prepends whichever sysroot is active.

Exactly one script in this toolchain needs it, `usr/lib/libc.so`;
`lib/libgcc_s.so` is an ld script too but names its members relatively. The rewrite
is done in Starlark (`ctx.read`/`ctx.file` over the `*.so` files, found with
`path.readdir()`) rather than by shelling out, so the fetch stays host-tool-free
and works from a macOS client — the previous `sed -i -E` did not. It fails loudly
if it finds nothing to rewrite, because an unrelocated script does not error at
link time, it silently resolves against the host libc.

`//third_party/xione_sysroot`'s `assemble_sysroot` applies the same rewrite to the
merged tree.

## Updating

Bump the `xione_bootlin_toolchain` URL + sha256 in `//MODULE.bazel`. If the
compiler version moves, re-check the device ABI match (hard-float VFP,
`_GLIBCXX_USE_CXX11_ABI=1`, glibc floor) — and note the fetch will fail if the ld
scripts moved, which is the intended prompt to re-check this section.
