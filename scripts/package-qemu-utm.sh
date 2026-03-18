#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

require_cmd awk
require_cmd dd
require_cmd file
require_cmd python3
require_cmd sgdisk
require_cmd sha256sum
require_cmd tar
require_cmd truncate

PRODUCT_OUT="$(product_out_dir)"
[[ -d "${PRODUCT_OUT}" ]] || die "Product output directory not found: ${PRODUCT_OUT}"

SIMG2IMG="${AOSP_ROOT}/out/host/linux-x86/bin/simg2img"
UNPACK_BOOTIMG="${AOSP_ROOT}/system/tools/mkbootimg/unpack_bootimg.py"

[[ -x "${SIMG2IMG}" ]] || die "Missing simg2img tool: ${SIMG2IMG}"
[[ -f "${UNPACK_BOOTIMG}" ]] || die "Missing unpack_bootimg.py: ${UNPACK_BOOTIMG}"

ART_NAME="$(artifact_name)"
OUT_DIR="${ARTIFACTS_DIR}/${ART_NAME}"
WORK_DIR="${ARTIFACTS_DIR}/.packaging-${ART_NAME}"
RAW_DIR="${WORK_DIR}/raw"
BOOT_DIR="${WORK_DIR}/boot-unpack"
RAW_DISK="${OUT_DIR}/${ART_NAME}.raw"
KERNEL_PATH="${OUT_DIR}/kernel"
INITRD_PATH="${OUT_DIR}/initrd.img"
RUNNER_PATH="${OUT_DIR}/run-qemu-macos.sh"
README_PATH="${OUT_DIR}/README-macos-qemu.md"
MANIFEST_PATH="${OUT_DIR}/manifest.json"
CHECKSUM_PATH="${OUT_DIR}/SHA256SUMS"
ARCHIVE_PATH="${ARTIFACTS_DIR}/${ART_NAME}.tar.zst"

rm -rf "${WORK_DIR}" "${OUT_DIR}"
ensure_dir "${RAW_DIR}"
ensure_dir "${BOOT_DIR}"
ensure_dir "${OUT_DIR}"

prepare_raw_image() {
  local src="$1"
  local dst="$2"

  if file -b "${src}" | grep -qi 'Android sparse image'; then
    log "Converting sparse image $(basename "${src}") to raw"
    "${SIMG2IMG}" "${src}" "${dst}"
  else
    cp "${src}" "${dst}"
  fi
}

create_blank_image() {
  local dst="$1"
  local size_mib="$2"
  truncate -s "$(( size_mib * 1024 * 1024 ))" "${dst}"
}

extract_boot_image() {
  local image_path="$1"
  local out_dir="$2"

  [[ -f "${image_path}" ]] || return 1
  ensure_dir "${out_dir}"
  python3 "${UNPACK_BOOTIMG}" --boot_img "${image_path}" --out "${out_dir}" >/dev/null
}

ceil_mib() {
  local file_path="$1"
  local bytes
  bytes="$(stat -c '%s' "${file_path}")"
  printf '%s\n' "$(( (bytes + 1024 * 1024 - 1) / (1024 * 1024) ))"
}

partition_size_mib() {
  local file_path="$1"
  local raw_size_mib
  raw_size_mib="$(ceil_mib "${file_path}")"
  printf '%s\n' "$(( raw_size_mib + 4 ))"
}

BOOT_IMG="${PRODUCT_OUT}/boot.img"
INIT_BOOT_IMG="${PRODUCT_OUT}/init_boot.img"
VENDOR_BOOT_IMG="${PRODUCT_OUT}/vendor_boot.img"
VENDOR_KERNEL_BOOT_IMG="${PRODUCT_OUT}/vendor_kernel_boot.img"
VBMETA_IMG="${PRODUCT_OUT}/vbmeta.img"
VBMETA_SYSTEM_IMG="${PRODUCT_OUT}/vbmeta_system.img"
SUPER_IMG="${PRODUCT_OUT}/super.img"
USERDATA_IMG="${PRODUCT_OUT}/userdata.img"
METADATA_IMG="${PRODUCT_OUT}/metadata.img"
MISC_IMG="${PRODUCT_OUT}/misc.img"

