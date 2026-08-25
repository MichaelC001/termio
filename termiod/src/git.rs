//! The `git:` resource kind (§C.13): status as a subscription, plus the read
//! tier the History and Compare panes are made of.
//!
//! Status is the second consumer of §C.10's one mechanism — id, cursor, ring,
//! gap, linger — nothing new to learn. The host runs a debounced
//! `git status --porcelain=v2` when the workspace watcher reports change and
//! publishes the *delta* against the previous run.
//!
//! Beside it sit four request/response verbs: `git.diff`, `git.log`,
//! `git.show`, `git.branches`. All of them read; the mutation and network
//! tiers are staged separately (`docs/design/20260818-remote-git-plane.md` §5) because
//! they need a design for prompts and for index-lock contention that reads do
//! not. Every one of them runs the box's own `git` as a child process, so the
//! box's config, hooks, and credential helper are the ones in force — nothing
//! here reimplements git.

use crate::protocol::{
    Event, GitBranchEntry, GitCommitEntry, GitCommitFile, GitFileStatus, GitStatusCode,
    GitStatusEntry, GitUnmergedCode,
};
use anyhow::{bail, Context, Result};
use std::collections::{HashMap, HashSet};

/// A `git.diff` reply is cut here — the same preview budget as `fs.read`.
pub const DIFF_CAP: usize = 1024 * 1024;

/// A `git.log` walk stops here however large `limit` was. A history pane
/// scrolls; it does not need the whole repository in one frame.
pub const LOG_CAP: u64 = 1000;

/// A `git.show` file list stops here. A tree-wide commit (a vendor drop, a
/// reformat) would otherwise put a megabyte of file rows on a control channel.
pub const SHOW_FILE_CAP: usize = 5000;

/// A `git.branches` reply stops here. Long-lived clones carry thousands of
/// stale remote-tracking refs and the picker shows a handful.
pub const BRANCH_CAP: usize = 2000;

/// Field separator inside one commit record (US), and the fields themselves.
/// Records are NUL-terminated by `-z` — `tformat:` and not `format:`, so the
/// terminator is there even for the single record `git show` prints — which is
/// what lets a subject holding a newline survive intact.
const FIELD: char = '\u{1f}';
const COMMIT_FORMAT: &str =
    "--pretty=tformat:%H\u{1f}%h\u{1f}%s\u{1f}%an\u{1f}%ae\u{1f}%ad\u{1f}%at\u{1f}%D";

/// Every git child starts here: the box's own git, the box's own config, and
/// `--no-optional-locks` so a read can never contend with the agent committing
/// in the terminal beside it.
fn git_command(root: &str) -> tokio::process::Command {
    let mut command = tokio::process::Command::new("git");
    command.arg("--no-optional-locks").arg("-C").arg(root);
    command
}

/// A revision reaches git as a positional argument, so one beginning with `-`
/// would be read as an option. Refused rather than escaped.
fn validate_revision(revision: &str) -> Result<()> {
    if revision.is_empty() || revision.starts_with('-') {
        bail!("not a usable revision: {revision:?}");
    }
    Ok(())
}

/// Everything one status run said. The live copy backs the synthetic
/// full-state batch a gap subscriber receives — only the host can "rescan"
/// git status, so on gap it does the scan for the client.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct GitSnapshot {
    pub statuses: HashMap<String, GitFileStatus>,
    pub branch: Option<String>,
    pub head: Option<String>,
    pub ahead_behind: Option<(u32, u32)>,
}

impl GitSnapshot {
    pub fn conflicts(&self) -> Vec<String> {
        let mut paths: Vec<String> = self
            .statuses
            .iter()
            .filter(|(_, status)| matches!(status, GitFileStatus::Unmerged { .. }))
            .map(|(path, _)| path.clone())
            .collect();
        paths.sort();
        paths
    }

    /// The full state as one batch — what a fresh or gap subscriber applies
    /// to an empty baseline.
    pub fn full_batch(&self) -> GitBatch {
        let mut updated: Vec<GitStatusEntry> = self
            .statuses
            .iter()
            .map(|(path, status)| GitStatusEntry {
                path: path.clone(),
                status: *status,
            })
            .collect();
        updated.sort_by(|a, b| a.path.cmp(&b.path));
        GitBatch {
            updated_statuses: updated,
            removed_paths: Vec::new(),
            branch: self.branch.clone(),
            head: self.head.clone(),
            ahead_behind: self.ahead_behind,
            conflicts: self.conflicts(),
        }
    }

    /// The delta that turns `previous` into `self`, or `None` when nothing a
    /// client can see moved.
    pub fn delta_from(&self, previous: &GitSnapshot) -> Option<GitBatch> {
        let mut updated: Vec<GitStatusEntry> = self
            .statuses
            .iter()
            .filter(|(path, status)| previous.statuses.get(*path) != Some(status))
            .map(|(path, status)| GitStatusEntry {
                path: path.clone(),
                status: *status,
            })
            .collect();
        updated.sort_by(|a, b| a.path.cmp(&b.path));
        let mut removed: Vec<String> = previous
            .statuses
            .keys()
            .filter(|path| !self.statuses.contains_key(*path))
            .cloned()
            .collect();
        removed.sort();

        let metadata_moved = self.branch != previous.branch
            || self.head != previous.head
            || self.ahead_behind != previous.ahead_behind;
        if updated.is_empty() && removed.is_empty() && !metadata_moved {
            return None;
        }
        Some(GitBatch {
            updated_statuses: updated,
            removed_paths: removed,
            branch: self.branch.clone(),
            head: self.head.clone(),
            ahead_behind: self.ahead_behind,
            conflicts: self.conflicts(),
        })
    }
}

