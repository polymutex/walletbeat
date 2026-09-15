# Review Instructions: `/src/schema`

These rules apply when reviewing changes under the `src/schema/` directory.

## Separation of concerns

- `features/` contains objective, factual data about wallet capabilities.
- `attributes/` contains evaluation logic that turns feature data into ratings.
- `attribute-groups.ts` defines logical groupings of related attributes.

## Attributes evaluate only feature data

Attribute evaluation logic must consume only the wallet's feature data. Never
pull in external sources, environment state, or hard-coded outcomes. Flag any
violation.

## Ratings

Each attribute returns exactly one of:

- `PASS` — meets criteria completely
- `FAIL` — does not meet criteria
- `PARTIAL` — partially meets criteria
- `UNRATED` — insufficient data to evaluate
- `EXEMPT` — not applicable to this wallet type

Ratings must be objective. Flag any logic that could produce a subjective or
promotional rating.

## Nullable feature blobs

Some feature blobs allow per-field unknowns while `/data` is incomplete. For
those, the exported feature type keeps the complete shape `F`, a `Nullable<F>`
is placed only on the `WalletBaseFeatures` field, and `ResolvedFeatures`
exposes either a full `F` or `null`. In `resolveFeatures`, wrap these entries
with `nullable()` so any remaining `null` property makes the whole resolved
feature `null`. For `Support`-wrapped blobs, put `Nullable` inside the
supported payload and resolve with
`nullable<Support<ResolvedShape>>(...)`. Flag any deviation from this pattern.
