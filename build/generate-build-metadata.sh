#!/bin/sh

set -eu

info_plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
commit_count="$(git -C "${SRCROOT}" rev-list --count HEAD 2>/dev/null || printf '0')"
short_hash="$(git -C "${SRCROOT}" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"

set_plist_value() {
  local plist_path="$1"
  local key="$2"
  local value="$3"

  if /usr/libexec/PlistBuddy -c "Print :${key}" "${plist_path}" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "${plist_path}"
  else
    /usr/libexec/PlistBuddy -c "Add :${key} string ${value}" "${plist_path}"
  fi
}

set_plist_value "${info_plist}" "CFBundleVersion" "${commit_count}"
set_plist_value "${info_plist}" "ShichiZipGitShortHash" "${short_hash}"

if [ -n "${SHICHIZIP_LICENSE_SOURCE_PATH:-}" ]; then
  license_source="${SRCROOT}/${SHICHIZIP_LICENSE_SOURCE_PATH}"
  license_dest="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/7zip-license.txt"

  mkdir -p "$(dirname "${license_dest}")"
  cp "${license_source}" "${license_dest}"
fi

if [ -n "${SHICHIZIP_SFX_SOURCE_PATH:-}" ]; then
  sfx_source="${SRCROOT}/${SHICHIZIP_SFX_SOURCE_PATH}"
  sfx_dest="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/7z.sfx"

  if [ ! -f "${sfx_source}" ]; then
    echo "Missing required SFX payload: ${sfx_source}" >&2
    exit 1
  fi

  cp "${sfx_source}" "${sfx_dest}"
fi
