# Windows (`windows-latest`) CI Failures

## Run context

- Commit: `8144c59843fa3da6d19971b484470a775156a714` — "ci: run check workflow on ubuntu, windows, and macos"
- Workflow: `.github/workflows/check.yaml` (modified to add `windows-latest` / `macos-latest` to the `check-quick` matrix)
- Run ID: `34798296631`
- Result: overall run **failed** on Windows due to **2 of 8** `check-quick` jobs.

## Summary of Windows results

| Check                                        | Result      |
| -------------------------------------------- | ----------- |
| Check: Astro (`check:astro`)                 | ✅ pass     |
| Test: Vitest (`check:vitest`)                | ✅ pass     |
| Lint: ESLint (`check:lint`)                  | ✅ pass     |
| Format: Prettier (`check:syntax`)            | ❌ **fail** |
| Spell check: CSpell (`check:spelling:quiet`) | ✅ pass     |
| Other checks (`check:misc`)                  | ✅ pass     |
| Build: Astro (`check:build:post:quiet`)      | ❌ **fail** |
| Commit signature (`check:signed-commit`)     | ✅ pass     |

The `check-full` job was **skipped** because it `needs: check-quick`, which did not fully succeed (see the "Would-fix" section for the consequences).

---

## Failure 1: Format: Prettier (`pnpm run check:syntax`)

### Observed error

```text
$ prettier --check .
[warn] .pi/agent/pi-permissions.jsonc
[warn] Code style issues found in the above file. Run Prettier with --write to fix.
[ELIFECYCLE] Command failed with exit code 1.
##[error]Process completed with exit code 1.
```

### Root cause

Prettier flags exactly one file: `.pi/agent/pi-permissions.jsonc`. It is a **`.jsonc`** file, and the repo's `.gitattributes` does **not** contain a rule for `.jsonc`:

```gitattributes
# .gitattributes (relevant excerpt)
* text=auto            # fallback — applies to .jsonc
*.json text eol=lf     # .json is covered, but .jsonc is NOT
```

`git check-attr` confirms the file resolves to `text: auto` / `eol: unspecified`. The committed blob is pure LF (0 CR bytes).

On the `windows-latest` runner, Git's default `core.autocrlf` behavior converts LF→CRLF on checkout for text files that fall under the `* text=auto` fallback. The result is that `.pi/agent/pi-permissions.jsonc` is checked out with **CRLF** line endings. Prettier's config in `package.json` pins `"endOfLine": "lf"`, so it reports the CRLF file as a formatting violation — even though the file is correct in the repository and passes on Linux/macOS.

This is a pure line-ending-normalization mismatch, not a real formatting problem. It is deterministic and happens on every Windows checkout.

### Fix

Add an explicit `eol=lf` rule for `.jsonc` (or broaden the existing `.json` rule) in `.gitattributes`:

```gitattributes
*.jsonc text eol=lf
```

This ensures Git normalizes `.jsonc` files to LF on every platform, matching the `*.json text eol=lf` rule that already covers the sibling type. After this change, Prettier's `endOfLine: lf` check passes on Windows.

---

## Failure 2: Build: Astro (`pnpm run check:build:post:quiet`)

### Observed error

```text
$ cross-env QUIET=true pnpm run check:build:post
$ tests/postbuild.sh
'tests' is not recognized as an internal or external command,
operable program or batch file.
[ELIFECYCLE] Command failed with exit code 1.
##[error]Process completed with exit code 1.
```

### Root cause

The `check:build:post` script in `package.json` is:

```json
"check:build:post": "tests/postbuild.sh",
```

`tests/postbuild.sh` is a **Bash** script. On the `windows-latest` runner, the default shell for `run:` steps is **PowerShell** (`pwsh.EXE`), which cannot execute a bare POSIX script path like `tests/postbuild.sh`. PowerShell tries to interpret `tests/postbuild.sh` as a command and fails with "not recognized as an internal or external command".

Note this is _not_ a problem with the script's contents per se — the script is a valid Bash script and runs fine under a Bash shell. The issue is purely the **shell mismatch** on Windows.

### Fix

Any of the following resolves it (listed in order of minimal change):

