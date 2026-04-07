#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
submodule_dir="$repo_root/vendor/7zip"

if [ ! -d "$submodule_dir" ]; then
  echo "vendor/7zip is missing" >&2
  exit 1
fi

current_commit=$(git -C "$submodule_dir" rev-parse HEAD)
current_version=$(sed -n 's/^#define MY_VERSION_NUMBERS "\([^"]*\)"/\1/p' "$submodule_dir/C/7zVersion.h" | head -n 1)
found_patch=false

for pattern in "$script_dir"/7zip-"$current_version"-*.patch "$script_dir"/7zip-"$current_commit"-*.patch; do
  for patch in $pattern; do
    if [ ! -e "$patch" ]; then
      continue
    fi

    found_patch=true

    if git -C "$submodule_dir" apply --reverse --check "$patch" >/dev/null 2>&1; then
      echo "7-Zip patch already applied: $(basename "$patch")"
      continue
    fi

    git -C "$submodule_dir" apply --check "$patch"
    git -C "$submodule_dir" apply "$patch"
    echo "Applied 7-Zip patch: $(basename "$patch")"
  done
done

if [ "$found_patch" = false ]; then
  exit 0
fi