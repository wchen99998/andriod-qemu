# android16-aosp-qemu-utm

Build Android 16 from AOSP and package the result as an ARM64 artifact that can
boot under raw QEMU on Apple Silicon and be adapted to UTM custom QEMU mode.

This repository does **not** vendor AOSP itself. Instead, it provides an
end-to-end pipeline that:

1. downloads AOSP Android 16 source,
2. builds an ARM64 virtual-device target that already uses virtio-oriented
   virtual hardware,
3. unpacks the Android boot images,
4. assembles a single GPT disk image with Android partitions, and
5. emits a launch bundle for macOS QEMU/UTM-style VMs.

## Why this target

The default product is:

- `aosp_cf_arm64_only_phone-userdebug`

That keeps the build close to upstream AOSP while still targeting an ARM64
virtual device that uses QEMU-friendly virtio devices. If you want AOSP's more
explicit virtio-focused automotive reference platform, override the product with
`aosp_trout_arm64`.

## Repository layout

- `docker/Dockerfile` - Ubuntu builder image with AOSP prerequisites
- `scripts/fetch-aosp.sh` - initializes and syncs Android 16 source
- `scripts/build-aosp.sh` - runs lunch + AOSP build
- `scripts/package-qemu-utm.sh` - creates a boot bundle for macOS QEMU/UTM-like
  use
- `scripts/e2e.sh` - fetch + build + package
- `scripts/docker-e2e.sh` - host-side Docker wrapper
- `.env.example` - configurable defaults

## What gets produced

After a successful run, the packaging step writes:

- `artifacts/<artifact-name>/android16-arm64-qemu-utm.raw`
- `artifacts/<artifact-name>/kernel`
- `artifacts/<artifact-name>/initrd.img`
- `artifacts/<artifact-name>/run-qemu-macos.sh`
- `artifacts/<artifact-name>/README-macos-qemu.md`
- `artifacts/<artifact-name>/manifest.json`
- `artifacts/<artifact-name>.tar.zst`

The `.raw` file is a single GPT disk image populated with Android partitions
(`boot_a`, `vendor_boot_a`, `super`, `userdata`, and related metadata
partitions). The generated `run-qemu-macos.sh` script uses direct kernel boot,
which is the most practical way to boot self-built AOSP images under generic
QEMU on Apple Silicon.

## Quick start

1. Copy the environment file:

   ```bash
   cp .env.example .env
   ```

2. Adjust any defaults you want in `.env`.

3. Run the full Dockerized pipeline:

   ```bash
   ./scripts/docker-e2e.sh
   ```

This will:

- build the Docker image,
- mount persistent `work/` and `artifacts/` directories,
- sync Android 16 source into `work/aosp`, and
- package the resulting artifact into `artifacts/`.

## Important defaults

These values can be overridden in `.env` or via environment variables:

```bash
AOSP_BRANCH=android16-release
TARGET_PRODUCT=aosp_cf_arm64_only_phone
TARGET_VARIANT=userdebug
JOBS=<host cpu count>
```

## Example overrides

Build AOSP's virtio-oriented Trout target instead of Cuttlefish:

```bash
TARGET_PRODUCT=aosp_trout_arm64 ./scripts/docker-e2e.sh
```

Use the moving latest Android release branch instead of the fixed Android 16
branch:

```bash
AOSP_BRANCH=android-latest-release ./scripts/docker-e2e.sh
```

## Running the artifact on macOS

Install QEMU:

```bash
brew install qemu
```

Then copy the packaged artifact directory to the Mac and run:

```bash
chmod +x run-qemu-macos.sh
./run-qemu-macos.sh
```

### UTM note

UTM does not have first-class support for self-built Android AOSP images, so the
generated QEMU launcher is the canonical output of this repository. In UTM, use
its custom QEMU mode and mirror the generated kernel, initrd, disk, CPU, memory
and virtio device settings from `run-qemu-macos.sh`.

## Disk and build requirements

AOSP builds are large. Plan for at least:

- 400 GB free disk
- 32-64 GB RAM
- a Linux Docker host for the build itself

The resulting guest artifact targets ARM64 for Apple Silicon Macs, but the build
host remains Linux because upstream AOSP build tooling is Linux-oriented.

## Notes and assumptions

- The packaging stage preserves the boot image command line extracted from AOSP
  build outputs and appends bootconfig values when present.
- The produced disk image is intended for experimentation and development.
  Android-on-generic-QEMU remains less turnkey than stock Linux guests.
- This repo deliberately keeps the source checkout outside git under `work/aosp`.
