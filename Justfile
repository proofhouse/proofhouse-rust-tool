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

# --- Dependencies ---

# Fail when Cargo.lock is missing or drifts from Cargo.toml. cargo
# metadata under the locked flag refuses to rewrite the lock, so a stale
# or absent one exits non-zero here instead of being regenerated behind
# the contributor's back. CI runs it on every PR; contributors commit
# the refreshed lock.
lock-check:
    cargo metadata --locked --format-version 1 > /dev/null

# --- Lint ---

# Aggregate lint gate. One entry point for contributors and CI, gaining a
# dependency as each gate lands. Today it carries prose (vale), spelling
# (cspell), Markdown (rumdl), and TOML (tombi).
lint: lint-prose lint-spelling lint-markdown lint-toml

# Check prose with vale against the styles in .vale.ini. The glob
# excludes the LICENSE (canonical Apache 2.0 text), the auto-generated
# changelog, vale's own style packages, scratch dirs, the gitignored
# agent worktrees under .claude/worktrees/, the COMMIT_AGENTMSG draft
# (whose own recipe checks it under the stricter commit scope), and the
# target/ build tree; the per-file-type rules in .vale.ini decide what
# else gets inspected. Findings render through the proofhouse-agent
# template from the proofhouse package: one machine-parseable line per
# finding.
lint-prose *args:
    vale --output=proofhouse-agent.tmpl --glob='!{LICENSE,CHANGELOG.md,.vale/*,tmp/*,.claude/worktrees/*,COMMIT_AGENTMSG,target/*}' {{ if args == "" { "." } else { args } }}

# Check spelling across the tree against the project dictionary at
# .cspell-words.txt, backed by cspell's bundled Rust word list and its
# crate-name list. The ignorePaths block in .cspell.jsonc keeps the
# build tree, the synced Vale styles, and the resolved lock file out of
# the scan. COMMIT_AGENTMSG is excluded here and checked by
# `lint-commit-msg` instead, so a message still being drafted never
# fails the tree-wide run.
lint-spelling *args:
    cspell --config .cspell.jsonc --no-summary --no-progress --no-must-find-files --exclude COMMIT_AGENTMSG {{ if args == "" { "." } else { args } }}

# Lint Markdown files against the project's .rumdl.toml ruleset.
# rumdl handles structural lints (heading style, list marker style,
# code fence style); vale handles prose.
lint-markdown *args:
    rumdl check {{ if args == "" { "." } else { args } }}

# tombi is the org TOML gate (tombi 1.2.0): lint-checks Cargo.toml (validated offline
# against the embedded SchemaStore cargo.json), rust-toolchain.toml, .cargo/config.toml,
# and workspace member manifests. Format gate runs in --check --diff so unformatted TOML
# fails without rewrite. Cargo.lock is excluded from formatting via tombi.toml. --offline
# keeps CI hermetic; --error-on-warnings makes warnings hard failures. Scope lives in
# tombi.toml, so no path args are passed.
lint-toml:
    tombi format --check --diff
    tombi lint --offline --error-on-warnings

# --- Format ---

# Aggregate in-place formatter. Grows per gate; carries the Markdown and
# TOML fixers today.
format: format-markdown format-toml

# Format Markdown files (whitespace, list markers, code fence styles).
# Rewrites in place. Pair with `fix-markdown` for semantic lint fixes.
format-markdown *args:
    rumdl fmt {{ if args == "" { "." } else { args } }}

# In-place TOML formatter — fixer paired with lint-toml's --check gate. Whitespace/style
# only; key order preserved (reordering disabled in tombi.toml).
format-toml:
    tombi format

# --- Fix ---

# Apply rumdl's auto-fixable rules to Markdown files. Complement to
# `format-markdown` (which only rewrites whitespace and ordering, not
# semantic lints).
fix-markdown *args:
    rumdl check --fix {{ if args == "" { "." } else { args } }}

# --- Utilities ---

# Sync Vale styles and dictionaries. Run once after cloning the repo,
# and whenever .vale.ini's Packages list changes. CI runs this before
# `just lint-prose`.
vale-sync:
    vale sync
