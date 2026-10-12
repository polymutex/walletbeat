// pi-ask-user ships raw TypeScript source (a pi extension) that is tested
// against TypeScript 5.9. Under this project's TypeScript 6 compiler that
// source no longer type-checks cleanly, so it must not be followed by the
// type-check. tsconfig `paths` redirects the import here; this declaration
// gives the module a stable shape matching the actual default export (an
// `ExtensionFactory`). Runtime resolution is unaffected (`paths` only affects
// the type-check).
import type { ExtensionFactory } from '@earendil-works/pi-coding-agent'

declare const askUserExtension: ExtensionFactory
export default askUserExtension
