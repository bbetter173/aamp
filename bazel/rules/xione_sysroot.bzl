"""assemble_sysroot — merge the deb sysroot, Bootlin glibc, and build-time
overlays into one XIONE_SYSROOT tree artifact for rules_foreign_cc.

AAMP's cmake/xione-armhf.cmake points CMAKE_SYSROOT at a single directory, so
the deb-derived tree (@xione_sysroot), the Bootlin glibc (headers/CRT/loader),
and any Bazel-built overlays (libethanlog, the WPE/JSC stub, libdash) have to be
physically merged. This rule emits a directory tree artifact that a cmake()
target consumes via `data`, with XIONE_SYSROOT pointing at its staged path.
"""

_MULTIARCH = "arm-linux-gnueabihf"

def _root_of(files, marker):
    """The directory path up to and including `marker`, from the first file."""
    p = files[0].path
    idx = p.find(marker)
    if idx == -1:
        fail("assemble_sysroot: marker {} not found in {}".format(marker, p))
    return p[:idx + len(marker)]

def _entries_under(files, prefix):
    """Sorted unique first path segments below `prefix`, from file paths."""
    seen = {}
    for f in files:
        if f.path.startswith(prefix):
            seen[f.path[len(prefix):].split("/")[0]] = True
    return sorted(seen)

def _has_file(files, path):
    """Whether the exact `path` is present in `files`."""
    for f in files:
        if f.path == path:
            return True
    return False

def _relative_link(ctx, dest, target):
    """An unresolved symlink artifact holding the *relative* link dest -> target.

    `declare_symlink` is the only primitive that produces a relative symlink with
    no host `ln`: repo rules cannot (`ctx.symlink` writes absolute links, which
    point into the local Bazel cache and dangle on any other runner), and a shell
    action would need `ln`. Bazel stages such an artifact as the symlink itself,
    so the assemble action places it with `cp -a`, which preserves link text
    verbatim.
    """
    link = ctx.actions.declare_symlink("{}_links/{}".format(ctx.attr.name, dest))
    ctx.actions.symlink(output = link, target_path = target)
    return link

def _stage_link(ctx, cmds, inputs, out, dest, target, replace = False):
    """Emit the commands staging a relative symlink artifact at `dest`."""
    link = _relative_link(ctx, dest, target)
    cmds.append("mkdir -p $(dirname {o}/{d})".format(o = out.path, d = dest))
    if replace:
        cmds.append("rm -f {o}/{d}".format(o = out.path, d = dest))
    cmds.append("cp -a {s} {o}/{d}".format(s = link.path, o = out.path, d = dest))
    inputs.append(link)

