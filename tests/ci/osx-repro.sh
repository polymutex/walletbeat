#!/bin/bash
# OSX-CI flake reproduction harness.
#
# Reproduces the Vite dependency-optimizer race that intermittently fails the
# macOS "Run all checks" step of .github/workflows/check.yaml.
#
# check:all runs several pnpm scripts in PARALLEL (pnpm run "/^check:(astro|...)$/").
# Three of those scripts all start a Vite process against the SAME node_modules:
#   - check:astro       -> `astro check`   (starts Vite)
#   - check:lint        -> `astro sync`    (starts Vite)
#   - check:build:post:quiet -> `astro build` (starts Vite)
# Vite's dependency optimizer writes to node_modules/.vite/deps via an atomic
# rename of a temp dir (deps_temp_XXX -> deps). When two Vite processes race,
# one loses the rename with `ENOTEMPTY: directory not empty` and the step fails.
#
# This harness runs the exact trio in parallel over many iterations and records
# every failure with full Vite debug logging.

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

ITERATIONS="${OSX_REPRO_ITERATIONS:-10}"
PARALLEL="${OSX_REPRO_PARALLEL:-3}"   # number of concurrent Vite processes

export VITE_DEBUG="${VITE_DEBUG:-1}"
export DEBUG="${DEBUG:-vite:*}"
export ASTRO_TELEMETRY_DISABLED=1
export WALLETBEAT_ENV=CI

failures=0
start=$(date +%s)

for ((i = 1; i <= ITERATIONS; i++)); do
	echo "=== [OSX-REPRO] iteration $i / $ITERATIONS (parallel=$PARALLEL) ==="
	rm -rf node_modules/.vite

	# Launch the three Vite-triggering checks concurrently, exactly like check:all.
	pids=()
	pnpm run astro sync > "/tmp/osx-repro-$i-sync.log" 2>&1 &
	pids+=($!)
	pnpm run astro check > "/tmp/osx-repro-$i-check.log" 2>&1 &
	pids+=($!)
	(cd "$REPO_DIR" && pnpm run astro build > "/tmp/osx-repro-$i-build.log" 2>&1) &
	pids+=($!)

	# Extra parallel Vite processes to increase collision probability.
	for ((p = 0; p < PARALLEL - 3; p++)); do
		pnpm run astro sync > "/tmp/osx-repro-$i-x$p.log" 2>&1 &
		pids+=($!)
	done

	iter_fail=0
	for pid in "${pids[@]}"; do
		if ! wait "$pid"; then
			iter_fail=1
		fi
	done

	if [[ "$iter_fail" -eq 1 ]]; then
		failures=$((failures + 1))
		echo ">>> [OSX-REPRO] iteration $i FAILED"
		echo ">>> ENOTEMPTY / rename evidence:"
		grep -rh "ENOTEMPTY\|deps_temp\|directory not empty\|rename" /tmp/osx-repro-$i-*.log 2>/dev/null | head -20
	else
		echo ">>> [OSX-REPRO] iteration $i ok"
	fi
done

elapsed=$(( $(date +%s) - start ))
echo ""
echo "=== [OSX-REPRO] RESULT: $failures / $ITERATIONS iterations failed (${elapsed}s) ==="
if [[ "$failures" -gt 0 ]]; then
	echo "REPRODUCED: $failures failures"
	exit 1
fi
echo "NO FAILURE REPRODUCED"
