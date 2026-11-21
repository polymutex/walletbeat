# GitHub Copilot Code Review Instructions

When performing a code review on a pull request in this repository, follow the
rules and review tasks below **in addition to** any CI check summary that the
Auto Review workflow posts.

## Repository context

Read the root `AGENTS.md` (also exposed as `CLAUDE.md`) for the project's
architecture, data pipeline, and rating system. The contributing guide at
`CONTRIBUTING.md` points to the detailed contributor docs under
`resources/docs/contribute/`. Review against those, not against general
JavaScript/Astro assumptions alone.

## Review tasks

1. **CI summary is authoritative, but not sufficient.** The workflow posts a
   comment summarizing which checks passed and which failed. Do not re-report
   CI results; instead, review the code that was changed for the issues below.
2. **Schema rules.** `/data` fields must be explicit: never `undefined` or `?`
   for new properties. Use `null` for unknown and a named sentinel (e.g.
   `NO_*`) or an empty array for "none / does not apply". Wallet feature data
   must be objective and unopinionated. Flag any violation.
3. **Attributes evaluate only feature data.** Attribute evaluation logic must
   consume only the wallet's feature data — never other inputs. Flag anything
   that pulls in external sources or hard-codes outcomes.
4. **No workarounds.** Flag `eslint-disable` comments, `as any` casts, and
   `// @ts-ignore` / `// @ts-expect-error` used to silence errors rather than
   fix them. These should not be used as escape hatches.
5. **Objectivity / neutrality.** Ratings must be objective. Flag changes that
   inject subjective or promotional language into features, attributes, or the
   site copy.
6. **Consistency with existing patterns.** Follow the conventions used by
   neighboring wallet files, attributes, and components. Flag gratuitous
   divergence from established patterns.
7. **Correctness & regressions.** Look for logic errors, off-by-one mistakes,
   broken imports, unused exports, and changes that could regress existing
   behavior or tests.
8. **Testing.** If behavior changes, confirm tests were added or updated and
   that `pnpm check:all` would still pass. Flag missing test coverage for
   nontrivial logic changes.

## What to prioritize

Focus review effort on the actual diff. High-signal issues (correctness,
security, schema violations, objectivity) should be raised first. Style-only
nits that the project's own tooling already enforces (Prettier, ESLint, the
spell checker) are lower priority — the CI checks cover those.

## Tone and format

- Be specific and actionable. Reference the exact file and line where possible.
- Do not restate the diff; comment on what is wrong or could be improved.
- Keep comments concise. Avoid repeating comments that CI already surfaces.
- Leave a "Comment" review by default, not "Approve" or "Request changes",
  unless a change is genuinely blocking.
