#!/usr/bin/env bash
# Builds the app icon from the same CupGlyph the menu bar draws, so the two
# always match. Usage: Packaging/make-icon.sh OUTPUT.icns
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 OUTPUT.icns" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.cache/make-icon"
mkdir -p "${BUILD_DIR}"

swiftc -O \
  -module-cache-path "${CLANG_MODULE_CACHE_PATH:-${ROOT_DIR}/.cache/clang}" \
  -o "${BUILD_DIR}/make-icon" \
  "${ROOT_DIR}/Sources/Shorty/CupGlyph.swift" \
  "${ROOT_DIR}/Packaging/MakeIcon/main.swift"

"${BUILD_DIR}/make-icon" "$1"
