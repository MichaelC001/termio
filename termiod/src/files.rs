//! The file request plane (§C.12): the **pull side** of the resource story.
//!
//! §C.10's `fs:` resources push change notification; this module answers the
//! reads — directory listings and file content. The posture is lazy + cached
//! + predictive, never a client replica: attach costs one listing, and
//! freshness is proven by the `fs:` resource cursor stamped on every reply
//! rather than guessed by TTL.
//!
//! Everything here is plain blocking filesystem code. The daemon calls it via
//! `spawn_blocking`, so a huge directory never parks other connections — and
//! nothing here can touch the terminal hot path by construction, because it
//! only ever runs on control channels.

use crate::protocol::{DirEntry, EntryKind, PathListing};
use anyhow::{anyhow, bail, Context, Result};
use std::path::{Component, Path, PathBuf};

/// Entries per `fs.list` page (§C.12: "pages capped (~2,000 entries)").
pub const LIST_PAGE_SIZE: usize = 2000;

/// `fs.read` soft cap: preview parity with the companion's 1 MiB budget.
pub const READ_SOFT_CAP: u64 = 1024 * 1024;

/// Directory names the host never walks on its own. These are the watcher's
/// ignore rules (`resource.rs::classify`) seen from the pull side: what the
/// watcher drops, the lister stubs as `unloaded_dir`.
fn is_unloaded_dir_name(name: &str) -> bool {
    name == ".git" || name == ".hg" || name == ".svn"
}

/// Canonicalise a workspace root. The root anchors confinement for every
/// path in the request, so it must resolve and be a directory.
pub fn canonical_root(root: &str) -> Result<PathBuf> {
    let path = Path::new(root);
    if !path.is_absolute() {
        bail!("workspace root must be absolute: {root}");
    }
    let canonical =
        std::fs::canonicalize(path).with_context(|| format!("resolving workspace root {root}"))?;
    if !canonical.is_dir() {
        bail!("workspace root is not a directory: {root}");
    }
    Ok(canonical)
}

/// Resolve one requested path against the canonical root and confine it:
/// no `..` components, and the canonicalised result must stay under the
/// root (which also rejects symlink escapes, because canonicalising
/// resolves the links first).
fn confine(root: &Path, requested: &str) -> Result<PathBuf> {
    let raw = Path::new(requested);
    if raw
        .components()
        .any(|component| matches!(component, Component::ParentDir))
    {
        bail!("path escapes the workspace root: {requested}");
    }
    let joined = if raw.is_absolute() {
        raw.to_path_buf()
    } else {
        root.join(raw)
    };
    let canonical =
        std::fs::canonicalize(&joined).with_context(|| format!("resolving {requested}"))?;
    if !canonical.starts_with(root) {
        bail!("path escapes the workspace root: {requested}");
    }
    Ok(canonical)
}

/// List a batch of directories under `root`, one page per path.
pub fn list(root: &str, paths: &[String], page: Option<u64>) -> Result<Vec<PathListing>> {
    list_with_page_size(root, paths, page, LIST_PAGE_SIZE)
}

fn list_with_page_size(
    root: &str,
    paths: &[String],
    page: Option<u64>,
    page_size: usize,
) -> Result<Vec<PathListing>> {
    let root = canonical_root(root)?;
    // A batched, speculative request must not be all-or-nothing: one child
    // that vanished between render and click fails alone.
    Ok(paths
        .iter()
        .map(|requested| match list_one(&root, requested, page, page_size) {
            Ok(listing) => listing,
            Err(error) => PathListing {
                path: requested.clone(),
                entries: Vec::new(),
                next_page: None,
                error: Some(format!("{error:#}")),
            },
        })
        .collect())
}

