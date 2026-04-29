# zioerrors

Error context with breadcrumbs for Zig's bare error union. Pin failures with structured payload, recover full context at the boundary. Inspired by Rust's `anyhow` / `eyre` and Go's wrapped errors.

> Status: scaffolding. The library is not yet implemented.

## What it will do

Zig errors carry no payload. `error.NotFound` says nothing about what wasn't found, where, or why. zioerrors adds a breadcrumb mechanism so failures travel with structured context (file path, request id, attempted operation) and can be reported as a chain at the boundary.

## Status

- [ ] Brainstorm and lock API
- [ ] Plan
- [ ] TDD implementation
- [ ] Functional example
- [ ] CI on Linux, Windows, macOS
- [ ] v0.1.0 release

## License

MIT. Copyright Alessandro De Blasis.
