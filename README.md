# OLA server installer — Ubuntu 24.04 (with MySQL)

Automated installer for an OLA server on **Ubuntu 24.04 LTS**, including a MySQL
setup configured with `lower_case_table_names = 1`.

## Quick start

```bash
wget https://raw.githubusercontent.com/hakanhammarin/ola_server_install/main/setup.sh && bash setup.sh
```

The script re-launches itself with `sudo` if needed, so you can run it as a normal user.

## Prerequisites

- Ubuntu **24.04 LTS** (the script warns but still runs on other versions).
- A **non-root user** with `sudo` rights — modules are cloned into that user's `$HOME`.
- **Internet access** to GitHub and the Ubuntu/Adoptium apt repositories.
- The four module repos must exist on GitHub (see below). Until they do, the
  clone step aborts with a clear message naming the missing repo.

## What it installs

**Packages:** `nano fio nginx smartmontools htop git python3 wget` · `openjdk-25-jdk`
(falls back to Adoptium Temurin 25, then `openjdk-21-jdk`, if unavailable) · `mysql-server`.

**Modules** — cloned as `ola_server_<name>` into `$HOME/<name>`:

| Repo | Cloned to | Used for |
|------|-----------|----------|
| `ola_server_OLA65_w_mysql_class` | `~/OLA65_w_mysql_class` | copied into `/opt` |
| `ola_server_ola_autostart` | `~/ola_autostart` | `ola10mila.service` → systemd, enabled |
| `ola_server_healthcheck` | `~/healthcheck` | runs `install.sh` |
| `ola_server_install_menu` | `~/install_menu` | runs `setup.py` (as user **and** root) |

## Steps performed

1. Install extra tools, Java, and MySQL.
2. `git clone` the four modules into the invoking user's home.
3. Copy `OLA65_w_mysql_class` into `/opt`.
4. Install + enable the `ola10mila` systemd autostart service.
5. Run the healthcheck installer.
6. **Re-initialize MySQL** with `lower_case_table_names = 1`, then set a new root
   password and verify the setting.
7. Run `install_menu/setup.py` for the user and for root.
8. Switch to **console-only** (`multi-user.target`, disable the display manager) and
   set the **physical power button to `ignore`** so it can't power off the server.
9. Show the host IP on the console login screen at boot (no login required).
10. Reboot.

## ⚠️ Destructive step

Step 6 **deletes `/var/lib/mysql`** and re-initializes MySQL from scratch — this is
required to enable `lower_case_table_names=1` on an existing install. It is gated
behind a `y/N` prompt. **Back up any existing databases first.** During this step
you will be prompted to enter a new MySQL `root` password.

The final reboot is also confirmation-gated.

## Configuration

Edit the variables at the top of `setup.sh` to change defaults:

- `GITHUB_USER` / `GITHUB_BASE` — source GitHub account.
- `MODULE_PREFIX` — repo name prefix (`ola_server_`).
- `MODULES` — the list of modules to clone.

## Re-running

The script is re-runnable: existing clones are `git pull`ed, packages already
installed are skipped, and the MySQL re-init / reboot both ask before acting.

## Notes

- `openjdk-25-jdk` is not in the default Ubuntu 24.04 repositories; the script
  attempts it first (as configured), then Adoptium Temurin 25, then `openjdk-21-jdk`.
- Boot-time IP display is implemented via `/usr/local/bin/show-ip-on-console.sh`
  and the `show-ip-on-console.service` systemd unit, which writes the hostname and
  IPv4 addresses to `/etc/issue`.
- Console-only mode uses `systemctl set-default multi-user.target` and disables any
  installed display manager (`gdm3`/`gdm`/`lightdm`/`sddm`/`lxdm`/`nodm`). The desktop
  packages are left installed — re-enable the GUI with
  `sudo systemctl set-default graphical.target`.
- The power button is disabled via a drop-in at
  `/etc/systemd/logind.conf.d/10-ola-power.conf` (`HandlePowerKey=ignore`,
  `HandlePowerKeyLongPress=ignore`). The machine can still be shut down with
  `sudo poweroff` / `sudo shutdown`.
