"""gcc_toolchain_config - cross-compile cc_toolchain config for the Bootlin armv7
toolchain. Slimmed-down version of
`@bazel_tools//tools/cpp:unix_cc_toolchain_config.bzl`.
"""

load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load(
    "@rules_cc//cc:cc_toolchain_config_lib.bzl",
    "feature",
    "flag_group",
    "flag_set",
    "tool_path",
)
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")

_ALL_COMPILE_ACTIONS = [
    ACTION_NAMES.c_compile,
    ACTION_NAMES.cpp_compile,
    ACTION_NAMES.linkstamp_compile,
    ACTION_NAMES.assemble,
    ACTION_NAMES.preprocess_assemble,
    ACTION_NAMES.cpp_header_parsing,
    ACTION_NAMES.cpp_module_compile,
    ACTION_NAMES.cpp_module_codegen,
    ACTION_NAMES.clif_match,
    ACTION_NAMES.lto_backend,
]

_ALL_CPP_COMPILE_ACTIONS = [
    ACTION_NAMES.cpp_compile,
    ACTION_NAMES.cpp_header_parsing,
    ACTION_NAMES.cpp_module_compile,
    ACTION_NAMES.cpp_module_codegen,
    ACTION_NAMES.clif_match,
]

_ALL_LINK_ACTIONS = [
    ACTION_NAMES.cpp_link_executable,
    ACTION_NAMES.cpp_link_dynamic_library,
    ACTION_NAMES.cpp_link_nodeps_dynamic_library,
]

# Keep the compiler from canonicalizing (realpath-ing) its own prefix and the
# built-in header dirs. Bazel stages toolchains as symlinks and reports headers
# for cache keys / builtin-dir validation via the symbolic exec-root path;
# canonicalization rewrites those to absolute cache paths that no longer match a
# declared builtin dir ("absolute path inclusion").
#
# Compile-only: the rationale is entirely about the compile step's
# builtin-header-dir reporting, and there is no link-side reason for it.
_NO_CANONICAL_FLAGS = [
    "-no-canonical-prefixes",
]

_HARDENING_COMPILE_FLAGS = [
    "-Wall",
    "-fstack-protector-strong",
    "-D_FORTIFY_SOURCE=2",
    "-Wformat",
    "-Wformat-security",
    "-Werror=format-security",
]

_HARDENING_LINK_FLAGS = [
    "-Wl,-z,relro",
    "-Wl,-z,now",
    "-Wl,--build-id=sha1",
    "-Wl,--hash-style=gnu",
    "-Wl,--as-needed",
]

_OPT_COMPILE_FLAGS = [
    "-O2",
    "-DNDEBUG",
    "-ffunction-sections",
    "-fdata-sections",
]

_OPT_LINK_FLAGS = [
    "-Wl,--gc-sections",
]

_DBG_COMPILE_FLAGS = [
    "-g",
    "-O0",
]

_FASTBUILD_COMPILE_FLAGS = [
    "-O0",
    "-g0",
]

_TOOL_PATHS = {
    "ar": "ar",
    "compat-ld": "ld",
    "cpp": "cpp",
    "dwp": "objdump",
    "gcc": "gcc",
    "gcov": "gcc",
    "ld": "ld",
    "nm": "nm",
    "objcopy": "objcopy",
    "objdump": "objdump",
    "strip": "strip",
}

def _builtin_include_dir(ctx, path):
    """Resolve a package-relative builtin include dir to an execroot path.

    Unlike `tool_path` (which Bazel resolves relative to the toolchain's
    package), `cxx_builtin_include_directories` are matched against the compiler's
    reported header paths as-is — a bare relative path is taken relative to the
    execroot *root*, so for a toolchain fetched into an external repo it misses
    the `external/<repo>/` prefix and every system header trips an "absolute path
    inclusion" error. Prepending the toolchain's own `workspace_root` fixes that;
    for a first-party (main-repo) toolchain `workspace_root` is empty and the
    path is returned unchanged. Absolute and `%token%`-prefixed paths pass
    through untouched.
    """
    if path.startswith("/") or path.startswith("%"):
        return path
    root = ctx.label.workspace_root
    return root + "/" + path if root else path

