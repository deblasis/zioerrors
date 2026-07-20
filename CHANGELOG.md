# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- `report` no longer attributes an unrelated failure's frames to the
  current error. A report ends the chain, so the next `fail` starts a
  new one instead of stacking onto frames a forgotten `clear` left
  behind.
- Each frame now records and prints the error it was raised for. The
  formatter used to stamp the error passed to `report` onto every line,
  which mislabelled any layer that translated one error into another.

### Changed

- `Frame` has a new `err_value` field. This is a breaking change for
  code that constructs `Frame` literals directly.

## [0.1.0] - 2025-04-30

### Added

- Error context breadcrumbs: `fail`, `failf`, `install`, `uninstall`, `clear`.
- Chainable `Builder` with `ctx`, `ctxf`, `attr`, `err`.
- Structured attributes: string, integer, unsigned, float, boolean.
- Multi-layer error chains with per-layer attributes.
- `report` formatter for human-readable error context output.
- Doc comments on all public symbols.
- CI workflow (fmt, test, run-example) for Linux, Windows, macOS.
- AGENTS.md for LLM-assisted development.
- CONTRIBUTING.md and FUNDING.yml.
