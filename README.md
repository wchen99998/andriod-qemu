# android16-aosp-qemu-utm

Build Android 16 from AOSP and package the result as an ARM64 artifact that can
boot under raw QEMU on Apple Silicon and be adapted to UTM custom QEMU mode.

This repository does **not** vendor AOSP itself. Instead, it provides an
end-to-end pipeline that:

1. downloads AOSP Android 16 source,
2. builds an ARM64 AOSP target that uses virtio-oriented virtual hardware,
3. unpacks the Android boot images,
4. assembles a single GPT disk image with Android partitions, and
5. emits a launch bundle for macOS QEMU/UTM-style VMs.

## Default target

The default product is:

- `aosp_trout_arm64-trunk_staging-userdebug`

This repository intentionally does **not** default to a Cuttlefish product.
Instead it uses AOSP's upstream Trout ARM64 product because Trout is the
reference virtio-based Android guest platform intended for QEMU-style
virtualization. The trade-off is that Trout is an Android Automotive oriented
product, not a phone product.

On Android 16 branches, upstream lunch targets use the three-part form
`<product>-<release>-<variant>`, so this repository models that directly rather
than assuming the older two-part `product-variant` syntax.

## Repository layout

- `docker/Dockerfile` - Ubuntu builder image with AOSP prerequisites
- `scripts/fetch-aosp.sh` - initializes and syncs Android 16 source
- `scripts/build-aosp.sh` - runs lunch + AOSP build
- `scripts/package-qemu-utm.sh` - creates a boot bundle for macOS QEMU/UTM-like
  use
- `scripts/install-host-deps.sh` - installs host-native build dependencies
- `scripts/e2e.sh` - fetch + build + package
- `scripts/docker-e2e.sh` - host-side Docker wrapper
- `.env.example` - configurable defaults

## What gets produced

After a successful run, the packaging step writes:

- `artifacts/<artifact-name>/<artifact-name>.raw`
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

3. Run either the native-host flow or the Docker flow.

### Native-host flow

Install dependencies:

```bash
./scripts/install-host-deps.sh
```

Run the full pipeline directly on Linux:

```bash
./scripts/e2e.sh
```

### Docker flow

Run the full Dockerized pipeline:

   ```bash
   ./scripts/docker-e2e.sh
   ```

Both flows will:

- sync Android 16 source into `work/aosp`, and
- package the resulting artifact into `artifacts/`.

The Docker wrapper additionally builds the Docker image and mounts persistent
`work/` directories into the container.

## Important defaults

These values can be overridden in `.env` or via environment variables:

```bash
AOSP_BRANCH=android16-release
TARGET_PRODUCT=aosp_trout_arm64
TARGET_RELEASE=trunk_staging
TARGET_VARIANT=userdebug
JOBS=<host cpu count>
```

## Host-native smoke testing

For a lightweight host-native validation of the fetch step, you can sync only
the projects needed to confirm that Android 16 still exposes the Trout target:

```bash
REPO_SYNC_PROJECTS="platform/build platform/build/soong device/google/trout platform/system/tools/mkbootimg" \
  ./scripts/fetch-aosp.sh
```

This is **not** enough for a full build, but it is useful for checking manifest
shape and lunch target availability without pulling the entire tree.

## Example overrides

Build a different Android 16 branch pointer:

```bash
AOSP_BRANCH=android-latest-release ./scripts/e2e.sh
```

Use Docker instead of the native host:

```bash
./scripts/docker-e2e.sh
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
- a Linux build host

The resulting guest artifact targets ARM64 for Apple Silicon Macs, but the build
host remains Linux because upstream AOSP build tooling is Linux-oriented.

## Notes and assumptions

- The packaging stage preserves the boot image command line extracted from AOSP
  build outputs and appends bootconfig values when present.
- Trout is an Android Automotive oriented product. If you need a phone-style UI,
  this repository will likely need downstream product work rather than just a
  lunch target switch.
- The produced disk image is intended for experimentation and development.
  Android-on-generic-QEMU remains less turnkey than stock Linux guests.
- This repo deliberately keeps the source checkout outside git under `work/aosp`.