def _impl(ctx):
    out = ctx.actions.declare_directory(ctx.attr.name + "_tree")

    deb_files = ctx.files.deb_sysroot
    glibc_files = ctx.files.glibc
    deb_root = _root_of(deb_files, "/sysroot")
    glibc_root = _root_of(glibc_files, "/arm-buildroot-linux-gnueabihf/sysroot")

    cmds = [
        "set -euo pipefail",
        "mkdir -p {o}".format(o = out.path),
        # deb-derived tree (headers + .pc + link .so's)
        "cp -a {r}/. {o}/".format(r = deb_root, o = out.path),
    ]
    inputs = list(deb_files) + list(glibc_files)

    # Multiarch fixups: bridge Debian's layout to the Bootlin gcc, which (unlike a
    # Debian-native gcc) searches only <sysroot>/usr/{lib,include} and not the
    # arm-linux-gnueabihf/ subdirs the .debs use.
    #
    #  - mirror every multiarch include entry into usr/include, so bare
    #    `#include <curl/curl.h>` resolves for builds that don't go through
    #    pkg-config (notably libdash's own CMake);
    #  - expose libz.so at usr/lib/libz.so, where CMake's FindZLIB
    #    (PATH_SUFFIXES=lib) looks.
    #
    # Relative links (see _relative_link), so they stay valid through
    # rules_foreign_cc's copy of this tree and carry no host `ln`.
    #
    # Which names get mirrored is decided HERE, at analysis time, from the deb
    # filegroup — not by a shell loop over the assembled tree. Same outcome, but
    # the set is visible in the analysis graph, and the load-bearing ordering
    # below becomes a property of the inputs rather than of command order.
    #
    # ORDER IS LOAD-BEARING: the mirror must consider the deb tree ALONE. It only
    # links names that tree does not already have (`openssl` is the live case),
    # while the Bootlin glibc overlaid below adds real usr/include entries (sys/,
    # bits/, gnu/, …) that would collide. Deriving the set from deb_files alone
    # and staging before the glibc `cp -an` (no-clobber) reproduces the layout
    # these consumers were built against; a loop run after glibc would silently
    # link fewer names.
    deb_include = deb_root + "/usr/include/"
    have = _entries_under(deb_files, deb_include)
    for entry in _entries_under(deb_files, deb_include + _MULTIARCH + "/"):
        if entry not in have:
            _stage_link(
                ctx,
                cmds,
                inputs,
                out,
                "usr/include/" + entry,
                _MULTIARCH + "/" + entry,
            )

    if _has_file(deb_files, deb_root + "/usr/lib/" + _MULTIARCH + "/libz.so"):
        _stage_link(ctx, cmds, inputs, out, "usr/lib/libz.so", _MULTIARCH + "/libz.so")

    cmds.extend([
        # Bootlin glibc: headers, CRT/static libs, and the shared libs + loader
        "mkdir -p {o}/usr/include {o}/usr/lib {o}/lib".format(o = out.path),
        "cp -an {g}/usr/include/. {o}/usr/include/".format(g = glibc_root, o = out.path),
        "cp -an {g}/usr/lib/. {o}/usr/lib/".format(g = glibc_root, o = out.path),
        "cp -an {g}/lib/. {o}/lib/".format(g = glibc_root, o = out.path),
    ])

    # Individual overlay files placed at explicit destinations. A target may
    # expose several files (e.g. a rules_foreign_cc cmake() emits both an include
    # dir and lib/<name>.so); pick the one whose basename matches the
    # destination, falling back to the sole/first file.
    for target, dest in ctx.attr.overlay_files.items():
        tfiles = target.files.to_list()
        want = dest.rsplit("/", 1)[-1]
        matches = [f for f in tfiles if f.basename == want]
        f = matches[0] if matches else tfiles[0]
        cmds.append("mkdir -p $(dirname {o}/{d})".format(o = out.path, d = dest))
        cmds.append("cp -a {src} {o}/{d}".format(src = f.path, o = out.path, d = dest))
        inputs.append(f)

    # Whole-tree overlays (e.g. a header dir) cp'd under a destination prefix.
    # The source root is the path up to and including a marker segment; a tree
    # may override the default marker via overlay_tree_markers (keyed by the same
    # label) when its sources are rooted elsewhere (e.g. libdash's source/ vs
    # include/ headers, both destined for one usr/include/libdash tree).
    marker_by_label = {t.label: m for t, m in ctx.attr.overlay_tree_markers.items()}
    for target, dest in ctx.attr.overlay_trees.items():
        tfiles = target.files.to_list()
        marker = marker_by_label.get(target.label, ctx.attr.overlay_tree_marker)
        troot = _root_of(tfiles, "/" + marker)
        cmds.append("mkdir -p {o}/{d}".format(o = out.path, d = dest))
        cmds.append("cp -a {r}/. {o}/{d}/".format(r = troot, o = out.path, d = dest))
        inputs.extend(tfiles)

    # Relative symlinks (dest -> target), portable through staging. Declared as
    # symlink artifacts (see _relative_link); `replace` keeps the old `ln -sfn`
    # semantics of winning over anything an overlay already put there.
    for dest, target in ctx.attr.symlinks.items():
        _stage_link(ctx, cmds, inputs, out, dest, target, replace = True)

    # Make the glibc/deb GNU ld scripts relocatable. ld only auto-prepends the
    # active --sysroot to a linker script's absolute GROUP/INPUT paths when the
    # sysroot equals the toolchain's *built-in* default; a relocated sysroot
    # (this merged tree) leaves `GROUP ( /lib/libc.so.6 ... )` pointing at the
    # host, so every cross link escapes to the host x86_64 libc ("file format
    # not recognized"). Prefixing each absolute path with `=` forces ld to
    # prepend whatever --sysroot is in effect regardless of its default. Covers
    # the Bootlin libc.so and the deb libpthreads.so alias; the sed is scoped to
    # GROUP/INPUT/AS_NEEDED lines and is idempotent. The scripts arrive as
    # symlinks into read-only repos, so rewrite through a temp file and replace.
    cmds.append(
        "find {o}/lib {o}/usr/lib \\( -type f -o -type l \\) | while read -r f; do".format(o = out.path) +
        " if grep -qI 'GNU ld script' \"$f\" 2>/dev/null; then" +
        " sed -E '/GROUP|INPUT|AS_NEEDED/ s#([ (])/#\\1=/#g' \"$f\" > \"$f.relocfix\";" +
        " rm -f \"$f\"; mv \"$f.relocfix\" \"$f\"; fi; done",
    )

    ctx.actions.run_shell(
        outputs = [out],
        inputs = inputs,
        command = "\n".join(cmds),
        mnemonic = "AssembleSysroot",
        progress_message = "Assembling XiOne sysroot %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

assemble_sysroot = rule(
    implementation = _impl,
    attrs = {
        "deb_sysroot": attr.label(mandatory = True, doc = "Filegroup of the deb-assembled sysroot tree (@xione_sysroot//:sysroot)."),
        "glibc": attr.label(mandatory = True, doc = "Filegroup of the Bootlin target sysroot (glibc headers/CRT/loader)."),
        "overlay_files": attr.label_keyed_string_dict(allow_files = True, doc = "Individual files -> destination path within the sysroot."),
        "overlay_trees": attr.label_keyed_string_dict(allow_files = True, doc = "Whole filegroups -> destination prefix within the sysroot."),
        "overlay_tree_marker": attr.string(default = "include", doc = "Default path segment marking the root of overlay_trees sources."),
        "overlay_tree_markers": attr.label_keyed_string_dict(doc = "Per-tree override of overlay_tree_marker, keyed by the same label as overlay_trees."),
        "symlinks": attr.string_dict(doc = "Destination link path -> relative symlink target."),
    },
)
