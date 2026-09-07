#!/usr/bin/env bash
# ============================================================================
#  Opiumware (Intel / x86_64) — ADVANCED logged installer
#  Based on @norbyv1's official installer, hardened with:
#    * full timestamped transcript to ~/Opiumware/logs/install-<ts>.log
#    * per-step logging (every mv / inject / codesign is its own logged step)
#    * DOWNLOAD-AND-VERIFY-FIRST ordering: nothing is removed until every
#      asset is fetched AND integrity-checked, so a dead URL can never leave
#      you with a half-removed install (the original's biggest failure mode)
#    * a post-install verification pass (dylib arch, injection, codesign, modules)
#    * --dry-run / --force / --no-launch / --keep-temp
#
#  Usage:
#    bash opiumware-install-intel-advanced.sh [--dry-run] [--force]
#                                             [--no-launch] [--keep-temp]
#  Made by alynoxiil and claude - with love
# ============================================================================
set -euo pipefail

# ----- args -----------------------------------------------------------------
DRY_RUN=0; FORCE=0; LAUNCH=1; KEEP_TEMP=0
for a in "$@"; do
    case "$a" in
        --dry-run)   DRY_RUN=1 ;;
        --force)     FORCE=1 ;;
        --no-launch) LAUNCH=0 ;;
        --keep-temp) KEEP_TEMP=1 ;;
        -h|--help)   grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $a" >&2; exit 2 ;;
    esac
done

# ----- asset sources (INTERCHANGEABLE) --------------------------------------
# These links rotate/expire. Each can be overridden WITHOUT editing this file,
# via an environment variable, e.g.:
#     DYLIB_URL="https://.../new" UI_URL="https://.../new" \
#         bash opiumware-install-intel-advanced.sh
#     OPIUMWARE_VERSION="version-xxxx" bash opiumware-install-intel-advanced.sh
# The effective URLs are recorded in the log so a rotated link is traceable.
VERSION="${OPIUMWARE_VERSION:-version-2a3a7efa1a934799}"
ROBLOX_URL="${ROBLOX_URL:-https://setup.rbxcdn.com/mac/${VERSION}-RobloxPlayer.zip}"
DYLIB_URL="${DYLIB_URL:-https://anc4cpypjs.ufs.sh/f/fuloy9zwEAJtAjK4o1OYAO54X3SkDGKqPbtUQWNrjwxuZdF8}"
MODULES_URL="${MODULES_URL:-https://anc4cpypjs.ufs.sh/f/fuloy9zwEAJttWYtKgNokjGhinW70dSALrVy1Ugmuf3b628T}"
UI_URL="${UI_URL:-https://anc4cpypjs.ufs.sh/f/fuloy9zwEAJtvE7eVgbncYl7dhxBGyMKF3U4o50piQgtJDnX}"

# ----- logging --------------------------------------------------------------
LOG_DIR="$HOME/Opiumware/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
# full transcript: everything below (echo + every command's stdout/stderr) is tee'd
exec > >(tee -a "$LOG_FILE") 2>&1

ts()   { date '+%Y-%m-%d %H:%M:%S'; }
line() { printf '%s [%-5s] %s\n' "$(ts)" "$1" "$2"; }
info() { line INFO  "$*"; }
step() { line STEP  "$*"; }
ok()   { line OK    "$*"; }
warn() { line WARN  "$*"; }
err()  { line ERROR "$*"; }

START_EPOCH=$(date +%s)

# run a single step: log it, run it (output flows to the transcript), tag OK/ERROR
run() {
    local desc="$1"; shift
    step "$desc"
    line CMD   "$*"
    if "$@"; then ok "$desc"; return 0
    else local rc=$?; err "$desc  (exit $rc)"; return $rc; fi
}

# ----- traps ----------------------------------------------------------------
cleanup() { [ "$KEEP_TEMP" = 1 ] || { [ -n "${TEMP:-}" ] && rm -rf "$TEMP" 2>/dev/null; }; }
on_err()  { local rc=$?; err "ABORTED at line $1: [$BASH_COMMAND] (exit $rc)";
            err "Full log: $LOG_FILE"; exit "$rc"; }
# deliberate, clean stop (a refusal, not a crash) — disables the ERR trap first
die()     { err "$*"; err "Full log: $LOG_FILE"; trap - ERR; exit 1; }
trap 'on_err $LINENO' ERR
trap cleanup EXIT