def _impl(ctx):
    triple = ctx.attr.target_triple
    builtin_include_dirs = [
        _builtin_include_dir(ctx, path)
        for path in ctx.attr.cxx_builtin_include_directories
    ]

    tool_paths_list = [
        tool_path(name = slot, path = "bin/{triple}-{binary}".format(
            triple = triple,
            binary = binary,
        ))
        for slot, binary in _TOOL_PATHS.items()
    ]

    default_compile_flags_feature = feature(
        name = "default_compile_flags",
        enabled = True,
        flag_sets = [
            flag_set(
                actions = _ALL_COMPILE_ACTIONS,
                flag_groups = [flag_group(
                    flags = ctx.attr.target_compile_flags + _HARDENING_COMPILE_FLAGS + _NO_CANONICAL_FLAGS,
                )],
            ),
            flag_set(
                actions = _ALL_CPP_COMPILE_ACTIONS,
                flag_groups = [flag_group(flags = ["-std=" + ctx.attr.cxx_standard])],
            ),
        ],
    )

    # Search the builtin system headers via relative `-isystem` paths, in the
    # same order gcc itself would. Declaring them in
    # cxx_builtin_include_directories is not enough on its own: the sandbox
    # invokes the compiler through an absolute argv[0], so with its compiled-in
    # sysroot gcc reports every system header as an absolute path rooted at the
    # sandbox execroot, which never prefix-matches Bazel's canonical execroot
    # and trips "absolute path inclusion". Passing the dirs as relative
    # `-isystem` flags makes gcc find (and therefore report) them relative to
    # the exec root, matching the declared builtin dirs.
    sysroot_includes_feature = feature(
        name = "sysroot_includes",
        enabled = True,
        flag_sets = [
            flag_set(
                actions = _ALL_COMPILE_ACTIONS,
                flag_groups = [flag_group(
                    flags = ["-isystem", d],
                )],
            )
            for d in builtin_include_dirs
        ],
    )

    default_link_flags_feature = feature(
        name = "default_link_flags",
        enabled = True,
        flag_sets = [
            flag_set(
                actions = _ALL_LINK_ACTIONS,
                flag_groups = [flag_group(flags = _HARDENING_LINK_FLAGS)],
            ),
        ],
    )

    opt_feature = feature(
        name = "opt",
        flag_sets = [
            flag_set(
                actions = _ALL_COMPILE_ACTIONS,
                flag_groups = [flag_group(flags = _OPT_COMPILE_FLAGS)],
            ),
            flag_set(
                actions = _ALL_LINK_ACTIONS,
                flag_groups = [flag_group(flags = _OPT_LINK_FLAGS)],
            ),
        ],
    )

    dbg_feature = feature(
        name = "dbg",
        flag_sets = [flag_set(
            actions = _ALL_COMPILE_ACTIONS,
            flag_groups = [flag_group(flags = _DBG_COMPILE_FLAGS)],
        )],
    )

    fastbuild_feature = feature(
        name = "fastbuild",
        flag_sets = [flag_set(
            actions = _ALL_COMPILE_ACTIONS,
            flag_groups = [flag_group(flags = _FASTBUILD_COMPILE_FLAGS)],
        )],
    )

    # A gcc cross toolchain with a compiled-in sysroot still lets the linker
    # fall back to the host's /lib (finding an x86_64 libc.so.6) unless Bazel
    # passes an explicit --sysroot. builtin_sysroot does that for both compile
    # and link. A package-relative value is resolved against workspace_root like
    # the builtin include dirs.
    builtin_sysroot = _builtin_include_dir(ctx, ctx.attr.sysroot) if ctx.attr.sysroot else None

    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        toolchain_identifier = ctx.attr.toolchain_identifier,
        host_system_name = "x86_64-pc-linux-gnu",
        target_system_name = ctx.attr.target_triple,
        target_cpu = ctx.attr.target_cpu,
        target_libc = ctx.attr.target_libc,
        compiler = "gcc",
        abi_version = "gcc",
        abi_libc_version = ctx.attr.target_libc.replace("glibc_", ""),
        builtin_sysroot = builtin_sysroot,
        cxx_builtin_include_directories = builtin_include_dirs,
        tool_paths = tool_paths_list,
        features = [
            default_compile_flags_feature,
            sysroot_includes_feature,
            default_link_flags_feature,
            opt_feature,
            dbg_feature,
            fastbuild_feature,
            feature(name = "pic", enabled = True),
            feature(name = "supports_pic", enabled = True),
            feature(name = "supports_dynamic_linker", enabled = True),
        ],
    )

gcc_toolchain_config = rule(
    implementation = _impl,
    attrs = {
        "target_triple": attr.string(
            mandatory = True,
            doc = "GNU target triple matching the cross compiler's binary prefix.",
        ),
        "toolchain_identifier": attr.string(
            mandatory = True,
            doc = "Stable identifier for the cc_toolchain. Surfaces in Bazel diagnostics.",
        ),
        "target_cpu": attr.string(
            mandatory = True,
            doc = "CPU label (e.g. `armv7`, `aarch64`).",
        ),
        "target_libc": attr.string(
            default = "glibc_2.27",
            doc = "Target libc identifier.",
        ),
        "cxx_standard": attr.string(
            default = "c++17",
            doc = "C++ standard passed via `-std=`. Applied to all C++ compile actions.",
        ),
        "target_compile_flags": attr.string_list(
            mandatory = True,
            doc = "Architecture-specific compile flags. Combined with universal hardening flags inside the rule.",
        ),
        "cxx_builtin_include_directories": attr.string_list(
            mandatory = True,
            doc = "Header search roots Bazel allows the compiler to read from. Must include glibc, libstdc++, and gcc compiler-internal headers.",
        ),
        "sysroot": attr.string(
            default = "",
            doc = "Package-relative sysroot dir. When set, Bazel passes it as --sysroot for compile and link, keeping the linker off the host's libc.",
        ),
    },
)
