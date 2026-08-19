//! Who is actually running in a session's terminal.
//!
//! A session's `command` is what it was *created* with. That answers nothing
//! once a login shell has been sitting there for an hour: the program the user
//! is talking to is whatever holds the tty's foreground process group, and the
//! directory that matters is wherever the child `cd`'d to since. The kernel
//! knows both; nothing in the byte stream does.
//!
//! termio's macOS app reads this with `KERN_PROCARGS2` + `proc_pidinfo`
//! (`Sources/termio/Terminal/Ghostty/PTYProcess.swift`), which is why it has
//! never worked for a Linux host. The same three questions have plain answers
//! under `/proc`, so this module asks them behind one interface and lets the
//! target pick the mechanism.
//!
//! Every function here is a syscall against a pid, so two rules hold at every
//! call site:
//!
//! 1. **Never on the byte path.** Sampling is a poll, bounded and infrequent;
//!    PTY delivery must not wait on it (the anti-100× invariant).
//! 2. **Never after the child is reaped.** A recycled pid answers confidently
//!    about a process that is not ours.
//!
//! Failure is always `None`. A refusal by the kernel, a process that exited
//! mid-read, a short buffer — none of them are worth an error type, because
//! every caller does the same thing with all of them: keep the last known
//! answer and try again next tick.

/// The binary a process is running, pinned tightly enough to notice it being
/// swapped underneath. The inode is the discriminating half: an agent that
/// updates itself in place keeps its path and changes its file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExecutableIdentity {
    pub path: String,
    /// `None` when the file was already gone at sampling time, which reads as
    /// "replaced" for every later comparison.
    pub inode: Option<u64>,
}

