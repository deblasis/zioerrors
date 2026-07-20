# Contributing

Thanks for your interest in contributing! This project follows the
[Zig style guide](https://ziglang.org/documentation/master/#Style-Guide)
and a few simple conventions.

## Development Setup

You need [Zig 0.16.0](https://ziglang.org/download/) on your `PATH`.

You also want [just](https://github.com/casey/just), since CI runs the
same `just ci` recipe you can run locally.

```sh
git clone https://github.com/deblasis/zioerrors
cd zioerrors
just ci                 # fmt check, tests, examples: what CI runs
zig build test          # tests only
zig build run-example   # run examples/cli
```

## Pull Requests

1. Fork and create a branch from `main`.
2. Make your change. Add or update tests.
3. Run `just ci` and make sure it exits 0.
4. Open a PR with a clear description of **what** and **why**.

## Reporting Issues

Open a [GitHub issue](../../issues/new) with:

- Zig version (`zig version`)
- Minimal repro steps
- Expected vs actual behavior

## Code Style

- Follow `zig fmt`, no custom formatting.
- Doc comments on every public symbol.
- Prefer explicit error sets over `anyerror` where practical.

## AI-Generated Code

AI tools are welcome for exploration and drafting. You must understand
every line you submit and be able to explain the behavior without the
tool. Do not submit code you cannot reason about.
