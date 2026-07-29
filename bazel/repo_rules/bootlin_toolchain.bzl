"""bootlin_toolchain — fetch the Bootlin armv7-eabihf toolchain with relocatable ld scripts.

An `http_archive` plus one fixup, expressed as a repository rule so the fixup needs
no host tools. As `patch_cmds` it was a `find | grep | sed -i -E` pipeline, which
had two problems: `sed -i` with no argument is GNU-only (BSD/macOS sed reads the
next argument as a backup suffix, so `-E` became the suffix and the expression a
filename), and fetches always run on the *local* host — even under `--config=rbe` —
so a macOS client failed inside the fetch. It also made XIONE-BUILD.md's claim that
the repository rules use no host tools at all untrue.

The fixup itself: this SDK's `ld` does not prepend the active `--sysroot` to a
linker script's absolute `GROUP`/`INPUT` paths, not even for its own default
sysroot, so `GROUP ( /lib/libc.so.6 … )` escapes to the host x86_64 libc ("file
format not recognized") on every link against this sysroot. Prefixing each absolute
path with `=` makes `ld` prepend whichever sysroot is in effect. In this toolchain
exactly one script needs it (`usr/lib/libc.so`); `lib/libgcc_s.so` is an ld script
too but names its members relatively, so it is left alone.

//bazel/rules:xione_sysroot.bzl applies the same rewrite to the merged AAMP sysroot.
"""

_MARKER = "GNU ld script"

# The Bootlin sysroot bottoms out around 8 levels (usr/include/c++/11.3.0/…).
# Starlark has neither recursion nor `while`, so the walk is a bounded
# breadth-first loop; a tree deeper than this fails rather than being silently
# half-scanned.
_MAX_DEPTH = 16

def _relocate_line(line):
    """Prefix absolute paths on a GROUP/INPUT/AS_NEEDED line with `=`.

    Equivalent to the old `sed -E '/GROUP|INPUT|AS_NEEDED/ s#([ (])/#\\1=/#g'`: an
    absolute path preceded by a space or an open paren. Idempotent, because once
    rewritten the text reads " =/" and no longer contains " /".
    """
    if "GROUP" not in line and "INPUT" not in line and "AS_NEEDED" not in line:
        return line
    return line.replace(" /", " =/").replace("(/", "(=/")

def _so_files(root):
    """Every `*.so` under `root`, breadth-first.

    Only `*.so` is read: a GNU ld script always stands in for a shared library, and
    reading all ~2300 files of the sysroot (including multi-megabyte `.a` archives)
    to grep for a marker would be gratuitous.
    """
    found = []
    frontier = [root]
    for _ in range(_MAX_DEPTH):
        if not frontier:
            break
        children = []
        for d in frontier:
            for entry in d.readdir():
                if entry.is_dir:
                    children.append(entry)
                elif entry.basename.endswith(".so"):
                    found.append(entry)
        frontier = children
    if frontier:
        fail("bootlin_toolchain: sysroot is deeper than {} levels, so ld scripts may be unscanned".format(_MAX_DEPTH))
    return found

def _bootlin_toolchain_impl(ctx):
    ctx.download_and_extract(
        url = ctx.attr.url,
        sha256 = ctx.attr.sha256,
        stripPrefix = ctx.attr.strip_prefix,
    )

    rewritten = []
    for path in _so_files(ctx.path(ctx.attr.sysroot)):
        content = ctx.read(path)
        if _MARKER not in content:
            continue
        fixed = "\n".join([_relocate_line(line) for line in content.split("\n")])
        if fixed != content:
            ctx.file(path, fixed, executable = False)
            rewritten.append(str(path))

    # Load-bearing. If nothing is rewritten, every cross link silently resolves
    # against the host libc instead of failing, so a toolchain bump that moves or
    # renames the scripts must be loud here rather than at link time.
    if not rewritten:
        fail(
            "bootlin_toolchain: no GNU ld script under {} needed relocating. Either the ".format(ctx.attr.sysroot) +
            "layout changed or the scripts are already relative; verify before removing this check, " +
            "since unrelocated absolute GROUP paths escape to the host libc.",
        )

    ctx.template("BUILD.bazel", ctx.attr.build_file)

bootlin_toolchain = repository_rule(
    implementation = _bootlin_toolchain_impl,
    attrs = {
        "url": attr.string(mandatory = True, doc = "Toolchain tarball URL."),
        "sha256": attr.string(mandatory = True, doc = "Tarball sha256."),
        "strip_prefix": attr.string(mandatory = True, doc = "Leading directory to strip from the archive."),
        "sysroot": attr.string(
            default = "arm-buildroot-linux-gnueabihf/sysroot",
            doc = "Target sysroot path within the extracted tree, scanned for ld scripts.",
        ),
        "build_file": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "Overlay BUILD file for the fetched toolchain tree.",
        ),
    },
)
