#!/usr/bin/env bash
# Asserts the XiOne cross-build produced libraries that can actually load on the
# device: the checks a zero exit status does not give you — a build that silently
# targeted the wrong architecture, or lost a library the player needs.
#
# Run it directly:
#   bazel build //tools/verify:xione_libs_ok --platforms=//bazel/platforms:xione
#
# argv: <cross-readelf> <expected-so-count> <path>...
# Paths that are not `*.so` are ignored, because //:aamp also exposes its include
# directory.
set -euo pipefail

readelf="$1"
expected="$2"
shift 2

libs=()
for p in "$@"; do
    case "$p" in
        *.so) libs+=("$p") ;;
    esac
done

fail() {
    echo "xione_libs_check: $*" >&2
    exit 1
}

# A dropped middleware library still links; it fails at dlopen on the device, where
# nothing reports why. Assert the count rather than trusting the build to notice.
[ "${#libs[@]}" -eq "$expected" ] ||
    fail "expected $expected shared libraries, got ${#libs[@]}: ${libs[*]##*/}"

for so in "${libs[@]}"; do
    name="${so##*/}"
    hdr="$("$readelf" -h "$so")"
    grep -q 'Class: *ELF32' <<<"$hdr" || fail "$name is not ELF32"
    grep -q 'Machine: *ARM' <<<"$hdr" || fail "$name is not EM_ARM"
    grep -q 'hard-float' <<<"$hdr" || fail "$name is not the hard-float ABI"
done

# Every AAMP-internal DT_NEEDED must be satisfied by a sibling in the same bundle. On
# the v2 line the middleware is split into separate shared libraries and libaamp.so
# needs five of them; the device's stock AAMP predates that split and does not provide
# them, so a bundle missing one cannot load.
present=" "
for so in "${libs[@]}"; do present="${present}${so##*/} "; done

for so in "${libs[@]}"; do
    name="${so##*/}"
    while read -r need; do
        [ -n "$need" ] || continue
        case "$need" in
            libaamp*.so | libplayer*.so | libmetrics.so | libbaseconversion.so | libsubtec.so)
                case "$present" in
                    *" $need "*) ;;
                    *) fail "$name needs $need, which is not in the bundle" ;;
                esac
                ;;
        esac
    done < <("$readelf" -d "$so" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
done

echo "ok: ${#libs[@]} libraries, all ELF32 ARM hard-float, internal DT_NEEDED closure self-contained"
