#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
submodule_arg="${1:-vendor/7zip}"

case "$submodule_arg" in
  /*)
    submodule_dir="$submodule_arg"
    ;;
  *)
    submodule_dir="$repo_root/$submodule_arg"
    ;;
esac

submodule_name=$(basename "$submodule_dir")

if [ ! -d "$submodule_dir" ]; then
  echo "$submodule_arg is missing" >&2
  exit 1
fi

current_commit=$(git -C "$submodule_dir" rev-parse HEAD)
current_version=$(sed -n 's/^#define MY_VERSION_NUMBERS "\([^"]*\)"/\1/p' "$submodule_dir/C/7zVersion.h" | head -n 1)
base_version=${current_version%% *}
found_patch=false
patch_list=$(mktemp "${TMPDIR:-/tmp}/shichizip-patches.XXXXXX")
unique_patch_list=$(mktemp "${TMPDIR:-/tmp}/shichizip-patches-unique.XXXXXX")

trap 'rm -f "$patch_list" "$unique_patch_list"' EXIT HUP INT TERM

for prefix in "$submodule_name"; do
  find "$script_dir" -maxdepth 1 -type f -name "$prefix-$current_version-*.patch" -print >> "$patch_list"
  find "$script_dir" -maxdepth 1 -type f -name "$prefix-$base_version-*.patch" -print >> "$patch_list"
  find "$script_dir" -maxdepth 1 -type f -name "$prefix-$current_commit-*.patch" -print >> "$patch_list"
done

LC_ALL=C sort -u "$patch_list" > "$unique_patch_list"

while IFS= read -r patch; do
  if [ -z "$patch" ]; then
    continue
  fi

  found_patch=true

  if git -C "$submodule_dir" apply --reverse --check "$patch" >/dev/null 2>&1; then
    echo "$submodule_name patch already applied: $(basename "$patch")"
    continue
  fi

  git -C "$submodule_dir" apply --check "$patch"
  git -C "$submodule_dir" apply "$patch"
  echo "Applied $submodule_name patch: $(basename "$patch")"
done < "$unique_patch_list"

if [ "$found_patch" = false ]; then
  exit 0
fi