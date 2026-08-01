set unstable
set positional-arguments

# Run [script] recipes under bash rather than the default sh. On Linux
# sh is dash, which lacks [[ ]], <<<, and set -o pipefail — constructs
# [script] recipes are free to rely on. macOS sh is bash, so a dash
# incompatibility would stay hidden locally until CI runs on Linux.
set script-interpreter := ['bash', '-eu']

# Put rustup's shims ahead of any distro or Homebrew cargo on PATH.
# rust-toolchain.toml pins the compiler, but a system cargo sitting
# earlier on PATH answers first and ignores the pin, so the build would
# silently run on the wrong toolchain. The Go twin prepends GOPATH/bin
# the same way. `home_directory()` resolves the platform home, so the
# expression still parses where nothing sets HOME.
export PATH := env("CARGO_HOME", home_directory() + "/.cargo") + "/bin:" + env("PATH")

# Locate a Docker-compatible container runtime. Probe PATH first, then
# well-known install locations so the recipe still works inside agentic
# harnesses or sandboxes that strip /usr/local/bin from PATH. Override by
# setting CONTAINER_RUNTIME in the environment.
#
# The continuation lines of the `for` list below hang under the first
# candidate path rather than on a two-space grid, which is what shell
# style calls for and what `lint-editorconfig` would otherwise reject
# under this file's indent_size = 2. Exempt just that span rather than
# re-indent a block the sibling repos carry verbatim.
# editorconfig-checker-disable
container_runtime := env("CONTAINER_RUNTIME", `bash -c '
    docker_path=$(command -v docker 2>/dev/null || true)
    podman_path=$(command -v podman 2>/dev/null || true)
    for p in "$docker_path" \
             /usr/local/bin/docker \
             /opt/homebrew/bin/docker \
             /Applications/Docker.app/Contents/Resources/bin/docker \
             "$HOME/.orbstack/bin/docker" \
             "$HOME/.rd/bin/docker" \
             "$podman_path" \
             /opt/podman/bin/podman; do
        if [ -n "$p" ] && [ -x "$p" ]; then echo "$p"; exit 0; fi
    done
    echo docker
'`)

# editorconfig-checker-enable

# actionlint version pin. The upstream image bundles actionlint (and
# the shellcheck it shells out to) at a known version, and actionlint
# has no crates.io release for the dev toolchain to install, so we pin
# a Docker image by digest instead. Renovate tracks the version +
# digest pair below via the comment marker (the shared Justfile
# customManager from the org's renovate presets).

# renovate: datasource=docker depName=rhysd/actionlint
actionlint_version := "1.7.12"
actionlint_image := "docker.io/rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667"

# actionlint invocation. Mounts the repo read-only at /repo with -w /repo
# so actionlint finds .github/workflows/ and .github/actionlint.yaml.
#
# DOCKER_CONFIG points at a fresh empty directory so docker skips the
# osxkeychain credential helper (public Docker Hub pulls don't need it,
# and sandboxed environments can't always reach the helper binary).
# PATH gets the runtime's directory prepended for cases where docker
# itself isn't on the calling shell's PATH. Shell substitutions
# evaluate at recipe-run time, not Justfile-parse time.
actionlint := 'DOCKER_CONFIG="$(mktemp -d)" PATH="$(dirname ' + container_runtime + '):$PATH" ' + container_runtime + ' run --rm -v "$(pwd):/repo:ro" -w /repo ' + actionlint_image

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

# --- Setup ---

# Set up development environment. New contributors run this once after
# cloning. Idempotent: re-running upgrades dependencies and refreshes
# Vale's synced style packages.
setup:
    just install-brew
    just install-tools

# Install Homebrew dependencies from Brewfile.
install-brew:
    brew bundle check || brew bundle install

# Refresh non-brew tooling: Vale's synced style packages, plus the cargo
# linters Homebrew publishes no formula for. Versions float here exactly
# as the brew ones do, which keeps a development machine on whatever is
# current. CI installs those same linters from a pinned version instead,
# so a release that breaks a gate lands as a failing job rather than as
# an argument between two contributors' laptops.
install-tools:
    vale sync
    cargo install --locked cargo-machete

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

# Run the test suite under nextest. Every test gets its own process, so
# a panic or an abort reports as that one test failing instead of taking
# the rest of the binary down with it, and the run reports the whole set
# of failures rather than the earliest one. Profiles live in
# .config/nextest.toml; CI passes `--profile ci` to select the stricter
# one. --workspace reaches the task runner beside the binary, whose own
# tests are what keep the coverage threshold honest.
test *args:
    cargo nextest run --workspace "$@"

