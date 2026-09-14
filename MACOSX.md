# macOS (`macos-latest`) CI Failures

## Run context

- Commit: `8144c59843fa3da6d19971b484470a775156a714` — "ci: run check workflow on ubuntu, windows, and macos"
- Workflow: `.github/workflows/check.yaml` (modified to add `windows-latest` / `macos-latest` to the `check-quick` matrix)
- Run ID: `34798296631`
- Result: overall run **failed** on macOS due to **1 of 8** `check-quick` jobs.

## Summary of macOS results

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

macOS is in much better shape than Windows: 7 of 8 checks pass. The single failure is the build, and it is **purely the `bwrap` (bubblewrap) sandbox requirement** — not a shell or line-ending issue. Note that the Prettier check passes on macOS because the `.jsonc` file is checked out with LF there (the line-ending problem is Windows-only).

The `check-full` job was **skipped** because it `needs: check-quick`, which did not fully succeed (see the "Additional latent issues" section for the consequences).

---

## Failure: Build: Astro (`pnpm run check:build:post:quiet`)

### Observed error

```text
$ cross-env QUIET=true pnpm run check:build:post
$ tests/postbuild.sh
$ deploy/build.sh
bwrap is required to sandbox the build (WALLETBEAT_ENV=CI), but bwrap is not installed.
[ELIFECYCLE] Command failed with exit code 1.
##[error]Process completed with exit code 1.
```

Note that on macOS the script **does execute** (`tests/postbuild.sh` and `deploy/build.sh` both run) — the failure happens _inside_ `deploy/build.sh`, not at the shell-invocation layer like on Windows. macOS uses `/bin/bash` by default, so the Bash scripts run fine. The abort is the explicit guard in `deploy/build.sh`:

```bash
if [[ "${WALLETBEAT_ENV:-}" == "CI" ]]; then
    echo "bwrap is required to sandbox the build (WALLETBEAT_ENV=CI), but bwrap is not installed." >&2
    exit 1
fi
```

### Root cause

`deploy/build.sh` **hard-requires `bwrap` (bubblewrap)** when `WALLETBEAT_ENV=CI` is set (which the workflow does for the Build step). `bwrap` is a **Linux-only** sandboxing tool — it relies on Linux kernel namespaces and `/proc`, and it cannot be installed on `macos-latest`.

This is not an accident. The build must be sandboxed for a deliberate reason: Astro computes resource hashes (the `astro-island uid`s) based on the **absolute path** of the source files on the filesystem. Running the build unsandboxed would make the output depend on _where_ the repo is checked out, producing a **non-deterministic** build. By running inside a `bwrap` sandbox that binds the workspace to a fixed path (`/tmp/wb-build`), the absolute paths are stable and the build is reproducible — which is exactly what `tests/ci/build-determinism.test.sh` verifies.

Because there is no `bwrap` on macOS, the build cannot satisfy its own determinism invariant, so it refuses to run in CI mode.

### Fix

This is a **structural/architectural** issue rather than a one-liner. Options, roughly in increasing effort:

1. **Run the Build check (and `check:ci`) only on Linux.** Keep `check-quick`/`check-full` running the non-build checks on macOS/Windows, but restrict the build + determinism checks to `ubuntu-latest`. This is the pragmatic path: macOS/Windows get lint, type, test, spell, format, and misc coverage; the deterministic build is validated on the platform it was designed for. Example workflow conditional:

   ```yaml
   - name: Build: Astro
     if: runner.os == 'Linux'
     run: pnpm run check:build:post:quiet
   ```

2. **Provide a cross-platform replacement for the bwrap sandbox.** Instead of sandboxing with namespaces, pin the checkout to a _fixed, well-known absolute path_ on every platform and run the build there. On GitHub-hosted runners the path is already fixed per-run (`/Users/runner/work/walletbeat/walletbeat`), but Astro's hashing needs the path to be identical _across_ build invocations and worktrees (the determinism test builds 4 separate `git worktree`s and requires identical CIDs). Achieving this without bwrap means either:
   - Copying/symlinking each worktree to a canonical fixed path before building, or
   - Configuring Astro to ignore absolute paths in its hashes (not supported by default), or
   - Using a cross-platform sandbox (e.g. a container runtime) — heavier and still not macOS-native.

3. **Relax the determinism check on non-Linux.** Set `WALLETBEAT_BUILD_MUST_BE_SANDBOXED` / the CI-sandbox requirement to off on macOS and accept a non-deterministic build there, while keeping the strict check on Linux. This weakens the guarantee and is generally undesirable, but is the minimal-effort path if cross-platform determinism is not required.

The most defensible long-term answer is option 1 (Linux-only for the deterministic build) combined with the portability fixes below, so macOS/Windows still get broad, meaningful coverage without the Linux-only bwrap dependency.

---

## Additional latent issues (would surface if `check-full` ran on macOS)

`check-full` was skipped because `check-quick` failed. If `check:ci` runs on macOS, these Bash-based tests would also hit portability problems. macOS ships BSD userland, which differs from GNU in several places:

1. **`tests/ci/bundle-size-delta.test.sh`** — uses `du -sb "$dir/dist"`. BSD/macOS `du` has **no `-b` flag** (GNU-only; BSD uses `-B`/`-k`). This would fail on macOS.

2. **`tests/ci/build-determinism.test.sh`** — requires `bwrap` (Linux-only, see above), so it is fatal on macOS regardless of other portability concerns.

3. **`deploy/build.sh`** — uses GNU-only `sed -r` (macOS `sed` uses `-E`), `/proc/$$/fd/2`, `readlink` on `/proc`, and `script -q -e -f` (GNU `script` flags differ from BSD `script`). These would need BSD-compatible alternatives.

4. **`deploy/helios/helios.sh` / `helios-wrap.sh`** — use `/proc/${PID}`, `seq`, and `mktemp -d --tmpdir=/dev/shm` (`/dev/shm` is Linux-only; macOS has no `/dev/shm`). These are deploy-only, not part of `check:*`, but they are not macOS-portable.

---

## Bottom line for macOS

- **No shell or line-ending problems** — macOS executes the Bash scripts and the `.jsonc` file stays LF. 7 of 8 checks already pass.
- **The single blocker is `bwrap`.** `deploy/build.sh` refuses to build in CI mode without the Linux-only bubblewrap sandbox, which is required for deterministic builds. This is an architectural constraint, not a bug in the script.
- **Recommended fix:** run the deterministic build + build-determinism checks only on `ubuntu-latest`, and keep macOS/Windows for the lint/type/test/spell/format/misc coverage. If full cross-platform builds are desired, a cross-platform replacement for the bwrap sandbox (fixed-path pinning or container runtime) is needed.
- **Deferred risk:** GNU-only utilities (`du -sb`, `sed -r`, `/dev/shm`, `/proc`) in the CI/deploy scripts would need BSD-compatible replacements before `check-full` can run on macOS.
