//! The host's view (`docs/design/20261025-termiod-owns-the-view.md`): which
//! projects exist on this machine, and how its sessions are arranged into
//! groups of panes.
//!
//! The view is the one place that answers "where does this session belong?".
//! Clients draw it and keep only their own viewport, so a session started from
//! a shell on this box lands in the same project row on every screen without
//! any client guessing from its cwd.
//!
//! Every change raises `revision` by one. The `view:host` resource (§C.10)
//! publishes the whole view at that revision, so a client replaces its copy and
//! never merges. Layout is control-plane state: nothing here runs on the byte
//! path.

use crate::resource::Registry;
use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// The file the view is kept in, inside the durable state directory.
const VIEW_FILE: &str = "view.json";

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct View {
    pub revision: u64,
    #[serde(default)]
    pub projects: Vec<Project>,
    /// Groups that belong to no project: the terminals a client lists apart
    /// from any repository.
    #[serde(default)]
    pub loose: Vec<Group>,
}

/// A directory registered on this host.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Project {
    pub id: String,
    /// Canonical absolute path. Two spellings of one directory are one project.
    pub path: String,
    pub label: String,
    #[serde(default, skip_serializing_if = "is_false")]
    pub pinned: bool,
    #[serde(default)]
    pub groups: Vec<Group>,
}

/// An arranged set of panes.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Group {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    pub root: Node,
    /// The pane that receives typing. Always a pane of this group.
    pub focused: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub zoomed: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Node {
    Split(Split),
    Pane(Pane),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Split {
    pub direction: Direction,
    /// The share of the split that `before` takes, between 0 and 1.
    pub ratio: f64,
    pub before: Box<Node>,
    pub after: Box<Node>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Direction {
    Right,
    Down,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Pane {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(flatten)]
    pub kind: PaneKind,
}

/// What a pane is. Its state names the thing it shows; what that thing
/// contains is read by the client when it draws, never stored here.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PaneKind {
    /// A session's terminal. The pane outlives the process when it exits on
    /// its own, so a client can still say why it ended.
    Terminal { session: String },
}

/// Where `create` puts a new session's pane.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Place {
    /// A project id. Without it, the project whose path holds the cwd.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
}

fn is_false(value: &bool) -> bool {
    !*value
}

impl Node {
    fn panes<'a>(&'a self, out: &mut Vec<&'a Pane>) {
        match self {
            Node::Pane(pane) => out.push(pane),
            Node::Split(split) => {
                split.before.panes(out);
                split.after.panes(out);
            }
        }
    }

    /// The tree with the pane showing `session` removed, its sibling taking
    /// the split's place. `None` when the removed pane was the whole tree.
    fn without_session(self, session: &str) -> Option<Node> {
        match self {
            Node::Pane(pane) if pane.shows(session) => None,
            Node::Pane(pane) => Some(Node::Pane(pane)),
            Node::Split(split) => {
                let before = split.before.without_session(session);
                let after = split.after.without_session(session);
                match (before, after) {
                    (Some(before), Some(after)) => Some(Node::Split(Split {
                        direction: split.direction,
                        ratio: split.ratio,
                        before: Box::new(before),
                        after: Box::new(after),
                    })),
                    (Some(only), None) | (None, Some(only)) => Some(only),
                    (None, None) => None,
                }
            }
        }
    }
}

impl Pane {
    fn shows(&self, session: &str) -> bool {
        matches!(&self.kind, PaneKind::Terminal { session: shown } if shown == session)
    }
}

impl Project {
    /// Every session a terminal pane in this project shows.
    pub fn sessions(&self) -> Vec<String> {
        self.groups
            .iter()
            .flat_map(|group| group.panes())
            .filter_map(|pane| match &pane.kind {
                PaneKind::Terminal { session } => Some(session.clone()),
            })
            .collect()
    }
}

impl Group {
    pub fn panes(&self) -> Vec<&Pane> {
        let mut out = Vec::new();
        self.root.panes(&mut out);
        out
    }