# Run doctests. nextest cannot execute them: the harness reaches into
# rustdoc through an entry point that has stayed unstable since the
# request for it opened in 2022. Documentation examples therefore need
# this recipe and a CI step of their own to run at all.
test-doc:
    cargo test --doc

# --- Coverage ---

# Toolchain the coverage run compiles under. Branch instrumentation is
# still an unstable feature, so it answers on a nightly compiler only,
# and a dated channel keeps two runs of one commit on the same one.
# Nothing bumps this date on its own: raise it by hand, rerun `just
# cover`, and move the workflow along with it — the cover job in
# .github/workflows/ci.yml sets up the same channel and points back here.
coverage_toolchain := "nightly-2026-08-01"

# Run the suite under branch instrumentation and hold the result at every
# line and every branch.
#
# --remap-path-prefix rewrites the workspace root out of the tracefile,
# so a path one operating system writes matches what the others write and
# the merge downstream lands one entry per source file. --skip-functions
# drops the per-function records; nothing reads them here and they are
# where a merge across platforms finds contradictions. The build script
# leaves the measured surface through the filename filter: it runs while
# cargo builds rather than under the harness, so no test can reach it,
# and the task runner is excluded the same way through --exclude. The
# region threshold on the run is the backstop the coverage tool enforces
# by itself; `cargo xtask coverage` then reads the tracefile and answers
# for lines and branches, which is the pair this project gates on.
#
# The slot argument names the tracefile. CI hands it the runner label so
# every matrix slot uploads a file of its own; locally it stays "local".
cover slot="local":
    cargo +{{ coverage_toolchain }} llvm-cov nextest --branch --all-features --workspace --exclude xtask --remap-path-prefix --skip-functions --ignore-filename-regex '^build\.rs$' --fail-under-regions 100 --lcov --output-path lcov-{{ slot }}.info
    cargo xtask coverage lcov-{{ slot }}.info

# Render the per-line HTML report and name the entry point. The source
# view shades each line and each branch arm by whether a test reached it,
# which points at the arm a new test still has to exercise. Local
# inspection only, so it names no threshold.
cover-html:
    cargo +{{ coverage_toolchain }} llvm-cov nextest --branch --all-features --workspace --exclude xtask --html
    @echo "open target/llvm-cov/html/index.html"

# Merge every slot's tracefile into one and check the merged total. This
# is the authoritative reading: a branch that no single operating system
# exercises still has to be reached by some slot, and only the merged
# file says whether it was. lcov does the merging rather than the task
# runner, because merging means combining the per-line hit counts of two
# reports over one file, where adding the summary lines of both would
# ask every slot to carry the whole tree alone. The CI coverage job
# runs this after collecting the per-slot artifacts.
#
# Two adjustments make that merge mean what it says. A Windows runner
# writes its source paths with a backslash, so the same file arrives
# under a second spelling and the merge would keep the two apart;
# rewriting the separator first lands one entry per source file.
# Branch records are the other: lcov discards them unless the run asks
# for them, and a merged report with no branch records left would clear
# a branch threshold by having nothing to fail on.
[script]
cover-combine:
    tracefiles=()
    for slot in lcov-*.info; do
        normalized=$(mktemp)
        tr '\\' '/' < "$slot" > "$normalized"
        mv "$normalized" "$slot"
        tracefiles+=(--add-tracefile "$slot")
    done
    lcov --branch-coverage "${tracefiles[@]}" --output-file lcov.info
    cargo xtask coverage lcov.info

# Fail when any line changed since [base] lacks coverage. The whole-tree
# floor already sits at every line, so on a clean branch this says
# nothing new; it earns its keep by naming the touched lines directly the
# moment a change does drop one, which reads faster than a total that
# moved. Reads the merged tracefile, so `cover-combine` runs first.
cover-diff base="origin/main":
    diff-cover lcov.info --compare-branch={{ base }} --fail-under=100

# --- Dependencies ---

# Fail when Cargo.lock is missing or drifts from Cargo.toml. cargo
# metadata under the locked flag refuses to rewrite the lock, so a stale
# or absent one exits non-zero here instead of being regenerated behind
# the contributor's back. CI runs it on every PR; contributors commit
# the refreshed lock.
lock-check:
    cargo metadata --locked --format-version 1 > /dev/null

# --- Lint ---

