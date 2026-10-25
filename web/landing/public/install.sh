#!/bin/sh
# Termio server for Linux.
#
#   curl -fsSL https://www.termio.sh/install | sh
#
# Puts termiod (the session host), termio (its CLI) and termio-tailnet (built-in
# Tailscale) in ~/.local/bin, checked against the release's SHA256SUMS, and
# keeps the daemon running under systemd --user. No root: everything is your
# own account's. Running it again upgrades in place; live sessions survive the
# upgrade.
#
# Run from a terminal, it then puts the daemon on your tailnet as a device of
# its own, which needs no Tailscale install here, and prints a pairing link for
# Settings > Remote Hosts > + > Pair with a Device... on a Mac or the iPhone app.
#
# Environment:
#   TERMIO_DOWNLOAD_BASE   where releases live (default https://downloads.termio.sh)
#   TERMIO_PREFIX          install prefix (default ~/.local)
#
# Everything runs from `main` on the last line, so a download cut short by the
# network defines functions and runs nothing.

set -eu

usage() {
    cat <<'USAGE'
Install the Termio server (termiod, termio and termio-tailnet) into ~/.local/bin.

  curl -fsSL https://www.termio.sh/install | sh
  curl -fsSL https://www.termio.sh/install | sh -s -- [options]

Options:
  --version X.Y.Z   install that release instead of the latest
  --no-service      install the binaries only
  --no-tailscale    do not join the tailnet
  --tailscale-auth-key-file FILE
                    join the tailnet with a one-time auth key instead of a
                    browser sign-in; works without a terminal
  --dry-run         print what would be done, change nothing
USAGE
}

say() { printf '%s\n' "$*"; }
step() { printf '==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

run() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '    would run: %s\n' "$*"
    else
        "$@"
    fi
}

parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --version) [ $# -ge 2 ] || fail "--version needs a value"; VERSION="${2#v}"; shift 2 ;;
            --version=*) VERSION="${1#--version=}"; VERSION="${VERSION#v}"; shift ;;
            --no-service) SERVICE=0; shift ;;
            --no-tailscale) TAILNET=0; shift ;;
            --tailscale-auth-key-file)
                [ $# -ge 2 ] || fail "--tailscale-auth-key-file needs a file"
                AUTH_KEY_FILE="$2"; TAILNET=1; shift 2 ;;
            --dry-run) DRY_RUN=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) fail "unknown option: $1 (see --help)" ;;
        esac
    done
}

choose_tools() {
    if command -v curl >/dev/null 2>&1; then
        fetch() { curl -fsSL --retry 2 -o "$2" "$1"; }
        fetch_text() { curl -fsSL --retry 2 "$1"; }
    elif command -v wget >/dev/null 2>&1; then
        fetch() { wget -q -O "$2" "$1"; }
        fetch_text() { wget -q -O - "$1"; }
    else
        fail "needs curl or wget."
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        digest() { sha256sum "$1" | cut -d' ' -f1; }
    elif command -v shasum >/dev/null 2>&1; then
        digest() { shasum -a 256 "$1" | cut -d' ' -f1; }
    else
        fail "needs sha256sum or shasum to check the download."
    fi
}

download() {
    if [ -z "$VERSION" ]; then
        VERSION="$(fetch_text "$BASE/linux/latest" 2>/dev/null | tr -d ' \r\n')" ||
            fail "couldn't read the latest version from $BASE/linux/latest."
        [ -n "$VERSION" ] || fail "no Linux build is published at $BASE yet."
    fi
    release="$BASE/v$VERSION/linux"

    step "Downloading termio $VERSION for $TARGET"
    fetch "$release/SHA256SUMS" "$WORK/SHA256SUMS" ||
        fail "termio $VERSION has no Linux build at $release."
    for name in $BINARIES; do
        file="$name-$TARGET"
        want="$(awk -v f="$file" '$2 == f || $2 == "*"f { print $1 }' "$WORK/SHA256SUMS")"
        if [ -z "$want" ] && [ "$name" = termio-tailnet ]; then
            # Releases before built-in Tailscale ship only the two.
            say "    termio $VERSION has no built-in Tailscale; skipping the tailnet."
            BINARIES="termiod termio"
            TAILNET=0
            continue
        fi
        [ -n "$want" ] || fail "SHA256SUMS lists no $file."
        fetch "$release/$file" "$WORK/$file" || fail "couldn't download $release/$file."
        got="$(digest "$WORK/$file")"
        [ "$got" = "$want" ] || fail "$file failed its checksum (got $got, want $want)."
    done
    say "    checksums match"
}

# Renamed into place, never written over: a running daemon keeps the file it
# was started from, and `handoff` moves it onto the new one.
install_binaries() {
    step "Installing into $BIN"
    run mkdir -p "$BIN"
    for name in $BINARIES; do
        run install -m 755 "$WORK/$name-$TARGET" "$BIN/.$name.new"
        run mv -f "$BIN/.$name.new" "$BIN/$name"
    done
    case ":$PATH:" in
        *":$BIN:"*) ;;
        *) say "    $BIN is not on your PATH. Add it to run termiod and termio by name." ;;
    esac
}

