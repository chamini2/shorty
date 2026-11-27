#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/.cache"
APP_DIR="${SCRIPT_DIR}/dist/Shorty.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

INSTALL=0
BUILD_ARGS=()
for arg in "$@"; do
  if [[ "${arg}" == "--install" ]]; then
    INSTALL=1
  else
    BUILD_ARGS+=("${arg}")
  fi
done

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${CACHE_DIR}/clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-${CACHE_DIR}/swiftpm}"

rm -rf "${APP_DIR}"

cd "${SCRIPT_DIR}"
mkdir -p "${CLANG_MODULE_CACHE_PATH}" "${SWIFTPM_MODULECACHE_OVERRIDE}"

"${SCRIPT_DIR}/build.sh" -c release ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}

BIN_DIR="$(swift build -c release ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} --show-bin-path)"
SHORTY_BIN="${BIN_DIR}/Shorty"

if [[ ! -x "${SHORTY_BIN}" ]]; then
  echo "Expected built binary at ${SHORTY_BIN}" >&2
  exit 1
fi

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${SHORTY_BIN}" "${MACOS_DIR}/Shorty"
cp "${SCRIPT_DIR}/Packaging/Shorty-Info.plist" "${CONTENTS_DIR}/Info.plist"
"${SCRIPT_DIR}/Packaging/make-icon.sh" "${RESOURCES_DIR}/Shorty.icns"

# A stable signing identity keeps the app's designated requirement the same
# across rebuilds, so macOS does not drop Accessibility approval on reinstall.
# Ad-hoc signing changes identity every build, which resets the permission.
SIGN_IDENTITY="${SHORTY_SIGN_IDENTITY:-Shorty Local Signing}"

if command -v codesign >/dev/null 2>&1; then
  # A self-signed identity is usually untrusted, so `find-identity -p
  # codesigning` does not list it even though codesign signs with it happily.
  # Try the identity, and fall back only if that fails.
  if codesign --force --sign "${SIGN_IDENTITY}" "${APP_DIR}" 2>/dev/null; then
    echo "Signed with identity: ${SIGN_IDENTITY}"
  else
    codesign --force --sign - "${APP_DIR}" >/dev/null 2>&1 || true
    echo "Signed ad-hoc: identity '${SIGN_IDENTITY}' not found." >&2
    echo "Accessibility approval will reset on each reinstall. See README > Signing." >&2
  fi
fi

echo "Built ${APP_DIR}"

if [[ "${INSTALL}" -eq 1 ]]; then
  INSTALL_DIR="${SHORTY_INSTALL_DIR:-/Applications}"
  INSTALL_APP="${INSTALL_DIR}/Shorty.app"

  if pgrep -x Shorty >/dev/null 2>&1; then
    pkill -x Shorty || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pgrep -x Shorty >/dev/null 2>&1 || break
      sleep 0.1
    done
  fi

  rm -rf "${INSTALL_APP}"
  cp -R "${APP_DIR}" "${INSTALL_APP}"
  open "${INSTALL_APP}"
  echo "Installed and launched ${INSTALL_APP}"
fi
