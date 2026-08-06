"""deb_sysroot — assemble a cross-compile sysroot from pinned Debian `.deb`s.

Downloads each `.deb` in a JSON manifest (pinned by snapshot.debian.org URL +
sha256), extracts its `data.tar.*` into a merged `sysroot/` tree, and exposes
that tree via an overlay BUILD file. This is the hermetic realisation of the
no-harvest XiOne sysroot: headers + `.pc` + link-stand-in `.so`s straight from
Debian armhf packages, no device harvest, no proprietary binaries.

A `.deb` is an `ar` archive whose `data.tar.{zst,xz,gz}` holds the filesystem
payload, and Bazel's extractor understands both layers — so unwrapping needs no
host binutils: one `ctx.extract` for the ar members, a second for the payload.
This rule uses **no host tools at all** — only `ctx.download`, `ctx.extract`,
`ctx.read` and `ctx.file`, the last two via
//bazel/repo_rules:ld_scripts.bzl, which makes the tree's GNU ld scripts
sysroot-relative. The multiarch fixups that bridge Debian's layout to the Bootlin gcc
live in //bazel/rules:xione_sysroot.bzl instead, because they need *relative*
symlinks: a repo rule cannot produce one (`ctx.symlink` writes absolute links,
which point into the local Bazel cache and do not survive rules_foreign_cc
copying the tree), while `ctx.actions.declare_symlink` can.

See //third_party/xione_sysroot/README.md ("Configure scope") for how the
manifest's package set was derived and validated.
"""

load(":ld_scripts.bzl", "relocate_ld_scripts")

_DATA_TARBALLS = ["data.tar.zst", "data.tar.xz", "data.tar.gz", "data.tar"]

# libdash is cross-built (bitmovin stable_3_0 + RDK patches), not a Debian
# package, but AAMP's configure does pkg_check_modules(libdash). Ship a stub
# `.pc` so configure resolves; the real lib is staged at build time.
_LIBDASH_PC = """\
prefix=/usr
libdir=${prefix}/lib/arm-linux-gnueabihf
includedir=${prefix}/include/libdash
Name: libdash
Description: stub .pc (libdash is cross-built and staged separately)
Version: 3.0
Cflags: -I${includedir}
Libs: -L${libdir} -ldash
"""

# AAMP's find_package(Threads) emits the misspelled `-lpthreads` (plural) under
# this cross toolchain. Rather than patch the fork, alias it: a linker script
# pointing at the real pthread stub + libc. On glibc 2.35 the pthread_* symbols
# live in libc, so shared-lib symbol resolution defers to runtime. The GROUP
# paths resolve once the Bootlin glibc is overlaid alongside this tree at build
# time (they live under the sysroot's /lib).
#
# Written with plain absolute paths; relocate_ld_scripts below rewrites them to
# `=`-prefixed form, the same treatment any ld script arriving in a .deb gets.
_LIBPTHREADS_SO = """\
/* GNU ld script — alias for the -lpthreads AAMP's find_package(Threads) emits. */
OUTPUT_FORMAT(elf32-littlearm)
GROUP ( /lib/libpthread.so.0 /lib/libc.so.6 )
"""

def _deb_sysroot_impl(ctx):
    debs = json.decode(ctx.read(ctx.attr.manifest))
    for d in debs:
        deb = "_debtmp/" + d["name"]
        ctx.download(url = d["url"], output = deb, sha256 = d["sha256"])

        # Bazel's own extractor understands the `ar` container a .deb is, so
        # unwrapping needs no host binutils: this yields debian-binary,
        # control.tar.* and data.tar.* alongside the .deb.
        ctx.extract(archive = deb, output = "_debtmp")
        data = None
        for name in _DATA_TARBALLS:
            if ctx.path("_debtmp/" + name).exists:
                data = name
                break
        if not data:
            fail("deb_sysroot: no data.tar.* found in {}".format(d["name"]))
        ctx.extract(archive = "_debtmp/" + data, output = "sysroot")

        # Clear the scratch dir before the next .deb so its control/data/deb
        # files don't collide with the next package's.
        ctx.delete("_debtmp")

    # libdash stub .pc + its include dir placeholder.
    ctx.file("sysroot/usr/lib/arm-linux-gnueabihf/pkgconfig/libdash.pc", _LIBDASH_PC)
    ctx.file("sysroot/usr/include/libdash/.keep", "")

    # -lpthreads alias (see _LIBPTHREADS_SO).
    ctx.file("sysroot/usr/lib/arm-linux-gnueabihf/libpthreads.so", _LIBPTHREADS_SO)

    # Make every ld script in the tree sysroot-relative, the alias above included.
    # Done here rather than over the merged tree at build time so the property is a
    # fetch-time invariant of both sysroot sources; a .deb that ever ships its own
    # ld script (libc6-dev would) is covered without anything downstream noticing.
    relocate_ld_scripts(ctx, "sysroot")

    ctx.template("BUILD.bazel", ctx.attr.build_file)

deb_sysroot = repository_rule(
    implementation = _deb_sysroot_impl,
    attrs = {
        "manifest": attr.label(
            mandatory = True,
            allow_single_file = [".json"],
            doc = "JSON list of {pkg, version, name, url, sha256} deb records to fetch and merge.",
        ),
        "build_file": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "Overlay BUILD file exposing the assembled sysroot/ tree.",
        ),
    },
)