# `status --json` is pretty-printed; squeezed flat, one grep reads it. Empty
# when the binary could not answer at all.
status_flat() {
    out="$("$TERMIOD" status --json 2>/dev/null)" || return 1
    printf '%s' "$out" | tr -d ' \n\t'
}

daemon_running() { status_flat | grep -q '"daemon":{"running":true'; }

keep_running() {
    SERVICE_OK=0
    [ "$SERVICE" = 1 ] || return 0
    if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
        say "    No systemd --user session here. Start the daemon yourself with: $TERMIOD serve"
        return 0
    fi
    step "Keeping termiod running with systemd --user"
    # `service install` writes the unit afresh. One that carries WebSocket
    # settings of its own was configured by hand, and rewriting it would drop
    # them at the next restart.
    unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/termiod.service"
    if grep -q -e 'TERMIOD_WSS' -e '--wss' "$unit" 2>/dev/null; then
        say "    $unit was configured by hand (it sets the WebSocket listener), so it is"
        say "    left as it is. Move those settings into a drop-in to let this manage it."
        SERVICE_OK=1
        return 0
    fi
    if ! "$TERMIOD" service install; then
        say "    A Mac may have started termiod here over SSH. Run termiod stop once"
        say "    its sessions are done, then run this installer again."
        return 0
    fi
    SERVICE_OK=1
}

# The daemon runs termio-tailnet itself and keeps it running across restarts
# and reboots. A browser sign-in needs someone to read the link, so without a
# terminal or an auth key the tailnet is left for later.
join_tailnet() {
    JOINED=0
    [ "$TAILNET" = 1 ] && [ "$SERVICE_OK" = 1 ] || return 0
    if [ -n "$AUTH_KEY_FILE" ]; then
        step "Joining your tailnet with the auth key"
        "$TERMIOD" tailscale on --auth-key-file "$AUTH_KEY_FILE" && JOINED=1
        return 0
    fi
    if [ ! -t 1 ]; then
        say "    Not run from a terminal, so the tailnet is left for later: $TERMIOD tailscale on"
        return 0
    fi
    step "Joining your tailnet with built-in Tailscale"
    say "    Sign in with the Tailscale account your Mac and iPhone use. Only that account gets in."
    "$TERMIOD" tailscale on && JOINED=1
    return 0
}

main() {
    # `set -u` is on, and a bare `su`, cron or `docker exec` leaves some of the
    # login environment unset; the ones read below get a value or a clear stop.
    [ -n "${HOME:-}" ] || fail "HOME is not set."
    PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}"
    BASE="${TERMIO_DOWNLOAD_BASE:-https://downloads.termio.sh}"
    PREFIX="${TERMIO_PREFIX:-$HOME/.local}"
    BIN="$PREFIX/bin"
    TERMIOD="$BIN/termiod"
    BINARIES="termiod termio termio-tailnet"
    VERSION=""
    SERVICE=1
    TAILNET=1
    AUTH_KEY_FILE=""
    DRY_RUN=0
    SERVICE_OK=0
    JOINED=0

    parse_arguments "$@"

    [ "$(uname -s)" = Linux ] ||
        fail "this installs the Linux server. On a Mac, install the app from https://www.termio.sh."
    case "$(uname -m)" in
        x86_64|amd64) TARGET=x86_64-unknown-linux-musl ;;
        aarch64|arm64) TARGET=aarch64-unknown-linux-musl ;;
        *) fail "no build for $(uname -m); termio ships x86_64 and aarch64." ;;
    esac
    choose_tools

    WORK="$(mktemp -d 2>/dev/null || mktemp -d -t termio)"
    trap 'rm -rf "$WORK"' EXIT INT TERM

    download
    install_binaries
    if [ "$DRY_RUN" = 1 ]; then
        say "Dry run: nothing was changed."
        return 0
    fi

    # A daemon from an earlier install becomes the new build in place: same
    # pid, same PTYs, nothing in a session notices.
    if daemon_running; then
        step "Upgrading the running daemon in place"
        if ! "$TERMIOD" handoff; then
            say "    The running daemon couldn't take the new build in place."
            say "    It picks it up at its next start: termiod stop, once its sessions are done."
        fi
    fi

    keep_running
    join_tailnet

    say ""
    say "termio $VERSION is installed: $TERMIOD"
    if [ "$JOINED" = 1 ] && "$TERMIOD" pair --qr > "$WORK/invite" 2>/dev/null; then
        say ""
        say "To use this machine from a Mac, open Settings > Remote Hosts > + > Pair with a Device..."
        say "and paste this link. Scan the code with the iPhone app to pair a phone."
        say ""
        cat "$WORK/invite"
    else
        say "A Mac can reach it over SSH: Settings > Remote Hosts > + > Add SSH Host..."
        [ "$TAILNET" = 1 ] && [ "$SERVICE_OK" = 1 ] && [ "$JOINED" = 0 ] &&
            say "To pair over your tailnet later: $TERMIOD tailscale on, then $TERMIOD pair --qr"
    fi
    return 0
}

main "$@"