fn list_one(
    root: &Path,
    requested: &str,
    page: Option<u64>,
    page_size: usize,
) -> Result<PathListing> {
    let dir = confine(root, requested)?;
    if !dir.is_dir() {
        bail!("not a directory: {requested}");
    }

    let mut entries: Vec<DirEntry> = Vec::new();
    for item in std::fs::read_dir(&dir).with_context(|| format!("listing {requested}"))? {
        let item = match item {
            Ok(item) => item,
            Err(_) => continue,
        };
        let name = item.file_name().to_string_lossy().into_owned();
        // lstat, not stat: a symlink is reported as itself, never followed —
        // following is how a listing walks out of the workspace.
        let Ok(metadata) = std::fs::symlink_metadata(item.path()) else {
            continue;
        };
        let mtime = metadata
            .modified()
            .ok()
            .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|duration| duration.as_secs())
            .unwrap_or(0);
        let (kind, symlink_target) = if metadata.file_type().is_symlink() {
            let target = std::fs::read_link(item.path())
                .ok()
                .map(|target| target.display().to_string());
            (EntryKind::Symlink, target)
        } else if metadata.is_dir() {
            if is_unloaded_dir_name(&name) {
                (EntryKind::UnloadedDir, None)
            } else {
                (EntryKind::Dir, None)
            }
        } else {
            (EntryKind::File, None)
        };
        entries.push(DirEntry {
            name,
            kind,
            size: metadata.len(),
            mtime,
            symlink_target,
        });
    }

    // A stable order is what makes pages meaningful across two requests.
    entries.sort_by(|a, b| a.name.cmp(&b.name));

    let page = usize::try_from(page.unwrap_or(0)).unwrap_or(usize::MAX);
    let start = page.saturating_mul(page_size).min(entries.len());
    let end = start.saturating_add(page_size).min(entries.len());
    let next_page = if end < entries.len() {
        Some(page as u64 + 1)
    } else {
        None
    };
    Ok(PathListing {
        path: requested.to_string(),
        entries: entries[start..end].to_vec(),
        next_page,
        error: None,
    })
}

/// A served `fs.read` window: the header fields plus the bytes themselves.
pub struct FileWindow {
    pub size: u64,
    pub offset: u64,
    pub truncated: bool,
    pub data: Vec<u8>,
}

/// Read a window of a regular file, applying the 1 MiB soft cap. `truncated`
/// is set exactly when the served window stops short of what was asked —
/// the whole file when no range was given, the requested length otherwise.
pub fn read(path: &str, offset: Option<u64>, length: Option<u64>) -> Result<FileWindow> {
    read_with_cap(path, offset, length, READ_SOFT_CAP)
}