# ============================================================================
info "Opiumware Intel advanced installer starting"
info "log file: $LOG_FILE"
[ "$DRY_RUN" = 1 ] && warn "DRY-RUN: will download + verify only, nothing will be installed"

# ----- environment capture --------------------------------------------------
step "Environment"
info "  date        : $(ts)"
info "  user        : $(whoami)"
info "  macOS       : $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
info "  uname       : $(uname -a)"
info "  arch        : $(uname -m)"
info "  cpu         : $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '?')"
info "  curl        : $(curl --version 2>/dev/null | head -1)"
info "  free space  : $(df -h /Applications 2>/dev/null | awk 'NR==2{print $4" on "$9}')"

# ----- arch guard -----------------------------------------------------------
ARCH="$(uname -m)"
if [ "$ARCH" != "x86_64" ]; then
    if [ "$FORCE" = 1 ]; then
        warn "arch is '$ARCH', not x86_64 — proceeding anyway (--force). The Intel dylib is x86_64; this is unsupported on Apple Silicon."
    else
        err "This is the INTEL (x86_64) installer but this Mac reports '$ARCH'."
        die "On Apple Silicon use the arm64 installer instead. Override with --force if you know what you're doing."
    fi
fi

# ----- install location -----------------------------------------------------
if [ -w "/Applications" ]; then APP_DIR="/Applications"; info "install target: /Applications"
else APP_DIR="$HOME/Applications"; mkdir -p "$APP_DIR"; warn "no write to /Applications — using $APP_DIR"; fi
ROBLOX_APP="$APP_DIR/Roblox.app"
OPIUM_APP="$APP_DIR/Opiumware.app"

# ----- asset sources (logged so rotated links stay traceable) ---------------
step "Asset sources (interchangeable — override via env vars)"
info "  ROBLOX_URL  = $ROBLOX_URL"
info "  DYLIB_URL   = $DYLIB_URL"
info "  MODULES_URL = $MODULES_URL"
info "  UI_URL      = $UI_URL"
info "  VERSION     = $VERSION"

TEMP="$(mktemp -d)"
info "temp dir: $TEMP"

# ----------------------------------------------------------------------------
# PHASE 1 — download every asset FIRST (nothing destructive yet)
# ----------------------------------------------------------------------------
step "PHASE 1 — downloading all assets (nothing is removed yet)"

download() { # url out label
    local url="$1" out="$2" label="$3"
    step "download: $label"
    line CMD "curl -fSL $url -> $out"
    local stats
    stats=$(curl -fSL --retry 3 --retry-delay 2 -o "$out" \
        -w 'http=%{http_code} bytes=%{size_download} time=%{time_total}s speed=%{speed_download}B/s' \
        "$url") || { err "download failed: $label"; return 1; }
    info "  curl: $stats"
    info "  size: $(stat -f%z "$out" 2>/dev/null || echo '?') bytes"
    info "  sha256: $(shasum -a 256 "$out" | cut -d' ' -f1)"
    ok "download: $label"
}

download "$ROBLOX_URL"  "$TEMP/RobloxPlayer.zip" "Roblox client ($VERSION)"
download "$DYLIB_URL"   "$TEMP/lib.zip"          "Opiumware dylib"
download "$MODULES_URL" "$TEMP/modules.zip"      "modules (Injector/Decompiler/LuauLSP)"
download "$UI_URL"      "$TEMP/ui.zip"           "Opiumware.app UI"

# ----------------------------------------------------------------------------
# PHASE 2 — verify every archive BEFORE touching the existing install
# ----------------------------------------------------------------------------
step "PHASE 2 — verifying archives + expected contents"

verify_zip() { # zip label
    step "verify: $2"
    line CMD "unzip -tqq $1"
    unzip -tqq "$1" >/dev/null || { err "corrupt archive: $2 (not a valid zip)"; return 1; }
    ok "verify: $2 (archive intact)"
}
verify_zip "$TEMP/RobloxPlayer.zip" "Roblox client"
verify_zip "$TEMP/lib.zip"          "dylib"
verify_zip "$TEMP/modules.zip"      "modules"
verify_zip "$TEMP/ui.zip"           "UI"

