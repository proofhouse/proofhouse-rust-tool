// SPDX-License-Identifier: Apache-2.0
// Copyright Authors of Proofhouse

//! Property checks over the version output.
//!
//! The tests beside the source pin a handful of concrete stamps. This suite
//! widens the input to every stamp a build can carry and holds the rendered
//! block to the shape a person skims and a script parses: three lines, one
//! stamp value each, under prefixes that never move.

// A test asserts what it expects and stops at the first surprise, so
// unwrapping through expect and reaching a line by index is the point rather
// than a hazard. Production code answers to both lints.
#![expect(
    clippy::expect_used,
    clippy::indexing_slicing,
    reason = "a failed assumption in a test should end the test"
)]
// The lint wants every #[test] inside a #[cfg(test)] module, which is what
// keeps test code out of a library build. Cargo builds this file only as a
// test binary, so the whole file is already that module.
#![expect(
    clippy::tests_outside_test_module,
    reason = "an integration test file compiles as a test target and nothing else"
)]

use clap::Parser as _;
use proptest::{option, prop_assert, prop_assert_eq, proptest};

use proofhouse_rust_tool::buildmeta;
use proofhouse_rust_tool::cli::{self, Cli};

/// Pattern the drawn stamp values match.
///
/// A stamp field holds free text of its own kind: git writes an abbreviated
/// hash into one and a formatted instant into the other, and neither is
/// anything the rendering inspects. What both do carry is a single line. The
/// class excludes the two line terminators for that reason, and the length
/// bound only keeps a failure report readable.
const STAMP_FIELD: &str = "[^\r\n]{0,32}";

proptest! {
    /// Any pair of stamp values renders as the same three-line block.
    ///
    /// Absent values stand for a build that ran outside a checkout, where the
    /// commit reads empty and the date reads as the documented placeholder.
    /// Both lines still appear, so the block a reader parses has one shape
    /// rather than two.
    #[test]
    fn version_renders_three_lines_for_any_stamp(
        commit in option::of(STAMP_FIELD),
        date in option::of(STAMP_FIELD),
    ) {
        let info = buildmeta::resolve(commit.as_deref(), date.as_deref());
        let cli = Cli::try_parse_from(["proofhouse-rust-tool", "version"])
            .expect("version subcommand parses");
        let mut out = Vec::new();
        cli::run(&cli, &info, &mut out).expect("writing to a vec succeeds");
        let text = String::from_utf8(out).expect("output is utf-8");

        let lines: Vec<&str> = text.lines().collect();
        prop_assert_eq!(lines.len(), 3);
        prop_assert_eq!(
            lines[0],
            format!("proofhouse-rust-tool {}", env!("CARGO_PKG_VERSION"))
        );
        prop_assert_eq!(lines[1], format!("commit: {}", commit.as_deref().unwrap_or("")));
        prop_assert_eq!(lines[2], format!("date:   {}", date.as_deref().unwrap_or("unknown")));
        prop_assert!(text.ends_with('\n'));
    }
}
