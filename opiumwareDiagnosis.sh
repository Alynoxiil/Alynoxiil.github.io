#!/usr/bin/env bash
# ============================================================================
#  Opiumware self-test  —  is Opiumware working as intended?
#
#  ASSUMES: macOS (Apple Silicon), Roblox is OPEN and you are IN A GAME,
#           and the Opiumware app is open + logged in.
#
#  Runs five checks and prints a status list:
#     [ ] = not tested   [✔] = functional   [✘] = failed
#
#  It is read-only except for one tiny self-test file it writes into your own
#  Opiumware workspace and then deletes. It does not phone home.
# ============================================================================

# re-exec under bash if launched with sh/zsh (we need /dev/tcp)
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi

# ----- config ---------------------------------------------------------------
PORTS=(8390 8391 8392 8393 8394 8395 8396 8397)  # Opiumware exec range (0.737 uses 8390)
DECOMP_PORT=9002                                # Decompiler (a 2nd local svc)
TOKEN="OPIUMWARE_SELFTEST_OK"
WORKSPACE="$HOME/Opiumware/workspace"
TARGET="$WORKSPACE/opiumware_selftest.txt"

# The EXACT script sent to Opiumware — shown in plaintext so you can see what
# runs on your machine. It is zlib-compressed at run time, exactly as the
# Opiumware API does (Node Zlib.deflate), because the exec socket expects a
# zlib stream. Nothing hidden: this line is the entire payload.
CODE='OpiumwareScript writefile("opiumware_selftest.txt", "OPIUMWARE_SELFTEST_OK")'

# ----- tri-state results: "" untested / PASS / FAIL -------------------------
S_DYLIB=""; S_EXEC=""; S_WRITE=""; S_NET=""; S_PORT=""
DIAG=()

# ----- helpers --------------------------------------------------------------
# bounded runner (macOS has no `timeout` by default)
to() { local t="$1"; shift; "$@" & local p=$!
       ( sleep "$t"; kill -9 "$p" 2>/dev/null ) & local w=$!
       wait "$p" 2>/dev/null; local rc=$?
       kill -9 "$w" 2>/dev/null; wait "$w" 2>/dev/null; return $rc; }

connect_ok() { ( exec 3<>"/dev/tcp/$1/$2" ) >/dev/null 2>&1; }   # SYN a 127.0.0.1 port

# zlib-deflate stdin -> stdout (same wire format as the Opiumware API's Zlib.deflate)
zlib_deflate() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys,zlib; sys.stdout.buffer.write(zlib.compress(sys.stdin.buffer.read()))'
    else
        perl -MCompress::Zlib -e 'undef $/; print compress(<STDIN>);'
    fi
}
have_deflate() {
    command -v python3 >/dev/null 2>&1 && return 0
    command -v perl >/dev/null 2>&1 && perl -MCompress::Zlib -e1 >/dev/null 2>&1 && return 0
    return 1
}

# API pipeline: connect -> write zlib("OpiumwareScript ...") -> close (EOF)
send_payload() {
    exec 3<>"/dev/tcp/127.0.0.1/$1" 2>/dev/null || return 1
    printf '%s' "$CODE" | zlib_deflate >&3 2>/dev/null            # compress at run time
    exec 3>&- 3<&-                                                # close = FIN/EOF
}

mark() { case "$1" in PASS) printf '✔';; FAIL) printf '✘';; *) printf ' ';; esac; }

RENDERED=0
render() {
    # on a non-terminal (curl | bash) only draw the final list; on a TTY draw live
    if [ ! -t 1 ] && [ "${FINAL:-0}" != 1 ]; then return; fi
    if [ -t 1 ] && [ "$RENDERED" = 1 ]; then printf '\033[5A'; fi   # redraw in place
    printf '  [%s]  Opiumware dylib existence\n'            "$(mark "$S_DYLIB")"
    printf '  [%s]  Opiumware script execution\n'           "$(mark "$S_EXEC")"
    printf '  [%s]  Opiumware workspace filewrite\n'        "$(mark "$S_WRITE")"
    printf '  [%s]  Opiumware local network access\n'       "$(mark "$S_NET")"
    printf '  [%s]  Opiumware port listener availability\n' "$(mark "$S_PORT")"
    RENDERED=1
}

# ============================================================================
echo
echo "  Opiumware diagnosis tool"
echo "  (Roblox must be open and you must be IN A GAME)"
echo "  script sent to Opiumware:  $CODE"
echo
render

# ----- 1. dylib existence ---------------------------------------------------
DYLIB=""
for c in "/Applications/Roblox.app/Contents/Resources/libOpiumwareNative.dylib" \
         "$HOME/Applications/Roblox.app/Contents/Resources/libOpiumwareNative.dylib"; do
    [ -f "$c" ] && { DYLIB="$c"; break; }
done
if [ -n "$DYLIB" ]; then S_DYLIB=PASS
else S_DYLIB=FAIL; DIAG+=("dylib: libOpiumwareNative.dylib not found — Opiumware not installed, or Roblox auto-updated to a stock build (reinstall Opiumware)."); fi
render

# ----- 5. port listener availability (run early; execution depends on it) ---
PORT=""
for p in "${PORTS[@]}"; do
    if to 2 connect_ok 127.0.0.1 "$p"; then PORT="$p"; break; fi
done
if [ -n "$PORT" ]; then S_PORT=PASS
else S_PORT=FAIL; DIAG+=("ports: none of 8390-8397 are listening — the exec server binds only once you are IN A GAME. If you are in-game, Roblox may have auto-updated to a stock build (reinstall Opiumware)."); fi
render

# ----- 4. local network access (loopback path to an Opiumware service) ------
if [ -n "$PORT" ] && to 2 connect_ok 127.0.0.1 "$PORT"; then S_NET=PASS
elif to 2 connect_ok 127.0.0.1 "$DECOMP_PORT"; then S_NET=PASS
else S_NET=FAIL; DIAG+=("local network: could not open a 127.0.0.1 connection to any Opiumware service — a local firewall (LuLu / Little Snitch) may be blocking loopback."); fi
render

# ----- 2. script execution  +  3. workspace filewrite -----------------------
if [ -n "$PORT" ] && ! have_deflate; then
    DIAG+=("execution/filewrite: skipped — need python3 (or perl with Compress::Zlib) to zlib-compress the script the way the Opiumware API does. Install one and re-run.")
elif [ -n "$PORT" ]; then
    mkdir -p "$WORKSPACE" 2>/dev/null
    rm -f "$TARGET" 2>/dev/null
    to 5 send_payload "$PORT"
    for ((i=0; i<25; i++)); do [ -f "$TARGET" ] && break; sleep 0.2; done

    if [ -f "$TARGET" ]; then
        S_EXEC=PASS; render
        if [ "$(cat "$TARGET" 2>/dev/null)" = "$TOKEN" ]; then S_WRITE=PASS
        else S_WRITE=FAIL; DIAG+=("filewrite: script ran but the file content was wrong — writefile is misbehaving."); fi
    else
        S_EXEC=FAIL;  DIAG+=("execution: connected on port $PORT but no result landed — script was rejected (wrong build/version) or execution is disabled.")
        S_WRITE=FAIL; DIAG+=("filewrite: not reached — execution did not complete.")
    fi
    rm -f "$TARGET" 2>/dev/null
else
    :   # no port -> execution & filewrite remain untested ([ ])
fi
FINAL=1; render

# ----- diagnostics ----------------------------------------------------------
if [ "${#DIAG[@]}" -gt 0 ]; then
    echo
    echo "  notes:"
    for d in "${DIAG[@]}"; do echo "   - $d"; done
fi
echo
