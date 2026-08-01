// SPDX-License-Identifier: Apache-2.0
// Copyright Authors of Proofhouse

//! Reference CLI for the Proofhouse Rust tool reference repository.

// `coverage(off)` below is a nightly attribute. The coverage run is the only
// build that sets this flag, so a release build never reaches the feature gate
// and never needs a nightly compiler.
#![cfg_attr(coverage_nightly, feature(coverage_attribute))]

use std::io::{self, Write as _};
use std::process::ExitCode;

use clap::Parser as _;

use proofhouse_rust_tool::buildmeta;
use proofhouse_rust_tool::cli::{self, Cli};

// The one function no test can call. It reads the real argv and hands an exit
// code back to the operating system, and everything it decides afterward lives
// in `cli::run`, which the tests drive directly. Marking it off keeps the
// coverage report at the whole of the measured surface rather than at the whole
// of it minus a wrapper.
#[cfg_attr(coverage_nightly, coverage(off))]
fn main() -> ExitCode {
    let cli = Cli::parse();
    let info = buildmeta::get();
    let mut out = io::stdout().lock();
    match cli::run(&cli, &info, &mut out) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            // A write to stderr that itself fails leaves nowhere to report
            // the failure, so the result goes unread on purpose.
            #[expect(
                clippy::let_underscore_must_use,
                reason = "the exit code already carries the failure"
            )]
            let _ = writeln!(io::stderr(), "proofhouse-rust-tool: {err}");
            ExitCode::FAILURE
        }
    }
}
