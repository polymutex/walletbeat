# Windows (`windows-latest`) CI — Issues and Resolution

## Summary

The `check` workflow was extended to run on `ubuntu-latest`, `windows-latest`, and `macos-latest`. On Windows, **2 of 8** `check-quick` jobs initially failed. All were resolved, and the workflow now passes on all three platforms (including the `check-full` job).

## Initial failures (run `34798296631`)

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

The `check-full` job was initially skipped because it `needs: check-quick`, which had not fully succeeded.

---

## Failure 1: Format: Prettier (`check:syntax`)

### Root cause

Prettier flagged exactly one file: `.pi/agent/pi-permissions.jsonc`. It is a **`.jsonc`** file, and the repo's `.gitattributes` had no rule for `.jsonc`:

```gitattributes
# .gitattributes (relevant excerpt)
* text=auto            # fallback — applies to .jsonc
*.json text eol=lf     # .json is covered, but .jsonc is NOT
```

`git check-attr` resolved the file to `text: auto` / `eol: unspecified`. On the `windows-latest` runner, Git's `core.autocrlf` converts LF→CRLF on checkout for files under the `* text=auto` fallback, so the `.jsonc` file was checked out with **CRLF**. Prettier's config pins `"endOfLine": "lf"`, so it reported the CRLF file as a formatting violation. The committed blob was pure LF; this was purely a line-ending-normalization mismatch.

### Fix

Added an explicit `*.jsonc text eol=lf` rule to `.gitattributes`:

```gitattributes
*.jsonc text eol=lf
```

This normalizes `.jsonc` files to LF on every platform, matching the existing `*.json text eol=lf` rule.

---

## Failure 2: Build: Astro (`check:build:post:quiet`)

This surfaced a chain of three distinct Windows-specific problems, each fixed in turn.

### 2a. Shell mismatch — `tests/postbuild.sh`

`check:build:post` ran `tests/postbuild.sh` (a Bash script) under the Windows default **PowerShell** shell, producing:

```text
$ tests/postbuild.sh
'tests' is not recognized as an internal or external command,
operable program or batch file.
```

**Fix:** prefixed the script with `bash` in `package.json` (`"check:build:post": "bash tests/postbuild.sh"`), matching the existing pattern used by `check:signed-commit`, `check:misc`, etc.

### 2b. Shell mismatch — `deploy/build.sh`

With `tests/postbuild.sh` now running under Bash, it invoked `pnpm run build`, which ran `deploy/build.sh` — also a Bash script — without a `bash` prefix:

```text
bash tests/postbuild.sh
bash deploy/build.sh   # (after fix) — previously failed with 'deploy' not recognized
```

**Fix:** changed `"build": "deploy/build.sh"` to `"build": "bash deploy/build.sh"` in `package.json`.

### 2c. Non-deterministic build / SRI hash recompute loop

With both scripts running under Bash, the Windows build proceeded but never converged: `deploy/build.sh`'s SRI hash recompute loop detected "SRI hashes have changed" on every pass and exhausted its 5 rebuild attempts. This is because the build is **non-deterministic without bwrap**: the `bwrap` sandbox (Linux-only) pins the workspace to a fixed path so Astro's resource hashes (the `astro-island uid`s) are stable. Without it, each build pass produces different hashes.

**Fix:** in `deploy/build.sh`, detect the host platform (`IS_LINUX` via `uname -s`) and skip the SRI recompute loop on non-Linux (where the build is non-deterministic by design and the loop cannot converge). On Linux, the loop is preserved unchanged.

### 2d. astro-shield SRI static generation bug (`._astro` path)

After the SRI loop was skipped, the Windows build still failed during astro-shield's `astro:build:done` hook. astro-shield scans `dist/` and throws `ENOENT` on the `._astro` AppleDouble-style path:

```text
ENOENT: no such file or directory, open 'D:\...\dist\._astro\ClientRouter...js'
An unhandled error occurred while running the "astro:build:done" hook
```

This is a bug in `@kindspells/astro-shield` (v1.7.1, the latest) that manifests on Windows only (Linux and macOS SRI hashing succeed). A request-time middleware fix cannot prevent a build-time hook failure.

**Fix:** skip the astro-shield integration on non-Linux platforms in `astro.config.mjs` (via `process.platform === 'linux'`), and guard the corresponding request-time middleware in `src/middleware.ts` so it also returns early on non-Linux. Linux keeps full SRI protection.

### 2e. `tee /dev/stderr` failure in CI

The final Windows build failure (and the Ubuntu `check-full` failure) was caused by `deploy/build.sh`'s no-tty branch using `tee /dev/stderr`. In a non-interactive/CI shell this fails with:

```text
tee: /dev/stderr: No such device or address
```

Even though `/dev/stderr` reports as writable, `tee /dev/stderr` is not a valid device in CI, so with `pipefail` the build pipeline returned non-zero and aborted the build.

**Fix:** replaced the `tee /dev/stderr` branch with a no-tty branch that echoes each build line to stdout and stderr directly, and propagates the build's real exit code via a temporary file (the process substitution's status is not surfaced by the `while read` loop).

---

## Final state

After all fixes, run `34815060919` passed on all three platforms:

- All 24 `check-quick` jobs pass (8 checks × 3 OS).
- `check-full` (`check:ci`) passes on **ubuntu-latest**, **windows-latest**, and **macos-latest**.

## Related notes

- The `WINDOWS.md` and `MACOSX.md` report files are excluded from the grammar and spell checks (via `.gitignore` and cspell's `ignorePaths`) because they contain technical jargon (LF, CRLF, CSpell, etc.) that the project's grammar linter (Harper) does not recognize.
- `src/generated/sriHashes.mjs` is gitignored and regenerated per-build; on Linux it is produced by astro-shield, on non-Linux it is not generated (the middleware skips SRI there).