    /// The group without `session`'s pane, or `None` when that was its last
    /// pane. Focus and zoom move off a removed pane.
    fn without_session(self, session: &str) -> Option<Group> {
        let root = self.root.without_session(session)?;
        let mut group = Group { root, ..self };
        let remaining: Vec<String> = group.panes().iter().map(|pane| pane.id.clone()).collect();
        if !remaining.contains(&group.focused) {
            group.focused = remaining.first().cloned().unwrap_or_default();
        }
        if group
            .zoomed
            .as_ref()
            .is_some_and(|zoomed| !remaining.contains(zoomed))
        {
            group.zoomed = None;
        }
        Some(group)
    }
}

impl View {
    fn groups(&self) -> impl Iterator<Item = &Group> {
        self.projects
            .iter()
            .flat_map(|project| project.groups.iter())
            .chain(self.loose.iter())
    }

    /// Every session a terminal pane shows.
    pub fn sessions(&self) -> Vec<String> {
        self.groups()
            .flat_map(|group| group.panes())
            .filter_map(|pane| match &pane.kind {
                PaneKind::Terminal { session } => Some(session.clone()),
            })
            .collect()
    }

    /// The session the terminal pane `pane` shows.
    pub fn session_of(&self, pane: &str) -> Option<String> {
        self.groups()
            .flat_map(|group| group.panes())
            .find(|shown| shown.id == pane)
            .map(|shown| match &shown.kind {
                PaneKind::Terminal { session } => session.clone(),
            })
    }

    fn has_id(&self, id: &str) -> bool {
        self.projects.iter().any(|project| project.id == id)
            || self
                .groups()
                .any(|group| group.id == id || group.panes().iter().any(|pane| pane.id == id))
    }

    fn fresh_id(&self, prefix: &str) -> String {
        loop {
            let mut hasher = RandomState::new().build_hasher();
            hasher.write_u64(self.revision);
            let id = format!("{prefix}:{:012x}", hasher.finish() & 0xffff_ffff_ffff);
            if !self.has_id(&id) {
                return id;
            }
        }
    }

    /// Register `path`, which the caller has already canonicalised. Returns the
    /// project's id and whether the view changed: registering a directory that
    /// is already a project returns that project.
    pub fn add_project(&mut self, path: &str, label: Option<&str>) -> (String, bool) {
        if let Some(existing) = self.projects.iter().find(|project| project.path == path) {
            return (existing.id.clone(), false);
        }
        let id = self.fresh_id("project");
        let label = label
            .map(str::to_string)
            .or_else(|| {
                Path::new(path)
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
            })
            .unwrap_or_else(|| path.to_string());
        self.projects.push(Project {
            id: id.clone(),
            path: path.to_string(),
            label,
            pinned: false,
            groups: Vec::new(),
        });
        (id, true)
    }

    /// Remove a project row. Returns the sessions its panes showed, which the
    /// caller ends: removing a project closes its sessions, as Remove Project
    /// does.
    pub fn remove_project(&mut self, id: &str) -> Result<Vec<String>> {
        let index = self
            .projects
            .iter()
            .position(|project| project.id == id)
            .ok_or_else(|| anyhow!("no such project: {id}"))?;
        let project = self.projects.remove(index);
        let view = View {
            revision: 0,
            projects: vec![project],
            loose: Vec::new(),
        };
        Ok(view.sessions())
    }

    /// The project a session in `cwd` belongs to: the deepest registered path
    /// that contains it, by whole path components.
    fn project_for(&self, cwd: &str) -> Option<usize> {
        let cwd = Path::new(cwd);
        self.projects
            .iter()
            .enumerate()
            .filter(|(_, project)| cwd.starts_with(&project.path))
            .max_by_key(|(_, project)| project.path.len())
            .map(|(index, _)| index)
    }

    /// Give `session` a pane in a new group of its own and return the pane's
    /// id. `place.project` picks the project; without it, the project whose
    /// path holds `cwd`, else no project.
    pub fn place_terminal(&mut self, session: &str, cwd: &str, place: &Place) -> Result<String> {
        let project = match &place.project {
            Some(id) => Some(
                self.projects
                    .iter()
                    .position(|project| &project.id == id)
                    .ok_or_else(|| anyhow!("no such project: {id}"))?,
            ),
            None => self.project_for(cwd),
        };
        let pane = self.fresh_id("pane");
        let group = Group {
            id: self.fresh_id("group"),
            label: None,
            root: Node::Pane(Pane {
                id: pane.clone(),
                label: None,
                kind: PaneKind::Terminal {
                    session: session.to_string(),
                },
            }),
            focused: pane.clone(),
            zoomed: None,
        };
        match project {
            Some(index) => self.projects[index].groups.push(group),
            None => self.loose.push(group),
        }
        Ok(pane)
    }

