#!/usr/bin/env bash
# mac mini modeling machine: the steps that need root. idempotent.
#   ssh macmini 'sudo bash -s' < macmini/setup_root.sh
# needs passwordless sudo for bbest (one-time, typed by a person):
#   echo "bbest ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/bbest && sudo chmod 440 /etc/sudoers.d/bbest
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "run with sudo" >&2; exit 1; }

BIG_VOL=${BIG_VOL:-/Volumes/msens_big}

# stay reachable: never sleep, come back after a power cut, wake on network ----
pmset -a sleep 0 disksleep 0 autorestart 1 womp 1 powernap 0

# remote login on ----
systemsetup -setremotelogin on >/dev/null 2>&1 || true

# mount external volumes at boot, before anyone logs in (default: only at login) ----
defaults write /Library/Preferences/SystemConfiguration/autodiskmount AutomountDisksWithoutUserLogin -bool true

# honour file ownership on the external volume ----
[ -d "$BIG_VOL" ] && diskutil enableOwnership "$BIG_VOL" || true

# tailscale: exactly ONE instance, the homebrew daemon, started at boot ----
# (the Tailscale.app system extension running beside it registers a second device and the two
#  steal each other's routes: tailscale ping answers, tcp times out. keep the app's device down
#  and remove the app from the machine by hand: drag it to the trash, approve the extension removal.)
if [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
  /Applications/Tailscale.app/Contents/MacOS/Tailscale down >/dev/null 2>&1 || true
fi
plist=/Library/LaunchDaemons/sh.brew.tailscale.plist
[ -f "$plist" ] || echo "WARN: $plist missing; run once: sudo brew services start tailscale, then tailscale up" >&2
pgrep -x tailscaled >/dev/null || launchctl kickstart -k system/sh.brew.tailscale || true

# report ----
pmset -g | grep -E " sleep|disksleep|autorestart|womp|powernap"
/opt/homebrew/bin/tailscale --socket=/var/run/tailscaled.socket status --peers=false || true