fn read_with_cap(
    path: &str,
    offset: Option<u64>,
    length: Option<u64>,
    cap: u64,
) -> Result<FileWindow> {
    let raw = Path::new(path);
    if !raw.is_absolute() {
        bail!("file path must be absolute: {path}");
    }
    let canonical = std::fs::canonicalize(raw).with_context(|| format!("resolving {path}"))?;
    let metadata =
        std::fs::metadata(&canonical).with_context(|| format!("inspecting {path}"))?;
    if !metadata.is_file() {
        bail!("not a regular file: {path}");
    }
    let size = metadata.len();
    let start = offset.unwrap_or(0).min(size);
    let asked = length.unwrap_or(u64::MAX).min(size - start);
    let serve = asked.min(cap);

    use std::io::{Read, Seek, SeekFrom};
    let mut file =
        std::fs::File::open(&canonical).with_context(|| format!("opening {path}"))?;
    file.seek(SeekFrom::Start(start))
        .with_context(|| format!("seeking {path}"))?;
    let mut data = vec![
        0u8;
        usize::try_from(serve).map_err(|_| anyhow!("read window exceeds memory"))?
    ];
    file.read_exact(&mut data)
        .with_context(|| format!("reading {path}"))?;

    Ok(FileWindow {
        size,
        offset: start,
        truncated: serve < asked,
        data,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("termiod-files-test-{name}-{}", unsafe {
            libc::getpid()
        }));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn touch(path: &Path, bytes: &[u8]) {
        let mut file = std::fs::File::create(path).unwrap();
        file.write_all(bytes).unwrap();
    }

    #[test]
    fn listing_reports_kinds_sorts_names_and_stubs_vcs_dirs() {
        let root = scratch("kinds");
        std::fs::create_dir(root.join("src")).unwrap();
        std::fs::create_dir(root.join(".git")).unwrap();
        touch(&root.join(".git").join("config"), b"[core]");
        touch(&root.join("b.txt"), b"bb");
        touch(&root.join("a.txt"), b"a");
        std::os::unix::fs::symlink("/etc", root.join("link")).unwrap();

        let listings = list(root.to_str().unwrap(), &[".".to_string()], None).unwrap();
        let entries = &listings[0].entries;
        let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec![".git", "a.txt", "b.txt", "link", "src"]);
        assert_eq!(entries[0].kind, EntryKind::UnloadedDir);
        assert_eq!(entries[1].kind, EntryKind::File);
        assert_eq!(entries[1].size, 1);
        assert_eq!(entries[3].kind, EntryKind::Symlink);
        assert_eq!(entries[3].symlink_target.as_deref(), Some("/etc"));
        assert_eq!(entries[4].kind, EntryKind::Dir);

        // A VCS dir is a stub in its parent, but an explicit list request for
        // it still answers — "never walked until explicitly listed".
        let explicit = list(root.to_str().unwrap(), &[".git".to_string()], None).unwrap();
        assert!(explicit[0].error.is_none());
        assert_eq!(explicit[0].entries[0].name, "config");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn pages_are_stable_and_chain_through_next_page() {
        let root = scratch("pages");
        for index in 0..7 {
            touch(&root.join(format!("f{index}")), b"x");
        }
        let root_str = root.to_str().unwrap();
        let paths = [".".to_string()];
        let first = list_with_page_size(root_str, &paths, None, 3).unwrap();
        assert_eq!(first[0].entries.len(), 3);
        assert_eq!(first[0].next_page, Some(1));
        let second = list_with_page_size(root_str, &paths, first[0].next_page, 3).unwrap();
        assert_eq!(second[0].entries.len(), 3);
        assert_eq!(second[0].next_page, Some(2));
        let last = list_with_page_size(root_str, &paths, second[0].next_page, 3).unwrap();
        assert_eq!(last[0].entries.len(), 1);
        assert_eq!(last[0].next_page, None);

        let mut seen: Vec<String> = [&first, &second, &last]
            .iter()
            .flat_map(|page| page[0].entries.iter().map(|e| e.name.clone()))
            .collect();
        seen.dedup();
        assert_eq!(seen.len(), 7, "pages must partition, not overlap");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn escapes_fail_alone_without_sinking_the_batch() {
        let root = scratch("confine");
        std::fs::create_dir(root.join("inside")).unwrap();
        std::os::unix::fs::symlink("/", root.join("out")).unwrap();

        let listings = list(
            root.to_str().unwrap(),
            &[
                "inside".to_string(),
                "../".to_string(),
                "out".to_string(),
                "/etc".to_string(),
            ],
            None,
        )
        .unwrap();
        assert!(listings[0].error.is_none());
        assert!(listings[1].error.is_some(), "dotdot must be rejected");
        assert!(
            listings[2].error.is_some(),
            "a symlink pointing out of the root must be rejected"
        );
        assert!(
            listings[3].error.is_some(),
            "an absolute path outside the root must be rejected"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn reads_window_and_honor_the_soft_cap() {
        let root = scratch("reads");
        let path = root.join("blob");
        touch(&path, b"0123456789");
        let path = path.to_str().unwrap().to_string();

        let whole = read_with_cap(&path, None, None, 1024).unwrap();
        assert_eq!(whole.data, b"0123456789");
        assert!(!whole.truncated);
        assert_eq!(whole.size, 10);

        let window = read_with_cap(&path, Some(2), Some(3), 1024).unwrap();
        assert_eq!(window.data, b"234");
        assert_eq!(window.offset, 2);
        assert!(!window.truncated);

        let capped = read_with_cap(&path, None, None, 4).unwrap();
        assert_eq!(capped.data, b"0123");
        assert!(capped.truncated, "cap short of the file must say so");

        let ranged_cap = read_with_cap(&path, Some(1), Some(9), 4).unwrap();
        assert_eq!(ranged_cap.data, b"1234");
        assert!(ranged_cap.truncated);

        let past_end = read_with_cap(&path, Some(50), None, 4).unwrap();
        assert!(past_end.data.is_empty());
        assert!(!past_end.truncated, "beyond EOF serves empty, not an error");

        assert!(read_with_cap(root.to_str().unwrap(), None, None, 4).is_err());
        let _ = std::fs::remove_dir_all(&root);
    }
}
