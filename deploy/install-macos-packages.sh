#!/bin/bash

# Installs the macOS packages listed in macos-packages.txt.
#
# Each line is a `name:version` entry (e.g. `inkscape:1.4.4`). For every
# package, this script dispatches to a specialized `install_<name>` function
# if one is defined in this file; otherwise it falls back to a generic
# `brew install --cask`. A specialized handler is needed when a package cannot
# be installed reliably by brew (e.g. because its download source is
# unreliable and must be fetched and verified before install).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_FILE="$SCRIPT_DIR/macos-packages.txt"

# Directory in which a verified download is kept so it can be reused (and
# cached by the CI workflow) across runs. Override in CI to match the cache
# path.
CACHE_DIR="${WALLETBEAT_MACOS_CACHE_DIR:-$HOME/.cache/walletbeat-macos}"

log() {
	echo "[install-macos]" "$@" >&2
}

fail() {
	echo "[install-macos] ERROR: $*" >&2
	exit 1
}

# Download a URL to a path, retrying transient failures with backoff.
#
# `--http1.1` avoids the HTTP/2 stream resets some CDNs produce. `--fail`
# makes non-2xx responses (e.g. transient HTTP 503s) fail the transfer so the
# retry loop can re-attempt. `--retry-all-errors` covers the remaining
# transient network failures. Some CDNs do not support range requests (they
# answer 501), so a failed transfer is always restarted from scratch rather
# than resumed.
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

# Verify that a file matches the expected SHA-256.
verify_sha256() {
	local file="$1" expected="$2" actual
	actual="$(shasum -a 256 "$file" 2>/dev/null | awk '{print $1}')"
	[[ "$actual" == "$expected" ]]
}

# Install a package generically via Homebrew cask.
install_with_brew() {
	local name="$1"
	brew install --cask "$name"
}

# ---------------------------------------------------------------------------
# Specialized install handlers. Each is invoked with the version parsed from
# the package line, or an empty string if the line has no version suffix.
# ---------------------------------------------------------------------------

# SHA-256 of the Inkscape arm64 DMG, keyed by version. Keep these in sync with
# the upstream Homebrew cask (https://formulae.brew.sh/cask/inkscape). A
# `case` is used rather than an associative array because the macOS runner's
# `/bin/bash` is version 3.2, which does not support associative arrays.
inkscape_sha256() {
	local version="$1"
	case "$version" in
		"1.4.4")
			echo "eacca94ab01e59467cdd5452a2867c3734450f9a4cfb3346956cc9b07f34f3f1"
			;;
		*)
			return 1
			;;
	esac
}

install_inkscape() {
	local version="$1"
	local sha url dmg mount_point
	sha="$(inkscape_sha256 "$version")" || fail "Unknown Inkscape version '$version'; no checksum available."
	url="https://media.inkscape.org/dl/resources/file/Inkscape-${version}_arm64.dmg"
	dmg="$CACHE_DIR/Inkscape-${version}_arm64.dmg"

	if [[ -f "$dmg" ]] && verify_sha256 "$dmg" "$sha"; then
		log "Using cached Inkscape DMG at $dmg."
	else
		rm -f "$dmg"
		download_with_retry "$url" "$dmg" || fail "Failed to download Inkscape ${version}."
		verify_sha256 "$dmg" "$sha" || fail "Inkscape ${version} DMG checksum mismatch; refusing to install."
		log "Inkscape DMG downloaded and verified."
	fi

	mount_point="$(mktemp -d)"
	hdiutil attach "$dmg" -nobrowse -mountpoint "$mount_point" >/dev/null
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

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

main() {
	[[ "$(uname -s)" == "Darwin" ]] || fail "This script is only for macOS."
	[[ -f "$PACKAGES_FILE" ]] || fail "Package list not found: $PACKAGES_FILE"

	local line name version handler
	while IFS= read -r line; do
		[[ -z "$line" || "$line" == \#* ]] && continue

		name="${line%%:*}"
		version=""
		if [[ "$line" == *:* ]]; then
			version="${line#*:}"
		fi

		handler="install_${name}"
		if declare -F "$handler" >/dev/null 2>&1; then
			log "Installing $name via specialized handler."
			"$handler" "$version"
		else
			log "Installing $name via brew."
			install_with_brew "$name"
		fi
	done < "$PACKAGES_FILE"

	log "All macOS packages installed."
}

main "$@"
