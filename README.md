# vlsync

A shell script that syncs a local directory of MP3s and `.m3u` playlists to [VLC for iOS](https://apps.apple.com/app/vlc-for-mobile/id650377962) over Wi-Fi, skipping files already on the device. Re-running is always safe and idempotent.

## How it works

VLC for iOS exposes a Wi-Fi upload interface. `vlsync.sh` uses that interface to push files, with two deduplication strategies:

- **MP3s** — fetched from VLC's `/libMediaVLC.xml` media list and skipped if already present
- **`.m3u` playlists** — VLC doesn't list these, so a local MD5 cache (`.m3u_cache` in your sync directory) tracks what's been uploaded

If VLC becomes unreachable mid-sync (e.g. the app is backgrounded), the script waits and retries automatically.

> **Note:** VLC has no delete API. Removing a file from your local directory does **not** remove it from the device — delete unwanted files manually in the VLC app.

## Requirements

- macOS (uses `md5 -q`; adapt to `md5sum` for Linux)
- `curl`
- `python3`

## Usage

```sh
./vlsync.sh --ip=<IP> --dir=<DIR> [OPTIONS]
```

### Options

| Flag | Description |
|------|-------------|
| `--ip IP` | VLC iOS device IP address (required) |
| `-d, --dir DIR` | Local directory to sync from (required) |
| `--reset-playlists` | Clear the `.m3u` cache so all playlists are re-uploaded next run |
| `-h, --help` | Show help |

### Examples

```sh
# Basic sync
./vlsync.sh --ip=192.168.4.21 --dir=~/Music

# Force re-upload of all playlists
./vlsync.sh --ip=192.168.4.21 --dir=~/Music --reset-playlists
```

## Finding your device IP

In VLC for iOS: **Settings → Wi-Fi Sharing** — the IP address is shown there while sharing is active.

## File name handling

VLC and `curl` have restrictions on certain characters in filenames (fullwidth Unicode, commas, quotes). The script sanitizes filenames before upload — transliterating non-ASCII characters and stripping or replacing problematic ones — so the on-device names are always ASCII-safe. Playlist `.m3u` file references should use the same sanitized names to match correctly.