    /// Remove the pane that shows `session`. Returns whether there was one.
    pub fn remove_session(&mut self, session: &str) -> bool {
        if !self.sessions().iter().any(|shown| shown == session) {
            return false;
        }
        for project in &mut self.projects {
            project.groups = std::mem::take(&mut project.groups)
                .into_iter()
                .filter_map(|group| group.without_session(session))
                .collect();
        }
        self.loose = std::mem::take(&mut self.loose)
            .into_iter()
            .filter_map(|group| group.without_session(session))
            .collect();
        true
    }

    /// Give every live session that has no pane a group of its own. This is
    /// how sessions that predate the view, or that crossed a handoff from a
    /// daemon without one, enter it. Each live session is `(id, cwd)`.
    pub fn place_unplaced(&mut self, live: &[(String, String)]) -> bool {
        let shown = self.sessions();
        let mut changed = false;
        for (session, cwd) in live {
            if shown.contains(session) {
                continue;
            }
            // Cannot fail: no project is named.
            if self.place_terminal(session, cwd, &Place::default()).is_ok() {
                changed = true;
            }
        }
        changed
    }
}

/// The host's view and the file it is kept in.
///
/// A change is made on a copy and installed only if it succeeds, so a failed
/// mutation leaves the view as it was. The resource is published while the
/// view lock is held: two changes can never reach subscribers out of order.
pub struct ViewStore {
    view: Mutex<View>,
    /// Set while a handoff carries the view. A change after the snapshot
    /// would be lost, and the new image would issue its revision again.
    frozen: std::sync::atomic::AtomicBool,
    file: Option<PathBuf>,
    registry: Registry,
}

impl ViewStore {
    /// Load the view from `dir`, or start an empty one. A file that cannot be
    /// read is moved aside and reported, never silently replaced; one that
    /// cannot even be moved is left alone and this daemon keeps the view in
    /// memory only, which a handoff carries on.
    ///
    /// `carried` is the view a handoff brought across. It is the same view
    /// the old image held, so it keeps its revision and every client cursor
    /// stays exact; it is saved at once, which also catches up a write the
    /// old image failed.
    ///
    /// Without it the revision restarts at no less than the current time in
    /// milliseconds. A client's cursor names a revision, and a restarted daemon
    /// may have lost the file or a write that failed, so counting on from the
    /// file could hand out a revision a client already holds for a different
    /// view. A floor above every revision an earlier run issued makes such a
    /// cursor stale, and a stale cursor is a gap that is served the whole view.
    pub fn open(dir: Option<&Path>, registry: Registry, carried: Option<View>) -> ViewStore {
        let (saved, file) = match dir.map(|dir| dir.join(VIEW_FILE)) {
            Some(file) => match load(&file) {
                Some(view) => (view, Some(file)),
                None => (View::default(), None),
            },
            None => (View::default(), None),
        };
        let view = match carried {
            Some(view) => {
                if let Some(file) = &file {
                    if let Err(error) = crate::tombstone::write_json(file, &view) {
                        eprintln!(
                            "termiod: the view was not saved to {}: {error:#}",
                            file.display()
                        );
                    }
                }
                view
            }
            None => View {
                revision: saved.revision.max(revision_floor()),
                ..saved
            },
        };
        registry.install_view(view.clone());
        ViewStore {
            view: Mutex::new(view),
            frozen: std::sync::atomic::AtomicBool::new(false),
            file,
            registry,
        }
    }

    pub fn snapshot(&self) -> View {
        self.view.lock().unwrap().clone()
    }

    /// The view a handoff carries. Every change after it is refused with
    /// [`Frozen`] until [`ViewStore::thaw`], which an aborted handoff calls.
    pub fn freeze(&self) -> View {
        let guard = self.view.lock().unwrap();
        self.frozen.store(true, std::sync::atomic::Ordering::SeqCst);
        guard.clone()
    }

    pub fn is_frozen(&self) -> bool {
        self.frozen.load(std::sync::atomic::Ordering::SeqCst)
    }

    pub fn thaw(&self) {
        self.frozen
            .store(false, std::sync::atomic::Ordering::SeqCst);
    }

