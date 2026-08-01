// SPDX-License-Identifier: Apache-2.0
// Copyright Authors of Proofhouse

//! Build-time information stamped into the tool.
//!
//! The version comes from the crate metadata. The commit and date come
//! from the compile-time environment variables the build script emits when
//! it runs inside a git checkout. Placeholders stand in for the commit and
//! date whenever a build starts from a source tarball with no git around.

/// Version, short git commit, and build date of a tool build.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BuildInfo {
    /// Semantic version, from the crate's `CARGO_PKG_VERSION`.
    pub version: &'static str,
    /// Short git commit SHA, or empty when built outside a checkout.
    pub commit: &'static str,
    /// Committer date in UTC ISO-8601, or `"unknown"` outside a checkout.
    pub date: &'static str,
}

/// Return the build metadata for the current binary.
#[must_use]
pub fn get() -> BuildInfo {
    resolve(
        option_env!("PROOFHOUSE_BUILD_COMMIT"),
        option_env!("PROOFHOUSE_BUILD_DATE"),
    )
}

/// Fill a [`BuildInfo`] from the optionally stamped commit and date, applying
/// the empty-string and `"unknown"` fallbacks when the build script emitted
/// nothing.
fn resolve(commit: Option<&'static str>, date: Option<&'static str>) -> BuildInfo {
    BuildInfo {
        version: env!("CARGO_PKG_VERSION"),
        commit: commit.unwrap_or(""),
        date: date.unwrap_or("unknown"),
    }
}

// Whether a stamped value looks right depends on whether git was around at
// build time, and a run can't pick which of the two builds it gets. The
// predicates below carry that either-or so a test can drive both sides of it
// by argument, leaving `get_yields_environment_agnostic_values` to assert
// against whichever one this build produced.
#[cfg(test)]
mod tests {
    use super::{get, resolve};

    /// Whether `commit` reads as a stamped short SHA or as the unstamped
    /// placeholder.
    fn commit_has_expected_shape(commit: &str) -> bool {
        commit.is_empty() || (commit.len() == 7 && commit.chars().all(|ch| ch.is_ascii_hexdigit()))
    }

    /// Whether `date` reads as a stamped ISO-8601 instant or as the unstamped
    /// placeholder.
    fn date_has_expected_shape(date: &str) -> bool {
        let year: Vec<char> = date.chars().take(4).collect();
        date == "unknown" || (year.len() == 4 && year.iter().all(char::is_ascii_digit))
    }

    #[test]
    fn commit_shape_spans_stamped_and_unstamped_builds() {
        assert!(commit_has_expected_shape(""));
        assert!(commit_has_expected_shape("abc1234"));
        assert!(!commit_has_expected_shape("abc123"));
        assert!(!commit_has_expected_shape("1234abz"));
    }

    #[test]
    fn date_shape_spans_stamped_and_unstamped_builds() {
        assert!(date_has_expected_shape("unknown"));
        assert!(date_has_expected_shape("2026-07-09T12:00:00Z"));
        assert!(!date_has_expected_shape("26"));
        assert!(!date_has_expected_shape("20x6-07-09T12:00:00Z"));
    }

    #[test]
    fn resolve_uses_fallbacks_when_unstamped() {
        let info = resolve(None, None);
        assert_eq!(info.commit, "");
        assert_eq!(info.date, "unknown");
        assert!(!info.version.is_empty());
    }

    #[test]
    fn resolve_passes_stamped_values_through() {
        let info = resolve(Some("abc1234"), Some("2026-07-09T12:00:00Z"));
        assert_eq!(info.commit, "abc1234");
        assert_eq!(info.date, "2026-07-09T12:00:00Z");
    }

    #[test]
    fn get_yields_environment_agnostic_values() {
        let info = get();
        assert_eq!(info.version, env!("CARGO_PKG_VERSION"));

        assert!(
            commit_has_expected_shape(info.commit),
            "commit must be empty or 7 hex chars, got {:?}",
            info.commit
        );
        assert!(
            date_has_expected_shape(info.date),
            "date must be \"unknown\" or start with a 4-digit year, got {:?}",
            info.date
        );
    }
}