1. **Force a Bash shell for the failing step** in the workflow:

   ```yaml
   - name: Build: Astro
     run: pnpm run check:build:post:quiet
     shell: bash
   ```

   GitHub-hosted Windows runners include Git Bash at `C:\Program Files\Git\bin\bash.exe`, and `shell: bash` routes the command through it. This makes `tests/postbuild.sh` executable. This is the simplest fix and keeps `package.json` unchanged.

2. **Invoke the script through bash explicitly** in `package.json`:

   ```json
   "check:build:post": "bash tests/postbuild.sh",
   ```

   (The repo already does exactly this pattern for other Bash-backed checks, e.g. `check:signed-commit` = `bash tests/signed-commit.test.sh`, and `check:ci:build-determinism` = `bash tests/ci/build-determinism.test.sh`.)

   > Important: `check:signed-commit` and `check:misc` already pass on Windows precisely because they prefix `bash` in `package.json`. The Build check is the odd one out.

### Important caveat — this is not the end of the Windows build story

Even with the shell fixed, the Windows build will **still fail** at a deeper layer. `tests/postbuild.sh` runs `deploy/build.sh`, and `deploy/build.sh` **hard-requires `bwrap` (bubblewrap)** whenever `WALLETBEAT_ENV=CI` is set:

```bash
if [[ "${WALLETBEAT_ENV:-}" == "CI" ]]; then
    echo "bwrap is required to sandbox the build (WALLETBEAT_ENV=CI), but bwrap is not installed." >&2
    exit 1
fi
```

`bwrap` is a **Linux-only** sandboxing tool (it relies on Linux namespaces/`/proc`). It cannot be installed on `windows-latest`. The workflow sets `WALLETBEAT_ENV: CI` on the step, so the build aborts immediately.

The reason bwrap is required is architectural: the build must be sandboxed so Astro's resource hashes (the `astro-island uid`s) are computed against a fixed absolute path, otherwise the build is **non-deterministic** — which is exactly what the `check:ci:build-determinism` test verifies.

So Windows cannot produce a valid CI build without either:

- **Not** running the sandboxed/deterministic build path on Windows, or
- **Replacing bwrap** with a cross-platform sandbox/workspace-pinning mechanism (e.g. a per-OS equivalent that pins the checkout to a fixed path before invoking Astro), or
- **Skipping the deterministic-build check** on non-Linux runners.

---

## Additional latent issues (would surface if `check-full` ran on Windows)

`check-full` was skipped because `check-quick` failed. If the above are fixed and `check:ci` runs on Windows, these Bash-based tests would also hit portability problems:

1. **`tests/ci/build-determinism.test.sh`** — uses `bwrap` (Linux-only, see above), plus `mktemp -d`, `seq`, and `git worktree`. The bwrap requirement alone is fatal on Windows.

2. **`tests/ci/bundle-size-delta.test.sh`** — uses `du -sb` (GNU-specific; BSD/macOS `du` has no `-b` flag) and `mktemp -d`.

3. **`deploy/build.sh`** — uses `/proc/$$/fd/2`, `readlink`, `sed -r` (GNU), `script -q -e -f`, and `/dev/tty`. None of these are portable to Windows PowerShell/CMD.

4. **`deploy/helios/helios.sh` / `helios-wrap.sh`** — use `/proc/${PID}`, `seq`, `mktemp -d --tmpdir=/dev/shm` (Linux-only `/dev/shm`). These are deploy-only and not part of `check:*`, but they are not Windows-portable.

---

## Bottom line for Windows

- **Real, fixable now:**
  - Prettier line-ending failure — add `*.jsonc text eol=lf` to `.gitattributes`.
  - Build shell mismatch — run the build step with `shell: bash` (or `bash tests/postbuild.sh` in `package.json`).
- **Structural, needs a design decision:**
  - The deterministic, sandboxed build (`deploy/build.sh`) requires `bwrap`, which is Linux-only. Making the build pass on Windows requires either a non-sandboxed/opt-out path on Windows or a cross-platform replacement for bwrap. Without this, `check:build:post` and `check:ci` (build-determinism) cannot pass on Windows.
- **Deferred risk:**
  - GNU-only utilities (`du -sb`, `sed -r`, `seq`, `/proc`, `/dev/shm`) throughout the CI/test scripts would need portability fixes before `check-full` can run on Windows.
