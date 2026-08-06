"""bootlin_toolchain — fetch the Bootlin armv7-eabihf toolchain with relocatable ld scripts.

An `http_archive` plus one fixup, expressed as a repository rule so the fixup needs
no host tools: see //bazel/repo_rules:ld_scripts.bzl for what the rewrite does and
why `patch_cmds` was the wrong place for it. In this toolchain exactly one script
needs it (`usr/lib/libc.so`); `lib/libgcc_s.so` is an ld script too but names its
members relatively, so it is left alone.

The merged AAMP sysroot inherits the fixed scripts — //bazel/rules:xione_sysroot.bzl
does not rewrite anything itself.
"""

load(":ld_scripts.bzl", "relocate_ld_scripts")

def _bootlin_toolchain_impl(ctx):
    ctx.download_and_extract(
        url = ctx.attr.url,
        sha256 = ctx.attr.sha256,
        stripPrefix = ctx.attr.strip_prefix,
    )
    relocate_ld_scripts(ctx, ctx.attr.sysroot)
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
