# Review Instructions: `/data`

These rules apply when reviewing changes under the `data/` directory.

## Wallet feature data must be explicit

- Never use `undefined` or an optional (`?`) property for new fields.
- Use `null` for genuinely unknown values.
- Use a named sentinel (e.g. `NO_*`) or an empty array for "does not apply /
  none".
- Wallet feature data must be objective and unopinionated. It records what a
  wallet _does_, never whether that is good or bad.

## Wallet types

- Hardware wallets live in `data/hardware-wallets/`.
- Software wallets live in `data/software-wallets/`.
- Embedded wallets live in `data/embedded-wallets/`.

Verify a new wallet is registered in the correct directory and follows the
existing template (`*.tmpl.ts`) for its type. Confirm the entity and
contributor files are wired up correctly (imports, `contributors: []`,
`entities`).

## Dates

Bare `YYYY-MM-DD` dates are UTC and match the treasury and wallet-data-collection
tooling. Flag any timezone ambiguity.
