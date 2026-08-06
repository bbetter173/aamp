"""relocate_ld_scripts — make a fetched sysroot's GNU ld scripts sysroot-relative.

Shared by the two repo rules that produce sysroot trees (`bootlin_toolchain` and
`deb_sysroot`), so the property holds at fetch time for both and the merged tree
//bazel/rules:xione_sysroot.bzl assembles inherits it rather than re-deriving it.

The problem: `ld` does not prepend the active `--sysroot` to a linker script's
absolute `GROUP`/`INPUT` paths — not even for the toolchain's own default sysroot —
so `GROUP ( /lib/libc.so.6 … )` resolves against the *host*, and on a cross link
that means the x86_64 libc ("file format not recognized"). Prefixing each absolute
path with `=` makes `ld` prepend whichever sysroot is in effect.

Doing this in Starlark rather than with `find | grep | sed` keeps the fetch phase
free of host tools, which matters beyond tidiness: `sed -i` with no argument is
GNU-only (BSD/macOS sed takes the next argument as a backup suffix), and repository
rules always run on the local host, even under `--config=rbe`.
"""

_MARKER = "GNU ld script"

# Deep enough for both trees (the Bootlin sysroot bottoms out around 8 levels at
# usr/include/c++/11.3.0/…). Starlark has neither recursion nor `while`, so the walk
# is a bounded breadth-first loop; a deeper tree fails rather than being silently
# half-scanned.
_MAX_DEPTH = 16

def _relocate_line(line):
    """Prefix absolute paths on a GROUP/INPUT/AS_NEEDED line with `=`.

    Equivalent to `sed -E '/GROUP|INPUT|AS_NEEDED/ s#([ (])/#\\1=/#g'`: an absolute
    path preceded by a space or an open paren. Idempotent, because once rewritten
    the text reads " =/" and no longer contains " /".
    """
    if "GROUP" not in line and "INPUT" not in line and "AS_NEEDED" not in line:
        return line
    return line.replace(" /", " =/").replace("(/", "(=/")

def _so_files(root):
    """Every readable `*.so` under `root`, breadth-first.

    Only `*.so` is read: a GNU ld script always stands in for a shared library, so
    reading every file in a sysroot — including multi-megabyte `.a` archives — to
    look for a marker would be gratuitous.

    The `exists` check is not paranoia. A deb-derived sysroot is full of dangling
    `.so` dev symlinks whose versioned target lives in a runtime package the
    manifest does not include (`libpcre2-32.so` is one), and `ctx.read` on a
    dangling symlink raises FileNotFoundException rather than returning empty.
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
                elif entry.basename.endswith(".so") and entry.exists:
                    found.append(entry)
        frontier = children
    if frontier:
        fail("relocate_ld_scripts: tree is deeper than {} levels, so ld scripts may be unscanned".format(_MAX_DEPTH))
    return found

def relocate_ld_scripts(ctx, root, require_some = True):
    """Rewrite every GNU ld script under `root` to use `=`-prefixed paths.

    Args:
      ctx: the repository_ctx of the calling repo rule.
      root: path within the fetched repo to scan, relative to its root.
      require_some: fail when nothing needed rewriting. Default on, because an
        unrelocated script does not error at link time — it silently resolves
        against the host libc — so a layout change upstream has to be loud here.

    Returns:
      The list of rewritten paths, as strings.
    """
    rewritten = []
    for path in _so_files(ctx.path(root)):
        content = ctx.read(path)
        if _MARKER not in content:
            continue
        fixed = "\n".join([_relocate_line(line) for line in content.split("\n")])
        if fixed != content:
            ctx.file(path, fixed, executable = False)
            rewritten.append(str(path))

    if require_some and not rewritten:
        fail(
            "relocate_ld_scripts: no GNU ld script under {} needed relocating. Either the ".format(root) +
            "layout changed or the scripts are already relative; verify before relaxing this, " +
            "since unrelocated absolute GROUP paths resolve against the host libc.",
        )
    return rewritten
