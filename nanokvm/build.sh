#!/bin/sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/../out"
OVERLAY_DIR="${SCRIPT_DIR}/overlay"
IMAGE_URL="https://github.com/scpcom/LicheeSG-Nano-Build/releases/download/v2.3.6-1/licheervnano-kvm_sd.img.xz"
IMAGE_XZ="${OUT_DIR}/$(basename "${IMAGE_URL}")"
OUTPUT="${OUT_DIR}/pikvm.img"

mkdir -p "${OUT_DIR}"

# Download image
if [ ! -f "${IMAGE_XZ}" ]; then
    echo "Downloading image..."
    curl -fSL -o "${IMAGE_XZ}" "${IMAGE_URL}"
fi


# Decompress
echo "Decompressing image..."
xz -dc "${IMAGE_XZ}" > "${OUTPUT}"

apply_overlay_linux() {
    MOUNT_DIR="$(mktemp -d)"
    LOOP_DEV=""

    cleanup() {
        if mount | grep -q " ${MOUNT_DIR} " 2>/dev/null; then
            sudo umount "${MOUNT_DIR}"
        fi
        [ -n "${LOOP_DEV}" ] && sudo losetup -d "${LOOP_DEV}" 2>/dev/null || true
        rm -rf "${MOUNT_DIR}"
    }
    trap cleanup EXIT

    LOOP_DEV=$(sudo losetup --find --show --partscan "${OUTPUT}")
    echo "Loop device: ${LOOP_DEV}"

    if [ -b "${LOOP_DEV}p2" ]; then
        PART="${LOOP_DEV}p2"
    elif [ -b "${LOOP_DEV}p1" ]; then
        PART="${LOOP_DEV}p1"
    else
        echo "ERROR: No usable partition found on ${LOOP_DEV}" >&2
        exit 1
    fi

    echo "Mounting ${PART} at ${MOUNT_DIR}..."
    sudo mount "${PART}" "${MOUNT_DIR}"

    echo "Applying overlay files from ${OVERLAY_DIR}..."
    sudo cp -av "${OVERLAY_DIR}/." "${MOUNT_DIR}/"

    sudo umount "${MOUNT_DIR}"
    LOOP_DEV_TMP="${LOOP_DEV}"
    LOOP_DEV=""
    sudo losetup -d "${LOOP_DEV_TMP}"
}

apply_overlay_docker() {
    echo "macOS detected: using Docker for loop mount and overlay..."
    docker run --rm --privileged \
        -v "${OUTPUT}:/image.img" \
        -v "${OVERLAY_DIR}:/overlay:ro" \
        alpine sh -ec '
            apk add -q util-linux
            # Find FAT partition: pick the entry with type "b" (FAT32) or "c", else last partition
            SECTOR_SIZE=512
            PART_LINE=$(fdisk -l /image.img 2>/dev/null | grep "^/image.img" | grep -i "W95\|FAT\|HPFS" | tail -1)
            if [ -z "${PART_LINE}" ]; then
                PART_LINE=$(fdisk -l /image.img 2>/dev/null | grep "^/image.img" | tail -1)
            fi
            if [ -z "${PART_LINE}" ]; then
                echo "ERROR: No partition found in image" >&2
                exit 1
            fi
            START_SECTOR=$(echo "${PART_LINE}" | awk "{print \$2}")
            # Strip leading asterisk (boot flag) if present
            echo "${START_SECTOR}" | grep -q "^[0-9]" || START_SECTOR=$(echo "${PART_LINE}" | awk "{print \$3}")
            OFFSET=$((START_SECTOR * SECTOR_SIZE))
            echo "Mounting FAT32 partition at offset ${OFFSET} (sector ${START_SECTOR})..."
            MNTDIR=$(mktemp -d)
            mount -o loop,offset=${OFFSET} /image.img "${MNTDIR}"
            cp -av /overlay/. "${MNTDIR}/"
            chmod 755 "${MNTDIR}/etc/init.d/S99ipmi_sim" "${MNTDIR}/etc/ipmi/ipmi_sim_chassiscontrol"
            umount "${MNTDIR}"
        '
}

case "$(uname -s)" in
    Linux)
        apply_overlay_linux
        ;;
    Darwin)
        apply_overlay_docker
        ;;
    *)
        echo "ERROR: Unsupported OS: $(uname -s)" >&2
        exit 1
        ;;
esac

echo "Done. Output image: ${OUTPUT}"
