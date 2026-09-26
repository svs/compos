#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'HELP'
Install the Linux x86_64 Compos executable.

Usage: bash install-linux.sh

Environment:
  COMPOS_REPO     GitHub repository. Default: svs/compos
  COMPOS_BIN_DIR  Executable directory. Default: $HOME/.local/bin

Example:
  COMPOS_REPO=harsh098/compos bash install-linux.sh

The script installs Compos. It does not start the server.
HELP
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
fi

repo="${COMPOS_REPO-svs/compos}"
bin_dir="${COMPOS_BIN_DIR:-$HOME/.local/bin}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
  die 'COMPOS_REPO must have the form owner/repository.'
[[ -n "$bin_dir" ]] || die 'COMPOS_BIN_DIR must not be empty.'

[[ "$(uname -s)" == Linux ]] || die 'This installer supports Linux only.'
[[ "$(uname -m)" == x86_64 ]] || die 'This installer supports x86_64 only.'

for tool in curl tar sha256sum install mktemp getconf mkdir mv rm; do
  command -v "$tool" >/dev/null 2>&1 || die "Install $tool, then run this script again."
done

glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null)" ||
  die 'Compos needs glibc. This release does not support Alpine Linux.'
[[ "$glibc" =~ ^glibc[[:space:]]([0-9]+)\.([0-9]+)$ ]] ||
  die "Cannot read the glibc version: $glibc"
(( BASH_REMATCH[1] > 2 || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] >= 39) )) ||
  die 'Use glibc 2.39 or later for this Linux release.'

work_dir=''
staged_binary=''
cleanup() {
  [[ -z "$staged_binary" ]] || rm -f -- "$staged_binary"
  [[ -z "$work_dir" ]] || rm -rf -- "$work_dir"
}
trap cleanup EXIT

printf 'Read the latest release in %s.\n' "$repo"
response="$(curl --silent --show-error --retry 3 --connect-timeout 15 --max-time 120 \
  --head --output /dev/null --write-out '%{http_code} %{redirect_url}' \
  "https://github.com/$repo/releases/latest")" ||
  die "Cannot connect to GitHub for $repo."
status="${response%% *}"
release_url="${response#* }"

if [[ "$status" == 404 || "$release_url" == "https://github.com/$repo/releases" ]]; then
  die "No published release exists in $repo. Set COMPOS_REPO to a repository with a Linux release."
fi
case "$status" in
  301|302|303|307|308) ;;
  *) die "Cannot find the latest release in $repo (HTTP $status)." ;;
esac
[[ "$release_url" == "https://github.com/$repo/releases/tag/"* ]] ||
  die "GitHub returned an unexpected release URL: $release_url"

download_url="${release_url/\/releases\/tag\//\/releases\/download\/}"
archive='compos-linux-x86_64.tar.gz'
work_dir="$(mktemp -d)"
cd "$work_dir"

download() {
  local file="$1" code
  code="$(curl --silent --show-error --location --retry 3 --connect-timeout 15 \
    --output "$file" --write-out '%{http_code}' "$download_url/$file")" ||
    die "Cannot download $file from $repo."
  [[ "$code" == 200 ]] || die "Linux asset $file is unavailable in $repo (HTTP $code)."
}

check_checksum() {
  local checksum_file="$1" file="$2" hash name extra
  local -a lines
  mapfile -t lines < "$checksum_file"
  [[ ${#lines[@]} -eq 1 ]] || die "Invalid checksum file: $checksum_file"
  read -r hash name extra <<< "${lines[0]}"
  name="${name#\*}"
  [[ "$hash" =~ ^[[:xdigit:]]{64}$ && "$name" == "$file" && -z "$extra" ]] ||
    die "Invalid checksum entry in $checksum_file."
  sha256sum --check "$checksum_file" || die "Checksum verification failed for $file."
}

printf 'Download Linux x86_64 assets from %s.\n' "$release_url"
download "$archive.sha256"
download "$archive"
check_checksum "$archive.sha256" "$archive"
tar -xzf "$archive" -- compos-linux-x86_64 SHA256SUMS
[[ -f compos-linux-x86_64 && ! -L compos-linux-x86_64 ]] ||
  die 'The archive does not contain a regular executable file.'
check_checksum SHA256SUMS compos-linux-x86_64

mkdir -p -- "$bin_dir"
bin_dir="$(cd "$bin_dir" && pwd -P)"
staged_binary="$(mktemp "$bin_dir/.compos.XXXXXX")"
install -m 0755 compos-linux-x86_64 "$staged_binary"
mv -f -- "$staged_binary" "$bin_dir/compos"
staged_binary=''

printf '\nInstalled Compos at %s/compos\n' "$bin_dir"
printf 'Source: %s\n' "$release_url"
printf '\nTo start Compos, run:\n'
printf 'COMPOS_BIND=127.0.0.1 COMPOS_PORT=4004 %q\n' "$bin_dir/compos"
printf '\nOpen http://localhost:4004 in a browser after the server starts.\n'