/// One published `git_changed` batch (the §C.10 ring element for this kind).
#[derive(Debug, Clone, PartialEq)]
pub struct GitBatch {
    pub updated_statuses: Vec<GitStatusEntry>,
    pub removed_paths: Vec<String>,
    pub branch: Option<String>,
    pub head: Option<String>,
    pub ahead_behind: Option<(u32, u32)>,
    pub conflicts: Vec<String>,
}

impl GitBatch {
    pub fn into_event(self, resource: String, seq: u64) -> Event {
        Event::GitChanged {
            resource,
            seq,
            updated_statuses: self.updated_statuses,
            removed_paths: self.removed_paths,
            branch: self.branch,
            head: self.head,
            ahead_behind: self.ahead_behind,
            conflicts: self.conflicts,
        }
    }
}

/// Run `git status --porcelain=v2 -z` for the repo at `root`.
/// `--no-optional-locks` matters: a plain `git status` refreshes the index
/// file, which the workspace watcher reports as `git_meta`, which would
/// trigger this again — a feedback loop by construction.
pub async fn run_status(root: &str) -> Result<GitSnapshot> {
    let output = git_command(root)
        .arg("status")
        .arg("--porcelain=v2")
        .arg("-z")
        .arg("--branch")
        .arg("--untracked-files=all")
        .output()
        .await
        .context("running git status")?;
    if !output.status.success() {
        bail!(
            "git status failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    parse_porcelain_v2(&output.stdout)
}

/// Parse `--porcelain=v2 -z` output. Records are NUL-terminated; a rename
/// record (`2`) is followed by one extra NUL-terminated field holding the
/// original path.
pub fn parse_porcelain_v2(bytes: &[u8]) -> Result<GitSnapshot> {
    let mut snapshot = GitSnapshot::default();
    let mut fields = bytes.split(|&byte| byte == 0);
    while let Some(record) = fields.next() {
        if record.is_empty() {
            continue;
        }
        let record = String::from_utf8_lossy(record);
        if let Some(header) = record.strip_prefix("# ") {
            parse_branch_header(header, &mut snapshot);
            continue;
        }
        let mut parts = record.splitn(2, ' ');
        let tag = parts.next().unwrap_or_default();
        let rest = parts.next().unwrap_or_default();
        match tag {
            "1" => {
                // 1 XY sub mH mI mW hH hI <path>
                let mut columns = rest.splitn(8, ' ');
                let xy = columns.next().unwrap_or_default();
                let path = columns.nth(6).unwrap_or_default();
                if let (Some(status), false) = (tracked_status(xy), path.is_empty()) {
                    snapshot.statuses.insert(path.to_string(), status);
                }
            }
            "2" => {
                // 2 XY sub mH mI mW hH hI Xscore <path> NUL <origPath>
                let mut columns = rest.splitn(9, ' ');
                let xy = columns.next().unwrap_or_default();
                let path = columns.nth(7).unwrap_or_default();
                // Consume the origPath field so it is not read as a record.
                let _orig = fields.next();
                if let (Some(status), false) = (tracked_status(xy), path.is_empty()) {
                    snapshot.statuses.insert(path.to_string(), status);
                }
            }
            "u" => {
                // u XY sub m1 m2 m3 mW h1 h2 h3 <path>
                let mut columns = rest.splitn(10, ' ');
                let xy = columns.next().unwrap_or_default();
                let path = columns.nth(8).unwrap_or_default();
                if let (Some(status), false) = (unmerged_status(xy), path.is_empty()) {
                    snapshot.statuses.insert(path.to_string(), status);
                }
            }
            "?" => {
                snapshot
                    .statuses
                    .insert(rest.to_string(), GitFileStatus::Untracked);
            }
            "!" => {
                snapshot
                    .statuses
                    .insert(rest.to_string(), GitFileStatus::Ignored);
            }
            _ => {}
        }
    }
    Ok(snapshot)
}

fn parse_branch_header(header: &str, snapshot: &mut GitSnapshot) {
    if let Some(oid) = header.strip_prefix("branch.oid ") {
        if oid != "(initial)" {
            snapshot.head = Some(oid.to_string());
        }
    } else if let Some(name) = header.strip_prefix("branch.head ") {
        if name != "(detached)" {
            snapshot.branch = Some(name.to_string());
        }
    } else if let Some(ab) = header.strip_prefix("branch.ab ") {
        let mut parts = ab.split(' ');
        let ahead = parts
            .next()
            .and_then(|part| part.strip_prefix('+'))
            .and_then(|part| part.parse().ok());
        let behind = parts
            .next()
            .and_then(|part| part.strip_prefix('-'))
            .and_then(|part| part.parse().ok());
        if let (Some(ahead), Some(behind)) = (ahead, behind) {
            snapshot.ahead_behind = Some((ahead, behind));
        }
    }
}

fn status_code(byte: u8) -> Option<GitStatusCode> {
    match byte {
        b'.' => Some(GitStatusCode::Unmodified),
        b'M' => Some(GitStatusCode::Modified),
        b'T' => Some(GitStatusCode::TypeChanged),
        b'A' => Some(GitStatusCode::Added),
        b'D' => Some(GitStatusCode::Deleted),
        b'R' => Some(GitStatusCode::Renamed),
        b'C' => Some(GitStatusCode::Copied),
        _ => None,
    }
}

fn tracked_status(xy: &str) -> Option<GitFileStatus> {
    let bytes = xy.as_bytes();
    if bytes.len() != 2 {
        return None;
    }
    Some(GitFileStatus::Tracked {
        index_status: status_code(bytes[0])?,
        worktree_status: status_code(bytes[1])?,
    })
}

fn unmerged_code(byte: u8) -> Option<GitUnmergedCode> {
    match byte {
        b'U' => Some(GitUnmergedCode::Updated),
        b'A' => Some(GitUnmergedCode::Added),
        b'D' => Some(GitUnmergedCode::Deleted),
        _ => None,
    }
}

fn unmerged_status(xy: &str) -> Option<GitFileStatus> {
    let bytes = xy.as_bytes();
    if bytes.len() != 2 {
        return None;
    }
    Some(GitFileStatus::Unmerged {
        first_head: unmerged_code(bytes[0])?,
        second_head: unmerged_code(bytes[1])?,
    })
}

/// `git.diff` (§C.13): a unified diff for one path, worktree-vs-index by
/// default, index-vs-HEAD with `staged`. Capped at [`DIFF_CAP`].
pub async fn run_diff(root: &str, path: &str, staged: bool) -> Result<(String, bool)> {
    let mut command = git_command(root);
    command.arg("diff");
    if staged {
        command.arg("--cached");
    }
    command.arg("--").arg(path);
    let output = command.output().await.context("running git diff")?;
    if !output.status.success() {
        bail!(
            "git diff failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(cap_diff(String::from_utf8_lossy(&output.stdout).into_owned()))
}

/// Cut a diff at [`DIFF_CAP`] on a character boundary, reporting that it was
/// cut. A client is told the text is partial; it is never handed a silently
/// short diff.
fn cap_diff(mut diff: String) -> (String, bool) {
    let truncated = diff.len() > DIFF_CAP;
    if truncated {
        let mut cut = DIFF_CAP;
        while !diff.is_char_boundary(cut) {
            cut -= 1;
        }
        diff.truncate(cut);
    }
    (diff, truncated)
}

/// One `git.log` page: commits newest first, and whether the walk stopped at
/// the limit rather than at the root.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitLogPage {
    pub commits: Vec<GitCommitEntry>,
    pub truncated: bool,
}

/// `git.log` (§C.13 read tier): the commit list behind the History tab.
/// `range` narrows the walk (`origin/main..HEAD` for a branch comparison).
pub async fn run_log(root: &str, limit: u64, range: Option<&str>) -> Result<GitLogPage> {
    if let Some(range) = range {
        validate_revision(range)?;
    }
    let wanted = limit.clamp(1, LOG_CAP);
    let mut command = git_command(root);
    command
        .arg("log")
        .arg("-z")
        .arg("-n")
        .arg(wanted.to_string())
        .arg("--date=relative")
        .arg(COMMIT_FORMAT);
    if let Some(range) = range {
        command.arg(range);
    }
    let output = command.output().await.context("running git log")?;
    if !output.status.success() {
        // A repository whose first commit is still unwritten has no history,
        // which is an empty list, not a failure. Asked of git rather than
        // matched against its stderr, which is localized.
        if !has_commits(root).await {
            return Ok(GitLogPage {
                commits: Vec::new(),
                truncated: false,
            });
        }
        bail!(
            "git log failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    let unpushed = unpushed_commits(root).await;
    let commits = parse_commits(&output.stdout, &unpushed);
    let truncated = commits.len() as u64 >= wanted;
    Ok(GitLogPage { commits, truncated })
}

/// One commit as `git.show` reports it: what it is, what it touched, and the
/// diff — the whole commit's, or one file's when the caller named a path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitCommitDetail {
    pub commit: GitCommitEntry,
    pub files: Vec<GitCommitFile>,
    pub diff: String,
    pub truncated: bool,
    pub files_truncated: bool,
}

/// `git.show` (§C.13 read tier). `--first-parent` throughout: without it a
/// merge commit's diff is a combined diff, which is empty for a clean merge,
/// so every merged pull request in the history would read as touching nothing.
pub async fn run_show(root: &str, commit: &str, path: Option<&str>) -> Result<GitCommitDetail> {
    validate_revision(commit)?;
    // Metadata and the file list in one child: `--raw` carries the status
    // letter and `--numstat` the counts, already keyed by the same paths.
    let described = git_command(root)
        .arg("show")
        .arg(COMMIT_FORMAT)
        .arg("--date=relative")
        .arg("--raw")
        .arg("--numstat")
        .arg("-z")
        .arg("-M")
        .arg("--first-parent")
        .arg(commit)
        .output()
        .await
        .context("running git show")?;
    if !described.status.success() {
        bail!(
            "git show failed: {}",
            String::from_utf8_lossy(&described.stderr).trim()
        );
    }
    let unpushed = unpushed_commits(root).await;
    let (mut entry, files, files_truncated) = parse_commit_detail(&described.stdout)?;
    entry.unpushed = unpushed.contains(&entry.sha);

    let mut command = git_command(root);
    command
        .arg("show")
        .arg("--format=")
        .arg("-M")
        .arg("--first-parent")
        .arg(commit);
    if let Some(path) = path {
        // A rename is limited to *both* paths: git applies the path limit
        // before rename detection, so asking for the destination alone turns a
        // pure rename into the whole file arriving as additions.
        command.arg("--").arg(path);
        if let Some(original) = files
            .iter()
            .find(|file| file.path == path)
            .and_then(|file| file.original_path.as_deref())
        {
            command.arg(original);
        }
    }
    let patch = command.output().await.context("running git show")?;
    if !patch.status.success() {
        bail!(
            "git show failed: {}",
            String::from_utf8_lossy(&patch.stderr).trim()
        );
    }
    let (diff, truncated) = cap_diff(String::from_utf8_lossy(&patch.stdout).into_owned());
    Ok(GitCommitDetail {
        commit: entry,
        files,
        diff,
        truncated,
        files_truncated,
    })
}

/// The refs a checkout can be compared against, plus where it stands.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GitBranchList {
    pub branches: Vec<GitBranchEntry>,
    pub current: Option<String>,
    pub default_branch: Option<String>,
    pub truncated: bool,
}

/// `git.branches` (§C.13 read tier). One `for-each-ref` answers all of it:
/// `%(HEAD)` marks the checkout's own branch and `%(symref)` resolves
/// `origin/HEAD` to the default branch, so the picker costs one child process
/// rather than one per field.
pub async fn run_branches(root: &str) -> Result<GitBranchList> {
    let output = git_command(root)
        .arg("for-each-ref")
        .arg("--format=%(HEAD) %(refname) %(symref)")
        .arg("refs/heads")
        .arg("refs/remotes")
        .output()
        .await
        .context("running git for-each-ref")?;
    if !output.status.success() {
        bail!(
            "git for-each-ref failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(parse_refs(&String::from_utf8_lossy(&output.stdout)))
}

/// Commits the branch's upstream does not have. No upstream means a non-zero
/// exit, which is an empty set — a purely local branch marks no rows rather
/// than all of them.
async fn unpushed_commits(root: &str) -> HashSet<String> {
    let output = git_command(root)
        .arg("rev-list")
        .arg("@{upstream}..HEAD")
        .output()
        .await;
    match output {
        Ok(output) if output.status.success() => String::from_utf8_lossy(&output.stdout)
            .split_whitespace()
            .map(str::to_string)
            .collect(),
        _ => HashSet::new(),
    }
}

/// Whether HEAD resolves to a commit at all.
async fn has_commits(root: &str) -> bool {
    git_command(root)
        .arg("rev-parse")
        .arg("--verify")
        .arg("--quiet")
        .arg("HEAD")
        .output()
        .await
        .map(|output| output.status.success())
        .unwrap_or(false)
}

/// Parse `git log -z` in [`COMMIT_FORMAT`]: records NUL-terminated,
/// fields US-separated. A record with the wrong field count is dropped rather
/// than guessed at.
fn parse_commits(bytes: &[u8], unpushed: &HashSet<String>) -> Vec<GitCommitEntry> {
    bytes
        .split(|&byte| byte == 0)
        .filter_map(|record| {
            let record = String::from_utf8_lossy(record);
            parse_commit_record(record.trim_start_matches('\n'), unpushed)
        })
        .collect()
}

fn parse_commit_record(record: &str, unpushed: &HashSet<String>) -> Option<GitCommitEntry> {
    let fields: Vec<&str> = record.split(FIELD).collect();
    if fields.len() != 8 || fields[0].is_empty() {
        return None;
    }
    Some(GitCommitEntry {
        sha: fields[0].to_string(),
        short_sha: fields[1].to_string(),
        subject: fields[2].to_string(),
        author: fields[3].to_string(),
        author_email: fields[4].to_string(),
        relative_date: fields[5].to_string(),
        timestamp: fields[6].parse().unwrap_or(0),
        tags: fields[7]
            .split(", ")
            .filter_map(|decoration| decoration.strip_prefix("tag: "))
            .map(str::to_string)
            .collect(),
        unpushed: unpushed.contains(fields[0]),
    })
}

/// Parse `git show <COMMIT_FORMAT> --raw --numstat -z`: the
/// commit record, then every `--raw` record, then every `--numstat` record.
/// The two sections are told apart by their first byte — `:` opens a raw
/// record — and merged by path, keeping git's own order.
fn parse_commit_detail(bytes: &[u8]) -> Result<(GitCommitEntry, Vec<GitCommitFile>, bool)> {
    let mut fields = bytes.split(|&byte| byte == 0).map(|field| {
        String::from_utf8_lossy(field)
            .trim_start_matches('\n')
            .to_string()
    });
    let header = fields.next().unwrap_or_default();
    let Some(entry) = parse_commit_record(&header, &HashSet::new()) else {
        bail!("git show did not describe a commit");
    };

    let mut files: Vec<GitCommitFile> = Vec::new();
    let mut index: HashMap<String, usize> = HashMap::new();
    let mut truncated = false;
    while let Some(field) = fields.next() {
        if field.is_empty() {
            continue;
        }
        if let Some(raw) = field.strip_prefix(':') {
            // :mode mode sha sha STATUS NUL path [NUL path] — a rename or a
            // copy names both paths, everything else one.
            let Some(code) = raw.split(' ').next_back().and_then(|token| {
                token
                    .as_bytes()
                    .first()
                    .copied()
                    .and_then(commit_status_code)
            }) else {
                continue;
            };
            let renamed = matches!(code, GitStatusCode::Renamed | GitStatusCode::Copied);
            let first = fields.next().unwrap_or_default();
            let (path, original) = if renamed {
                (fields.next().unwrap_or_default(), Some(first))
            } else {
                (first, None)
            };
            if path.is_empty() {
                continue;
            }
            if files.len() >= SHOW_FILE_CAP {
                truncated = true;
                continue;
            }
            index.insert(path.clone(), files.len());
            files.push(GitCommitFile {
                path,
                original_path: original,
                status: code,
                additions: 0,
                deletions: 0,
                binary: false,
            });
            continue;
        }
        // adds TAB dels TAB path, or adds TAB dels TAB NUL old NUL new for a
        // rename. `-` for either count means git called the file binary.
        let mut columns = field.splitn(3, '\t');
        let (Some(additions), Some(deletions), Some(rest)) =
            (columns.next(), columns.next(), columns.next())
        else {
            continue;
        };
        let path = if rest.is_empty() {
            let _original = fields.next();
            fields.next().unwrap_or_default()
        } else {
            rest.to_string()
        };
        let Some(position) = index.get(&path) else {
            continue;
        };
        let file = &mut files[*position];
        file.binary = additions == "-" || deletions == "-";
        file.additions = additions.parse().unwrap_or(0);
        file.deletions = deletions.parse().unwrap_or(0);
    }
    Ok((entry, files, truncated))
}

/// A commit's file carries one status letter, unlike a worktree file's two
/// axes. `T` (type change) is folded into the modified axis exactly as the
/// status kind folds it.
fn commit_status_code(byte: u8) -> Option<GitStatusCode> {
    match byte {
        b'M' => Some(GitStatusCode::Modified),
        b'T' => Some(GitStatusCode::TypeChanged),
        b'A' => Some(GitStatusCode::Added),
        b'D' => Some(GitStatusCode::Deleted),
        b'R' => Some(GitStatusCode::Renamed),
        b'C' => Some(GitStatusCode::Copied),
        _ => None,
    }
}

/// Parse `for-each-ref --format='%(HEAD) %(refname) %(symref)'`. `%(HEAD)` is
/// one character — `*` for the checkout's own branch, a space for every other
/// ref — and a refname can hold no whitespace, which is what makes a
/// space-separated format unambiguous here.
fn parse_refs(text: &str) -> GitBranchList {
    let mut list = GitBranchList::default();
    for line in text.lines() {
        let Some(rest) = line.get(1..) else {
            continue;
        };
        let checked_out = line.starts_with('*');
        let mut columns = rest.split_whitespace();
        let Some(refname) = columns.next() else {
            continue;
        };
        let symref = columns.next().unwrap_or("");
        if let Some(name) = refname.strip_prefix("refs/heads/") {
            if checked_out {
                list.current = Some(name.to_string());
            }
            if list.branches.len() < BRANCH_CAP {
                list.branches.push(GitBranchEntry {
                    name: name.to_string(),
                    remote: false,
                });
            } else {
                list.truncated = true;
            }
        } else if let Some(name) = refname.strip_prefix("refs/remotes/") {
            // `origin/HEAD` is a symbolic pointer at the remote's default
            // branch, not a branch of its own.
            if name.ends_with("/HEAD") {
                list.default_branch = symref
                    .strip_prefix("refs/remotes/")
                    .filter(|target| !target.is_empty())
                    .map(str::to_string);
                continue;
            }
            if list.branches.len() < BRANCH_CAP {
                list.branches.push(GitBranchEntry {
                    name: name.to_string(),
                    remote: true,
                });
            } else {
                list.truncated = true;
            }
        }
    }
    list
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::{Path, PathBuf};

    fn joined(records: &[&str]) -> Vec<u8> {
        let mut bytes = Vec::new();
        for record in records {
            bytes.extend_from_slice(record.as_bytes());
            bytes.push(0);
        }
        bytes
    }

    #[test]
    fn porcelain_v2_maps_to_the_two_axis_vocabulary() {
        let snapshot = parse_porcelain_v2(&joined(&[
            "# branch.oid 1234567890abcdef",
            "# branch.head main",
            "# branch.ab +2 -1",
            "1 M. N... 100644 100644 100644 aaaa bbbb staged.rs",
            "1 .M N... 100644 100644 100644 aaaa aaaa dirty.rs",
            "1 MM N... 100644 100644 100644 aaaa bbbb both.rs",
            "1 D. N... 100644 000000 000000 aaaa 0000 gone.rs",
            "2 R. N... 100644 100644 100644 aaaa aaaa R100 new-name.rs",
            "old-name.rs",
            "u UU N... 100644 100644 100644 100644 a b c conflicted.rs",
            "u AA N... 000000 100644 100644 000000 a b c both-added.rs",
            "? fresh.txt",
            "! target/debug",
        ]))
        .unwrap();

        assert_eq!(snapshot.branch.as_deref(), Some("main"));
        assert_eq!(snapshot.head.as_deref(), Some("1234567890abcdef"));
        assert_eq!(snapshot.ahead_behind, Some((2, 1)));
        let status = |path: &str| snapshot.statuses[path];
        assert_eq!(
            status("staged.rs"),
            GitFileStatus::Tracked {
                index_status: GitStatusCode::Modified,
                worktree_status: GitStatusCode::Unmodified,
            }
        );
        assert_eq!(
            status("dirty.rs"),
            GitFileStatus::Tracked {
                index_status: GitStatusCode::Unmodified,
                worktree_status: GitStatusCode::Modified,
            }
        );
        assert_eq!(
            status("both.rs"),
            GitFileStatus::Tracked {
                index_status: GitStatusCode::Modified,
                worktree_status: GitStatusCode::Modified,
            }
        );
        assert_eq!(
            status("gone.rs"),
            GitFileStatus::Tracked {
                index_status: GitStatusCode::Deleted,
                worktree_status: GitStatusCode::Unmodified,
            }
        );
        assert_eq!(
            status("new-name.rs"),
            GitFileStatus::Tracked {
                index_status: GitStatusCode::Renamed,
                worktree_status: GitStatusCode::Unmodified,
            }
        );
        assert!(
            !snapshot.statuses.contains_key("old-name.rs"),
            "a rename's origin path is a field, not a record"
        );
        assert_eq!(
            status("conflicted.rs"),
            GitFileStatus::Unmerged {
                first_head: GitUnmergedCode::Updated,
                second_head: GitUnmergedCode::Updated,
            }
        );
        assert_eq!(status("fresh.txt"), GitFileStatus::Untracked);
        assert_eq!(status("target/debug"), GitFileStatus::Ignored);
        assert_eq!(
            snapshot.conflicts(),
            vec!["both-added.rs", "conflicted.rs"],
            "the conflict set is first-class"
        );
    }

    #[test]
    fn branch_placeholders_stay_absent() {
        let snapshot = parse_porcelain_v2(&joined(&[
            "# branch.oid (initial)",
            "# branch.head (detached)",
        ]))
        .unwrap();
        assert_eq!(snapshot.branch, None);
        assert_eq!(snapshot.head, None);
        assert_eq!(snapshot.ahead_behind, None);
    }

    #[test]
    fn deltas_carry_only_what_moved_and_full_batches_carry_everything() {
        let before = parse_porcelain_v2(&joined(&[
            "# branch.head main",
            "1 .M N... 100644 100644 100644 a a keeps.rs",
            "1 .M N... 100644 100644 100644 a a reverts.rs",
            "? becomes-tracked.txt",
        ]))
        .unwrap();
        let after = parse_porcelain_v2(&joined(&[
            "# branch.head main",
            "1 .M N... 100644 100644 100644 a a keeps.rs",
            "1 A. N... 000000 100644 100644 0 b becomes-tracked.txt",
        ]))
        .unwrap();

        let delta = after.delta_from(&before).unwrap();
        assert_eq!(
            delta
                .updated_statuses
                .iter()
                .map(|entry| entry.path.as_str())
                .collect::<Vec<_>>(),
            vec!["becomes-tracked.txt"],
            "an unchanged status is not re-sent"
        );
        assert_eq!(delta.removed_paths, vec!["reverts.rs"]);
        assert_eq!(delta.branch.as_deref(), Some("main"));

        assert!(
            after.delta_from(&after).is_none(),
            "no movement, no batch"
        );

        let mut detached = after.clone();
        detached.branch = None;
        assert!(
            detached.delta_from(&after).is_some(),
            "branch metadata moving is a publishable change"
        );

        let full = after.full_batch();
        assert_eq!(full.updated_statuses.len(), after.statuses.len());
        assert!(full.removed_paths.is_empty());
    }

    #[test]
    fn status_events_serialize_the_adopted_vocabulary() {
        let event = GitBatch {
            updated_statuses: vec![
                GitStatusEntry {
                    path: "a.rs".to_string(),
                    status: GitFileStatus::Tracked {
                        index_status: GitStatusCode::Modified,
                        worktree_status: GitStatusCode::Unmodified,
                    },
                },
                GitStatusEntry {
                    path: "b.rs".to_string(),
                    status: GitFileStatus::Untracked,
                },
            ],
            removed_paths: vec![],
            branch: Some("main".to_string()),
            head: None,
            ahead_behind: Some((1, 0)),
            conflicts: vec![],
        }
        .into_event("git:/repo".to_string(), 7);
        let json = serde_json::to_value(&event).unwrap();
        assert_eq!(json["ev"], "git_changed");
        assert_eq!(json["seq"], 7);
        assert_eq!(
            json["updated_statuses"][0]["status"]["tracked"]["index_status"],
            "modified"
        );
        assert_eq!(json["updated_statuses"][1]["status"], "untracked");
        assert_eq!(json["ahead_behind"][0], 1);
    }

    // The read tier is tested against a real repository built here, not
    // against captured fixtures: what it must stay compatible with is the git
    // on the box, and a fixture cannot notice that changing.

    fn run_git(dir: &Path, args: &[&str]) -> String {
        let output = std::process::Command::new("git")
            .arg("-C")
            .arg(dir)
            // Hermetic: the developer's own global config must not decide
            // whether these commits can be made.
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .env("GIT_AUTHOR_DATE", "2026-08-18T10:00:00+00:00")
            .env("GIT_COMMITTER_DATE", "2026-08-18T10:00:00+00:00")
            .args(args)
            .output()
            .expect("git is on PATH");
        assert!(
            output.status.success(),
            "git {args:?} failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).trim().to_string()
    }

    fn scratch_repo(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "termiod-git-read-{name}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        run_git(&dir, &["init", "-q", "-b", "main"]);
        run_git(&dir, &["config", "user.email", "test@termio.sh"]);
        run_git(&dir, &["config", "user.name", "termio test"]);
        run_git(&dir, &["config", "commit.gpgsign", "false"]);
        dir
    }

    fn write(dir: &Path, name: &str, body: &str) {
        std::fs::write(dir.join(name), body).unwrap();
    }

    fn commit(dir: &Path, message: &str) -> String {
        run_git(dir, &["add", "-A"]);
        run_git(dir, &["commit", "-q", "-m", message]);
        run_git(dir, &["rev-parse", "HEAD"])
    }

    #[tokio::test]
    async fn log_reads_a_real_repository_newest_first() {
        let dir = scratch_repo("log");
        write(&dir, "a.txt", "one\n");
        let first = commit(&dir, "first commit");
        run_git(&dir, &["tag", "v0.1.0"]);
        write(&dir, "a.txt", "one\ntwo\n");
        let second = commit(&dir, "second commit: subject with spaces");

        let root = dir.to_string_lossy().into_owned();
        let page = run_log(&root, 50, None).await.unwrap();
        assert_eq!(
            page.commits
                .iter()
                .map(|entry| entry.sha.as_str())
                .collect::<Vec<_>>(),
            vec![second.as_str(), first.as_str()],
            "newest first"
        );
        assert!(!page.truncated, "the walk reached the root commit");
        let newest = &page.commits[0];
        assert_eq!(newest.subject, "second commit: subject with spaces");
        assert_eq!(newest.author, "termio test");
        assert_eq!(newest.author_email, "test@termio.sh");
        assert_eq!(newest.short_sha, second[..newest.short_sha.len()]);
        assert!(newest.timestamp > 0, "an instant the client can format");
        assert!(!newest.relative_date.is_empty());
        assert!(newest.tags.is_empty(), "branch decorations are not tags");
        assert_eq!(
            page.commits[1].tags,
            vec!["v0.1.0"],
            "a tag pointing at the commit is kept"
        );

        let page = run_log(&root, 1, None).await.unwrap();
        assert_eq!(page.commits.len(), 1);
        assert!(page.truncated, "the walk stopped at the limit, and says so");

        let ranged = run_log(&root, 50, Some(&format!("{first}..HEAD")))
            .await
            .unwrap();
        assert_eq!(
            ranged
                .commits
                .iter()
                .map(|entry| entry.sha.as_str())
                .collect::<Vec<_>>(),
            vec![second.as_str()],
            "a range narrows the walk — what the Compare tab is composed from"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn log_marks_what_the_upstream_does_not_have() {
        let dir = scratch_repo("unpushed");
        write(&dir, "a.txt", "one\n");
        let first = commit(&dir, "pushed");
        write(&dir, "a.txt", "one\ntwo\n");
        let second = commit(&dir, "not pushed");
        // A remote-tracking ref and a branch upstream, with no network: the
        // upstream is one commit behind. `@{upstream}` resolves through the
        // remote's fetch refspec, so the remote needs one.
        run_git(&dir, &["update-ref", "refs/remotes/origin/main", &first]);
        run_git(&dir, &["config", "remote.origin.url", "/dev/null"]);
        run_git(
            &dir,
            &[
                "config",
                "remote.origin.fetch",
                "+refs/heads/*:refs/remotes/origin/*",
            ],
        );
        run_git(&dir, &["config", "branch.main.remote", "origin"]);
        run_git(&dir, &["config", "branch.main.merge", "refs/heads/main"]);

        let root = dir.to_string_lossy().into_owned();
        let page = run_log(&root, 50, None).await.unwrap();
        let marked: Vec<&str> = page
            .commits
            .iter()
            .filter(|entry| entry.unpushed)
            .map(|entry| entry.sha.as_str())
            .collect();
        assert_eq!(marked, vec![second.as_str()]);

        // Without an upstream the set is empty, not everything.
        run_git(&dir, &["config", "--unset", "branch.main.remote"]);
        run_git(&dir, &["config", "--unset", "branch.main.merge"]);
        let page = run_log(&root, 50, None).await.unwrap();
        assert!(page.commits.iter().all(|entry| !entry.unpushed));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn log_of_a_repository_with_no_commits_is_empty_not_an_error() {
        let dir = scratch_repo("unborn");
        let root = dir.to_string_lossy().into_owned();
        let page = run_log(&root, 50, None).await.unwrap();
        assert!(page.commits.is_empty());
        assert!(!page.truncated);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn show_reads_a_commit_its_files_and_its_diff() {
        let dir = scratch_repo("show");
        write(&dir, "a.txt", "one\n");
        commit(&dir, "first");
        write(&dir, "a.txt", "one\ntwo\n");
        write(&dir, "added.txt", "fresh\n");
        std::fs::write(dir.join("blob.bin"), [0u8, 1, 2, 0, 3]).unwrap();
        let sha = commit(&dir, "second");

        let root = dir.to_string_lossy().into_owned();
        let detail = run_show(&root, &sha, None).await.unwrap();
        assert_eq!(detail.commit.sha, sha);
        assert_eq!(detail.commit.subject, "second");
        assert!(!detail.truncated && !detail.files_truncated);

        let file = |path: &str| {
            detail
                .files
                .iter()
                .find(|file| file.path == path)
                .unwrap_or_else(|| panic!("{path} missing from the commit"))
        };
        assert_eq!(file("a.txt").status, GitStatusCode::Modified);
        assert_eq!(file("a.txt").additions, 1);
        assert_eq!(file("a.txt").deletions, 0);
        assert_eq!(file("added.txt").status, GitStatusCode::Added);
        assert!(file("blob.bin").binary, "counting binary lines would lie");
        assert_eq!(file("blob.bin").additions, 0);
        assert!(detail.diff.contains("+two"));
        assert!(detail.diff.contains("added.txt"));

        let narrowed = run_show(&root, &sha, Some("a.txt")).await.unwrap();
        assert!(narrowed.diff.contains("+two"));
        assert!(
            !narrowed.diff.contains("added.txt"),
            "a path narrows the diff but not the file list"
        );
        assert_eq!(narrowed.files.len(), detail.files.len());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn show_keeps_a_rename_a_rename() {
        let dir = scratch_repo("rename");
        write(&dir, "before.txt", "one\ntwo\nthree\nfour\n");
        commit(&dir, "first");
        run_git(&dir, &["mv", "before.txt", "after.txt"]);
        let sha = commit(&dir, "rename it");

        let root = dir.to_string_lossy().into_owned();
        let detail = run_show(&root, &sha, None).await.unwrap();
        assert_eq!(detail.files.len(), 1);
        assert_eq!(detail.files[0].path, "after.txt");
        assert_eq!(detail.files[0].status, GitStatusCode::Renamed);
        assert_eq!(
            detail.files[0].original_path.as_deref(),
            Some("before.txt")
        );
        assert_eq!(detail.files[0].additions, 0);

        // Asking for the destination alone would make git limit the path
        // before rename detection and re-emit the whole file as additions.
        let narrowed = run_show(&root, &sha, Some("after.txt")).await.unwrap();
        assert!(
            narrowed.diff.contains("rename from before.txt"),
            "the per-file diff of a rename is still a rename: {}",
            narrowed.diff
        );
        assert!(!narrowed.diff.contains("+one"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn branches_report_locals_remotes_the_checkout_and_the_default() {
        let dir = scratch_repo("branches");
        write(&dir, "a.txt", "one\n");
        let first = commit(&dir, "first");
        run_git(&dir, &["branch", "feat/side"]);
        run_git(&dir, &["update-ref", "refs/remotes/origin/main", &first]);
        run_git(
            &dir,
            &[
                "symbolic-ref",
                "refs/remotes/origin/HEAD",
                "refs/remotes/origin/main",
            ],
        );

        let root = dir.to_string_lossy().into_owned();
        let list = run_branches(&root).await.unwrap();
        assert_eq!(list.current.as_deref(), Some("main"));
        assert_eq!(list.default_branch.as_deref(), Some("origin/main"));
        assert!(!list.truncated);
        let locals: Vec<&str> = list
            .branches
            .iter()
            .filter(|branch| !branch.remote)
            .map(|branch| branch.name.as_str())
            .collect();
        let remotes: Vec<&str> = list
            .branches
            .iter()
            .filter(|branch| branch.remote)
            .map(|branch| branch.name.as_str())
            .collect();
        assert_eq!(locals, vec!["feat/side", "main"]);
        assert_eq!(
            remotes,
            vec!["origin/main"],
            "origin/HEAD is a pointer at the default, not a branch"
        );

        run_git(&dir, &["checkout", "-q", "--detach", &first]);
        let detached = run_branches(&root).await.unwrap();
        assert_eq!(
            detached.current, None,
            "a detached HEAD is on no branch, and says so rather than guessing"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_revision_that_would_read_as_an_option_is_refused() {
        let dir = scratch_repo("revision");
        write(&dir, "a.txt", "one\n");
        commit(&dir, "first");
        write(&dir, "a.txt", "one\ntwo\n");
        commit(&dir, "second");
        let root = dir.to_string_lossy().into_owned();

        assert!(run_log(&root, 10, Some("--output=/tmp/pwned")).await.is_err());
        assert!(run_show(&root, "-x", None).await.is_err());
        assert!(
            run_log(&root, 10, Some("HEAD~1..HEAD")).await.is_ok(),
            "an ordinary range still runs"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn commit_records_drop_branch_decorations_and_survive_a_missing_field() {
        let unpushed: HashSet<String> = ["aaaa".to_string()].into_iter().collect();
        let record = |fields: &[&str]| fields.join("\u{1f}");
        let bytes = [
            record(&[
                "aaaa", "aaa", "subject", "Ada", "ada@example.com", "2 hours ago", "1787165226",
                "HEAD -> main, tag: v1.2.3, origin/main, tag: latest",
            ]),
            record(&["bbbb", "bbb", "too", "few", "fields"]),
            record(&[
                "cccc", "ccc", "plain", "Ada", "ada@example.com", "3 days ago", "1787165000", "",
            ]),
        ]
        .join("\0");

        let commits = parse_commits(bytes.as_bytes(), &unpushed);
        assert_eq!(commits.len(), 2, "a malformed record is dropped, not guessed");
        assert_eq!(commits[0].tags, vec!["v1.2.3", "latest"]);
        assert_eq!(commits[0].timestamp, 1787165226);
        assert!(commits[0].unpushed);
        assert!(commits[1].tags.is_empty());
        assert!(!commits[1].unpushed);
    }

    #[test]
    fn a_commit_over_the_file_cap_is_cut_and_flagged() {
        let mut records = vec![format!(
            "{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}",
            "aaaa", "aaa", "wide", "Ada", "ada@example.com", "now", "1", ""
        )];
        for index in 0..(SHOW_FILE_CAP + 5) {
            records.push(":100644 100644 aaa bbb M".to_string());
            records.push(format!("file{index}.rs"));
        }
        let (_, files, truncated) = parse_commit_detail(records.join("\0").as_bytes()).unwrap();
        assert_eq!(files.len(), SHOW_FILE_CAP);
        assert!(truncated, "the list is cut at the cap and says so");
    }

    #[test]
    fn refs_over_the_cap_are_cut_and_flagged() {
        let mut lines = String::new();
        for index in 0..(BRANCH_CAP + 3) {
            lines.push_str(&format!("  refs/heads/branch-{index} \n"));
        }
        let list = parse_refs(&lines);
        assert_eq!(list.branches.len(), BRANCH_CAP);
        assert!(list.truncated);
        assert_eq!(list.current, None);
    }
}
