# Sample task suite — schema (the only Harness-side document the suite author needs)

The suite measures a local coding agent end to end. For each task the agent receives a natural-language request
and a small Swift package, edits production code, and its result is checked by building and running tests in an
OS sandbox (no network). The suite is frozen before any agent run; nothing in it may be tuned to the agent.

## One file per task: `tasks/b5-NN.json` (NN = 01, 02, …)
```json
{
  "id": "s-01",
  "objective": "日本語の自然な依頼文。ユーザーが実際に書くように。",
  "size": "small | medium | large",
  "category": "bugfix | feature | behaviour-change | refactor-preserving | multi-file feature | unfamiliar-codebase",
  "multiFile": true,
  "unfamiliar": false,
  "initialFiles": {
    "Package.swift": "// swift-tools-version: 6.0 …",
    "Sources/<Target>/<File>.swift": "production code BEFORE the change",
    "Tests/<Target>Tests/<Name>AcceptanceTests.swift": "acceptance tests the agent's change must pass"
  },
  "protectedTests": ["Tests/<Target>Tests/<Name>AcceptanceTests.swift"],
  "maxEdits": 4,
  "maxLines": 40,
  "reference": { "Sources/<Target>/<File>.swift": "full file content AFTER a correct change" },
  "holdoutTests": { "Tests/<Target>Tests/<Name>HoldoutTests.swift": "hidden tests, added only after the run" },
  "plausibleWrong": { "Sources/<Target>/<File>.swift": "full content of a believable WRONG change (optional)" },
  "origin": "what kind of real-world code this imitates",
  "rationale": "why the request, acceptance tests and holdout tests together pin the intended behaviour"
}
```

### What the agent sees and does not see
- Sees: `objective` and the production files in `initialFiles`. Protected test sources are never shown to the agent;
  it only learns whether the build and tests passed. `maxEdits`/`maxLines` bound its change.
- Never sees: `reference`, `holdoutTests`, `plausibleWrong`, `origin`, `rationale`, labels.
- The agent can only **modify existing production files** (no new files, no deletions, no test edits).
  `reference` and `plausibleWrong` must therefore only contain paths that already exist in `initialFiles` under `Sources/`.

### Outcome definitions used by the measurement
- tests passed = the agent's final package builds and all tests in `initialFiles` pass.
- **proxy success** = tests passed AND every holdout test passes on the agent's final code.
- **false success** = tests passed BUT a holdout test fails. Holdout tests exist to expose changes that satisfy the
  visible acceptance tests yet violate the request (wrong boundary, missed case, broken existing behaviour, …).

## Rules
- Package: `// swift-tools-version: 6.0`, `import PackageDescription`, 1–3 library `.target`s, exactly one
  `.testTarget`, no external package dependencies, no resources, no plugins, no `unsafeFlags`, no executables.
- Tests: Swift Testing only (`import Testing`, `@testable import <Target>`, `@Test func name()`, `#expect`/`#require`).
  Every test function name is unique across acceptance + holdout + any other test files of the package.
  All test files live in the single test target directory.
- `protectedTests` ⊆ test files in `initialFiles`; at least one. Other (unprotected) test files are allowed
  (e.g. existing regression tests) but the agent is not allowed to edit any test file either way.
- The initial package must build, and at least one acceptance test must fail on it.
- `reference` must make every acceptance and holdout test pass. Holdout tests must fail on the initial code.
- `plausibleWrong` (when present) must pass all acceptance tests and fail at least one holdout test.
- `objective`: Japanese, written like a real user request; never names test functions or test files and never
  pastes the solution. It may name types or functions that exist in the code, or describe them in prose.
- Change size: the diff from `initialFiles` to `reference` must fit `maxLines` changed lines and ≤ `maxEdits`
  contiguous edited regions; choose limits with honest slack (≤ 2× what the reference needs, `maxEdits` ≤ 12,
  `maxLines` ≤ 200).
- `multiFile` is true exactly when `reference` changes ≥ 2 files.
- Sizes (production `Sources/` bytes in `initialFiles`): small ≤ 6 KB, medium ≤ 20 KB, large ≤ 40 KB.
  Large tasks should have several production files with real dependencies between them.
- `unfamiliar`: the package uses conventions a model is unlikely to have memorised (an in-house DSL, unusual naming
  scheme, non-obvious invariants documented only in code comments), so the agent must read the code to succeed.
- No network, file system, process, clock or randomness dependence in sources or tests (tests must be deterministic).
- Text files only, UTF-8, `\n` line endings.

## Mix (the validator enforces these minimums)
- ≥ 30 tasks; ≥ 8 small, ≥ 10 medium, ≥ 6 large.
- ≥ 10 multi-file tasks; ≥ 5 unfamiliar tasks; ≥ 10 tasks with `plausibleWrong`.
- At least 4 different `category` values.

## Validation
`python3 validate_suite.py` (static checks) and `python3 validate_suite.py --dynamic --candidate <path>` (each check
builds and tests a copy in the OS sandbox). The suite is complete when both report `OK`.
