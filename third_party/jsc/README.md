# JavaScriptCore / WPE link stub (XiOne AAMP jsbindings)

`libaampjsbindings.so` links against WPEWebKit only for the **classic
JavaScriptCore C API** (`<JavaScriptCore/JavaScript.h>` — `JSObjectRef`,
`JSContextRef`, `JSValueRef`, `JSStringRef`, …), never the WPE/WebKit browser
APIs. That C API is closed and ABI-stable. So the build needs neither WPEWebKit
source (a Yocto-scale build) nor the device's prebuilt `libWPEWebKit` — only the
JSC headers and an armv7hf `.so` that carries the device soname and exports the
JSC C-API symbols. At runtime the `DT_NEEDED` (`libWPEWebKit-1.1.so.0`) binds to
the real library already present on the device.

This directory replaces the SSH-harvested `libWPEWebKit-1.1.so.0.2.17` and
`libwpe-1.0.so.1.9.5` (`add-wpe-to-sysroot.sh` in the AAMP fork) with hermetic,
device-free artifacts. `libwpe` drops out entirely: it was only in the sysroot
because the *real* `libWPEWebKit` has a `DT_NEEDED` on it; the stub has no such
dependency, and the real one is pulled transitively on-device at runtime.

**Caveat.** This holds only while jsbindings stays within the JSC C API. If it
ever calls WPE/WebKit APIs beyond it (view, injected-bundle, …), the symbol list
must grow to match. Because `@jsc_deb` provides JSC-only headers, such a change
surfaces as a compile error early rather than a silent link/runtime failure.

## Contents

- `wpe-webkit-1.1.pc` — stub pkg-config satisfying `pkg_check_modules(WPE_WEBKIT
  wpe-webkit-1.1)`.
- `BUILD.bazel` — generates a trivial stub `.c` from the exported-symbol list and
  links it (freestanding, `-nostdlib`) into `libWPEWebKit-1.1.so.0` with the
  matching soname.

The **headers** and the **symbol list** are no longer vendored here — they are
sourced at fetch time from pinned Debian debs by `@jsc_deb`
(`//bazel/repo_rules:jsc_deb.bzl`): `@jsc_deb//:headers` and
`@jsc_deb//:wpe-webkit.syms`.

## Provenance (`@jsc_deb`)

Both come from the Debian **WebKitGTK** packages, `webkit2gtk` version
**2.50.6-1~deb12u2** (bookworm, armhf), pinned by snapshot.debian.org URL +
sha256 in `//MODULE.bazel`:

| Purpose | Package |
|---|---|
| C-API headers (`usr/include/webkitgtk-4.1/JavaScriptCore/*.h`) | `libjavascriptcoregtk-4.1-dev` |
| Symbol list, via `nm -D` on the real runtime `.so` | `libjavascriptcoregtk-4.1-0` |

**Why WebKitGTK and not WPE:** the device runs WPE, but WPE's own
`libWPEWebKit-1.1.so.0` exports **only** the glib `jsc_*`/`webkit_*` APIs — *not*
the classic `JSObjectRef` C API (verified against the Debian `libwpewebkit-1.1-0`
`.so`). WebKitGTK's `libjavascriptcoregtk` is the classic-C-API library, so it is
the only distro source for these symbols. The C API is ABI-frozen, so the
device's WPE exports the same set at runtime; the exact package version is not
load-bearing.

## Regenerating the symbol list

Automatic: `@jsc_deb` runs `nm -D --defined-only` on `libjavascriptcoregtk-4.1.so`
and keeps every `JS*`/`kJS*` export (~170 symbols, computed at fetch time — a
superset of what jsbindings references; extra exports are harmless for a link
stub). To bump the WebKitGTK
version, update the two `jsc_deb(...)` pins in `//MODULE.bazel`.

## SONAME caveat

The stub's soname `libWPEWebKit-1.1.so.0` is the device soname (the versioned
file on-device is `libWPEWebKit-1.1.so.0.2.17`). jsbindings records it as its
`DT_NEEDED`, so it must match the real library on the device for runtime
resolution. **Re-check if the device image bumps WPEWebKit.**

## Validation

`readelf` on the built `libWPEWebKit-1.1.so.0` should show: `Class ELF32`,
`Machine ARM`, `SONAME libWPEWebKit-1.1.so.0`, no `NEEDED` entries, and the
`@jsc_deb//:wpe-webkit.syms` symbols as defined dynamic symbols. `readelf -d` on
the built `libaampjsbindings.so` should show a single WebKit dependency,
`libWPEWebKit-1.1.so.0`, and no `libwpe`.
