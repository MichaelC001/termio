//! Who is running in the session's terminal, and where.
//!
//! This answers "which agent is in there" — a question whose answer changes
//! when a human starts or stops a program, not per frame. It knows nothing
//! about clients, snapshots or the protocol; it needs a tty and a child pid,
//! and everything else it learns from the kernel.
//!
//! Split deliberately along what each half costs. `tcgetpgrp` is one syscall
//! and runs on the session actor; reading argv is a `KERN_PROCARGS2` sysctl on
//! macOS and a file read on Linux, and finding *which* pid to read it for can
//! mean walking every process on the box when a pipeline's leader has exited.
//! None of that may happen on the actor: that task also runs the PTY read and
//! the fan-out, so a process-table walk there is time the byte path spends
//! waiting — the anti-100× invariant, which is about more than the VT parse.

use crate::proc::ExecutableIdentity;
use crate::pty::Pty;
use tokio::sync::mpsc;

/// How often the session asks the kernel what is running in its terminal.
/// Slow on purpose, for the reason in the module note above.
pub(crate) const POLL_INTERVAL: std::time::Duration = std::time::Duration::from_secs(2);

/// What the session believes about its foreground right now.
#[derive(Default, Clone, PartialEq, Eq)]
pub(crate) struct ForegroundSample {
    /// The foreground process *group*, exactly as `tcgetpgrp` reported it.
    /// Kept even when no member of it could be read, because "is a job
    /// running?" is answered by comparing this against the session's own child
    /// and must not turn into "no" the moment a pipeline's leader exits.
    pgid: Option<i32>,
    /// The member of that group whose argv is reported below. Equal to `pgid`
    /// whenever the group leader is still usable, which is the common case.
    pub(super) pid: Option<i32>,
    pub(super) argv: Option<Vec<String>>,
    pub(super) job: bool,
    pub(super) cwd: Option<String>,
}

/// The expensive half of a foreground sample, computed on a blocking thread and
/// handed back to the actor.
pub(crate) struct ForegroundResolution {
    /// The group this answer describes. The foreground can move while the
    /// resolution is in flight, and an answer about a group that has since lost
    /// the terminal is not a stale version of the truth — it is the answer to a
    /// different question, and gets dropped.
    pgid: Option<i32>,
    pid: Option<i32>,
    argv: Option<Vec<String>>,
    cwd: Option<String>,
    /// Only set when the session had not pinned its binary yet.
    executable: Option<ExecutableIdentity>,
}

/// The session's foreground knowledge and the machinery that keeps it current.
///
/// The three pieces live together because they are only meaningful together:
/// `pending` guards the dispatch that fills `sample`, and `executable` is
/// pinned by the same resolution. They are not a state machine — a resolution
/// in flight says nothing about what `sample` currently holds, which is exactly
/// why [`Foreground::apply`] re-checks the group before believing an answer.
#[derive(Default)]
pub(crate) struct Foreground {
    sample: ForegroundSample,
    /// A resolution is in flight on a blocking thread. One at a time: the poll
    /// is slower than the work, and piling up would only queue answers about
    /// groups that have already lost the terminal.
    pending: bool,
    /// The binary the child is running, pinned on the first sample that finds
    /// it. One-shot on purpose: this is the *launch* baseline that
    /// `was_replaced()` compares against, and resampling would paper over the
    /// in-place upgrade it exists to notice.
    executable: Option<ExecutableIdentity>,
}

impl Foreground {
    pub(super) fn current(&self) -> &ForegroundSample {
        &self.sample
    }

    /// The path of the binary the session's child is running, as pinned at
    /// launch.
    pub(super) fn executable_path(&self) -> Option<String> {
        self.executable.as_ref().map(|identity| identity.path.clone())
    }

    /// Whether that binary has since been replaced on disk. A fresh read every
    /// time it is asked: the record that matters most is the one built on the
    /// exit path, and a binary swapped during the seconds before the child quit
    /// is exactly the case this answers.
    pub(super) fn executable_replaced(&self) -> bool {
        self.executable
            .as_ref()
            .is_some_and(|identity| identity.was_replaced())
    }

    /// The cheap half of the poll, and the only half that runs on the actor:
    /// one `tcgetpgrp` on the master. Returns whether anything moved, so a
    /// quiet session emits no roster traffic.
    ///
    /// The expensive half is dispatched to a blocking thread and applied later
    /// by [`Foreground::apply`]. Both halves have to exist because they answer
    /// different questions on different deadlines: "is a job running?" is read
    /// at close time and must be current, and it is answerable from the group
    /// id alone; "what is that job?" drives an icon and can be a beat late.
    pub(super) fn poll(
        &mut self,
        pty: &Pty,
        child: i32,
        resolved: &mpsc::UnboundedSender<ForegroundResolution>,
    ) -> bool {
        if child <= 0 {
            return false;
        }
        let pgid = pty.foreground_pgid();
        // Compared against the *group*: a foreground group that is not the
        // child's own is a running job whether or not any member of it could
        // be read.
        let job = pgid.is_some_and(|pgid| pgid != child);
        let mut changed = false;
        if self.sample.pgid != pgid {
            self.sample.pgid = pgid;
            // The cached identity described a group that no longer holds the
            // terminal. Dropping it is an honest gap the resolution below
            // fills; keeping it would name a program that has already exited.
            self.sample.pid = None;
            self.sample.argv = None;
            changed = true;
        }
        if self.sample.job != job {
            self.sample.job = job;
            changed = true;
        }
        self.request(pgid, child, resolved);
        changed
    }

    /// Hand the process-table work to a blocking thread.
    fn request(
        &mut self,
        pgid: Option<i32>,
        child: i32,
        resolved: &mpsc::UnboundedSender<ForegroundResolution>,
    ) {
        if self.pending {
            return;
        }
        self.pending = true;
        let pin_executable = self.executable.is_none();
        let resolved = resolved.clone();
        tokio::task::spawn_blocking(move || {
            // A group id is not a pid. The shell names each job's group after
            // its leader, so the two agree for as long as that leader is alive
            // — and stop agreeing in a pipeline the moment it is not, which is
            // why the pid comes from the host rather than from that assumption.
            let pid = pgid.and_then(crate::proc::foreground_member);
            let _ = resolved.send(ForegroundResolution {
                pgid,
                pid,
                argv: pid.and_then(crate::proc::process_arguments),
                cwd: crate::proc::working_directory(child),
                executable: pin_executable
                    .then(|| crate::proc::executable_identity(child))
                    .flatten(),
            });
        });
    }

    /// Take a resolution the blocking thread finished, unless the foreground
    /// moved while it was in flight. Returns whether anything moved.
    pub(super) fn apply(&mut self, resolution: ForegroundResolution) -> bool {
        self.pending = false;
        if resolution.pgid != self.sample.pgid {
            return false;
        }
        if self.executable.is_none() {
            self.executable = resolution.executable;
        }
        let mut changed = false;
        if self.sample.pid != resolution.pid {
            self.sample.pid = resolution.pid;
            changed = true;
        }
        if self.sample.argv != resolution.argv {
            self.sample.argv = resolution.argv;
            changed = true;
        }
        if self.sample.cwd != resolution.cwd {
            self.sample.cwd = resolution.cwd;
            changed = true;
        }
        changed
    }
}
