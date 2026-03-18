#!/usr/bin/env python3
"""Prepare public Android CI Cuttlefish ARM64 images for direct QEMU boot.

This tool is intentionally self-contained:

* It talks to the public ci.android.com JSON API using the same Origin/Referer
  headers as the web UI.
* It downloads the public ARM64 QEMU U-Boot binary from
  device/google/cuttlefish_prebuilts.
* It converts Android sparse images to raw without external helpers.
* It assembles the partition images into a single GPT disk image with the same
  partition labels that Cuttlefish's assemble_cvd uses.

The public CI metadata for older builds may outlive the underlying artifact
objects. When that happens the build API still lists the artifacts, but the
download URL resolves to a storage object that no longer exists. This tool
surfaces that state clearly so users can distinguish "bad script" from
"artifact retention expired".
"""

from __future__ import annotations

import argparse
import base64
import binascii
import io
import json
import os
import shutil
import struct
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET
import zipfile
from dataclasses import dataclass
from pathlib import Path


DEFAULT_BUILD_ID = "12884649"
DEFAULT_TARGET = "aosp_cf_arm64_only_phone-trunk_staging-userdebug"
DEFAULT_IMAGE_ARTIFACT = f"aosp_cf_arm64_only_phone-img-{DEFAULT_BUILD_ID}.zip"
DEFAULT_BOOTLOADER_REF = "refs/heads/main"

CI_API_KEY = "AIzaSyDnrU64gFcNp5hIjL6gHEPStH1413hl8Uc"
CI_API_ROOT = "https://androidbuildinternal.googleapis.com/android/internal/build/v3"
CI_BROWSER_HEADERS = {
    "Accept": "application/json",
    "Origin": "https://ci.android.com",
    "Referer": "https://ci.android.com/",
    "User-Agent": "Mozilla/5.0",
}

ANDROID_SPARSE_MAGIC = 0xED26FF3A
ANDROID_SPARSE_HEADER = struct.Struct("<IHHHHIIII")
ANDROID_SPARSE_CHUNK_HEADER = struct.Struct("<HHII")
CHUNK_TYPE_RAW = 0xCAC1
CHUNK_TYPE_FILL = 0xCAC2
CHUNK_TYPE_DONT_CARE = 0xCAC3
CHUNK_TYPE_CRC32 = 0xCAC4

SECTOR_SIZE = 512
GPT_NUM_PARTITION_ENTRIES = 128
GPT_PARTITION_ENTRY_SIZE = 128
GPT_PARTITION_ARRAY_SECTORS = (
    GPT_NUM_PARTITION_ENTRIES * GPT_PARTITION_ENTRY_SIZE
) // SECTOR_SIZE
GPT_HEADER_SIZE = 92
GPT_ALIGN_BYTES = 1024 * 1024
LINUX_FS_GUID = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4")


class ToolError(RuntimeError):
    """Base class for user-facing tool failures."""


class ArtifactUnavailableError(ToolError):
    """Raised when CI metadata exists but the backing object is gone."""


@dataclass(frozen=True)
class PartitionSpec:
    label: str
    image_path: Path


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr)


def _http_get(url: str, *, headers: dict[str, str] | None = None) -> bytes:
    request = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(request) as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        body = exc.read()
        raise ToolError(
            f"HTTP {exc.code} for {url}\n{body.decode('utf-8', 'replace')}"
        ) from exc


def ci_json_request(path: str, **query: object) -> dict:
    params = {"key": CI_API_KEY}
    for key, value in query.items():
        if value is not None:
            params[key] = value
    url = f"{CI_API_ROOT}{path}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(url, headers=CI_BROWSER_HEADERS)
    try:
        with urllib.request.urlopen(request) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read()
        raise ToolError(
            f"CI API request failed for {path}: HTTP {exc.code}\n"
            f"{body.decode('utf-8', 'replace')}"
        ) from exc


def ci_list_artifacts(
    build_id: str, target: str, *, page_size: int = 200
) -> list[dict]:
    artifacts: list[dict] = []
    page_token: str | None = None
    while True:
        payload = ci_json_request(
            f"/builds/{urllib.parse.quote(build_id)}/"
            f"{urllib.parse.quote(target)}/attempts/latest/artifacts",
            maxResults=page_size,
            pageToken=page_token,
        )
        artifacts.extend(payload.get("artifacts", []))
        page_token = payload.get("nextPageToken")
        if not page_token:
            return artifacts


