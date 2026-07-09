set unstable := true
set positional-arguments := true

# Run [script] recipes under bash rather than the default sh. On Linux
# sh is dash, which lacks [[ ]], <<<, and set -o pipefail — constructs
# [script] recipes are free to rely on. macOS sh is bash, so a dash
# incompatibility would stay hidden locally until CI runs on Linux.
set script-interpreter := ['bash', '-eu']

# Put rustup's shims ahead of any distro or Homebrew cargo on PATH.
# rust-toolchain.toml pins the compiler, but a system cargo sitting
# earlier on PATH answers first and ignores the pin, so the build would
# silently run on the wrong toolchain. The Go twin prepends GOPATH/bin
# the same way.
export PATH := env("CARGO_HOME", env("HOME") + "/.cargo") + "/bin:" + env("PATH")

# Build metadata. `date` is the *committer date* (UTC, ISO-8601), not
# build invocation time, so two builds of the same commit produce an
# identical binary. `source_date_epoch` exports the same instant as a
# unix timestamp for downstream tooling (archive tooling, the
# reproducible-build check) that honors SOURCE_DATE_EPOCH. build.rs
# stamps the binary from these same git commands, so the two
# derivations must not drift — otherwise the values the Justfile
# reports and the values compiled into the binary would disagree.
#
# `--abbrev=7` / `--short=7` pin the abbreviated hash length so two
# checkouts of the same commit produce the same string. Without this,
# git uses `core.abbrev=auto`, whose length depends on object count
# (shallow clones, freshly-packed repos, and aged working copies all
# differ). 7 matches goreleaser's `.ShortCommit`.

version := `git describe --tags --abbrev=7 2>/dev/null || git rev-parse --short=7 HEAD 2>/dev/null || echo "DEV"`
commit := `git rev-parse --short=7 HEAD 2>/dev/null || echo ""`
date := `TZ=UTC git log -1 --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown"`
source_date_epoch := `git log -1 --format=%ct 2>/dev/null || echo "0"`

# Default recipe
default: test

# --- Build ---

# Build the release binary
build:
    cargo build --release

# Run the binary
run *args:
    cargo run -- "$@"

# Clean build artifacts
clean:
    cargo clean

# --- Test ---

# Run tests
test *args:
    cargo test "$@"

# Run doctests. Kept apart from `test` because the test runner adopted
# later on does not execute doctests, so they need their own recipe and
# CI job to stay covered.
test-doc:
    cargo test --doc
