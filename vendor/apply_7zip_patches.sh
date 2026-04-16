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

# Snapshot the submodule state so a mid-loop patch failure can roll
# everything back to a clean, fully-unapplied working tree. Without
# this, a partial apply leaves a mix of staged and unstaged edits that
# subsequent runs cannot reliably identify as "applied" or "not
# applied", and the next invocation silently skips the broken patch.
submodule_rollback_ref=$(git -C "$submodule_dir" rev-parse HEAD)
submodule_rollback_needed=true

cleanup() {
  rm -f "$patch_list" "$unique_patch_list"
  if [ "$submodule_rollback_needed" = true ]; then
    echo "Rolling $submodule_name back to $submodule_rollback_ref due to patch failure" >&2
    git -C "$submodule_dir" reset --hard "$submodule_rollback_ref" >/dev/null 2>&1 || true
    git -C "$submodule_dir" clean -fd >/dev/null 2>&1 || true
  fi
}

trap 'cleanup' EXIT HUP INT TERM

# Count every patch that targets this submodule — irrespective of the
# version/commit marker — so we can detect the case where the
# submodule has been bumped to a new upstream release but the vendor
# patches still carry the old version in their filenames. Without this
# sanity check the old logic would silently drop to zero matches,
# leave the submodule completely unpatched, and exit 0.
all_candidate_patches=$(find "$script_dir" -maxdepth 1 -type f -name "$submodule_name-*.patch" | wc -l | tr -d ' ')

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

# We got through the loop without a non-zero exit; disable rollback.
submodule_rollback_needed=false

if [ "$found_patch" = false ]; then
  if [ "$all_candidate_patches" -gt 0 ]; then
    echo "error: $submodule_name has $all_candidate_patches candidate patch(es) under vendor/ but none match" >&2
    echo "       version=$current_version base=$base_version commit=$current_commit." >&2
    echo "       Did the submodule get bumped without refreshing the patch set?" >&2
    exit 1
  fi
  exit 0
fi