def ci_get_artifact_metadata(build_id: str, target: str, artifact: str) -> dict:
    return ci_json_request(
        f"/builds/{urllib.parse.quote(build_id)}/"
        f"{urllib.parse.quote(target)}/attempts/latest/artifacts/"
        f"{urllib.parse.quote(artifact)}"
    )


def ci_get_signed_url(build_id: str, target: str, artifact: str) -> str:
    payload = ci_json_request(
        f"/builds/{urllib.parse.quote(build_id)}/"
        f"{urllib.parse.quote(target)}/attempts/latest/artifacts/"
        f"{urllib.parse.quote(artifact)}/url",
        redirect="false",
    )
    signed_url = payload.get("signedUrl")
    if not signed_url:
        raise ToolError(f"No signedUrl returned for artifact {artifact}")
    return signed_url


def download_signed_url(url: str, output_path: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(request) as response, output_path.open("wb") as out:
            shutil.copyfileobj(response, out)
    except urllib.error.HTTPError as exc:
        body = exc.read()
        message = body.decode("utf-8", "replace")
        output_path.unlink(missing_ok=True)
        if exc.code == 404 and "NoSuchKey" in message:
            details = _extract_gcs_no_such_key(message)
            raise ArtifactUnavailableError(
                "The CI API still exposes metadata for this artifact, but the "
                "backing GCS object no longer exists. This usually means the "
                "build aged out of public artifact retention.\n"
                f"Missing object: {details or '<unknown>'}"
            ) from exc
        raise ToolError(
            f"Artifact download failed with HTTP {exc.code}\n{message}"
        ) from exc


def download_artifact(
    build_id: str, target: str, artifact: str, output_dir: Path
) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    metadata = ci_get_artifact_metadata(build_id, target, artifact)
    metadata_path = output_dir / f"{artifact}.metadata.json"
    metadata_path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")

    signed_url = ci_get_signed_url(build_id, target, artifact)
    output_path = output_dir / artifact
    download_signed_url(signed_url, output_path)
    return output_path


def gitiles_raw_url(project: str, ref: str, file_path: str) -> str:
    quoted_path = "/".join(urllib.parse.quote(part) for part in file_path.split("/"))
    ref = urllib.parse.quote(ref, safe="")
    return f"https://android.googlesource.com/{project}/+/{ref}/{quoted_path}?format=TEXT"


def download_bootloader(output_path: Path, ref: str = DEFAULT_BOOTLOADER_REF) -> Path:
    raw_url = gitiles_raw_url(
        "device/google/cuttlefish_prebuilts",
        ref,
        "bootloader/qemu_aarch64/u-boot.bin",
    )
    encoded = _http_get(raw_url, headers={"User-Agent": "Mozilla/5.0"})
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(base64.b64decode(encoded))
    return output_path


def _extract_gcs_no_such_key(xml_text: str) -> str | None:
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return None
    details = root.findtext("Details")
    return details or None


def is_sparse_image(path: Path) -> bool:
    with path.open("rb") as fp:
        header = fp.read(ANDROID_SPARSE_HEADER.size)
    if len(header) != ANDROID_SPARSE_HEADER.size:
        return False
    magic, *_ = ANDROID_SPARSE_HEADER.unpack(header)
    return magic == ANDROID_SPARSE_MAGIC


def sparse_to_raw(src: Path, dst: Path) -> None:
    with src.open("rb") as inp, dst.open("wb") as out:
        header_data = inp.read(ANDROID_SPARSE_HEADER.size)
        if len(header_data) != ANDROID_SPARSE_HEADER.size:
            raise ToolError(f"{src} is too small to be an Android sparse image")
        (
            magic,
            major_version,
            _minor_version,
            file_hdr_sz,
            chunk_hdr_sz,
            block_size,
            total_blocks,
            total_chunks,
            _image_checksum,
        ) = ANDROID_SPARSE_HEADER.unpack(header_data)
        if magic != ANDROID_SPARSE_MAGIC:
            raise ToolError(f"{src} is not an Android sparse image")
        if major_version != 1:
            raise ToolError(
                f"{src} uses unsupported sparse major version {major_version}"
            )
        if file_hdr_sz > ANDROID_SPARSE_HEADER.size:
            inp.read(file_hdr_sz - ANDROID_SPARSE_HEADER.size)

        blocks_written = 0
        for _ in range(total_chunks):
            chunk_header = inp.read(ANDROID_SPARSE_CHUNK_HEADER.size)
            if len(chunk_header) != ANDROID_SPARSE_CHUNK_HEADER.size:
                raise ToolError(f"Truncated sparse chunk header in {src}")
            chunk_type, _reserved, chunk_sz, total_sz = ANDROID_SPARSE_CHUNK_HEADER.unpack(
                chunk_header
            )
            if chunk_hdr_sz > ANDROID_SPARSE_CHUNK_HEADER.size:
                inp.read(chunk_hdr_sz - ANDROID_SPARSE_CHUNK_HEADER.size)
            data_sz = total_sz - chunk_hdr_sz
            output_bytes = chunk_sz * block_size

            if chunk_type == CHUNK_TYPE_RAW:
                expected = output_bytes
                if data_sz != expected:
                    raise ToolError(
                        f"RAW chunk in {src} has {data_sz} bytes, expected {expected}"
                    )
                _copy_n_bytes(inp, out, data_sz)
            elif chunk_type == CHUNK_TYPE_FILL:
                if data_sz != 4:
                    raise ToolError(f"FILL chunk in {src} has invalid size {data_sz}")
                fill = inp.read(4)
                repeats, remainder = divmod(output_bytes, 4)
                chunk = fill * min(repeats, 1024)
                for _ in range(repeats // 1024):
                    out.write(chunk)
                if repeats % 1024:
                    out.write(fill * (repeats % 1024))
                if remainder:
                    out.write(fill[:remainder])
            elif chunk_type == CHUNK_TYPE_DONT_CARE:
                if output_bytes:
                    out.seek(output_bytes - 1, io.SEEK_CUR)
                    out.write(b"\0")
            elif chunk_type == CHUNK_TYPE_CRC32:
                if data_sz != 4:
                    raise ToolError(f"CRC32 chunk in {src} has invalid size {data_sz}")
                inp.read(4)
            else:
                raise ToolError(f"Unsupported sparse chunk type {chunk_type:#x} in {src}")

            blocks_written += chunk_sz

        expected_bytes = total_blocks * block_size
        out.truncate(expected_bytes)
        if blocks_written != total_blocks:
            raise ToolError(
                f"Sparse conversion mismatch for {src}: wrote {blocks_written} blocks, "
                f"expected {total_blocks}"
            )


def _copy_n_bytes(inp: io.BufferedReader, out: io.BufferedWriter, size: int) -> None:
    remaining = size
    while remaining:
        chunk = inp.read(min(remaining, 1024 * 1024))
        if not chunk:
            raise ToolError("Unexpected end of file while copying sparse chunk")
        out.write(chunk)
        remaining -= len(chunk)


def ensure_raw_image(src: Path, raw_dir: Path) -> Path:
    raw_dir.mkdir(parents=True, exist_ok=True)
    if not is_sparse_image(src):
        return src
    dst = raw_dir / f"{src.stem}.raw{src.suffix if src.suffix != '.img' else '.img'}"
    sparse_to_raw(src, dst)
    return dst


def create_zero_image(path: Path, size_bytes: int) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as fp:
        fp.truncate(size_bytes)
    return path


def build_partition_specs(images_dir: Path, raw_dir: Path) -> list[PartitionSpec]:
    def require(name: str) -> Path:
        path = images_dir / name
        if not path.exists():
            raise ToolError(f"Required image not found: {path}")
        return path

    def optional(name: str) -> Path | None:
        path = images_dir / name
        return path if path.exists() else None

    misc = optional("misc.img")
    if misc is None:
        misc = create_zero_image(raw_dir / "misc.img", 1 * 1024 * 1024)

    metadata = optional("metadata.img")
    if metadata is None:
        metadata = create_zero_image(raw_dir / "metadata.img", 64 * 1024 * 1024)

    boot = require("boot.img")
    init_boot = optional("init_boot.img")
    vendor_boot = require("vendor_boot.img")
    vbmeta = require("vbmeta.img")
    vbmeta_system = require("vbmeta_system.img")
    vbmeta_vendor_dlkm = optional("vbmeta_vendor_dlkm.img")
    vbmeta_system_dlkm = optional("vbmeta_system_dlkm.img")
    super_img = require("super.img")
    userdata = require("userdata.img")

    specs = [
        PartitionSpec("misc", ensure_raw_image(misc, raw_dir)),
        PartitionSpec("boot_a", ensure_raw_image(boot, raw_dir)),
        PartitionSpec("boot_b", ensure_raw_image(boot, raw_dir)),
    ]
    if init_boot is not None:
        init_boot_raw = ensure_raw_image(init_boot, raw_dir)
        specs.extend(
            [
                PartitionSpec("init_boot_a", init_boot_raw),
                PartitionSpec("init_boot_b", init_boot_raw),
            ]
        )
    vendor_boot_raw = ensure_raw_image(vendor_boot, raw_dir)
    specs.extend(
        [
            PartitionSpec("vendor_boot_a", vendor_boot_raw),
            PartitionSpec("vendor_boot_b", vendor_boot_raw),
        ]
    )

    vbmeta_raw = ensure_raw_image(vbmeta, raw_dir)
    specs.extend(
        [
            PartitionSpec("vbmeta_a", vbmeta_raw),
            PartitionSpec("vbmeta_b", vbmeta_raw),
        ]
    )

    vbmeta_system_raw = ensure_raw_image(vbmeta_system, raw_dir)
    specs.extend(
        [
            PartitionSpec("vbmeta_system_a", vbmeta_system_raw),
            PartitionSpec("vbmeta_system_b", vbmeta_system_raw),
        ]
    )

    if vbmeta_vendor_dlkm is not None:
        vbmeta_vendor_dlkm_raw = ensure_raw_image(vbmeta_vendor_dlkm, raw_dir)
        specs.extend(
            [
                PartitionSpec("vbmeta_vendor_dlkm_a", vbmeta_vendor_dlkm_raw),
                PartitionSpec("vbmeta_vendor_dlkm_b", vbmeta_vendor_dlkm_raw),
            ]
        )

    if vbmeta_system_dlkm is not None:
        vbmeta_system_dlkm_raw = ensure_raw_image(vbmeta_system_dlkm, raw_dir)
        specs.extend(
            [
                PartitionSpec("vbmeta_system_dlkm_a", vbmeta_system_dlkm_raw),
                PartitionSpec("vbmeta_system_dlkm_b", vbmeta_system_dlkm_raw),
            ]
        )

    specs.extend(
        [
            PartitionSpec("super", ensure_raw_image(super_img, raw_dir)),
            PartitionSpec("userdata", ensure_raw_image(userdata, raw_dir)),
            PartitionSpec("metadata", ensure_raw_image(metadata, raw_dir)),
        ]
    )
    return specs


def align_up(value: int, align: int) -> int:
    return ((value + align - 1) // align) * align


def _partition_name_bytes(name: str) -> bytes:
    encoded = name.encode("utf-16le")
    if len(encoded) > 72:
        raise ToolError(f"GPT label too long: {name}")
    return encoded.ljust(72, b"\0")


def _pack_gpt_partition_entry(
    type_guid: uuid.UUID,
    unique_guid: uuid.UUID,
    first_lba: int,
    last_lba: int,
    attributes: int,
    name: str,
) -> bytes:
    return (
        type_guid.bytes_le
        + unique_guid.bytes_le
        + struct.pack("<QQQ", first_lba, last_lba, attributes)
        + _partition_name_bytes(name)
    )


def _gpt_header(
    *,
    current_lba: int,
    backup_lba: int,
    first_usable_lba: int,
    last_usable_lba: int,
    disk_guid: uuid.UUID,
    partition_entry_lba: int,
    partition_array_crc32: int,
) -> bytes:
    header = bytearray(SECTOR_SIZE)
    struct.pack_into(
        "<8sIIIIQQQQ16sQIII",
        header,
        0,
        b"EFI PART",
        0x00010000,
        GPT_HEADER_SIZE,
        0,
        0,
        current_lba,
        backup_lba,
        first_usable_lba,
        last_usable_lba,
        disk_guid.bytes_le,
        partition_entry_lba,
        GPT_NUM_PARTITION_ENTRIES,
        GPT_PARTITION_ENTRY_SIZE,
        partition_array_crc32,
    )
    header_crc = binascii.crc32(header[:GPT_HEADER_SIZE]) & 0xFFFFFFFF
    struct.pack_into("<I", header, 16, header_crc)
    return bytes(header)


def _protective_mbr(total_lbas: int) -> bytes:
    mbr = bytearray(SECTOR_SIZE)
    entry = struct.pack(
        "<B3sB3sII",
        0x00,
        b"\0\2\0",
        0xEE,
        b"\xff\xff\xff",
        1,
        min(total_lbas - 1, 0xFFFFFFFF),
    )
    mbr[446 : 446 + len(entry)] = entry
    mbr[510:512] = b"\x55\xaa"
    return bytes(mbr)


def write_gpt_disk(output_path: Path, partitions: list[PartitionSpec]) -> dict:
    if not partitions:
        raise ToolError("No partitions were supplied for GPT assembly")

    prepared: list[tuple[PartitionSpec, int, int, int]] = []
    current_offset = GPT_ALIGN_BYTES
    first_usable_lba = current_offset // SECTOR_SIZE
    last_partition_end = current_offset

    for partition in partitions:
        size_bytes = partition.image_path.stat().st_size
        if size_bytes == 0:
            raise ToolError(f"Partition image is empty: {partition.image_path}")
        start = align_up(current_offset, GPT_ALIGN_BYTES)
        end = start + size_bytes
        start_lba = start // SECTOR_SIZE
        end_lba = (end + SECTOR_SIZE - 1) // SECTOR_SIZE - 1
        prepared.append((partition, start, start_lba, end_lba))
        current_offset = align_up(end, GPT_ALIGN_BYTES)
        last_partition_end = max(last_partition_end, end)

    minimum_tail = (GPT_PARTITION_ARRAY_SECTORS + 1) * SECTOR_SIZE
    total_size = align_up(last_partition_end + minimum_tail, GPT_ALIGN_BYTES)
    total_lbas = total_size // SECTOR_SIZE
    last_usable_lba = total_lbas - GPT_PARTITION_ARRAY_SECTORS - 2
    backup_partition_entry_lba = total_lbas - GPT_PARTITION_ARRAY_SECTORS - 1
    backup_header_lba = total_lbas - 1

    partition_array = bytearray(
        GPT_NUM_PARTITION_ENTRIES * GPT_PARTITION_ENTRY_SIZE
    )
    manifest_partitions = []
    for index, (partition, _start, start_lba, end_lba) in enumerate(prepared):
        entry = _pack_gpt_partition_entry(
            LINUX_FS_GUID,
            uuid.uuid4(),
            start_lba,
            end_lba,
            0,
            partition.label,
        )
        entry_offset = index * GPT_PARTITION_ENTRY_SIZE
        partition_array[entry_offset : entry_offset + len(entry)] = entry
        manifest_partitions.append(
            {
                "label": partition.label,
                "source_image": str(partition.image_path),
                "first_lba": start_lba,
                "last_lba": end_lba,
                "size_bytes": partition.image_path.stat().st_size,
            }
        )

    partition_array_crc32 = binascii.crc32(partition_array) & 0xFFFFFFFF
    disk_guid = uuid.uuid4()
    primary_header = _gpt_header(
        current_lba=1,
        backup_lba=backup_header_lba,
        first_usable_lba=first_usable_lba,
        last_usable_lba=last_usable_lba,
        disk_guid=disk_guid,
        partition_entry_lba=2,
        partition_array_crc32=partition_array_crc32,
    )
    backup_header = _gpt_header(
        current_lba=backup_header_lba,
        backup_lba=1,
        first_usable_lba=first_usable_lba,
        last_usable_lba=last_usable_lba,
        disk_guid=disk_guid,
        partition_entry_lba=backup_partition_entry_lba,
        partition_array_crc32=partition_array_crc32,
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("wb") as disk:
        disk.truncate(total_size)
        disk.seek(0)
        disk.write(_protective_mbr(total_lbas))
        disk.seek(SECTOR_SIZE)
        disk.write(primary_header)
        disk.seek(2 * SECTOR_SIZE)
        disk.write(partition_array)
        disk.seek(backup_partition_entry_lba * SECTOR_SIZE)
        disk.write(partition_array)
        disk.seek(backup_header_lba * SECTOR_SIZE)
        disk.write(backup_header)
        for partition, start, _start_lba, _end_lba in prepared:
            disk.seek(start)
            with partition.image_path.open("rb") as source:
                shutil.copyfileobj(source, disk)

    return {
        "disk_image": str(output_path),
        "disk_guid": str(disk_guid),
        "size_bytes": total_size,
        "partitions": manifest_partitions,
    }


def extract_selected_images(zip_path: Path, out_dir: Path) -> list[str]:
    wanted = {
        "android-info.txt",
        "boot.img",
        "fastboot-info.txt",
        "init_boot.img",
        "metadata.img",
        "misc.img",
        "misc_info.txt",
        "super.img",
        "userdata.img",
        "vbmeta.img",
        "vbmeta_system.img",
        "vbmeta_system_dlkm.img",
        "vbmeta_vendor_dlkm.img",
        "vendor_boot.img",
    }
    extracted: list[str] = []
    out_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as archive:
        names = set(archive.namelist())
        for name in sorted(wanted & names):
            archive.extract(name, out_dir)
            extracted.append(name)
    missing = sorted({"boot.img", "super.img", "userdata.img", "vendor_boot.img"} - set(extracted))
    if missing:
        raise ToolError(
            f"{zip_path} did not contain the expected required images: {', '.join(missing)}"
        )
    return extracted


def build_qemu_script(
    script_path: Path, disk_path: Path, bootloader_path: Path
) -> None:
    script = f"""\
#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${{BASH_SOURCE[0]}}")" && pwd)"
QEMU_BIN="${{QEMU_BIN:-qemu-system-aarch64}}"
CPUS="${{CF_CPUS:-8}}"
MEMORY_MB="${{CF_MEMORY_MB:-8192}}"

if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
  echo "missing $QEMU_BIN in PATH" >&2
  echo "Install qemu-system-aarch64 (package names vary by distro: qemu-system-arm or qemu-system-misc)." >&2
  exit 1
fi

MACHINE="virt,gic-version=2,usb=off"
ACCEL_ARGS=()
if [[ "$(uname -m)" == "aarch64" ]]; then
  MACHINE="virt,gic-version=3,usb=off"
  if [[ -e /dev/kvm ]]; then
    ACCEL_ARGS=(-accel kvm)
  fi
fi

exec "$QEMU_BIN" \\
  -machine "$MACHINE" \\
  "${{ACCEL_ARGS[@]}}" \\
  -cpu cortex-a76 \\
  -smp "$CPUS" \\
  -m "${{MEMORY_MB}}M" \\
  -nographic \\
  -serial mon:stdio \\
  -no-reboot \\
  -device virtio-rng-pci \\
  -netdev user,id=net0 \\
  -device virtio-net-pci,netdev=net0 \\
  -drive "file={disk_path},if=none,id=drive-virtio-disk0,format=raw,aio=threads" \\
  -device virtio-blk-pci-non-transitional,drive=drive-virtio-disk0,id=virtio-disk0,bootindex=1 \\
  -bios "{bootloader_path}"
"""
    script_path.write_text(script)
    script_path.chmod(0o755)


def cmd_list_artifacts(args: argparse.Namespace) -> int:
    artifacts = ci_list_artifacts(args.build_id, args.target)
    for artifact in artifacts:
        print(
            f"{artifact.get('name','<unknown>')}\t"
            f"{artifact.get('size','?')}\t"
            f"{artifact.get('contentType','?')}"
        )
    return 0


def cmd_download(args: argparse.Namespace) -> int:
    output_dir = Path(args.output_dir).resolve()
    artifacts = args.artifact or [DEFAULT_IMAGE_ARTIFACT]
    failures = 0
    for artifact in artifacts:
        print(f"Downloading {artifact} ...")
        try:
            path = download_artifact(args.build_id, args.target, artifact, output_dir)
            print(f"Wrote {path}")
        except ArtifactUnavailableError as exc:
            failures += 1
            eprint(f"{artifact}: unavailable\n{exc}")
        except ToolError as exc:
            failures += 1
            eprint(f"{artifact}: failed\n{exc}")
    return 1 if failures else 0


def cmd_download_bootloader(args: argparse.Namespace) -> int:
    output_path = Path(args.output).resolve()
    download_bootloader(output_path, ref=args.ref)
    print(f"Wrote {output_path}")
    return 0


def cmd_prepare(args: argparse.Namespace) -> int:
    out_dir = Path(args.output_dir).resolve()
    images_dir = out_dir / "images"
    raw_dir = out_dir / "raw"
    bootloader_dir = out_dir / "bootloader"
    qemu_dir = out_dir / "qemu"

    if args.images_zip:
        zip_path = Path(args.images_zip).resolve()
        extracted = extract_selected_images(zip_path, images_dir)
        print(f"Extracted {len(extracted)} image artifacts from {zip_path}")
    elif args.images_dir:
        src_dir = Path(args.images_dir).resolve()
        if src_dir != images_dir:
            images_dir.mkdir(parents=True, exist_ok=True)
            for entry in src_dir.iterdir():
                if entry.is_file():
                    target = images_dir / entry.name
                    if target.exists():
                        continue
                    try:
                        os.link(entry, target)
                    except OSError:
                        shutil.copy2(entry, target)
        else:
            images_dir.mkdir(parents=True, exist_ok=True)
    else:
        raise ToolError("prepare requires either --images-zip or --images-dir")

    bootloader_path = (
        Path(args.bootloader).resolve() if args.bootloader else bootloader_dir / "u-boot.bin"
    )
    if not bootloader_path.exists():
        print(f"Downloading public qemu_aarch64 bootloader to {bootloader_path}")
        download_bootloader(bootloader_path)

    partitions = build_partition_specs(images_dir, raw_dir)
    qemu_dir.mkdir(parents=True, exist_ok=True)
    disk_path = qemu_dir / "android_cf_arm64.qcowless.raw"
    manifest = write_gpt_disk(disk_path, partitions)
    manifest_path = qemu_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

    launch_script = qemu_dir / "run-qemu.sh"
    build_qemu_script(launch_script, disk_path, bootloader_path)

    print(f"Disk image: {disk_path}")
    print(f"Bootloader: {bootloader_path}")
    print(f"Manifest:   {manifest_path}")
    print(f"Launcher:   {launch_script}")
    return 0


def cmd_launch(args: argparse.Namespace) -> int:
    run_script = Path(args.run_script).resolve()
    if not run_script.exists():
        raise ToolError(f"Launch script not found: {run_script}")
    os.execv(run_script, [str(run_script)])
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Download and prepare cuttlefish ARM64 Android CI images for QEMU."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    list_parser = subparsers.add_parser("list-artifacts", help="List build artifacts")
    list_parser.add_argument("--build-id", default=DEFAULT_BUILD_ID)
    list_parser.add_argument("--target", default=DEFAULT_TARGET)
    list_parser.set_defaults(func=cmd_list_artifacts)

    download_parser = subparsers.add_parser(
        "download", help="Download one or more artifacts from public Android CI"
    )
    download_parser.add_argument("--build-id", default=DEFAULT_BUILD_ID)
    download_parser.add_argument("--target", default=DEFAULT_TARGET)
    download_parser.add_argument(
        "--artifact",
        action="append",
        help="Artifact name to download. Repeat for multiple artifacts.",
    )
    download_parser.add_argument("--output-dir", default="artifacts/downloads")
    download_parser.set_defaults(func=cmd_download)

    bootloader_parser = subparsers.add_parser(
        "download-bootloader",
        help="Download the public cuttlefish qemu_aarch64 U-Boot binary",
    )
    bootloader_parser.add_argument("--output", default="artifacts/bootloader/u-boot.bin")
    bootloader_parser.add_argument("--ref", default=DEFAULT_BOOTLOADER_REF)
    bootloader_parser.set_defaults(func=cmd_download_bootloader)

    prepare_parser = subparsers.add_parser(
        "prepare",
        help="Extract image artifacts, unsparse them, and build a GPT QEMU disk",
    )
    prepare_group = prepare_parser.add_mutually_exclusive_group(required=True)
    prepare_group.add_argument("--images-zip", help="Path to the CI image zip")
    prepare_group.add_argument(
        "--images-dir",
        help="Directory containing already extracted image files",
    )
    prepare_parser.add_argument(
        "--bootloader",
        help="Path to qemu_aarch64 u-boot.bin; downloads a public fallback if omitted",
    )
    prepare_parser.add_argument("--output-dir", default="artifacts/prepared")
    prepare_parser.set_defaults(func=cmd_prepare)

    launch_parser = subparsers.add_parser(
        "launch", help="Exec the generated QEMU launch script"
    )
    launch_parser.add_argument(
        "--run-script", default="artifacts/prepared/qemu/run-qemu.sh"
    )
    launch_parser.set_defaults(func=cmd_launch)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except ToolError as exc:
        eprint(exc)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
