// SPDX-License-Identifier: Apache-2.0
// Copyright Authors of Proofhouse

//! Reference CLI for the Proofhouse Rust tool reference repository.

use std::io::{self, Write};
use std::process::ExitCode;

use clap::Parser;

use proofhouse_rust_tool::cli::{self, Cli};

fn main() -> ExitCode {
    let cli = Cli::parse();
    let mut out = io::stdout().lock();
    match cli::run(&cli, &mut out) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            let _ = writeln!(io::stderr(), "proofhouse-rust-tool: {err}");
            ExitCode::FAILURE
        }
    }
}