# Aggregator over the Rust-flavored lint sub-recipes: the rustfmt drift
# check, clippy, the documentation build, the unused-dependency scan,
# the duplication scan, the license declaration check, and actionlint.
# Kept apart from `lint` so someone iterating on the crate can run the
# source-side gates without waiting on the whole text-quality
# toolchain. Each new gate of that kind appends itself here. actionlint
# reads YAML rather than Rust, but it belongs to the same per-PR set,
# in the slot the Go repository gives it inside `lint-go-all`.
lint-rs-all: lint-rs-format lint-clippy lint-docs lint-machete lint-dup-code lint-reuse lint-workflows

# Aggregate lint gate. One entry point for contributors and CI, gaining a
# dependency as each gate lands. Today it carries the Rust gates (via
# lint-rs-all), prose (vale), spelling (cspell), Markdown (rumdl),
# config / JS / TS (biome), YAML (yamllint), TOML (tombi), this file's
# own layout (just --fmt), and the tree-wide .editorconfig baseline
# (editorconfig-checker).
lint: lint-rs-all lint-prose lint-spelling lint-markdown lint-config lint-yaml lint-toml lint-just lint-editorconfig

# Check Rust formatting against rustfmt.toml. --check reports drift and
# exits non-zero without touching the tree, so CI never rewrites what a
# contributor pushed; `format-rs` is the in-place twin, the same pairing
# lint-toml and format-toml use.
lint-rs-format:
    cargo fmt --all --check

# Run clippy over every workspace member. The lint set lives in
# Cargo.toml and the counting thresholds in clippy.toml; this recipe only
# decides what gets compiled and how loud a finding is. --all-targets
# reaches the test and build-script code a bare run skips, --all-features
# leaves no gated module unread, and -D warnings makes every enabled lint
# a failure rather than a note nobody sees.
lint-clippy:
    cargo clippy --workspace --all-targets --all-features -- -D warnings

# Render the workspace documentation and treat any complaint as a failure.
# Building the docs is the whole check here — nothing is published, the
# manifest sets publish = false and no docs.rs page exists, so a dead
# link or a malformed example would otherwise stay invisible until a
# reader hit it. The rustdoc lint levels live in Cargo.toml; RUSTDOCFLAGS
# covers whatever warns outside that table. --no-deps stops the run at
# this crate rather than re-rendering the dependency graph.
lint-docs:
    RUSTDOCFLAGS="-D warnings" cargo doc --workspace --no-deps

# Report dependencies the manifest declares and no source file names.
# cargo machete answers from the manifest and a text scan of the crate,
# in well under a second and without a build, which is why it belongs on
# the per-commit path. The trade is reach: a crate pulled in only
# through a macro expansion or behind a cfg gate leaves no name for the
# scan to find. Catching those takes a real compile, and that sweep runs
# on a schedule of its own rather than here. --with-metadata makes cargo
# resolve the graph, and resolution is free to write Cargo.lock, which
# no gate should do to a contributor's tree.
lint-machete:
    cargo machete

# Report dependencies the compiler never loads. cargo udeps builds every
# target and then asks rustc which of the resolved crates it actually
# read, so the answer covers what a text scan has no way to see: a crate
# named only from inside a macro expansion, or one behind a feature gate
# the scan leaves off. Paying for that answer takes a full build on a
# nightly compiler, because the flag the tool reads is unstable. Nothing
# a merge waits on may depend on nightly, so this recipe stays out of
# lint-rs-all and runs on a schedule instead; lint-machete above holds
# the pull request side of the same question.
lint-udeps:
    cargo +nightly udeps --all-targets

# Confirm the crate builds on the oldest compiler its manifest claims to
# support. cargo msrv verify reads `rust-version`, fetches that release
# when the machine has never seen it, and runs a check under it. The
# download plus a build from cold runs to minutes, so no hook fires this
# one and the lint aggregate leaves it out. The floor sits a minor
# release behind the pinned compiler, far enough back that a run under
# it answers something a build on the pin cannot.
lint-msrv:
    cargo msrv verify

# The same question in the form a remote runner can afford. cargo hack
# reads the floor the manifest declares and hands the check to that
# release through rustup, and a pinned build of it unpacks in seconds
# where the tool above publishes nothing to unpack and would have to
# compile first. --all-targets carries the check past the binary into
# the tests, where a development dependency raising its own floor would
# surface. Every member answers here, the task runner included: a
# single field in the workspace manifest sets the floor for both, and a
# runner that refuses to compile under it makes that number false for
# the tree it names. The workflow runs this recipe; the one above is
# what a contributor reaches for after moving the floor by hand.
lint-msrv-targets:
    cargo hack check --workspace --rust-version --all-targets