    /// Apply `change` to the view. `change` returns its result and whether it
    /// changed anything; an unchanged view keeps its revision and publishes
    /// nothing. Returns the result and the revision after the call.
    pub fn change<T>(
        &self,
        change: impl FnOnce(&mut View) -> Result<(T, bool)>,
    ) -> Result<(T, u64)> {
        let mut guard = self.view.lock().unwrap();
        if self.frozen.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(Frozen.into());
        }
        let mut next = guard.clone();
        let (result, changed) = change(&mut next)?;
        if !changed {
            return Ok((result, guard.revision));
        }
        next.revision = guard.revision + 1;
        if let Some(file) = &self.file {
            // The view in memory stays authoritative for this daemon's life;
            // a write that fails costs only the next restart's copy.
            if let Err(error) = crate::tombstone::write_json(file, &next) {
                eprintln!(
                    "termiod: the view was not saved to {}: {error:#}",
                    file.display()
                );
            }
        }
        let revision = next.revision;
        *guard = next.clone();
        self.registry.publish_view(next);
        Ok((result, revision))
    }
}

/// A view change refused because a handoff is carrying the view.
#[derive(Debug)]
pub struct Frozen;

impl std::fmt::Display for Frozen {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("the view is being handed to a new daemon; reconnect and ask again")
    }
}

impl std::error::Error for Frozen {}

fn revision_floor() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as u64)
        .unwrap_or(0)
}

