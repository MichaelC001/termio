#!/usr/bin/env bash
#
# Phase-0 proof for the Seatbelt sandbox (replacing the micro-VM). Builds the
# baseline Seatbelt profile termio will generate and runs commands under
# `sandbox-exec` to assert the security denies actually hold — before any app
# code is wired up or any VM code is removed.
#
# Asserts, inside the sandbox:
#   - the project workspace is read-write          (agent can do its job)
#   - /etc and system paths are readable           (tools run)
#   - ~/.ssh is NOT readable                        (no key exfiltration)
#   - the login Keychain is NOT reachable           (no token theft, incl. via Mach IPC)
#   - a .env *inside the writable workspace* is NOT readable
#       (proves the "last matching rule wins" override over the workspace allow)
#
# The profile here is the single source of truth Phase 1 ports into Swift
# (Sources/termio/Sandbox.swift). Run: scripts/seatbelt-smoke.sh
set -u

HOME_DIR="$HOME"
TMP_REAL="$(cd "${TMPDIR:-/tmp}" && pwd -P)"

workspace="$(mktemp -d "${TMPDIR:-/tmp}/termio-seatbelt-smoke.XXXXXX")"
workspace="$(cd "$workspace" && pwd -P)"   # resolve /var -> /private/var so subpath matches
printf 'secret-in-env\n' > "$workspace/.env"
printf 'hello\n'         > "$workspace/notes.txt"

# Build the baseline profile. Security-critical denies come LAST so they win over
# the broad workspace / system allows above them.
read -r -d '' PROFILE <<SBPL
(version 1)
(deny default)

;; process / exec basics
(allow process-exec*)
(allow process-fork)
(allow process-info* (target self))
(allow signal (target self) (target same-sandbox))
(allow sysctl-read)
(allow system-info)
(allow system-fsctl)
(allow mach-task-name)
(allow mach-per-user-lookup)
(allow mach-lookup)
(allow ipc-posix-shm-read-data)
(allow ipc-posix-shm-write-data)
(allow ipc-posix-shm-write-create)

;; a real terminal needs the tty
(allow pseudo-tty)
(allow file-ioctl (literal "/dev/tty"))
(allow file-ioctl (regex #"^/dev/ttys[0-9]+\$"))

;; read the root dir entry itself (exec path resolution)
(allow file-read* (literal "/"))

;; system read so tools and dyld work
(allow file-read*
  (subpath "/bin") (subpath "/sbin") (subpath "/usr") (subpath "/System")
  (subpath "/Library") (subpath "/etc") (subpath "/private/etc")
  (subpath "/private/var/db/dyld") (subpath "/var/db/dyld")
  (subpath "/opt") (subpath "/dev") (subpath "/Applications")
  (subpath "/private/var/db/timezone") (subpath "/usr/share"))

;; map executables only from those readable trees (DYLD_INSERT_LIBRARIES guard)
(allow file-map-executable
  (subpath "/usr") (subpath "/System") (subpath "/Library") (subpath "/opt")
  (subpath "$workspace"))

;; dev toolchain caches the agent legitimately reads
(allow file-read*
  (subpath "$HOME_DIR/.npm") (subpath "$HOME_DIR/.nvm") (subpath "$HOME_DIR/.cache")
  (literal "$HOME_DIR/.gitconfig") (subpath "/opt/homebrew"))

;; temp + user caches writable
(allow file-read* file-write*
  (subpath "$TMP_REAL") (subpath "/private/tmp")
  (subpath "$HOME_DIR/Library/Caches") (subpath "$HOME_DIR/Library/Logs"))

;; the project workspace: read-write (the agent edits the real repo)
(allow file-read* file-write* (subpath "$workspace"))

;; network (full)
(allow network*)
(allow system-socket)

;; ===== security baseline — these are LAST so they override the allows above =====
(deny file-read*
  (subpath "$HOME_DIR/.ssh") (subpath "$HOME_DIR/.gnupg") (subpath "$HOME_DIR/.aws")
  (subpath "$HOME_DIR/.config/gcloud") (subpath "$HOME_DIR/.kube")
  (subpath "$HOME_DIR/.docker") (literal "$HOME_DIR/.git-credentials")
  (literal "$HOME_DIR/.netrc") (literal "$HOME_DIR/.npmrc"))
(deny file-read* (subpath "$HOME_DIR/Library/Keychains") (subpath "/Library/Keychains"))
(deny mach-lookup
  (global-name "com.apple.secd")
  (global-name "com.apple.securityd")
  (global-name "com.apple.security.keychaind")
  (global-name "com.apple.SecurityServer")
  (global-name "com.apple.security.agent"))

;; .env anywhere (incl. inside the writable workspace) — blocks secret reads
(deny file-read* (regex #"/\\.env(\\.[^/]+)?\$"))
SBPL

pass=0; fail=0
# $1 = description, $2 = "allow"|"deny" (expected outcome), $3.. = command
check() {
  local desc="$1" expect="$2"; shift 2
  if /usr/bin/sandbox-exec -p "$PROFILE" "$@" >/dev/null 2>&1; then
    actual=allow
  else
    actual=deny
  fi
  if [[ "$actual" == "$expect" ]]; then
    printf '  \033[32mPASS\033[0m  %s (%s)\n' "$desc" "$expect"; pass=$((pass+1))
  else
    printf '  \033[31mFAIL\033[0m  %s — expected %s, got %s\n' "$desc" "$expect" "$actual"; fail=$((fail+1))
  fi
}

echo "Seatbelt sandbox smoke test"
echo "workspace: $workspace"
echo

check "read /etc/passwd (system read works)"     allow /bin/cat /etc/passwd
check "write inside workspace"                    allow /usr/bin/touch "$workspace/written-by-sandbox"
check "read a normal workspace file"              allow /bin/cat "$workspace/notes.txt"
check "read ~/.ssh/id_ed25519 (key)"              deny  /bin/cat "$HOME_DIR/.ssh/id_ed25519"
check "list ~/.ssh"                               deny  /bin/ls  "$HOME_DIR/.ssh"
check "read login Keychain file"                  deny  /bin/cat "$HOME_DIR/Library/Keychains/login.keychain-db"
check "read .env inside the writable workspace"   deny  /bin/cat "$workspace/.env"
check "read .env.local inside the workspace"      deny  sh -c ": > '$workspace/.env.local'; cat '$workspace/.env.local'"

echo
echo "passed: $pass  failed: $fail"
rm -rf "$workspace"
[[ "$fail" -eq 0 ]]
