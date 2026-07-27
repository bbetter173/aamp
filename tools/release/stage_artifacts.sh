#!/usr/bin/env bash
# Stage the XiOne cross-build outputs into a release tarball.
#
# Takes the .so files from a completed
#   bazel build //:aamp --platforms=//bazel/platforms:xione
# and produces a self-contained, deploy-ready tarball plus a manifest recording
# exactly which inputs produced it.
#
# Two things happen here that the raw bazel-bin outputs do NOT have:
#
#   1. RPATH is rewritten to $ORIGIN. rules_foreign_cc bakes the build sandbox
#      path into DT_RPATH. Left unpatched, a bundled libaampjsbindings.so
#      silently loads the *stock* /usr/lib/libaamp.so on the device and defeats
#      the whole point of the swap — with no error, just the wrong code running.
#      Doing it here means every published artifact is correct by construction
#      and no downstream consumer has to remember.
#
#   2. The layout matches the .wgt: usr/lib/<name>.so. Deploying is then a
#      straight copy into the widget tree.
#
# Usage:
#   tools/release/stage_artifacts.sh --version <ver> [--out <dir>] [--keep-debug]
#
# Env: BAZEL (default: bazelisk), PATCHELF (default: patchelf)
set -euo pipefail

VERSION=""
OUT="staging-xione"
KEEP_DEBUG=0
BAZEL="${BAZEL:-bazelisk}"
PATCHELF="${PATCHELF:-patchelf}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version) [ "$#" -ge 2 ] || { echo "ERROR: --version needs a value" >&2; exit 2; }
                   VERSION="$2"; shift 2 ;;
        --out)     [ "$#" -ge 2 ] || { echo "ERROR: --out needs a value" >&2; exit 2; }
                   OUT="$2"; shift 2 ;;
        --keep-debug) KEEP_DEBUG=1; shift ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$VERSION" ] || { echo "ERROR: --version is required" >&2; exit 2; }

command -v "$PATCHELF" >/dev/null 2>&1 || {
    echo "ERROR: patchelf not found. It is required to rewrite RPATH; staging" >&2
    echo "       without it would publish libraries carrying a sandbox RPATH." >&2
    exit 1
}

# Stripping needs the *cross* strip. The host's binutils cannot read ELF32 ARM
# ("Unable to recognise the architecture of the input file"), so use the one from
# the Bootlin toolchain Bazel already fetched rather than whatever is on PATH.
resolve_cross_strip() {
    if [ -n "${STRIP:-}" ]; then
        echo "$STRIP"
        return
    fi
    local ob
    ob="$("$BAZEL" info output_base 2>/dev/null)" || return 1
    echo "${ob}/external/+http_archive+xione_bootlin_toolchain/bin/arm-buildroot-linux-gnueabihf-strip"
}

# The nine libraries //:aamp emits. Keep in sync with out_shared_libs in
# //BUILD.bazel; a missing one is a hard error rather than a partial tarball.
LIBS=(
    libaamp.so
    libaampjsbindings.so
    libbaseconversion.so
    libmetrics.so
    libplayerfbinterface.so
    libplayergstinterface.so
    libplayerjsonobject.so
    libplayerlogmanager.so
    libsubtec.so
)

ARCH_DIR="aamp-xione-armv7-${VERSION}"
STAGE="${OUT}/${ARCH_DIR}"
TARBALL="${OUT}/aamp-xione-armv7-${VERSION}.tar.gz"

echo "[stage] building //:aamp for the XiOne"
"$BAZEL" build //:aamp --platforms=//bazel/platforms:xione

LIBDIR="$("$BAZEL" info bazel-bin 2>/dev/null)/aamp/lib"
[ -d "$LIBDIR" ] || { echo "ERROR: $LIBDIR not found after build" >&2; exit 1; }

