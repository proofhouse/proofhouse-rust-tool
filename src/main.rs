// SPDX-License-Identifier: Apache-2.0
// Copyright Authors of Proofhouse

//! Reference CLI for the Proofhouse Rust tool reference repository.

use std::io::{self, Write as _};
use std::process::ExitCode;

use clap::Parser as _;

use proofhouse_rust_tool::cli::{self, Cli};

fn main() -> ExitCode {
    let cli = Cli::parse();
    let mut out = io::stdout().lock();
    match cli::run(&cli, &mut out) {
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