step "extracting into temp"
run "extract Roblox"  unzip -oq "$TEMP/RobloxPlayer.zip" -d "$TEMP"
run "extract dylib"   unzip -oq "$TEMP/lib.zip"          -d "$TEMP"
run "extract modules" unzip -oq "$TEMP/modules.zip"      -d "$TEMP"
run "extract UI"      unzip -oq "$TEMP/ui.zip"           -d "$TEMP"

step "checking expected payload files exist"
need() { if [ -e "$1" ]; then info "  present: ${1#$TEMP/}"; else err "MISSING from download: ${1#$TEMP/}"; return 1; fi; }
need "$TEMP/RobloxPlayer.app"
need "$TEMP/libOpiumware.dylib"
need "$TEMP/Resources/Injector"
need "$TEMP/Resources/Decompiler"
need "$TEMP/Resources/LuauLSP"
need "$TEMP/Opiumware.app"
ok "all expected payloads verified"

if [ "$DRY_RUN" = 1 ]; then
    warn "DRY-RUN complete — assets are valid. Nothing was installed."
    info "elapsed: $(( $(date +%s) - START_EPOCH ))s   log: $LOG_FILE"
    exit 0
fi

# ----------------------------------------------------------------------------
# PHASE 3 — stop running processes
# ----------------------------------------------------------------------------
step "PHASE 3 — stopping running processes"
run "kill Decompiler on :9002" bash -c 'kill -9 $(lsof -ti :9002) 2>/dev/null || true'
run "kill RobloxPlayer/Opiumware" bash -c 'killall -9 RobloxPlayer Opiumware 2>/dev/null || true'

# ----------------------------------------------------------------------------
# PHASE 4 — back up + remove old installs (assets already verified above)
# ----------------------------------------------------------------------------
step "PHASE 4 — backing up + removing old installs"
BACKUP_DIR="$LOG_DIR/backup-$(date +%Y%m%d-%H%M%S)"
if [ -e "$OPIUM_APP" ]; then
    mkdir -p "$BACKUP_DIR"
    run "back up existing Opiumware.app -> $BACKUP_DIR" cp -R "$OPIUM_APP" "$BACKUP_DIR/Opiumware.app"
else info "  no existing Opiumware.app to back up"; fi

remove_app() { # path
    [ -e "$1" ] || { info "  not present: $1"; return 0; }
    step "remove $(basename "$1")"
    rm -rf "$1" 2>/dev/null || true
    if [ -e "$1" ]; then warn "  normal remove failed, trying sudo"; sudo rm -rf "$1" 2>/dev/null || true; fi
    [ -e "$1" ] && { err "could not remove $1 — delete it manually and re-run"; return 1; }
    ok "removed $(basename "$1")"
}
remove_app "$ROBLOX_APP"
remove_app "$OPIUM_APP"

# Stale modules: the original does `rm -rf ~/Opiumware/modules/{LuauLSP,decompiler}`,
# an unconditional recursive delete that can break (a still-running / watchdog-
# respawned Decompiler holding files, or nuking more than intended). We do it
# MANUALLY and safely instead: back up + remove ONLY the two known binaries, never
# recurse a directory, and never abort the install if a removal fails — Phase 5's
# `mv -f` overwrites them regardless.
step "clear stale module binaries (targeted, non-fatal — no recursive wipe)"
mkdir -p "$BACKUP_DIR" 2>/dev/null || true
for m in "modules/decompiler/Decompiler" "modules/LuauLSP/LuauLSP"; do
    src="$HOME/Opiumware/$m"
    if [ -e "$src" ]; then
        mkdir -p "$BACKUP_DIR/$(dirname "$m")" 2>/dev/null || true
        cp -f "$src" "$BACKUP_DIR/$m" 2>/dev/null && info "  backed up  $m -> $BACKUP_DIR/$m" || warn "  could not back up $m"
        rm -f "$src" 2>/dev/null && ok "  removed stale $m" || warn "  could not remove stale $m (mv -f will overwrite it)"
    else
        info "  not present: $m"
    fi
done
rm -f "$HOME/Opiumware/modules/update.json" 2>/dev/null || true
info "  left ~/Opiumware/modules/ directory tree intact (no rm -rf)"

# ----------------------------------------------------------------------------
# PHASE 5 — install (each step logged individually)
# ----------------------------------------------------------------------------
step "PHASE 5 — installing"
MIMALLOC="$ROBLOX_APP/Contents/MacOS/libmimalloc.3.dylib"
DYLIB_DEST="$ROBLOX_APP/Contents/Resources/libOpiumware.dylib"

