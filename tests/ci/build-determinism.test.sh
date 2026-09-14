#!/bin/bash

set -euo pipefail

# Test for build non-determinism.
#
# Spawns N parallel `pnpm build` commands, each building the current revision
# (HEAD) into a different git worktree. If any build fails, the test fails.
# If all builds succeed, it computes the IPFS CID of each build's `dist`
# directory (`pnpm omnipin pack --only-hash dist`) and verifies that they all
# match. Different CIDs mean the build is not reproducible and deterministic.
#
# Each build must run sandboxed via `bwrap` (see deploy/build.sh), which binds
# the worktree to a fixed path so that the absolute paths Astro embeds into
# its output (e.g. the `astro-island uid`) do not depend on where each
# worktree happens to be checked out.
#
# WALLETBEAT_MUST_INSTALL_DEPENDENCIES_CLEANLY is set so that the build
# *requires* bwrap and installs dependencies cleanly inside the sandbox.
#
# This test is intentionally NOT part of the default `check:all` runs.
# It is invoked only by the dedicated CI workflow via `pnpm run check:ci`.
# It can be invoked manually with `pnpm run check:ci:build-determinism`.

# Number of parallel builds to compare. Overridable via env (CI uses more to
# exercise the non-determinism more often).
BUILD_COUNT="${WALLETBEAT_DETERMINISM_BUILD_COUNT:-4}"

log() {
	echo "[Build determinism]" "$@" >&2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HEAD="$(git -C "$ROOT" rev-parse HEAD)"

WORKTREE_ROOT="$(mktemp -d)"
cleanup() {
	local name
	for name in $(seq 1 "$BUILD_COUNT"); do
		git -C "$ROOT" worktree remove --force "$WORKTREE_ROOT/build-$name" 2>/dev/null || true
	done
	rm -rf "$WORKTREE_ROOT"
}
trap cleanup EXIT

log "Creating $BUILD_COUNT worktrees at $HEAD..."
for name in $(seq 1 "$BUILD_COUNT"); do
	if ! git -C "$ROOT" worktree add --force --detach "$WORKTREE_ROOT/build-$name" "$HEAD" >/dev/null 2>&1; then
		log "Could not create worktree build-$name."
		exit 1
	fi
done

log "Building in $BUILD_COUNT worktrees in parallel..."
pids=()
for name in $(seq 1 "$BUILD_COUNT"); do
	(
		cd "$WORKTREE_ROOT/build-$name" || exit 1
		if ! WALLETBEAT_MUST_INSTALL_DEPENDENCIES_CLEANLY=true pnpm build >/dev/null 2>&1; then
			log "\`pnpm build\` failed for build-$name."
			exit 1
		fi
	) &
	pids+=("$!")
done

failed=0
for pid in "${pids[@]}"; do
	if ! wait "$pid"; then
		failed=1
	fi
done
if [[ "$failed" -ne 0 ]]; then
	log "At least one build failed; test FAILED."
	exit 1
fi

log "All builds succeeded. Computing bundle CIDs..."
cids=()
for name in $(seq 1 "$BUILD_COUNT"); do
	dir="$WORKTREE_ROOT/build-$name"
	if [[ ! -d "$dir/dist" ]]; then
		log "No \`dist\` directory produced in build-$name."
		exit 1
	fi
	cid="$(pnpm omnipin pack --only-hash "$dir/dist" 2>/dev/null)"
	cids+=("$cid")
done

first="${cids[0]}"
all_same=1
for cid in "${cids[@]}"; do
	if [[ "$cid" != "$first" ]]; then
		all_same=0
	fi
done

if [[ "$all_same" -eq 1 ]]; then
	log "OK: all $BUILD_COUNT bundles had an identical CID: $first"
	exit 0
fi

log "FAIL: found different bundle CID hashes (build is non-deterministic):"
for name in $(seq 1 "$BUILD_COUNT"); do
	log "  build-$name: ${cids[$((name - 1))]}"
done

# Debug: dump the exact differing files/bytes between the first build and each
# differing build. This is only for diagnosing the root cause.
log "Debug: dumping diffs against build-1..."
for name in $(seq 2 "$BUILD_COUNT"); do
	if [[ "${cids[$((name - 1))]}" == "$first" ]]; then
		continue
	fi
	log "Debug: build-1 vs build-$name differing files:"
	diff -rq "$WORKTREE_ROOT/build-1/dist" "$WORKTREE_ROOT/build-$name/dist" 2>&1 \
		| while read -r line; do log "  $line"; done
	# Show first differing lines of up to 3 files.
	count=0
	while read -r line; do
		if [[ "$line" =~ ^Files[[:space:]]+(.*)[[:space:]]and[[:space:]]+(.*)[[:space:]]differ$ ]]; then
			f1="${BASH_REMATCH[1]}"
			f2="${BASH_REMATCH[2]}"
			log "Debug: diff $f1"
			diff "$f1" "$f2" 2>&1 | head -c 600 | while read -r dl; do log "    $dl"; done
			count=$((count + 1))
			if [[ "$count" -ge 3 ]]; then break; fi
		fi
	done < <(diff -rq "$WORKTREE_ROOT/build-1/dist" "$WORKTREE_ROOT/build-$name/dist" 2>&1)
done

exit 1
