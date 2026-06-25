#!/usr/bin/env bash
# =============================================================================
# VLSync (vlsync.sh)
# Syncs a local directory of MP3s and .m3u playlists to a VLC for iOS device
# via its Wi-Fi upload interface, skipping anything already on the device:
#   - MP3s   → checked against VLC's structured /libMediaVLC.xml media list
#   - .m3u   → VLC doesn't list these, so skipped via a small local MD5 cache
# Re-running is always safe and idempotent.
#
# Usage:
#   ./vlsync.sh --ip=<IP> --dir=<DIR> [OPTIONS]
#
# Options:
#   --ip IP             VLC iOS IP address for Wi-Fi sync (e.g. 192.168.4.21) (required)
#   -d, --dir DIR       Directory to sync from (required)
#   --reset-playlists   Re-upload all .m3u playlist files on the next sync.
#   -h, --help          Show this help message
#
# Notes:
#   VLC has no delete API; removing a file from --dir does NOT remove it from the
#   device. Delete unwanted files manually in the VLC app.
#
# Examples:
#   ./vlsync.sh --ip=192.168.4.21 --dir=~/Music
#   ./vlsync.sh --ip=192.168.4.21 --dir=~/Music --reset-playlists
#
# Dependencies: curl, python3
# =============================================================================

set -euo pipefail

# --------------------
# Defaults
# --------------------
SYNC_DIR=""       # required, set via --dir; directory to sync from
VLC_IP=""         # required, set via --ip
VLC_URL=""
M3U_CACHE=""      # set after SYNC_DIR is finalised
RESET_M3U_CACHE=false

# --------------------
# Colors for output
# --------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
print_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
print_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --------------------
# Help
# --------------------
show_help() {
  grep '^#' "$0" | grep -v '#!/' | sed 's/^# \?//'
  exit 0
}

# Compute the filename VLC will store a file under. Must be used everywhere
# (upload, dedup check) so the names always agree with what VLC lists:
# 1. Replace fullwidth/special chars that iconv can't translate and that break
#    curl's file-open path handling (＂ ⧸ etc.)
# 2. Transliterate remaining non-ASCII (accents like À) to ASCII via iconv
# 3. Strip ? (iconv placeholder) and " (VLC URL-encodes it, breaking matches);
#    replace comma (curl -F option delimiter) with hyphen
vlc_safe_name() {
  # iconv returns non-zero when it performs a non-reversible transliteration
  # (e.g. À -> `A); the trailing || true keeps the function from tripping set -e
  # under pipefail while still emitting the converted name.
  printf '%s' "$1" \
    | sed 's/⧸/-/g; s/＂//g; s/：/-/g; s/？//g; s/！/!/g; s/＊/-/g' \
    | { iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null || true; } \
    | sed 's/?//g; s/"//g; s/,/-/g'
}

# Upload a single file to VLC. Copies to a sanitized temp filename first because
# curl's -F parser breaks on commas (option delimiter) and certain fullwidth Unicode
# chars (＂ ⧸) that confuse curl's file-open path handling.
vlc_upload() {
  local src="$1" url="$2"
  local fname safe_fname tmpdir tmpfile
  fname=$(basename "$src")
  safe_fname=$(vlc_safe_name "$fname")
  tmpdir=$(mktemp -d /tmp/vlcsyncXXXXXX)
  tmpfile="$tmpdir/$safe_fname"
  cp "$src" "$tmpfile"
  curl -sf -F "files[]=@$tmpfile" "$url/upload.json" > /dev/null 2>&1
  local status=$?
  rm -rf "$tmpdir"
  return $status
}

# Wait until VLC is reachable, retrying every 10 seconds.
vlc_wait() {
  local url="$1"
  until curl -sf --max-time 5 "$url/" > /dev/null 2>&1; do
    print_warn "VLC unreachable — waiting 10s for it to come back (keep VLC open)..."
    sleep 10
  done
}

# Fetch the set of filenames currently on VLC (one per line), parsed from VLC's
# structured /libMediaVLC.xml media list. Each <Media> element carries a pathfile
# attribute (the on-device file path); we extract and URL-decode the basename.
# A partial/truncated response would drop files and cause spurious re-uploads,
# so we insist on a complete transfer: retry until curl exits 0.
vlc_fetch_filelist() {
  local url="$1"
  local xml attempt=0
  while :; do
    if xml=$(curl -sf --max-time 30 "$url/libMediaVLC.xml"); then
      break
    fi
    (( attempt++ )) || true
    if [[ $attempt -ge 5 ]]; then
      print_warn "Could not fetch a complete file list from VLC after 5 tries; skipping dedup this run." >&2
      return 0
    fi
    print_warn "Incomplete file list from VLC — retrying ($attempt/5)..." >&2
    vlc_wait "$url"
    sleep 2
  done
  printf '%s' "$xml" | python3 -c "
import sys, re, urllib.parse
xml = sys.stdin.read()
names = set()
for p in re.findall(r'pathfile=\"http://[^/]+/download/([^\"]+)\"', xml):
    names.add(urllib.parse.unquote(p).split('/Documents/')[-1])
print('\n'.join(sorted(names)))
"
}