CROSS_STRIP="$(resolve_cross_strip)" || { echo "ERROR: could not resolve bazel output_base" >&2; exit 1; }
[ -x "$CROSS_STRIP" ] || { echo "ERROR: cross strip not found at $CROSS_STRIP" >&2; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE/usr/lib"
[ "$KEEP_DEBUG" -eq 1 ] && mkdir -p "$STAGE/debug"

echo "[stage] copying, stripping and repointing RPATH -> \$ORIGIN"
for so in "${LIBS[@]}"; do
    src="${LIBDIR}/${so}"
    [ -f "$src" ] || { echo "ERROR: expected $src (is out_shared_libs in sync?)" >&2; exit 1; }
    dst="${STAGE}/usr/lib/${so}"
    install -m 0644 "$src" "$dst"

    if [ "$KEEP_DEBUG" -eq 1 ]; then
        cp "$src" "${STAGE}/debug/${so}"
    fi

    # $ORIGIN so each library resolves its siblings inside /package/usr/lib
    # rather than falling back to the device's stock /usr/lib.
    "$PATCHELF" --set-rpath '$ORIGIN' "$dst"
    "$CROSS_STRIP" --strip-unneeded "$dst"
done

echo "[verify] asserting every staged library is ELF32 ARM with RPATH=\$ORIGIN"
for so in "${LIBS[@]}"; do
    dst="${STAGE}/usr/lib/${so}"

    hdr="$(readelf -h "$dst")"
    grep -q 'Class:  *ELF32' <<<"$hdr" || { echo "ERROR: $so is not ELF32" >&2; exit 1; }
    grep -q 'Machine:  *ARM' <<<"$hdr" || { echo "ERROR: $so is not EM_ARM" >&2; exit 1; }

    rpath="$("$PATCHELF" --print-rpath "$dst" 2>/dev/null || true)"
    [ "$rpath" = '$ORIGIN' ] || { echo "ERROR: $so has RPATH '$rpath', expected \$ORIGIN" >&2; exit 1; }
done

# Every AAMP-internal DT_NEEDED must be satisfied inside the tarball; anything
# else (libc, libcurl, gstreamer, libWPEWebKit, ...) comes from the device.
echo "[verify] asserting the AAMP-internal DT_NEEDED closure is self-contained"
for so in "${LIBS[@]}"; do
    while read -r need; do
        case "$need" in
            libaamp*.so|libplayer*.so|libmetrics.so|libbaseconversion.so|libsubtec.so)
                [ -f "${STAGE}/usr/lib/${need}" ] || {
                    echo "ERROR: $so needs $need, which is not in the tarball" >&2; exit 1; }
                ;;
        esac
    done < <(readelf -d "${STAGE}/usr/lib/${so}" |
             sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
done

# Record what produced these bytes. The artifact is a function of the AAMP commit
# *and* the sysroot/toolchain pins, so no upstream version identifies it.
echo "[stage] writing manifest.json"
GIT_COMMIT="$(git rev-parse HEAD)"
GIT_DESCRIBE="$(git describe --tags --always --dirty 2>/dev/null || echo unknown)"
DEBS_SHA="$(sha256sum third_party/xione_sysroot/xione-debs.json | cut -d' ' -f1)"
TOOLCHAIN_SHA="$(sed -n 's/.*sha256 = "\(.*\)".*/\1/p' MODULE.bazel | head -1)"

cat >"${STAGE}/manifest.json" <<JSON
{
  "name": "aamp-xione-armv7",
  "version": "${VERSION}",
  "target": {
    "platform": "//bazel/platforms:xione",
    "arch": "armv7-eabihf-neon",
    "libc": "glibc 2.35",
    "elf": "ELF32 EM_ARM hard-float"
  },
  "source": {
    "repo": "rillanetwork/aamp",
    "commit": "${GIT_COMMIT}",
    "describe": "${GIT_DESCRIBE}"
  },
  "inputs": {
    "bootlin_toolchain_sha256": "${TOOLCHAIN_SHA}",
    "xione_debs_manifest_sha256": "${DEBS_SHA}"
  },
  "libraries": [
$(printf '    "%s"' "${LIBS[0]}"; printf ',\n    "%s"' "${LIBS[@]:1}")
  ],
  "rpath": "\$ORIGIN",
  "stripped": true
}
JSON

echo "[stage] creating $TARBALL"
tar -czf "$TARBALL" -C "$STAGE" usr manifest.json $([ "$KEEP_DEBUG" -eq 1 ] && echo debug)

echo "[stage] done"
sha256sum "$TARBALL"
