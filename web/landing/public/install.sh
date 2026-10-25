#!/bin/sh
# Termio server for Linux.
#
#   curl -fsSL https://www.termio.sh/install | sh
#
# Puts termiod (the session host) and termio (its CLI) in ~/.local/bin,
# checked against the release's SHA256SUMS, and keeps the daemon running under
# systemd --user. No root: everything is your own account's. Running it again
# upgrades in place; live sessions survive the upgrade.
#
# With Tailscale signed in and HTTPS on for the tailnet, it also publishes the
# daemon on the tailnet and prints a pairing link for Settings > Remote Hosts >
# + > Pair with a Device... on a Mac.
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
Install the Termio server (termiod and termio) into ~/.local/bin.

  curl -fsSL https://www.termio.sh/install | sh
  curl -fsSL https://www.termio.sh/install | sh -s -- [options]

Options:
  --version X.Y.Z   install that release instead of the latest
  --no-service      install the binaries only
  --no-tailscale    do not publish on the tailnet
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
    for name in termiod termio; do
        file="$name-$TARGET"
        fetch "$release/$file" "$WORK/$file" || fail "couldn't download $release/$file."
        want="$(awk -v f="$file" '$2 == f || $2 == "*"f { print $1 }' "$WORK/SHA256SUMS")"
        [ -n "$want" ] || fail "SHA256SUMS lists no $file."
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
    for name in termiod termio; do
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

# The live session count, or a failure when it cannot be known. `status`
# reports an empty roster whenever its own request fails, so the count comes
# from `list`, which fails loudly instead. `list` also starts a daemon when
# none answers, so it is asked only of one that `status` saw running.
verified_live_sessions() {
    daemon_running || return 1
    roster="$("$TERMIOD" list --json 2>/dev/null)" || return 1
    printf '%s' "$roster" | tr -d ' \n\t' | grep -o '"alive":true' | wc -l | tr -d ' '
}

tailnet_name() {
    tailscale status --json --peers=false 2>/dev/null |
        grep -m1 '"DNSName"' | sed 's/.*"DNSName": *"\([^"]*\)".*/\1/; s/\.$//'
}

tailnet_has_https() {
    tailscale status --json --peers=false 2>/dev/null | tr -d '\n ' | grep -q '"CertDomains":\["'
}

# One WebSocket setting as the daemon would see it, wherever it was set and
# however it was spelled: systemd's reading of the unit, then the drop-in
# files, then the file termiod keeps for a hand-run `serve --wss`. Empty when
# nothing sets it.
existing_setting() {
    key="$1" state_file="$2"
    shown="$(systemctl --user show termiod.service -p Environment --value 2>/dev/null || true)"
    for word in $shown; do
        word="${word#\"}"
        case "$word" in
            "$key"=*) printf '%s\n' "${word#"$key"=}" | tr -d '"'; return 0 ;;
        esac
    done
    from_dropins="$(cat "$(dirname "$DROPIN")"/*.conf 2>/dev/null |
        sed -n "s/^Environment=\"\{0,1\}$key=\([^\"]*\)\"\{0,1\}[[:space:]]*\$/\1/p" | tail -n1)"
    if [ -n "$from_dropins" ]; then
        printf '%s\n' "$from_dropins"
        return 0
    fi
    persisted="${XDG_STATE_HOME:-$HOME/.local/state}/termio/$state_file"
    [ -f "$persisted" ] && tr -d ' \n' < "$persisted"
    return 0
}

# Decides, before anything starts, whether the daemon will listen for the
# tailnet, so a fresh box starts once with the listener and its token in place.
# The drop-in is the same file, in the same form, that a Mac's Publish writes:
# a second file would lose to it, and an origin the user already published is
# theirs to replace.
plan_tailnet() {
    URL=""
    LISTENER_CHANGED=0
    LISTENER_WANTED=0
    [ "$TAILNET" = 1 ] && [ "$SERVICE" = 1 ] || return 0
    command -v tailscale >/dev/null 2>&1 || return 0
    name="$(tailnet_name)"
    if [ -z "$name" ]; then
        say "    Tailscale is installed but not signed in; skipping the tailnet."
        return 0
    fi
    if ! tailnet_has_https; then
        say "    Your tailnet has HTTPS off, which Tailscale Serve needs. Turn it on in the"
        say "    admin console under DNS > HTTPS Certificates, then run this installer again."
        return 0
    fi
    want_origin="https://$name"
    want_bind="127.0.0.1:$PORT"
    existing="$(existing_setting TERMIOD_WSS_ORIGIN wss.origin)"
    existing_bind="$(existing_setting TERMIOD_WSS wss.bind)"
    # Anything already set that is not exactly this is someone's publication:
    # a Mac's tunnel, a custom domain, a hand-run listener. It is left alone.
    if { [ -n "$existing" ] && [ "$existing" != "$want_origin" ]; } ||
        { [ -n "$existing_bind" ] && [ "$existing_bind" != "$want_bind" ]; }; then
        say "    termiod is already published (${existing:-no origin} on ${existing_bind:-no bind}),"
        say "    so the tailnet is left alone. To publish on the tailnet instead, remove that"
        say "    setting (see termiod/DEPLOY.md) and run this again."
        return 0
    fi
    URL="$want_origin"
    step "Publishing on your tailnet as $URL"
    LISTENER_WANTED=1
    # The listener refuses to start without a pairing token, so it exists first.
    "$TERMIOD" pair >/dev/null
    if [ "$existing" != "$want_origin" ] || [ "$existing_bind" != "$want_bind" ]; then
        mkdir -p "$(dirname "$DROPIN")"
        printf '[Service]\nEnvironment="TERMIOD_WSS=127.0.0.1:%s"\nEnvironment="TERMIOD_WSS_ORIGIN=%s"\n' \
            "$PORT" "$URL" > "$DROPIN.new"
        mv -f "$DROPIN.new" "$DROPIN"
        LISTENER_CHANGED=1
    fi
}

