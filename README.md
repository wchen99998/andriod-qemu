# android-qemu

Prepare the public Android CI build
`12884649 / aosp_cf_arm64_only_phone-trunk_staging-userdebug`
for direct boot under `qemu-system-aarch64`.

This repository now contains a self-contained workflow that:

1. Talks to the public `ci.android.com` artifact API.
2. Downloads the public ARM64 Cuttlefish QEMU bootloader (`u-boot.bin`).
3. Extracts the Android image zip.
4. Converts Android sparse images to raw without `simg2img`.
5. Rebuilds the partition set into one GPT disk image with the same partition
   labels that Cuttlefish's `assemble_cvd` uses.
6. Generates a direct QEMU launch script.

## Important limitation for this exact build

The requested build still appears in the public CI metadata index, but its
artifact download URLs currently resolve to missing GCS objects (`NoSuchKey`).
In practice that means:

- `list-artifacts` works
- metadata inspection works
- direct byte download for this aged build currently fails upstream

The tooling here detects that condition and reports it clearly. If you already
have a local copy of the image zip, or if the same target is available in a
newer build whose artifacts have not expired, the prepare/launch workflow is
ready to use.

## Repository layout

- `tools/cf_qemu.py` - downloader, sparse-image converter, GPT disk builder,
  and QEMU launcher generator.

## Requirements

The script is intentionally light on external dependencies:

- Python 3.10+
- `unzip`
- `qemu-system-aarch64` only when you actually launch

The cloud environment used for this change did not permit `apt-get`, so QEMU
could not be installed system-wide here. The generated launch script checks for
`qemu-system-aarch64` and prints a package hint when it is missing.

Typical packages by distro:

- Debian/Ubuntu: `qemu-system-arm` or `qemu-system-misc`
- Fedora: `qemu-system-aarch64`
- Arch: `qemu-system-aarch64`

## Usage

### 1) List the public artifacts for the build

```bash
python3 tools/cf_qemu.py list-artifacts
```

### 2) Attempt to download the image zip from public CI

```bash
python3 tools/cf_qemu.py download \
  --artifact aosp_cf_arm64_only_phone-img-12884649.zip
```

If the build has aged out of public retention, the script will tell you that
the metadata still exists but the backing object is gone.

### 3) Prepare a local image zip for QEMU

If you have the image zip locally already:

```bash
python3 tools/cf_qemu.py prepare \
  --images-zip /path/to/aosp_cf_arm64_only_phone-img-12884649.zip
```

This produces:

- `artifacts/prepared/images/` - extracted partition images
- `artifacts/prepared/raw/` - raw converted copies of sparse images
- `artifacts/prepared/bootloader/u-boot.bin` - public QEMU ARM64 bootloader
- `artifacts/prepared/qemu/android_cf_arm64.qcowless.raw` - single GPT disk
- `artifacts/prepared/qemu/run-qemu.sh` - direct QEMU launcher

You can also point it at an already-extracted directory:

```bash
python3 tools/cf_qemu.py prepare \
  --images-dir /path/to/extracted-images
```

### 4) Launch directly in QEMU

```bash
artifacts/prepared/qemu/run-qemu.sh
```

Or:

```bash
python3 tools/cf_qemu.py launch
```

## Boot sequence

The generated boot flow mirrors the ARM64 Cuttlefish layout from AOSP:

1. `qemu-system-aarch64` starts with `-bios u-boot.bin`.
2. U-Boot reads the GPT on the generated raw disk.
3. It selects slot `a` semantics from the standard Android A/B partition names
   (`boot_a`, `init_boot_a`, `vendor_boot_a`, `vbmeta_a`, and friends).
4. Verified Boot metadata is taken from:
   - `vbmeta_a`
   - `vbmeta_system_a`
   - optional `vbmeta_vendor_dlkm_a`
   - optional `vbmeta_system_dlkm_a`
5. The bootloader loads:
   - `boot_a`
   - `init_boot_a`
   - `vendor_boot_a`
6. Android first-stage init mounts:
   - `metadata`
   - `misc`
   - dynamic partitions from `super`
   - `userdata`

## Partition map used for the generated disk

The GPT builder intentionally follows the same labels used by
`device/google/cuttlefish/host/commands/assemble_cvd/disk_flags.cc`:

- `misc`
- `boot_a`, `boot_b`
- `init_boot_a`, `init_boot_b` if present
- `vendor_boot_a`, `vendor_boot_b`
- `vbmeta_a`, `vbmeta_b`
- `vbmeta_system_a`, `vbmeta_system_b`
- `vbmeta_vendor_dlkm_a`, `vbmeta_vendor_dlkm_b` if present
- `vbmeta_system_dlkm_a`, `vbmeta_system_dlkm_b` if present
- `super`
- `userdata`
- `metadata`

If `misc.img` or `metadata.img` is absent, the tool creates blank placeholders
matching the Cuttlefish defaults:

- `misc`: 1 MiB
- `metadata`: 64 MiB

## Notes

- This repo uses the public `qemu_aarch64/u-boot.bin` bootloader from
  `device/google/cuttlefish_prebuilts` as a fallback, so a host package is not
  required just to get a bootloader.
- The generated disk image is raw even though the file name is explicit about
  that; it is not qcow2.
- The downloader uses the same public CI API surface as the website, including
  the browser `Origin` and `Referer` headers required by the key-restricted API.