# Sync all mp3/m3u files in a directory to VLC, skipping files already on the device.
# MP3s: checked against VLC's live file listing.
# M3U files: VLC doesn't list them, so skipped via a local MD5 cache.
vlc_sync() {
  local dir="$1" url="$2" depth="$3"
  local SYNC_COUNT=0 SYNC_ERRORS=0 FNAME SAFE_FNAME CHECKSUM

  print_info "Fetching file list from VLC..."
  local vlc_files
  vlc_files=$(vlc_fetch_filelist "$url")
  touch "$M3U_CACHE"

  while IFS= read -r -d '' f; do
    FNAME=$(basename "$f")
    SAFE_FNAME=$(vlc_safe_name "$FNAME")
    # MP3s: skip if VLC already has the file
    if [[ "$f" == *.mp3 ]] && echo "$vlc_files" | grep -qF "$SAFE_FNAME"; then
      continue
    fi
    # M3U files: skip if content hasn't changed since last upload
    if [[ "$f" == *.m3u ]]; then
      CHECKSUM=$(md5 -q "$f")
      if grep -qF "$CHECKSUM  $SAFE_FNAME" "$M3U_CACHE"; then
        continue
      fi
    fi
    # Retry loop: if upload fails, wait for VLC to come back and retry
    local attempts=0
    while ! vlc_upload "$f" "$url"; do
      (( attempts++ )) || true
      if [[ $attempts -ge 10 ]]; then
        print_warn "Giving up on: $FNAME after 10 attempts."
        (( SYNC_ERRORS++ )) || true
        break
      fi
      print_warn "Upload failed: $FNAME — waiting for VLC..."
      vlc_wait "$url"
      sleep 3  # give VLC a moment to fully wake up after reconnect
    done
    if [[ $attempts -lt 10 ]]; then
      (( SYNC_COUNT++ )) || true
      print_info "Uploaded: $FNAME"
      if [[ "$f" == *.m3u ]]; then
        CHECKSUM=$(md5 -q "$f")
        # Remove any old entry for this file, then append the new checksum
        grep -vF "  $SAFE_FNAME" "$M3U_CACHE" > "${M3U_CACHE}.tmp" || true
        echo "$CHECKSUM  $SAFE_FNAME" >> "${M3U_CACHE}.tmp"
        mv "${M3U_CACHE}.tmp" "$M3U_CACHE"
      fi
    fi
  done < <(find "$dir" -maxdepth "$depth" \( -name "*.mp3" -o -name "*.m3u" \) -print0 | sort -z)
  print_success "Synced $SYNC_COUNT file(s) to VLC."
  [[ "$SYNC_ERRORS" -gt 0 ]] && print_warn "$SYNC_ERRORS file(s) failed after retries."
}

# --------------------
# Argument parsing
# --------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip=*)        VLC_IP="${1#*=}"; shift ;;
    --ip)          VLC_IP="$2"; shift 2 ;;
    -d|--dir)      SYNC_DIR="$2"; shift 2 ;;
    --dir=*)       SYNC_DIR="${1#*=}"; shift ;;
    --reset-playlists)  RESET_M3U_CACHE=true; shift ;;
    -h|--help)     show_help ;;
    -*)
      print_error "Unknown option: $1"
      echo "Run with --help for usage."
      exit 1
      ;;
    *)
      print_error "Unexpected argument: $1"
      echo "Run with --help for usage."
      exit 1
      ;;
  esac
done

# --------------------
# Validate input
# --------------------
if [[ -z "$VLC_IP" ]]; then
  print_error "No VLC IP provided. Use --ip=<IP> (e.g. 192.168.4.21)."
  echo ""
  echo "Usage: $0 --ip=<IP> --dir=<DIR> [OPTIONS]"
  echo "       $0 --help"
  exit 1
fi

if [[ -z "$SYNC_DIR" ]]; then
  print_error "No directory provided. Use --dir=<DIR> to set the folder to sync from."
  exit 1
fi

if [[ ! -d "$SYNC_DIR" ]]; then
  print_error "Directory does not exist: $SYNC_DIR"
  exit 1
fi

M3U_CACHE="$SYNC_DIR/.m3u_cache"
[[ "$RESET_M3U_CACHE" == true ]] && rm -f "$M3U_CACHE" && print_info "Playlist cache cleared — all .m3u files will be re-uploaded."

# --------------------
# Sync
# --------------------
VLC_URL="http://$VLC_IP"
print_info "Uploading all files in $SYNC_DIR to VLC at $VLC_URL..."
vlc_wait "$VLC_URL"
vlc_sync "$SYNC_DIR" "$VLC_URL" 2
