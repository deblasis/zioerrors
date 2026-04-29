# zio-zig shared brief

You are building a package in the **zio-zig** portfolio: a family of small,
high-leverage Zig developer-experience libraries. Each one replaces a 40+ line
stdlib ceremony with a 3-line API. "zio" is Italian for uncle. The portfolio
is inspired by ivanleomk/gil.

Read this file before reading the per-project prompt. The constraints below
are non-negotiable.

## Hard constraints

### Toolchain
- **Zig 0.16** (master-track). The 0.13 to 0.16 stdlib API drift is large
  (Allocator vtable, std.http, GeneralPurposeAllocator rename, build system
  options). Verify every std symbol via the
  `mcp__plugin_context7_context7__query-docs` tool before relying on it.
- Pin Zig in CI with `mlugg/setup-zig@v1` (or current equivalent verified at
  build time).

### Repo layout
- Private GitHub repo under `github.com/deblasis`. Repo name is the package
  name, single word, no hyphen: `zioerrors`, `ziomemtrace`, `zioenv`,
  `ziosh`, `zioarg`, `ziolog`, `ziobuild`.
- Zig module name matches the repo name.
- Create with: `gh repo create deblasis/<name> --private --source=. --remote=origin`.
- Branch `main`. Develop on a feature branch; open a PR; merge via
  fast-forward.

### Code style
- Mitchell Hashimoto / Ghostty conventions. Invoke
  `ghostty-reviewer-skill:ghostty-reviewer` BEFORE writing the first line of
  code, and again before opening the PR.
- File header convention, doc comments on every public symbol, no
  `pub` leakage of internals.
- Errors are explicit and named; no anonymous error sets at API boundaries.

### Commits
- Author: `Alessandro De Blasis <alex@deblasis.net>`.
- ABSOLUTELY NO `Co-Authored-By: Claude` trailer.
- NO `Generated with Claude Code` line.
- NO Claude branding in README, commit messages, code comments, or
  release notes.

### No em-dashes
- No em-dashes (U+2014) anywhere: README, commits, code, comments,
  error strings, doc comments, release notes.
- Substitute with commas, periods, colons, parentheses, or hyphens.
- Add a CI grep guard that fails on em-dash:
  `! git grep -nP $'—' -- '*.md' '*.zig' '*.yml' '*.yaml'`

### Tests
- Every public function has unit tests.
- Every error path is exercised.
- Integration tests cover realistic flows (use `std.process.Child`,
  `std.fs`, real syscalls where practical, mocks only when isolation
  matters).
- Aim for 90%+ line coverage of the public API. Use `kcov` or equivalent
  on Linux CI for the report.
- Use `std.testing` plus a CI smoke test that exits non-zero on any
  failure.

### Functional example
- Exactly one example under `examples/<name>/main.zig`, exposed by
  `zig build run-example`. CI runs it on every push so it never
  bit-rots.

### CI
- GitHub Actions matrix: `{ubuntu-latest, windows-latest, macos-latest}`.
- Steps: setup-zig, `zig build test`, `zig build run-example`,
  em-dash guard, basic `zig fmt --check`.
- Workflow file `.github/workflows/ci.yml`.

### README
- Include a side-by-side "before / after" demo at the top: the verbose
  stdlib version and the zio version. The pitch is the diff.
- Sections: Install, Quickstart, API, Examples, FAQ, License.
- License: MIT, copyright Alessandro De Blasis.

## Process (in order, no shortcuts)

1. `superpowers:brainstorming` to lock the API surface. Stop at
   signed-off API; do not write code yet.
2. `superpowers:writing-plans` to produce `docs/plan.md`.
3. `superpowers:test-driven-development` for each public function:
   tests first, implementation second.
4. `superpowers:verification-before-completion` before claiming done.
5. `ghostty-reviewer-skill:ghostty-reviewer` on the final diff.
6. Open PR titled `feat: initial release`.

## Reporting back

When done, report:
- Repo URL.
- Lines of code, lines of tests, ratio.
- Coverage estimate.
- Link to the example run output.
- Anything you cut for scope and why.
- Anything that surprised you in the Zig 0.16 stdlib so the next
  package starts with the right priors.

# zioerrors (priority 1)

Read `00-shared-header.md` first. All hard constraints there apply.

## Pitch

Error-context breadcrumbs for Zig's bare error union. Pin failures with
structured payload, recover full context at the boundary.

## Problem

Zig errors carry no payload. `error.NotFound` says nothing about what
wasn't found, where, or why. Today devs either log inline (noise) or build
a parallel context struct (boilerplate). Net loss versus Rust's
`anyhow`/`eyre` or Go's wrapped errors.

## API sketch (validate or revise during brainstorm)

```zig
const zio = @import("zioerrors");

pub fn loadConfig(path: []const u8) zio.Result(Config) {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err|
        return zio.fail(err).ctx("loading config").attr("path", path);
    defer file.close();
    // ...
}

// at the boundary
const cfg = loadConfig("/etc/app.toml") catch |err| {
    std.log.err("{}", .{zio.report(err)});
    // prints: error.FileNotFound: loading config (path=/etc/app.toml)
    //   at src/config.zig:42
    return err;
};
```

## Design points to settle in brainstorm

- **Storage.** Thread-local breadcrumb stack vs payload struct returned
  by-value alongside the error. Trade-off: allocator hookup vs alloc-free
  hot path. Pick one and justify.
- **Stack traces.** Integrate with `std.debug.captureStackTrace`?
  Symbolicate lazily on `report()` only.
- **Error set.** Expose a `zio.Error` sum, or stay structural and let
  callers keep their domain error sets?
- **Chain ergonomics.** Builder pattern (`.ctx().attr()`) vs format-string
  convenience (`zio.failf(err, "loading config (path={s})", .{path})`).
  Builder is more discoverable; format is more familiar. Pick or offer
  both.
- **Allocation policy.** Zero-alloc happy path is required. Allocation
  permitted only on the fail path when capturing context.

## Acceptance

- README before/after demo: 12 lines without zioerrors versus 4 with.
- `examples/cli/main.zig` reads a missing file and prints a chained
  report including the path attribute.
- Bench in `bench/` showing zero-alloc happy path on 1M operations.
- Tests cover: success path, single-frame fail, multi-frame chain,
  attr types (string, int, float, bool), report formatting, thread
  safety if thread-local is the chosen design.

## Out of scope

- Panic / recovery hooks.
- Full stack-walking on Windows beyond what `std.debug` exposes.
- Serialization to JSON (defer to ziolog integration).
- Cross-thread error propagation primitives.