keep_running() {
    SERVICE_OK=0
    [ "$SERVICE" = 1 ] || return 0
    if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
        say "    No systemd --user session here. Start the daemon yourself with: $TERMIOD serve"
        return 0
    fi
    step "Keeping termiod running with systemd --user"
    [ "$LISTENER_CHANGED" = 1 ] && systemctl --user daemon-reload
    # `service install` writes the unit afresh. One that carries WebSocket
    # settings of its own was configured by hand, and rewriting it would drop
    # them at the next restart.
    unit="$(dirname "$DROPIN")/../termiod.service"
    if grep -q -e 'TERMIOD_WSS' -e '--wss' "$unit" 2>/dev/null; then
        say "    $unit was configured by hand (it sets the WebSocket listener), so it is"
        say "    left as it is. Move those settings into a drop-in to let this manage it."
        SERVICE_OK=1
    elif ! "$TERMIOD" service install; then
        say "    A Mac may have started termiod here over SSH. Run termiod stop once"
        say "    its sessions are done, then run this installer again."
        return 0
    fi
    SERVICE_OK=1
    # A unit that was already running read its environment when it started,
    # this run's or an earlier one's that had to wait. Restarting ends its
    # sessions, so it happens only when the daemon said it holds none.
    [ "$LISTENER_WANTED" = 1 ] || return 0
    wait_for_listener && return 0
    if port_taken; then
        say "    Another program is using 127.0.0.1:$PORT, so termiod can't listen there and"
        say "    nothing is published on the tailnet."
        LISTENER_WANTED=0
        URL=""
        return 0
    fi
    if [ "$(verified_live_sessions || echo unknown)" = 0 ]; then
        systemctl --user restart termiod.service
        wait_for_listener || say "    termiod didn't open its tailnet listener. See: termiod logs"
    else
        say "    The tailnet listener turns on at the daemon's next start. Restarting now"
        say "    would end its running sessions: systemctl --user restart termiod"
    fi
}

# Whether termiod itself is listening on 127.0.0.1:$PORT. The kernel's table
# names the listening socket's inode (address and port in hex, 0A is LISTEN),
# and the daemon's own descriptors must hold that inode: another program on
# the port must never be what Tailscale Serve publishes.
listening() {
    entry="0100007F:$(printf '%04X' "$PORT") 00000000:0000 0A"
    inode="$(grep "$entry" /proc/net/tcp 2>/dev/null | awk '{ print $10 }' | head -n1)"
    [ -n "$inode" ] || return 1
    pid="$(status_flat | sed -n 's/.*"daemon":{[^}]*"pid":\([0-9]*\).*/\1/p')"
    [ -n "$pid" ] || return 1
    ls -l "/proc/$pid/fd" 2>/dev/null | grep -q "socket:\[$inode\]"
}

# Something other than termiod listens on the port, on any address.
port_taken() {
    cat /proc/net/tcp /proc/net/tcp6 2>/dev/null |
        grep -q " [0-9A-F]*:$(printf '%04X' "$PORT") [0-9A-F]*:0000 0A" && ! listening
}

# A daemon that was just started binds its socket before its listener.
wait_for_listener() {
    tries=0
    while [ "$tries" -lt 10 ]; do
        listening && return 0
        tries=$((tries + 1))
        sleep 0.5
    done
    return 1
}

# Published only once termiod's own listener is confirmed: whatever else could
# be on that port must never reach the tailnet.
serve_on_tailnet() {
    [ -n "$URL" ] && [ "$SERVICE_OK" = 1 ] || return 0
    if ! listening; then
        say "    Nothing is published on the tailnet until termiod is listening. Run this"
        say "    installer again after the daemon restarts."
        return 0
    fi
    if ! tailscale serve --bg --https=443 "http://127.0.0.1:$PORT" >/dev/null 2>&1; then
        say "    Tailscale Serve needs permission. Run once:"
        say "      sudo tailscale serve --bg --https=443 http://127.0.0.1:$PORT"
        say "    or allow it for your user with: sudo tailscale set --operator=$(id -un)"
    fi
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
    DROPIN="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/termiod.service.d/override.conf"
    PORT=8790
    VERSION=""
    SERVICE=1
    TAILNET=1
    DRY_RUN=0
    URL=""
    LISTENER_CHANGED=0
    LISTENER_WANTED=0
    SERVICE_OK=0

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

    plan_tailnet
    keep_running
    serve_on_tailnet

    say ""
    say "termio $VERSION is installed: $TERMIOD"
    if [ -n "$URL" ] && [ "$SERVICE_OK" = 1 ] && listening; then
        say ""
        say "To use this machine from a Mac, open Settings > Remote Hosts > + > Pair with a Device..."
        say "and paste this link. Scan the code with the iPhone app to pair a phone."
        say ""
        "$TERMIOD" pair --url "$URL" --qr
    else
        say "A Mac can reach it over SSH: Settings > Remote Hosts > + > Add SSH Host..."
    fi
}

main "$@"