/// The saved view, an empty one, or `None` when the file must not be written:
/// it holds something that could not be read and could not be moved aside.
fn load(file: &Path) -> Option<View> {
    let problem = match std::fs::read_to_string(file) {
        Ok(text) => match serde_json::from_str(&text) {
            Ok(view) => return Some(view),
            Err(error) => format!("did not parse ({error})"),
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Some(View::default()),
        Err(error) => format!("could not be read ({error})"),
    };
    // Named by the time, so a fault that recurs on every start never moves a
    // later, emptier file over the copy an earlier start set aside.
    let aside = file.with_extension(format!("json.unreadable-{}", revision_floor()));
    match std::fs::rename(file, &aside) {
        Ok(()) => {
            eprintln!(
                "termiod: the view at {} {problem}; moved to {} and starting empty",
                file.display(),
                aside.display()
            );
            Some(View::default())
        }
        Err(error) => {
            eprintln!(
                "termiod: the view at {} {problem} and could not be moved aside ({error}); \
                 this daemon will not save the view",
                file.display()
            );
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn terminal(view: &View, session: &str) -> Option<String> {
        view.groups()
            .flat_map(|group| group.panes())
            .find(|pane| pane.shows(session))
            .map(|pane| pane.id.clone())
    }

    #[test]
    fn registering_a_directory_twice_returns_the_same_project() {
        let mut view = View::default();
        let (first, changed) = view.add_project("/work/termio", None);
        assert!(changed);
        let (second, changed) = view.add_project("/work/termio", Some("other"));
        assert!(!changed);
        assert_eq!(first, second);
        assert_eq!(view.projects.len(), 1);
        assert_eq!(view.projects[0].label, "termio");
    }

    #[test]
    fn a_session_lands_in_the_deepest_project_that_holds_its_cwd() {
        let mut view = View::default();
        let (outer, _) = view.add_project("/work", None);
        let (inner, _) = view.add_project("/work/termio", None);
        view.place_terminal("a", "/work/termio/src", &Place::default())
            .unwrap();
        view.place_terminal("b", "/work/other", &Place::default())
            .unwrap();
        view.place_terminal("c", "/tmp", &Place::default()).unwrap();
        let project = |id: &str| view.projects.iter().find(|p| p.id == id).unwrap();
        assert_eq!(project(&inner).groups.len(), 1);
        assert_eq!(project(&outer).groups.len(), 1);
        assert_eq!(view.loose.len(), 1);
    }

    #[test]
    fn a_path_prefix_is_not_a_parent_directory() {
        let mut view = View::default();
        view.add_project("/work/termio", None);
        view.place_terminal("a", "/work/termio-worktrees/x", &Place::default())
            .unwrap();
        assert_eq!(view.loose.len(), 1);
    }

    #[test]
    fn an_unknown_project_is_refused() {
        let mut view = View::default();
        let place = Place {
            project: Some("project:missing".to_string()),
        };
        assert!(view.place_terminal("a", "/work", &place).is_err());
    }

    #[test]
    fn removing_a_pane_collapses_its_split_and_moves_focus() {
        let mut view = View::default();
        let first = view.place_terminal("a", "/tmp", &Place::default()).unwrap();
        view.place_terminal("b", "/tmp", &Place::default()).unwrap();
        // Join the two into one split by hand; phase 2 adds the op that does this.
        let second_group = view.loose.pop().unwrap();
        let group = &mut view.loose[0];
        let first_pane = std::mem::replace(
            &mut group.root,
            Node::Pane(Pane {
                id: String::new(),
                label: None,
                kind: PaneKind::Terminal {
                    session: String::new(),
                },
            }),
        );
        group.root = Node::Split(Split {
            direction: Direction::Right,
            ratio: 0.5,
            before: Box::new(first_pane),
            after: Box::new(second_group.root),
        });
        group.zoomed = Some(first.clone());

        assert!(view.remove_session("a"));
        let group = &view.loose[0];
        assert!(matches!(group.root, Node::Pane(_)));
        assert_eq!(Some(group.focused.clone()), terminal(&view, "b"));
        assert_eq!(group.zoomed, None);
    }

    #[test]
    fn removing_the_last_pane_removes_the_group() {
        let mut view = View::default();
        view.add_project("/work", None);
        view.place_terminal("a", "/work", &Place::default())
            .unwrap();
        assert!(view.remove_session("a"));
        assert!(view.projects[0].groups.is_empty());
        assert!(!view.remove_session("a"));
    }

    #[test]
    fn removing_a_project_returns_its_sessions() {
        let mut view = View::default();
        let (id, _) = view.add_project("/work", None);
        view.place_terminal("a", "/work", &Place::default())
            .unwrap();
        view.place_terminal("b", "/tmp", &Place::default()).unwrap();
        assert_eq!(view.remove_project(&id).unwrap(), vec!["a".to_string()]);
        assert_eq!(view.sessions(), vec!["b".to_string()]);
    }

    #[test]
    fn only_unplaced_sessions_are_placed() {
        let mut view = View::default();
        view.place_terminal("a", "/tmp", &Place::default()).unwrap();
        let live = vec![
            ("a".to_string(), "/tmp".to_string()),
            ("b".to_string(), "/tmp".to_string()),
        ];
        assert!(view.place_unplaced(&live));
        assert!(!view.place_unplaced(&live));
        assert_eq!(view.loose.len(), 2);
    }

    #[test]
    fn the_wire_shape_round_trips() {
        let mut view = View::default();
        view.add_project("/work", None);
        view.place_terminal("a", "/work", &Place::default())
            .unwrap();
        let text = serde_json::to_string(&view).unwrap();
        assert!(text.contains(r#""kind":"terminal""#), "{text}");
        assert!(text.contains(r#""pane":{"#), "{text}");
        assert_eq!(serde_json::from_str::<View>(&text).unwrap(), view);
    }

    #[test]
    fn a_change_bumps_the_revision_and_persists() {
        let dir = std::env::temp_dir().join(format!("termiod-view-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let store = ViewStore::open(Some(&dir), Registry::new(), None);
        let start = store.snapshot().revision;
        let ((), revision) = store
            .change(|view| Ok(((), view.add_project("/work", None).1)))
            .unwrap();
        assert_eq!(revision, start + 1);
        let ((), revision) = store
            .change(|view| Ok(((), view.add_project("/work", None).1)))
            .unwrap();
        assert_eq!(revision, start + 1, "an unchanged view keeps its revision");
        assert!(store
            .change(|_| -> Result<((), bool)> { Err(anyhow!("refused")) })
            .is_err());

        let reopened = ViewStore::open(Some(&dir), Registry::new(), None);
        assert_eq!(reopened.snapshot().projects, store.snapshot().projects);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_restart_never_reissues_a_revision_a_client_may_hold() {
        let dir = std::env::temp_dir().join(format!("termiod-view-floor-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // A view saved at a low revision: a lost file or a failed write leaves
        // the daemon behind revisions its clients already saw.
        std::fs::write(
            dir.join(VIEW_FILE),
            r#"{"revision":5,"projects":[],"loose":[]}"#,
        )
        .unwrap();
        let store = ViewStore::open(Some(&dir), Registry::new(), None);
        assert!(store.snapshot().revision >= revision_floor() - 60_000);

        // A saved revision above the clock (the clock went back) still counts on.
        let ahead = revision_floor() + 1_000_000;
        std::fs::write(
            dir.join(VIEW_FILE),
            format!(r#"{{"revision":{ahead},"projects":[],"loose":[]}}"#),
        )
        .unwrap();
        assert_eq!(
            ViewStore::open(Some(&dir), Registry::new(), None)
                .snapshot()
                .revision,
            ahead
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_unparseable_file_is_moved_aside() {
        let dir = std::env::temp_dir().join(format!("termiod-view-bad-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(VIEW_FILE), "{not json").unwrap();
        let store = ViewStore::open(Some(&dir), Registry::new(), None);
        assert_eq!(store.snapshot().projects, Vec::new());
        assert!(std::fs::read_dir(&dir).unwrap().any(|entry| entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with("view.json.unreadable-")));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_file_that_cannot_be_read_is_never_overwritten() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("termiod-view-locked-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join(VIEW_FILE);
        let saved = r#"{"revision":4,"projects":[],"loose":[]}"#;
        std::fs::write(&file, saved).unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o000)).unwrap();

        // Readable once moved aside: the good copy survives under a new name,
        // and the same fault on the next start never moves the newer, emptier
        // file over it.
        let asides = |dir: &Path| -> Vec<PathBuf> {
            let mut found: Vec<PathBuf> = std::fs::read_dir(dir)
                .unwrap()
                .map(|entry| entry.unwrap().path())
                .filter(|path| path.to_string_lossy().contains(".unreadable-"))
                .collect();
            found.sort();
            found
        };
        let store = ViewStore::open(Some(&dir), Registry::new(), None);
        store
            .change(|view| Ok(((), view.add_project("/work", None).1)))
            .unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o000)).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(2));
        let _store = ViewStore::open(Some(&dir), Registry::new(), None);
        let found = asides(&dir);
        assert_eq!(found.len(), 2, "{found:?}");
        std::fs::set_permissions(&found[0], std::fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(std::fs::read_to_string(&found[0]).unwrap(), saved);
        let aside = found[0].clone();

        // Not even movable: the daemon keeps the view in memory and writes nothing.
        std::fs::rename(&aside, &file).unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o000)).unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o500)).unwrap();
        let store = ViewStore::open(Some(&dir), Registry::new(), None);
        store
            .change(|view| Ok(((), view.add_project("/work", None).1)))
            .unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(std::fs::read_to_string(&file).unwrap(), saved);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_carried_view_keeps_its_revision_and_is_saved() {
        let dir = std::env::temp_dir().join(format!("termiod-view-carried-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // The file lags the carried view: the old image's last write failed.
        std::fs::write(
            dir.join(VIEW_FILE),
            r#"{"revision":5,"projects":[],"loose":[]}"#,
        )
        .unwrap();
        let mut carried = View::default();
        carried.add_project("/work", None);
        carried.revision = 9;
        let store = ViewStore::open(Some(&dir), Registry::new(), Some(carried.clone()));
        assert_eq!(store.snapshot(), carried);
        let saved: View =
            serde_json::from_str(&std::fs::read_to_string(dir.join(VIEW_FILE)).unwrap()).unwrap();
        assert_eq!(saved, carried);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_frozen_view_refuses_changes_until_thawed() {
        let store = ViewStore::open(None, Registry::new(), None);
        let carried = store.freeze();
        let refused = store
            .change(|view| Ok(((), view.add_project("/work", None).1)))
            .unwrap_err();
        assert!(refused.is::<Frozen>(), "{refused:#}");
        assert_eq!(store.snapshot(), carried);
        store.thaw();
        let ((), revision) = store
            .change(|view| Ok(((), view.add_project("/work", None).1)))
            .unwrap();
        assert_eq!(revision, carried.revision + 1);
    }

    #[test]
    fn a_pane_names_its_session() {
        let mut view = View::default();
        let pane = view.place_terminal("a", "/", &Place::default()).unwrap();
        assert_eq!(view.session_of(&pane).as_deref(), Some("a"));
        assert_eq!(view.session_of("pane:missing"), None);
    }
}
