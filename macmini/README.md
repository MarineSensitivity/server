# Mac mini modeling machine (`ssh macmini`)

Apple M4 Pro (8 performance + 4 efficiency cores), 48 GB, 512 GB internal, 2 TB external SSD.
It fits species distribution models; it does not serve anything and holds no AWS write keys
(the laptop stays the publish machine; results come back by `rsync` over Tailscale).

A wiped machine is rebuilt by rerunning these, in order:

| step | script | runs as | what |
|---|---|---|---|
| 0 | by hand, once | a person | Homebrew; Remote Login on; passwordless sudo for `bbest` (header of `setup_root.sh`); erase the external drive to APFS named `msens_big` (`diskutil eraseDisk APFS msens_big GPT <disk>`) |
| 1 | `setup_root.sh` | `sudo` | never sleep, restart after power loss, mount external volumes before login, one Tailscale (the Homebrew boot daemon) |
| 2 | `setup_user.sh` | `bbest` | `Brewfile`, `~/_big` -> `/Volumes/msens_big/_big`, `rio-cogeo`, repos under `~/Github` |
| 3 | `setup_r.sh` | `bbest` (calls sudo) | `rig`, R 4.6.1, Quarto, base R packages |

```bash
ssh macmini 'sudo bash -s' < macmini/setup_root.sh
ssh macmini 'bash -s'      < macmini/setup_user.sh
ssh macmini 'bash -s'      < macmini/setup_r.sh
```

## Gotchas

- **Exactly one Tailscale.** The Tailscale app (system extension) and the Homebrew `tailscaled`
  each register their own device (`bbests-mac-mini`, `bbest-macmini`). Running both, each steals
  the other's routes: `tailscale ping` answers while ssh times out (2026-10-04). Keep the
  Homebrew daemon (it starts at boot, before login); keep the app's device down and remove the
  app. If Tailscale is unreachable at home, the LAN address works: `ssh bbest@<lan ip>`.
- **Node key expiry.** Disable key expiry for `bbest-macmini` in the Tailscale admin console, or
  the machine drops off the tailnet after 180 days with nobody at the keyboard.
- **FileVault is off on purpose**: with it on, a reboot stops at the unlock screen and the
  machine is unreachable until someone types a password.
- **Long runs** go under `tmux` (or `nohup`) with a log and an exit-code file, never a bare ssh
  command: a dropped connection kills the run.
