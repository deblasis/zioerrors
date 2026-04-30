# AGENTS.md

Build and development instructions for AI coding agents working on this repository.

## What this is

zioerrors: error context breadcrumbs for Zig. Pin a failure with structured context at the call site, then recover the full chain at the boundary via `report`.

## Build

Requires Zig 0.16.

```
zig build
```

## Test

```
zig build test --summary all
```

This runs unit tests (in `src/*.zig`) and integration tests (in `tests/integration.zig`).

## Run example

```
zig build run-example
```

## Format check

```
zig fmt --check src tests examples build.zig
```

## Project layout

```
src/
  root.zig          public API surface (Context, fail, failf, report, install, uninstall, clear)
  context.zig       thread-local breadcrumb storage
  builder.zig       chainable context-attaching API (ctx, ctxf, attr, err)
  frame.zig         Frame, Attr, AttrValue types
  report.zig        Report formatter for std.fmt
tests/
  integration.zig   end-to-end behavior tests
examples/
  cli/main.zig      example demonstrating the boundary pattern
build.zig           build configuration
build.zig.zon       package manifest
```

## Key conventions

- Every public symbol has a doc comment.
- Errors are explicit and named. No anonymous error sets at API boundaries.
- Commits: author `Alessandro De Blasis <alex@deblasis.net>`, no AI co-author trailers.
- Code style follows Mitchell Hashimoto / Ghostty conventions.
