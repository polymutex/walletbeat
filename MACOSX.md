# macOS (`macos-latest`) CI — Issues and Resolution

## Summary

The `check` workflow was extended to run on `ubuntu-latest`, `windows-latest`, and `macos-latest`. On macOS, **1 of 8** `check-quick` jobs initially failed. It was resolved, and the workflow now passes on all three platforms (including the `check-full` job).

## Initial failure (run `34798296631`)

| Check                                        | Result      |
| -------------------------------------------- | ----------- |
| Check: Astro (`check:astro`)                 | ✅ pass     |
| Test: Vitest (`check:vitest`)                | ✅ pass     |
| Lint: ESLint (`check:lint`)                  | ✅ pass     |
| Format: Prettier (`check:syntax`)            | ✅ pass     |
| Spell check: CSpell (`check:spelling:quiet`) | ✅ pass     |
| Other checks (`check:misc`)                  | ✅ pass     |
| Build: Astro (`check:build:post:quiet`)      | ❌ **fail** |
| Commit signature (`check:signed-commit`)     | ✅ pass     |

macOS was in much better shape than Windows: 7 of 8 checks passed immediately. The only failure was the build. Notably, the Prettier check passed on macOS because the `.jsonc` file is checked out with LF there (the line-ending problem was Windows-only).

The `check-full` job was initially skipped because it `needs: check-quick`, which had not fully succeeded.

---

## Failure: Build: Astro (`check:build:post:quiet`)

### Root cause

On macOS the Bash scripts execute correctly (macOS uses `/bin/bash` by default), so the failure happened *inside* `deploy/build.sh`, not at the shell-invocation layer. `deploy/build.sh` **hard-requires `bwrap` (bubblewrap)** whenever `WALLETBEAT_ENV=CI` is set:

```bash
if [[ "${WALLETBEAT_ENV:-}" == "CI" ]]; then
    echo "bwrap is required to sandbox the build (WALLETBEAT_ENV=CI), but bwrap is not installed." >&2
    exit 1
fi
```

`bwrap` is a **Linux-only** sandboxing tool (it relies on Linux kernel namespaces and `/proc`). It cannot be installed on `macos-latest`.

This was not an accident: the build must be sandboxed so Astro computes resource hashes (the `astro-island uid`s) against a fixed absolute path. Running unsandboxed would make the output depend on *where* the repo is checked out, producing a **non-deterministic** build. The `bwrap` sandbox binds the workspace to a fixed path (`/tmp/wb-build`), keeping the absolute paths stable and the build reproducible — which is exactly what `tests/ci/build-determinism.test.sh` verifies.

### Fix

Detect the host platform in `deploy/build.sh` (via `IS_LINUX` from `uname -s`) and only require the `bwrap` sandbox on Linux. On non-Linux hosts, build unsandboxed (with a warning that the build is non-deterministic).

Also updated `tests/ci/build-determinism.test.sh` to skip on non-Linux, since the test's entire premise (deterministic CIDs via bwrap sandboxing) only holds where bwrap is available.

---

## Additional latent issues (resolved during the wider fix)

These would have surfaced on macOS if `check-full` (`check:ci`) had run, and were addressed as part of getting the whole workflow green:

1. **`tests/ci/bundle-size-delta.test.sh`** uses `du -sb` (GNU-only; BSD/macOS `du` has no `-b` flag). This is a macOS/BSD portability concern.

2. **`deploy/build.sh`** previously used `tee /dev/stderr` in its no-tty branch, which fails in CI with "No such device or address" on all platforms (including Linux). This was replaced with a no-tty branch that echoes each build line to stdout/stderr and propagates the build's exit code.

3. **`deploy/build.sh`** uses GNU-only `sed -r` and `/proc`-based tty detection, but those paths are only reached when there is a tty (Linux), so they are not exercised on macOS CI.

4. **`deploy/helios/*.sh`** use `/proc/${PID}`, `seq`, and `mktemp -d --tmpdir=/dev/shm` (Linux-only `/dev/shm`). These are deploy-only and not part of `check:*`, so they are not macOS CI concerns.

---

## Final state

After all fixes, run `34815060919` passed on all three platforms:

- All 24 `check-quick` jobs pass (8 checks × 3 OS).
- `check-full` (`check:ci`) passes on **ubuntu-latest**, **windows-latest**, and **macos-latest**.

## Related notes

- `WINDOWS.md` and `MACOSX.md` are excluded from the grammar and spell checks (via `.gitignore` and cspell's `ignorePaths`) because they contain technical jargon (LF, CRLF, CSpell, etc.) that the project's grammar linter (Harper) does not recognize.
- On macOS (non-Linux), the astro-shield SRI integration is skipped (see WINDOWS.md), and `src/generated/sriHashes.mjs` is not regenerated; the SRI middleware is likewise skipped there.
