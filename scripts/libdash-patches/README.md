# libdash RDK patches

The 12 RDK downstream patches for bitmovin libdash (`stable_3_0`), vendored here
so builds can apply them without cloning `meta-rdk-ext` at build time.

Source of truth: `meta-rdk-ext/recipes-multimedia/libdash/libdash/` on branch
`rdk-next`
(`https://code.rdkcentral.com/r/rdk/components/generic/rdk-oe/meta-rdk-ext`).
These are byte-for-byte copies of the patches `scripts/install_libdash.sh`
downloads and applies, in filename order, with `patch -p1` against the inner
`libdash/` project root.
