// SPDX-License-Identifier: Apache-2.0
// Copyright Authors of Proofhouse

//! Command-line surface of the proofhouse-rust-tool reference CLI.
//!
//! The command set stays intentionally small: a single `version` subcommand
//! that prints the stamped build metadata. The repository's value sits in the
//! supply-chain gates built around the binary, not in the command surface.

use std::io;

use clap::{Parser, Subcommand};

use crate::buildmeta;

/// Reference CLI for the Proofhouse Rust tool reference repository.
#[derive(Parser, Debug)]
#[command(name = "proofhouse-rust-tool", arg_required_else_help = true)]
pub struct Cli {
    /// Subcommand selected on the command line.
    #[command(subcommand)]
    command: Command,
}

/// Subcommands the tool understands.
#[derive(Subcommand, Debug)]
enum Command {
    /// Print version information.
    Version,
}

/// Run the parsed command, writing its output to `out`.
///
/// # Errors
///
/// Returns any error raised while writing to `out`.
pub fn run(cli: &Cli, out: &mut impl io::Write) -> io::Result<()> {
    match cli.command {
        Command::Version => {
            let info = buildmeta::get();
            writeln!(
                out,
                "proofhouse-rust-tool {}\ncommit: {}\ndate:   {}",
                info.version, info.commit, info.date
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use clap::Parser;
    use clap::error::ErrorKind;

    use super::{Cli, run};
    use crate::buildmeta;

    #[test]
    fn version_renders_three_stamped_lines() {
        let cli = Cli::try_parse_from(["proofhouse-rust-tool", "version"])
            .expect("version subcommand parses");
        let mut out = Vec::new();
        run(&cli, &mut out).expect("writing to a vec succeeds");
        let text = String::from_utf8(out).expect("output is utf-8");

        let info = buildmeta::get();
        assert_eq!(
            text,
            format!(
                "proofhouse-rust-tool {}\ncommit: {}\ndate:   {}\n",
                info.version, info.commit, info.date
            )
        );

        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 3);
        assert!(lines[0].starts_with("proofhouse-rust-tool "));
        assert!(lines[1].starts_with("commit: "));
        assert!(lines[2].starts_with("date:   "));
    }

    #[test]
    fn bare_invocation_asks_for_help() {
        let err = Cli::try_parse_from(["proofhouse-rust-tool"])
            .expect_err("a missing subcommand is an error");
        assert_eq!(
            err.kind(),
            ErrorKind::DisplayHelpOnMissingArgumentOrSubcommand
        );
        assert!(err.to_string().contains("Usage:"));
    }
}
