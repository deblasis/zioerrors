# zioerrors CI recipes.
#
# `just ci` runs exactly what .github/workflows/ci.yml runs, so you can
# check a change locally before pushing. The workflow calls `just ci` too,
# which keeps the two from drifting apart.

default: ci

# everything CI runs, in the same order
ci: fmt-check test example

# fail if anything is not formatted, without rewriting files
fmt-check:
    zig fmt --check src tests examples build.zig

# rewrite files in place
fmt:
    zig fmt src tests examples build.zig

# unit and integration tests
test:
    zig build test --summary all

# build and run the examples so they cannot silently rot
example:
    zig build run-example
    zig build run-example-multi-layer