[[ -f "${BOOT_IMG}" ]] || die "Missing boot image: ${BOOT_IMG}"
[[ -f "${SUPER_IMG}" ]] || die "Missing super image: ${SUPER_IMG}"
[[ -f "${USERDATA_IMG}" ]] || die "Missing userdata image: ${USERDATA_IMG}"

extract_boot_image "${BOOT_IMG}" "${BOOT_DIR}/boot"
extract_boot_image "${INIT_BOOT_IMG}" "${BOOT_DIR}/init_boot" || true
extract_boot_image "${VENDOR_BOOT_IMG}" "${BOOT_DIR}/vendor_boot" || true

[[ -f "${BOOT_DIR}/boot/kernel" ]] || die "Kernel not found after unpacking boot.img"

cp "${BOOT_DIR}/boot/kernel" "${KERNEL_PATH}"

: > "${INITRD_PATH}"
if [[ -s "${BOOT_DIR}/init_boot/ramdisk" ]]; then
  cat "${BOOT_DIR}/init_boot/ramdisk" >> "${INITRD_PATH}"
elif [[ -s "${BOOT_DIR}/boot/ramdisk" ]]; then
  cat "${BOOT_DIR}/boot/ramdisk" >> "${INITRD_PATH}"
fi

for ramdisk_fragment in "${BOOT_DIR}/vendor_boot"/vendor_ramdisk*; do
  [[ -e "${ramdisk_fragment}" ]] || continue
  if [[ "$(basename "${ramdisk_fragment}")" =~ ^vendor_ramdisk[0-9]+$ ]]; then
    cat "${ramdisk_fragment}" >> "${INITRD_PATH}"
  fi
done

[[ -s "${INITRD_PATH}" ]] || die "Combined initrd is empty"

KERNEL_CMDLINE="$(normalize_text_file "${BOOT_DIR}/boot/cmdline")"

if [[ -f "${BOOT_DIR}/vendor_boot/cmdline" ]]; then
  VENDOR_CMDLINE="$(normalize_text_file "${BOOT_DIR}/vendor_boot/cmdline")"
  if [[ -n "${VENDOR_CMDLINE}" ]]; then
    KERNEL_CMDLINE="${KERNEL_CMDLINE} ${VENDOR_CMDLINE}"
  fi
fi

if [[ -f "${BOOT_DIR}/vendor_boot/bootconfig" ]]; then
  BOOTCONFIG_CMDLINE="$(normalize_text_file "${BOOT_DIR}/vendor_boot/bootconfig")"
  if [[ -n "${BOOTCONFIG_CMDLINE}" ]]; then
    KERNEL_CMDLINE="${KERNEL_CMDLINE} ${BOOTCONFIG_CMDLINE}"
  fi
fi

KERNEL_CMDLINE="$(printf '%s' "${KERNEL_CMDLINE}" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"

RAW_SUPER="${RAW_DIR}/super.raw"
RAW_USERDATA="${RAW_DIR}/userdata.raw"
RAW_BOOT="${RAW_DIR}/boot.img"
RAW_VBMETA="${RAW_DIR}/vbmeta.img"
RAW_VBMETA_SYSTEM="${RAW_DIR}/vbmeta_system.img"
RAW_METADATA="${RAW_DIR}/metadata.img"
RAW_MISC="${RAW_DIR}/misc.img"
RAW_INIT_BOOT="${RAW_DIR}/init_boot.img"
RAW_VENDOR_BOOT="${RAW_DIR}/vendor_boot.img"
RAW_VENDOR_KERNEL_BOOT="${RAW_DIR}/vendor_kernel_boot.img"

prepare_raw_image "${SUPER_IMG}" "${RAW_SUPER}"
prepare_raw_image "${USERDATA_IMG}" "${RAW_USERDATA}"
cp "${BOOT_IMG}" "${RAW_BOOT}"

if [[ -f "${VBMETA_IMG}" ]]; then
  cp "${VBMETA_IMG}" "${RAW_VBMETA}"
else
  create_blank_image "${RAW_VBMETA}" 4
fi

if [[ -f "${VBMETA_SYSTEM_IMG}" ]]; then
  cp "${VBMETA_SYSTEM_IMG}" "${RAW_VBMETA_SYSTEM}"
else
  create_blank_image "${RAW_VBMETA_SYSTEM}" 4
fi

if [[ -f "${METADATA_IMG}" ]]; then
  prepare_raw_image "${METADATA_IMG}" "${RAW_METADATA}"
else
  create_blank_image "${RAW_METADATA}" 16
