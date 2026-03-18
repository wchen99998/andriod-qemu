#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/fetch-aosp.sh"
"${SCRIPT_DIR}/build-aosp.sh"
"${SCRIPT_DIR}/package-qemu-utm.sh"
