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

# Check that release builds are reproducible: copy the working tree
# (minus .git and target; the untracked Cargo.lock rides along) into two
# separate temp dirs, build each with identical flags, and compare the
# sha256 of the two binaries, failing on any mismatch.
#
# Building from two different paths — not twice in the same one — is what
# makes this stronger than a same-dir double build. It catches absolute
# build and registry paths leaking into the binary: rustc embeds
# $CARGO_HOME/registry/... in dependency panic messages by default. The
# --remap-path-prefix pair rewrites this checkout's path to /build and
# the cargo home to /cargo, and --remap-path-scope=object confines the
# rewrite to emitted objects; the scope flag is stable since 1.95.
# Cargo's own trim-paths profile key would subsume these flags but is
# still nightly (cargo#12137) — migrate to it once it stabilizes.
#
# Excluding .git drops both builds onto the buildmeta fallback (empty
# commit, "unknown" date) instead of a stamped value; that is identical
# across the two trees, which is exactly what the comparison needs.
# SOURCE_DATE_EPOCH is exported for parity with the sibling repos; rustc
# ignores it on Linux and macOS today, so it only guards against future
# timestamp stamping.
[script]
build-repro-check:
    src="$PWD"
    dir_a=$(mktemp -d)
    dir_b=$(mktemp -d)
    trap 'rm -rf "$dir_a" "$dir_b"' EXIT
    for dir in "$dir_a" "$dir_b"; do
        rsync -a --exclude=.git --exclude=target "$src"/ "$dir"/
        (
            cd "$dir"
            RUSTFLAGS="--remap-path-prefix=$PWD=/build --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo --remap-path-scope=object" \
            CARGO_INCREMENTAL=0 SOURCE_DATE_EPOCH={{ source_date_epoch }} \
            cargo build --release --locked
        )
    done
    sum_a=$(shasum -a 256 < "$dir_a/target/release/proofhouse-rust-tool")
    sum_b=$(shasum -a 256 < "$dir_b/target/release/proofhouse-rust-tool")
    if [[ "$sum_a" != "$sum_b" ]]; then
        echo "build not reproducible: binary differs between runs" >&2
        exit 1
    fi
    echo "reproducible: ${sum_a%% *}"

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