impl ExecutableIdentity {
    /// Whether the recorded binary has since been replaced on disk: the file is
    /// gone (a package manager purging the old versioned directory on upgrade)
    /// or its inode changed (an in-place reinstall). This is how an exit that
    /// means "the agent updated itself and quit" is told from a plain quit,
    /// whose binary is untouched.
    pub fn was_replaced(&self) -> bool {
        let Some(inode) = self.inode else {
            return true;
        };
        match std::fs::metadata(&self.path) {
            Ok(metadata) => {
                use std::os::unix::fs::MetadataExt;
                metadata.ino() != inode
            }
            Err(_) => true,
        }
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use super::ExecutableIdentity;

    /// Reads a process's full argument vector from the kernel
    /// (`KERN_PROCARGS2`), whose buffer is laid out
    /// `[argc: i32][exec path]\0…\0[argv0]\0[argv1]\0…[env]`. Own-user
    /// processes only, which is exactly the scope here: the session child and
    /// its descendants.
    pub fn process_arguments(pid: i32) -> Option<Vec<String>> {
        let mut mib: [libc::c_int; 3] = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
        let mut size: libc::size_t = 0;
        let probe = unsafe {
            libc::sysctl(
                mib.as_mut_ptr(),
                mib.len() as libc::c_uint,
                std::ptr::null_mut(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        if probe != 0 || size <= std::mem::size_of::<i32>() {
            return None;
        }
        let mut buffer = vec![0u8; size];
        let read = unsafe {
            libc::sysctl(
                mib.as_mut_ptr(),
                mib.len() as libc::c_uint,
                buffer.as_mut_ptr() as *mut libc::c_void,
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        if read != 0 {
            return None;
        }
        buffer.truncate(size);
        super::split_procargs2(&buffer)
    }

    /// The process's current working directory, read from the kernel
    /// (`PROC_PIDVNODEPATHINFO`). This is the fallback every terminal without
    /// shell integration relies on: macOS's stock zsh only emits OSC 7 under
    /// `TERM_PROGRAM=Apple_Terminal`, and termiod injects no shell
    /// integration — but the kernel always knows.
    pub fn working_directory(pid: i32) -> Option<String> {
        let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
        let size = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDVNODEPATHINFO,
                0,
                &mut info as *mut _ as *mut libc::c_void,
                std::mem::size_of::<libc::proc_vnodepathinfo>() as libc::c_int,
            )
        };
        if size <= 0 {
            return None;
        }
        // `vip_path` is declared as nested arrays purely to sidestep a const
        // generics limit in libc; the bytes are one flat NUL-terminated path.
        let raw = &info.pvi_cdir.vip_path;
        let flat = unsafe {
            std::slice::from_raw_parts(raw.as_ptr() as *const u8, std::mem::size_of_val(raw))
        };
        super::string_until_nul(flat)
    }

    pub fn executable_path(pid: i32) -> Option<String> {
        let mut buffer = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
        let written = unsafe {
            libc::proc_pidpath(
                pid,
                buffer.as_mut_ptr() as *mut libc::c_void,
                buffer.len() as u32,
            )
        };
        if written <= 0 {
            return None;
        }
        buffer.truncate(written as usize);
        super::string_until_nul(&buffer)
    }

    pub fn executable_identity(pid: i32) -> Option<ExecutableIdentity> {
        let path = executable_path(pid)?;
        Some(super::identity_for(path))
    }
}

#[cfg(target_os = "linux")]
mod imp {
    use super::ExecutableIdentity;

    /// `/proc/<pid>/cmdline` is argv verbatim, NUL-separated and NUL-
    /// terminated. Kernel threads have an empty one; so does a process caught
    /// mid-exec, and both are correctly "no answer yet".
    pub fn process_arguments(pid: i32) -> Option<Vec<String>> {
        let raw = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
        let arguments: Vec<String> = raw
            .split(|byte| *byte == 0)
            .filter(|part| !part.is_empty())
            .map(|part| String::from_utf8_lossy(part).into_owned())
            .collect();
        (!arguments.is_empty()).then_some(arguments)
    }

    /// `/proc/<pid>/cwd` is a symlink the kernel resolves on read, so this is
    /// the live directory rather than the one the process started in.
    pub fn working_directory(pid: i32) -> Option<String> {
        let path = std::fs::read_link(format!("/proc/{pid}/cwd")).ok()?;
        let path = path.to_str()?.to_string();
        (!path.is_empty()).then_some(path)
    }

    /// `/proc/<pid>/exe` gains a literal " (deleted)" suffix once the binary is
    /// unlinked — an upgrade caught in the act. The suffix is stripped so the
    /// path stays usable, and the missing inode carries the fact forward.
    pub fn executable_path(pid: i32) -> Option<String> {
        let path = std::fs::read_link(format!("/proc/{pid}/exe")).ok()?;
        let path = path.to_str()?;
        let path = path.strip_suffix(" (deleted)").unwrap_or(path).to_string();
        (!path.is_empty()).then_some(path)
    }

    pub fn executable_identity(pid: i32) -> Option<ExecutableIdentity> {
        let path = executable_path(pid)?;
        Some(super::identity_for(path))
    }
}

/// Anything that is neither macOS nor Linux compiles and answers "unknown"
/// rather than failing the build. termiod has no third host today; when it does,
/// this is the one place that needs a mechanism.
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
mod imp {
    use super::ExecutableIdentity;

    pub fn process_arguments(_pid: i32) -> Option<Vec<String>> {
        None
    }

    pub fn working_directory(_pid: i32) -> Option<String> {
        None
    }

    pub fn executable_identity(_pid: i32) -> Option<ExecutableIdentity> {
        None
    }
}

pub use imp::{executable_identity, process_arguments, working_directory};

#[cfg(any(target_os = "macos", test))]
fn split_procargs2(buffer: &[u8]) -> Option<Vec<String>> {
    let header = std::mem::size_of::<i32>();
    if buffer.len() <= header {
        return None;
    }
    let mut argc_bytes = [0u8; 4];
    argc_bytes.copy_from_slice(&buffer[..header]);
    let argc = i32::from_ne_bytes(argc_bytes);
    if argc <= 0 {
        return None;
    }
    let mut index = header;
    // Skip the executable path that precedes argv[0], then the NUL padding
    // between it and argv[0].
    while index < buffer.len() && buffer[index] != 0 {
        index += 1;
    }
    while index < buffer.len() && buffer[index] == 0 {
        index += 1;
    }
    let mut arguments = Vec::new();
    let mut current = Vec::new();
    while index < buffer.len() && arguments.len() < argc as usize {
        let byte = buffer[index];
        index += 1;
        if byte == 0 {
            arguments.push(String::from_utf8_lossy(&current).into_owned());
            current.clear();
        } else {
            current.push(byte);
        }
    }
    (!arguments.is_empty()).then_some(arguments)
}

#[cfg(target_os = "macos")]
fn string_until_nul(bytes: &[u8]) -> Option<String> {
    let end = bytes
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(bytes.len());
    let text = String::from_utf8_lossy(&bytes[..end]).into_owned();
    (!text.is_empty()).then_some(text)
}

#[cfg(any(target_os = "macos", target_os = "linux", test))]
fn identity_for(path: String) -> ExecutableIdentity {
    use std::os::unix::fs::MetadataExt;
    let inode = std::fs::metadata(&path).ok().map(|metadata| metadata.ino());
    ExecutableIdentity { path, inode }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};

    /// Spawn a real child and wait until the kernel agrees it has exec'd — the
    /// window between `fork` and `exec` is real, and a test that reads through
    /// it asserts against the parent's argv instead of the child's.
    struct Sleeper(std::process::Child);

    fn sleep_binary() -> &'static str {
        ["/bin/sleep", "/usr/bin/sleep"]
            .into_iter()
            .find(|path| std::path::Path::new(path).exists())
            .expect("no sleep binary on this host")
    }

    impl Sleeper {
        fn spawn(cwd: &str) -> Sleeper {
            // Absolute on purpose: the test asserts on the executable path the
            // kernel reports, and a PATH lookup would make that unpredictable.
            let child = Command::new(sleep_binary())
                .arg("30")
                .current_dir(cwd)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .expect("spawning /bin/sleep");
            let sleeper = Sleeper(child);
            let deadline = Instant::now() + Duration::from_secs(5);
            while Instant::now() < deadline {
                if let Some(argv) = process_arguments(sleeper.pid()) {
                    if argv.first().is_some_and(|arg| arg.ends_with("sleep")) {
                        return sleeper;
                    }
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            panic!("child never showed up in the kernel's process table");
        }

        fn pid(&self) -> i32 {
            self.0.id() as i32
        }
    }

    impl Drop for Sleeper {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    #[test]
    fn reads_a_live_child_argv() {
        let child = Sleeper::spawn("/");
        let argv = process_arguments(child.pid()).expect("argv for a live child");
        assert_eq!(argv.len(), 2, "argv was {argv:?}");
        assert!(argv[0].ends_with("sleep"), "argv[0] was {:?}", argv[0]);
        assert_eq!(argv[1], "30");
    }

    #[test]
    fn reads_a_live_child_working_directory() {
        let temp = std::env::temp_dir().join(format!("termiod-proc-{}", std::process::id()));
        std::fs::create_dir_all(&temp).expect("creating the test directory");
        // The kernel answers with the resolved path; macOS's /tmp is a symlink,
        // so the expectation has to be resolved too.
        let expected = std::fs::canonicalize(&temp).expect("canonicalizing the test directory");
        let child = Sleeper::spawn(temp.to_str().expect("utf-8 temp path"));

        let cwd = working_directory(child.pid()).expect("cwd for a live child");
        assert_eq!(std::path::Path::new(&cwd), expected);

        drop(child);
        let _ = std::fs::remove_dir_all(&temp);
    }

    #[test]
    fn pins_the_child_executable_and_sees_it_intact() {
        let child = Sleeper::spawn("/");
        let identity = executable_identity(child.pid()).expect("identity for a live child");
        // Resolved, not spelled: on a busybox host /bin/sleep is a symlink and
        // the kernel correctly names /bin/busybox as what is running. Asserting
        // the literal path would encode one distro's layout as the contract.
        let expected = std::fs::canonicalize(sleep_binary()).expect("canonical sleep binary");
        assert_eq!(std::path::Path::new(&identity.path), expected);
        assert!(identity.inode.is_some(), "no inode for an on-disk binary");
        assert!(
            !identity.was_replaced(),
            "an untouched binary must not read as replaced"
        );
    }

    /// The whole point of pinning the inode: a path that still exists but is a
    /// different file is a replacement, and a path that is gone is one too.
    #[test]
    fn notices_a_replaced_executable() {
        let dir = std::env::temp_dir().join(format!("termiod-exe-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("creating the test directory");
        let path = dir.join("agent");
        std::fs::write(&path, b"#!/bin/sh\n").expect("writing the fake binary");
        let identity = identity_for(path.to_string_lossy().into_owned());
        assert!(!identity.was_replaced());

        // The upgrade shape, and deterministic about it: the replacement exists
        // alongside the original before the rename, so the two inodes cannot
        // collide. Deleting and rewriting in place can hand back the same inode
        // number on some filesystems, which would prove nothing.
        let upgrade = dir.join("agent.new");
        std::fs::write(&upgrade, b"#!/bin/sh\n# v2\n").expect("writing the replacement");
        std::fs::rename(&upgrade, &path).expect("swapping the replacement in");
        assert!(identity.was_replaced(), "a new inode is a replacement");

        std::fs::remove_file(&path).expect("removing the fake binary");
        assert!(identity.was_replaced(), "a missing file is a replacement");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn refuses_a_pid_that_is_not_running() {
        // pid 0 is never a queryable user process on either host.
        assert!(process_arguments(0).is_none());
        assert!(working_directory(0).is_none());
        assert!(executable_identity(0).is_none());
    }

    /// The macOS buffer layout, asserted without the kernel: argc, the exec
    /// path, NUL padding, then argv.
    #[test]
    fn parses_the_procargs2_layout() {
        let mut buffer = Vec::new();
        buffer.extend_from_slice(&2i32.to_ne_bytes());
        buffer.extend_from_slice(b"/usr/local/bin/claude\0\0\0");
        buffer.extend_from_slice(b"claude\0--resume\0");
        buffer.extend_from_slice(b"PATH=/usr/bin\0");
        let argv = split_procargs2(&buffer).expect("argv from a well-formed buffer");
        assert_eq!(argv, vec!["claude".to_string(), "--resume".to_string()]);
    }

    #[test]
    fn rejects_a_truncated_procargs2_buffer() {
        assert!(split_procargs2(&[]).is_none());
        assert!(split_procargs2(&0i32.to_ne_bytes()).is_none());
        assert!(split_procargs2(&(-1i32).to_ne_bytes()).is_none());
    }
}