run "place Roblox.app"                 mv "$TEMP/RobloxPlayer.app" "$ROBLOX_APP"
run "clear quarantine xattrs"          xattr -cr "$ROBLOX_APP"
run "strip Roblox code signature"      codesign --remove-signature "$ROBLOX_APP/Contents/MacOS/RobloxPlayer"
run "place executor dylib"             mv "$TEMP/libOpiumware.dylib" "$DYLIB_DEST"
run "inject dylib into libmimalloc"    "$TEMP/Resources/Injector" "$DYLIB_DEST" "$MIMALLOC" --strip-codesig --all-yes

step "confirm injector produced patched libmimalloc"
[ -f "${MIMALLOC}_patched" ] || die "injector did not produce ${MIMALLOC}_patched — injection failed"
ok "patched libmimalloc present"

run "swap in patched libmimalloc"      mv -f "${MIMALLOC}_patched" "$MIMALLOC"
run "remove RobloxPlayerInstaller.app" rm -rf "$ROBLOX_APP/Contents/MacOS/RobloxPlayerInstaller.app"
run "remove RobloxMenuBar.app"         rm -rf "$ROBLOX_APP/Contents/MacOS/RobloxMenuBar.app"
run "codesign Roblox.app (adhoc,deep)" codesign --force --deep --sign - "$ROBLOX_APP"
run "place Opiumware.app"              mv -f "$TEMP/Opiumware.app" "$OPIUM_APP"
run "codesign Opiumware.app"           codesign --force --deep --sign - "$OPIUM_APP"
run "create ~/Opiumware directories"   bash -c 'mkdir -p ~/Opiumware/{workspace,autoexec,themes,modules} ~/Opiumware/modules/{decompiler,LuauLSP}'
run "install Decompiler module"        mv -f "$TEMP/Resources/Decompiler" "$HOME/Opiumware/modules/decompiler/Decompiler"
run "install LuauLSP module"           mv -f "$TEMP/Resources/LuauLSP" "$HOME/Opiumware/modules/LuauLSP/LuauLSP"

# ----------------------------------------------------------------------------
# PHASE 6 — post-install verification
# ----------------------------------------------------------------------------
step "PHASE 6 — verifying the installed result"
V_OK=1
vcheck() { if eval "$2" >/dev/null 2>&1; then ok "verify: $1"; else err "verify: $1  <-- FAILED"; V_OK=0; fi; }

vcheck "executor dylib present"          "[ -f '$DYLIB_DEST' ]"
info  "  dylib arch: $(lipo -archs "$DYLIB_DEST" 2>/dev/null || file "$DYLIB_DEST")"
vcheck "dylib is x86_64"                 "lipo -archs '$DYLIB_DEST' | grep -q x86_64"
vcheck "libmimalloc loads the dylib"     "otool -L '$MIMALLOC' | grep -qi 'libOpiumware.dylib'"
vcheck "Roblox.app codesign valid"       "codesign --verify --deep '$ROBLOX_APP'"
vcheck "Opiumware.app codesign valid"    "codesign --verify --deep '$OPIUM_APP'"
vcheck "Decompiler module installed"     "[ -f \"$HOME/Opiumware/modules/decompiler/Decompiler\" ]"
vcheck "LuauLSP module installed"        "[ -f \"$HOME/Opiumware/modules/LuauLSP/LuauLSP\" ]"

# ----------------------------------------------------------------------------
# summary
# ----------------------------------------------------------------------------
ELAPSED=$(( $(date +%s) - START_EPOCH ))
echo
if [ "$V_OK" = 1 ]; then
    ok "INSTALL COMPLETE — all verification checks passed (${ELAPSED}s)"
else
    warn "INSTALL FINISHED WITH WARNINGS — one or more verification checks failed (${ELAPSED}s)"
    warn "review the log before launching: $LOG_FILE"
fi
info "log saved to: $LOG_FILE"
[ -d "${BACKUP_DIR:-/nonexistent}" ] && info "previous Opiumware.app backed up at: $BACKUP_DIR"

if [ "$LAUNCH" = 1 ] && [ "$V_OK" = 1 ]; then
    run "launch Roblox.app"    open "$ROBLOX_APP"
    run "launch Opiumware.app" open "$OPIUM_APP"
else
    info "not launching (either --no-launch or verification failed). Launch manually when ready."
fi
