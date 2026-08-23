//! The VT sidecar's side of a session: what it is asked to do, what it hands
//! back, and the budget that keeps a slow parse from costing unbounded memory.
//!
//! The sidecar is deliberately off the byte path — bytes reach clients whether
//! or not it keeps up, which is the anti-100x invariant. This module owns the
//! machinery that makes "whether or not" safe: a queue that refuses work rather
//! than growing, so falling behind degrades the snapshot and never the stream.

use bytes::Bytes;
use std::sync::atomic::{AtomicUsize, Ordering};

/// PTY bytes allowed to sit unparsed in the sidecar's command FIFO. The
/// per-client budget stops a slow socket from buying unbounded memory; this
/// stops a slow *parse* from doing the same one hop upstream.
const SIDECAR_QUEUE_CAP: usize = 16 * 1024 * 1024;

/// The budget in the words a staleness notice uses. Asked for rather than
/// restated, so the number and the sentence explaining it cannot drift.
/// The budget itself, for tests that need to fill it exactly.
#[cfg(test)]
pub(crate) const CAP_FOR_TESTS: usize = SIDECAR_QUEUE_CAP;

pub(crate) fn cap_description() -> String {
    format!("{} MiB", SIDECAR_QUEUE_CAP / (1024 * 1024))
}

use crate::protocol::GridDiff;
use crate::id::ClientId;

/// Counts PTY bytes queued for the VT sidecar but not yet parsed.
pub(crate) struct SidecarQueue {
    outstanding: AtomicUsize,
}

impl SidecarQueue {
    pub(crate) fn new() -> Self {
        Self {
            outstanding: AtomicUsize::new(0),
        }
    }

    pub(crate) fn try_reserve(&self, bytes: usize) -> bool {
        self.outstanding
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |outstanding| {
                outstanding
                    .checked_add(bytes)
                    .filter(|total| *total <= SIDECAR_QUEUE_CAP)
            })
            .is_ok()
    }

    /// Whether every byte charged to the queue has been credited back. A
    /// healthy session ends here; anything else means the budget ratchets shut.
    pub(crate) fn is_drained(&self) -> bool {
        self.outstanding.load(Ordering::Relaxed) == 0
    }

    pub(crate) fn release(&self, bytes: usize) {
        let _ =
            self.outstanding
                .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |outstanding| {
                    Some(outstanding.saturating_sub(bytes))
                });
    }
}

pub(crate) enum SidecarCommand {
    Write(Bytes),
    Resize {
        rows: u16,
        cols: u16,
    },
    Snapshot {
        client_id: ClientId,
        request_id: u64,
        scrollback: bool,
    },
    SetGridDiff(bool),
    Shutdown,
}

/// Snapshot replies and live grid updates share this single FIFO channel.
/// Separate channels could let a post-boundary G overtake its S and regress
/// rows after the client applies the newer snapshot.
pub(crate) enum SidecarResult {
    Snapshot {
        client_id: ClientId,
        request_id: u64,
        result: Result<SidecarCapture, String>,
    },
    Grid(GridDiff),
    Keyframe(termiod_vt::Snapshot),
}

pub(crate) struct SidecarCapture {
    pub(crate) snapshot: termiod_vt::Snapshot,
    /// The same screen serialised back to VT sequences. `None` only if the
    /// formatter failed, in which case delivery falls back to packed cells.
    pub(crate) vt: Option<Vec<u8>>,
    pub(crate) scrollback: Option<Result<termiod_vt::Scrollback, String>>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sidecar_queue_stops_admitting_bytes_past_its_budget() {
        let queue = SidecarQueue::new();

        assert!(queue.try_reserve(SIDECAR_QUEUE_CAP));
        assert!(!queue.try_reserve(1));

        queue.release(SIDECAR_QUEUE_CAP);
        assert!(queue.try_reserve(1));
        queue.release(1);
        // Releasing more than was reserved is a bug, not a panic: the VT thread
        // and the session actor account independently.
        queue.release(SIDECAR_QUEUE_CAP);
        assert!(queue.try_reserve(SIDECAR_QUEUE_CAP));
    }
}