# Report code that appears more than once. jscpd hashes a sliding
# window of tokens rather than lines, so renaming the identifiers in a
# copy or reflowing its layout does not hide it. The window is fifty
# tokens, upstream's default and roughly a dozen lines of Rust; below
# that, ordinary idiom starts matching itself. .jscpd.json puts the
# tolerance at zero percent, so whatever the run reports fails the
# gate, matching the stance the Python repositories take toward
# pylint's similarity checker. That file also holds the scan to Rust
# sources. Left open it reads the workflow files and .vale.ini, where
# a repeated block is how the format reads rather than a defect. Four
# small modules have little to copy between them, and the gate stays
# regardless: the sibling library runs the same one, and a run that
# finds nothing puts that on record instead of leaving it assumed.
# --no-tips drops the donation and product lines the tool prints after
# every scan.
lint-dup-code:
    jscpd --no-tips .

# Confirm every tracked file names a copyright holder and a license,
# whether through the two-line header each Rust source opens with or
# through a bulk annotation in REUSE.toml. The canonical license text
# lives under LICENSES/, which is where reuse looks for it. Turning off
# the per-file process pool costs nothing on a tree of this size, where
# spawning it takes longer than the scan it parallelizes, and the
# serial path still answers inside sandboxes that refuse a process the
# semaphores a pool wants.
lint-reuse:
    reuse --no-multiprocessing lint

# Check prose with vale against the styles in .vale.ini. The glob
# excludes both copies of the canonical Apache 2.0 text (the root
# LICENSE and the LICENSES/ directory reuse reads), the auto-generated
# changelog, vale's own style packages, scratch dirs, the gitignored
# agent worktrees under .claude/worktrees/, the COMMIT_AGENTMSG draft
# (whose own recipe checks it under the stricter commit scope), and the
# target/ build tree; the per-file-type rules in .vale.ini decide what
# else gets inspected. Findings render through the proofhouse-agent
# template from the proofhouse package: one machine-parseable line per
# finding.
lint-prose *args:
    vale --output=proofhouse-agent.tmpl --glob='!{LICENSE,LICENSES/*,CHANGELOG.md,.vale/*,tmp/*,.claude/worktrees/*,COMMIT_AGENTMSG,target/*}' {{ if args == "" { "." } else { args } }}

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

# Lint JSON / JS / TS files via biome. Recommended ruleset, biome's
# own formatter; covers config files (biome.json, .cspell.jsonc) and
# any future scripts under .github/actions/.
lint-config *args:
    biome check --files-ignore-unknown=true {{ if args == "" { "." } else { args } }}

# Lint YAML files (config, workflows, action definitions). --strict
# treats warnings as errors so the gate matches CI behavior; per-rule
# tuning lives in .yamllint.yaml.
lint-yaml *args:
    yamllint --strict {{ if args == "" { "." } else { args } }}

# tombi is the org TOML gate (tombi 1.2.0): lint-checks Cargo.toml (validated offline
# against the embedded SchemaStore cargo.json), rust-toolchain.toml, .cargo/config.toml,
# and workspace member manifests. Format gate runs in --check --diff so unformatted TOML
# fails without rewrite. Cargo.lock is excluded from formatting via tombi.toml. --offline
# keeps CI hermetic; --error-on-warnings makes warnings hard failures. Scope lives in
# tombi.toml, so no path args are passed.
lint-toml:
    tombi format --check --diff
    tombi lint --offline --error-on-warnings

# Check this Justfile against just's own formatter in --check mode:
# report drift and fail without rewriting anything. Nothing else in the
# chain reads this file's layout — biome, rumdl, yamllint, and tombi
# each own a different language — so absent this gate the Justfile is
# the one config in the tree whose formatting drifts unchecked.
# `format-just` below is the in-place counterpart. See that recipe for
# why --unstable is spelled out.
lint-just:
    just --fmt --check --unstable

# Enforce .editorconfig with editorconfig-checker: charset, line
# endings, final newline, trailing whitespace, and both the
# tab-versus-space indent style and the indent width. The file has sat
# in the tree unread by anything but editors; this is the gate that
# makes it binding. With no path arguments the checker walks the files
# git tracks, so the target/ build tree and Vale's synced style
# packages are out of scope by construction —
# .editorconfig-checker.json repeats the Vale exclusion for the case
# where a caller names paths explicitly, mirroring the top-level
# `exclude:` in .pre-commit-config.yaml, and adds CHANGELOG.md, which
# `cog changelog` regenerates wholesale, and LICENSES/, whose contents
# are upstream license text nobody here may reflow. Upstream's release
# archives also ship a short `ec` alias, but the Homebrew formula the
# Brewfile provisions from builds the long name only, so the recipe
# spells it out.
lint-editorconfig:
    editorconfig-checker