fi

if [[ -f "${MISC_IMG}" ]]; then
  prepare_raw_image "${MISC_IMG}" "${RAW_MISC}"
else
  create_blank_image "${RAW_MISC}" 16
fi

if [[ -f "${INIT_BOOT_IMG}" ]]; then
  cp "${INIT_BOOT_IMG}" "${RAW_INIT_BOOT}"
fi

if [[ -f "${VENDOR_BOOT_IMG}" ]]; then
  cp "${VENDOR_BOOT_IMG}" "${RAW_VENDOR_BOOT}"
fi

if [[ -f "${VENDOR_KERNEL_BOOT_IMG}" ]]; then
  cp "${VENDOR_KERNEL_BOOT_IMG}" "${RAW_VENDOR_KERNEL_BOOT}"
fi

declare -a PARTITION_NAMES=()
declare -a PARTITION_SOURCES=()

add_partition() {
  PARTITION_NAMES+=("$1")
  PARTITION_SOURCES+=("$2")
}

add_partition "misc" "${RAW_MISC}"
add_partition "metadata" "${RAW_METADATA}"
add_partition "vbmeta_a" "${RAW_VBMETA}"
add_partition "vbmeta_b" "${RAW_VBMETA}"
add_partition "vbmeta_system_a" "${RAW_VBMETA_SYSTEM}"
add_partition "vbmeta_system_b" "${RAW_VBMETA_SYSTEM}"
add_partition "boot_a" "${RAW_BOOT}"
add_partition "boot_b" "${RAW_BOOT}"

if [[ -f "${RAW_INIT_BOOT}" ]]; then
  add_partition "init_boot_a" "${RAW_INIT_BOOT}"
  add_partition "init_boot_b" "${RAW_INIT_BOOT}"
fi

if [[ -f "${RAW_VENDOR_BOOT}" ]]; then
  add_partition "vendor_boot_a" "${RAW_VENDOR_BOOT}"
  add_partition "vendor_boot_b" "${RAW_VENDOR_BOOT}"
fi

if [[ -f "${RAW_VENDOR_KERNEL_BOOT}" ]]; then
  add_partition "vendor_kernel_boot_a" "${RAW_VENDOR_KERNEL_BOOT}"
  add_partition "vendor_kernel_boot_b" "${RAW_VENDOR_KERNEL_BOOT}"
fi

add_partition "super" "${RAW_SUPER}"
add_partition "userdata" "${RAW_USERDATA}"

TOTAL_MIB=64
for src in "${PARTITION_SOURCES[@]}"; do
  TOTAL_MIB="$(( TOTAL_MIB + $(partition_size_mib "${src}") ))"
done

truncate -s "$(( TOTAL_MIB * 1024 * 1024 ))" "${RAW_DISK}"
sgdisk --clear "${RAW_DISK}" >/dev/null

for idx in "${!PARTITION_NAMES[@]}"; do
  number="$(( idx + 1 ))"
  part_name="${PARTITION_NAMES[${idx}]}"
  part_src="${PARTITION_SOURCES[${idx}]}"
  part_size_mib="$(partition_size_mib "${part_src}")"
  sgdisk \
    --new="${number}:0:+${part_size_mib}MiB" \
    --typecode="${number}:8300" \
    --change-name="${number}:${part_name}" \
    "${RAW_DISK}" >/dev/null
done

declare -a PARTITION_JSON_LINES=()

for idx in "${!PARTITION_NAMES[@]}"; do
  number="$(( idx + 1 ))"
  part_name="${PARTITION_NAMES[${idx}]}"
  part_src="${PARTITION_SOURCES[${idx}]}"
  first_sector="$(sgdisk -i "${number}" "${RAW_DISK}" | awk -F': ' '/First sector/ {print $2}')"
  size_bytes="$(stat -c '%s' "${part_src}")"

  dd if="${part_src}" of="${RAW_DISK}" bs=512 seek="${first_sector}" conv=notrunc,sparse status=none
  PARTITION_JSON_LINES+=("{\"name\":\"${part_name}\",\"size_bytes\":${size_bytes},\"first_sector\":${first_sector}}")
done

cat > "${RUNNER_PATH}" <<EOF
#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
DISK_IMAGE="\${SCRIPT_DIR}/$(basename "${RAW_DISK}")"
KERNEL_IMAGE="\${SCRIPT_DIR}/$(basename "${KERNEL_PATH}")"
INITRD_IMAGE="\${SCRIPT_DIR}/$(basename "${INITRD_PATH}")"

