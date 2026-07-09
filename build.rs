// SPDX-License-Identifier: Apache-2.0
// Copyright Authors of Proofhouse

//! Build script that stamps git build metadata into the binary.
//!
//! It probes git for the short commit SHA and the committer date, emitting
//! them as compile-time environment variables the `buildmeta` module reads.
//! When git is unavailable or this is not a checkout, it emits nothing and
//! the crate falls back to its placeholder values.

use std::env;
use std::fs;
use std::path::Path;
use std::process::Command;

fn main() {
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap_or_else(|_| ".".to_owned());

    if let Some(commit) = run_git(&manifest_dir, &["rev-parse", "--short=7", "HEAD"], None) {
        println!("cargo::rustc-env=PROOFHOUSE_BUILD_COMMIT={commit}");
    }
    if let Some(date) = run_git(
        &manifest_dir,
        &[
            "log",
            "-1",
            "--format=%cd",
            "--date=format-local:%Y-%m-%dT%H:%M:%SZ",
        ],
        Some(("TZ", "UTC")),
    ) {
        println!("cargo::rustc-env=PROOFHOUSE_BUILD_DATE={date}");
    }

    register_rerun(&manifest_dir);
}

/// Run a git command in `dir` and return its trimmed stdout, or `None` when
/// git is missing, the command fails, or the output is empty.
fn run_git(dir: &str, args: &[&str], var: Option<(&str, &str)>) -> Option<String> {
    let mut command = Command::new("git");
    command.args(args).current_dir(dir);
    if let Some((key, value)) = var {
        command.env(key, value);
    }
    let output = command.output().ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8(output.stdout).ok()?;
    let trimmed = text.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_owned())
    }
}

/// Register the git refs whose change should retrigger a rebuild. Watching
/// `.git/HEAD` alone goes stale, since a new commit on the current branch
/// rewrites the branch ref rather than HEAD, so a symbolic HEAD also
/// registers the ref file it points at.
fn register_rerun(dir: &str) {
    println!("cargo::rerun-if-changed=.git/HEAD");
    let head = Path::new(dir).join(".git").join("HEAD");
    if let Ok(contents) = fs::read_to_string(head)
        && let Some(reference) = contents.strip_prefix("ref: ")
    {
        println!("cargo::rerun-if-changed=.git/{}", reference.trim());
    }
}
