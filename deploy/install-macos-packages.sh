#!/bin/bash

# Installs the macOS packages listed in macos-packages.txt.
#
# Inkscape is installed from a DMG that is hosted on `media.inkscape.org`.
# That host's CDN is unreliable and frequently fails to serve the file
# (HTTP/2 stream resets, and HTTP 503 responses). Rather than let `brew
# install --cask` perform a single fragile download, this script fetches the
# DMG itself with a resilient `curl` invocation and then mounts it and copies
# the app bundle into place. A verified copy of the DMG is kept in a cache
# directory (populated by the CI workflow via `actions/cache`) so that
# subsequent runs do not have to reach the flaky CDN at all.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_FILE="$SCRIPT_DIR/macos-packages.txt"

# Directory in which a verified DMG is kept so it can be reused (and cached
# by the CI workflow) across runs. Override in CI to match the cache path.
CACHE_DIR="${WALLETBEAT_MACOS_CACHE_DIR:-$HOME/.cache/walletbeat-macos}"

# Inkscape version and the SHA-256 of its arm64 DMG. Keep these in sync with
# the upstream Homebrew cask (https://formulae.brew.sh/cask/inkscape).
INKSCAPE_VERSION="1.4.4"
INKSCAPE_SHA256="eacca94ab01e59467cdd5452a2867c3734450f9a4cfb3346956cc9b07f34f3f1"
INKSCAPE_URL="https://media.inkscape.org/dl/resources/file/Inkscape-${INKSCAPE_VERSION}_arm64.dmg"
INKSCAPE_DMG="$CACHE_DIR/Inkscape-${INKSCAPE_VERSION}_arm64.dmg"

log() {
	echo "[install-macos]" "$@" >&2
}

fail() {
	echo "[install-macos] ERROR: $*" >&2
	exit 1
}

# Download a URL to a path, retrying transient failures with backoff.
#
# `--http1.1` avoids the HTTP/2 stream resets the Inkscape CDN produces.
# `--fail` makes non-2xx responses (e.g. the transient HTTP 503s) fail the
# transfer so the retry loop can re-attempt. `--retry-all-errors` covers the
# remaining transient network failures. The Inkscape CDN does not support
# range requests (it answers 501), so a failed transfer is always restarted
# from scratch rather than resumed.
download_with_retry() {
	local url="$1" dest="$2" attempt=1 max_attempts=5 delay=5
	mkdir -p "$(dirname "$dest")"
	while [[ "$attempt" -le "$max_attempts" ]]; do
		log "Downloading $url (attempt $attempt/$max_attempts)..."
		if curl -fL --http1.1 --retry 3 --retry-all-errors \
			--retry-delay 5 --connect-timeout 30 --max-time 600 \
			-o "$dest" "$url"; then
			return 0
		fi
		log "Download attempt $attempt failed. Retrying in ${delay}s..."
		rm -f "$dest"
		sleep "$delay"
		attempt=$((attempt + 1))
		delay=$((delay * 2))
	done
	return 1
}

# Verify that a DMG matches the expected SHA-256.
verify_inkscape() {
	local actual
	actual="$(shasum -a 256 "$INKSCAPE_DMG" 2>/dev/null | awk '{print $1}')"
	[[ "$actual" == "$INKSCAPE_SHA256" ]]
}

# Ensure the Inkscape DMG is present and valid, downloading it if needed.
ensure_inkscape_dmg() {
	if [[ -f "$INKSCAPE_DMG" ]] && verify_inkscape; then
		log "Using cached Inkscape DMG at $INKSCAPE_DMG."
		return 0
	fi
	rm -f "$INKSCAPE_DMG"
	download_with_retry "$INKSCAPE_URL" "$INKSCAPE_DMG" || fail "Failed to download Inkscape."
	if ! verify_inkscape; then
		fail "Inkscape DMG checksum mismatch; refusing to install."
	fi
	log "Inkscape DMG downloaded and verified."
}

# Mount the Inkscape DMG and copy the app bundle into /Applications.
install_inkscape() {
	local mount_point
	mount_point="$(mktemp -d)"
	hdiutil attach "$INKSCAPE_DMG" -nobrowse -mountpoint "$mount_point" >/dev/null
	if [[ ! -d "$mount_point/Inkscape.app" ]]; then
		hdiutil detach "$mount_point" >/dev/null 2>&1 || true
		rmdir "$mount_point"
		fail "Inkscape.app not found in DMG."
	fi
	rm -rf /Applications/Inkscape.app
	cp -R "$mount_point/Inkscape.app" /Applications/
	hdiutil detach "$mount_point" >/dev/null
	rmdir "$mount_point"
	# Expose the CLI on PATH so the tests can invoke `inkscape`.
	ln -sfn "/Applications/Inkscape.app/Contents/MacOS/inkscape" /usr/local/bin/inkscape
}

main() {
	[[ "$(uname -s)" == "Darwin" ]] || fail "This script is only for macOS."
	[[ -f "$PACKAGES_FILE" ]] || fail "Package list not found: $PACKAGES_FILE"

	# Only Inkscape is listed today. Install it via the resilient DMG path.
	# Any future packages should be handled here or via `brew install`.
	if grep -qx 'inkscape' "$PACKAGES_FILE"; then
		ensure_inkscape_dmg
		install_inkscape
	fi

	if ! command -v inkscape >/dev/null 2>&1; then
		fail "inkscape is not available on PATH after installation."
	fi
	log "All macOS packages installed."
}

main "$@"