QEMU_BIN="\${QEMU_BIN:-qemu-system-aarch64}"
QEMU_CPUS="\${QEMU_CPUS:-${QEMU_CPUS}}"
QEMU_MEMORY_MB="\${QEMU_MEMORY_MB:-${QEMU_MEMORY_MB}}"

exec "\${QEMU_BIN}" \
  -machine virt,accel=hvf,highmem=off \
  -cpu host \
  -smp "\${QEMU_CPUS}" \
  -m "\${QEMU_MEMORY_MB}" \
  -serial mon:stdio \
  -display default,show-cursor=on \
  -device virtio-gpu-pci \
  -device virtio-keyboard-pci \
  -device virtio-mouse-pci \
  -device virtio-rng-pci \
  -netdev user,id=net0,hostfwd=tcp::5555-:5555,hostfwd=tcp::5554-:5554 \
  -device virtio-net-pci,netdev=net0 \
  -drive if=none,file="\${DISK_IMAGE}",format=raw,id=androiddisk,discard=unmap,detect-zeroes=unmap \
  -device virtio-blk-pci,drive=androiddisk \
  -kernel "\${KERNEL_IMAGE}" \
  -initrd "\${INITRD_IMAGE}" \
  -append '$(printf '%s' "${KERNEL_CMDLINE}" | sed "s/'/'\\\\''/g")'
EOF

chmod +x "${RUNNER_PATH}"

cat > "${README_PATH}" <<EOF
# macOS QEMU launch notes

This bundle was generated from:

- branch: ${AOSP_BRANCH}
- product: ${TARGET_PRODUCT}
- variant: ${TARGET_VARIANT}

## Supported host expectation

The supported launch path for this bundle is raw QEMU on an Apple Silicon Mac.
UTM can mirror the same settings in custom QEMU mode, but the generated
\`run-qemu-macos.sh\` launcher is the authoritative reference.

## Steps

1. Install QEMU:

   \`\`\`bash
   brew install qemu
   \`\`\`

2. Launch the VM:

   \`\`\`bash
   chmod +x ./run-qemu-macos.sh
   ./run-qemu-macos.sh
   \`\`\`

3. Optional overrides:

   \`\`\`bash
   QEMU_CPUS=6 QEMU_MEMORY_MB=12288 ./run-qemu-macos.sh
   \`\`\`

ADB is forwarded to port 5555 and fastboot-style traffic to port 5554.
EOF

export ART_NAME OUT_DIR RAW_DISK KERNEL_PATH INITRD_PATH KERNEL_CMDLINE AOSP_BRANCH TARGET_PRODUCT TARGET_VARIANT
export TARGET_RELEASE
export PARTITION_JSON="$(printf '%s\n' "${PARTITION_JSON_LINES[@]}")"

python3 - <<'PY' > "${MANIFEST_PATH}"
import json
import os

partitions = []
for line in os.environ["PARTITION_JSON"].splitlines():
    if line.strip():
        partitions.append(json.loads(line))

manifest = {
    "artifact_name": os.environ["ART_NAME"],
    "aosp_branch": os.environ["AOSP_BRANCH"],
    "target_product": os.environ["TARGET_PRODUCT"],
    "target_release": os.environ.get("TARGET_RELEASE", ""),
    "target_variant": os.environ["TARGET_VARIANT"],
    "files": {
        "disk_image": os.path.basename(os.environ["RAW_DISK"]),
        "kernel": os.path.basename(os.environ["KERNEL_PATH"]),
        "initrd": os.path.basename(os.environ["INITRD_PATH"]),
        "launcher": "run-qemu-macos.sh",
    },
    "kernel_cmdline": os.environ["KERNEL_CMDLINE"],
    "partitions": partitions,
}

print(json.dumps(manifest, indent=2))
PY

(
  cd "${OUT_DIR}"
  sha256sum ./* > "${CHECKSUM_PATH}"
)

tar --zstd -cf "${ARCHIVE_PATH}" -C "${ARTIFACTS_DIR}" "${ART_NAME}"

log "Packaged QEMU/UTM artifact at ${OUT_DIR}"
log "Compressed archive written to ${ARCHIVE_PATH}"
