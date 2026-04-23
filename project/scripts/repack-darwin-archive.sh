#!/bin/sh

set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: $0 ZIG_EXE INPUT_ARCHIVE OUTPUT_ARCHIVE" >&2
  exit 1
fi

zig_exe="$1"
input_archive="$2"
output_archive="$3"

case "$input_archive" in
  /*) ;;
  *) input_archive="$(pwd -P)/$input_archive" ;;
esac

if [ ! -f "$input_archive" ]; then
  echo "missing input archive: $input_archive" >&2
  exit 1
fi

output_dir="$(dirname "$output_archive")"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/shichizip-darwin-archive.XXXXXX")"
work_dir="$work_root/work"

cleanup() {
  rm -rf "$work_root"
}

trap cleanup EXIT HUP INT TERM

mkdir -p "$output_dir" "$work_dir"
rm -f "$output_archive"

(
  cd "$work_dir"
  "$zig_exe" ar x "$input_archive"

  set -- ./*.o
  if [ "$1" = "./*.o" ]; then
    echo "archive extraction produced no object files: $input_archive" >&2
    exit 1
  fi

  # Zig's deterministic archive headers can leave extracted members unreadable.
  chmod u+rw "$@"

  "$zig_exe" ar --format=darwin rcs "$output_archive" "$@"
)