# Lint GitHub Actions workflow files via actionlint. actionlint walks
# `.github/workflows/` by default, parses each workflow, and flags
# unknown actions, mis-typed expressions, shellcheck issues inside
# `run:` blocks, and SHA-pin drift. Complements `lint-yaml` (which
# checks YAML structure) with workflow-shape rules yamllint can't see.
# Pinned Docker image; Renovate bumps the version + digest via the
# shared Justfile customManager.
lint-workflows:
    {{ actionlint }}

# Pre-validate a drafted commit message against the same gates the
# commit-msg hook runs, so message problems surface while iterating
# rather than at commit time. Reads the draft from the repo-root
# COMMIT_AGENTMSG file (gitignored; see AGENTS.md for the workflow) and
# runs the commit-msg stage through prek, which fires the four shared
# hooks from proofhouse/pre-commit-hooks: commit-trailers, commitlint,
# vale-commit-msg, and cspell-commit-msg. The real gate stays the prek
# commit-msg hook on .git/COMMIT_EDITMSG; this recipe only mirrors it.
# Commit the validated draft with `git commit -F COMMIT_AGENTMSG`.
lint-commit-msg:
    prek run --stage commit-msg --commit-msg-filename COMMIT_AGENTMSG

# --- Format ---

# Aggregate in-place formatter. Grows per gate; carries the Rust
# formatter plus the Markdown, config, and TOML fixers and this file's
# own formatter today.
format: format-rs format-markdown format-config format-toml format-just

# Rewrite Rust sources through rustfmt. Style settings come from
# rustfmt.toml at the repo root.
format-rs:
    cargo fmt --all

# Format Markdown files (whitespace, list markers, code fence styles).
# Rewrites in place. Pair with `fix-markdown` for semantic lint fixes.
format-markdown *args:
    rumdl fmt {{ if args == "" { "." } else { args } }}

# Format JSON / JS / TS files in place via biome's formatter.
format-config *args:
    biome format --write {{ if args == "" { "." } else { args } }}

# In-place TOML formatter — fixer paired with lint-toml's --check gate. Whitespace/style
# only; key order preserved (reordering disabled in tombi.toml).
format-toml:
    tombi format

# Rewrite this Justfile in just's own canonical format. `lint-just`
# runs the --check form, so drift fails the gate instead of being
# rewritten behind the contributor's back; this is the in-place
# counterpart, the same split `format-toml` and `lint-toml` follow.
# `just --fmt` is still an unstable feature, and the flag is passed
# explicitly rather than leaning on the `set unstable` at the top of
# this file, so the recipe keeps working if that setting ever goes.
format-just:
    just --fmt --unstable

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

# Run pre-commit hooks on changed files (the everyday invocation).
prek:
    prek

# Run pre-commit hooks on every file in the tree. Useful after a
# hook config change or before a release sweep.
prek-all:
    prek run --all-files

# Install the project's pre-commit hooks (commit-msg, pre-commit,
# pre-push). New contributors run this once after `just setup`; the
# `just setup` recipe does NOT run it automatically because installing
# hooks modifies .git/ and contributors may prefer to opt in.
prek-install:
    prek install -t commit-msg -t pre-commit -t pre-push

# Generate the full CHANGELOG.md from Conventional Commit history.
# `cog changelog` emits Markdown without an H1; the pipeline prepends
# one and runs rumdl with MD024 (duplicate headings) disabled so
# adjacent releases with the same section names don't fight the
# linter.
generate-changelog:
    cog changelog | { echo "# Changelog"; cat; } | rumdl check -d MD024 --fix --stdin > CHANGELOG.md

# Preview the changelog entries since the last tagged release. Useful
# during release prep to see what `cog changelog` will emit before
# committing the regeneration.
preview-changelog:
    cog changelog --at $(git describe --tags)..HEAD -t full_hash | rumdl check -d MD041 --fix --stdin

# Generate release notes for a specific version (or for HEAD if no
# version is given). Output goes to stdout; pipe to a file or paste
# into the GitHub release body.
[script]
generate-release-notes version="":
    v=$([[ -n "{{ version }}" ]] && echo "v{{ version }}" || echo "..$(git rev-parse HEAD)")
    cog changelog --at $v -t full_hash | rumdl check -d MD024,MD041 --isolated --fix --stdin
