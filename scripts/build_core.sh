#!/bin/sh
# ============================================================================
# Compile the openFPGA bitstream in a Quartus 18.1 container.
#
# Sources are copied to the container-local filesystem before compiling:
# Quartus does heavy small-file I/O in db/, which is pathologically slow over
# a bind mount (measured on Apple Container / virtiofs). Only output_files/
# is copied back.
#
# Runtime-neutral: the same image and command are used locally and in CI.
#   CONTAINER_RUNTIME  container (default, Apple Container + Rosetta) |
#                      podman | docker
#   QUARTUS_IMAGE      override the Quartus image (default raetro/quartus:18.1)
#   QUARTUS_CPUS       cpu count for the Apple Container runtime (default 8)
#   QUARTUS_MEMORY     memory for the Apple Container runtime (default 8g)
#
# Usage: scripts/build_core.sh [revision]   (default: ap_core)
# Output: build/output_files/<revision>.rbf
#         build/bitstream.rbf_r
#
# SPDX-License-Identifier: GPL-2.0-or-later
# ============================================================================
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
RUNTIME=${CONTAINER_RUNTIME:-container}
IMAGE=${QUARTUS_IMAGE:-docker.io/raetro/quartus:18.1}
REVISION=${1:-ap_core}

OUT_DIR="$REPO/build/output_files"

BUILD_CMD='
set -e
mkdir -p /work
cp -a /src/src/fpga/. /work/
cd /work
quartus_sh --flow compile "$1"
mkdir -p /src/build/output_files
cp -a /work/output_files/. /src/build/output_files/
'

echo "build_core: runtime=$RUNTIME image=$IMAGE revision=$REVISION"
mkdir -p "$OUT_DIR"

case "$RUNTIME" in
    container)
        container run --rm --arch amd64 \
            --cpus "${QUARTUS_CPUS:-8}" --memory "${QUARTUS_MEMORY:-8g}" \
            --volume "$REPO:/src" \
            "$IMAGE" sh -c "$BUILD_CMD" build "$REVISION"
        ;;
    podman|docker)
        "$RUNTIME" run --rm --platform linux/amd64 \
            -v "$REPO:/src" \
            "$IMAGE" sh -c "$BUILD_CMD" build "$REVISION"
        ;;
    *)
        echo "error: unknown CONTAINER_RUNTIME '$RUNTIME'" >&2
        exit 2
        ;;
esac

RBF="$OUT_DIR/$REVISION.rbf"
if [ ! -f "$RBF" ]; then
    echo "error: $RBF was not produced" >&2
    exit 1
fi

python3 "$REPO/scripts/reverse_rbf_bits.py" "$RBF" "$REPO/build/bitstream.rbf_r"

echo
echo "==== build summary ===="
for f in "$OUT_DIR"/*.summary; do
    [ -f "$f" ] || continue
    echo "----- $(basename "$f")"
    cat "$f"
done
