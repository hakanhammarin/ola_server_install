#!/usr/bin/env bash
#
# setup.sh — OLA server installer for Ubuntu 24.04 (with MySQL, lower_case_table_names=1)
#
# One-liner install:
#   wget https://raw.githubusercontent.com/hakanhammarin/ola_server_install/main/setup.sh && bash setup.sh
#
# What it does (automates TODO.md):
#   1. Installs extra tools (nano fio nginx openjdk-25-jdk smartmontools htop git python3 mysql-server)
#   2. git clones the OLA server modules (prefix: ola_server_) into the invoking user's $HOME
#   3. Deploys OLA65_w_mysql_class to /opt
#   4. Installs the ola10mila systemd autostart service
#   5. Runs the healthcheck installer
#   6. Re-initializes MySQL with lower_case_table_names=1 and sets a new root password
#   7. Runs the install_menu (for both the user and root)
#   8. Disables the desktop UI (boots to console) and ignores the physical power button
#   9. Shows the machine IP on the console at boot (no login required)
#  10. Reboots
#
# Re-runnable: most steps are idempotent. The MySQL re-init (step 6) is DESTRUCTIVE
# (it wipes /var/lib/mysql) and asks for confirmation.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
GITHUB_USER="hakanhammarin"
GITHUB_BASE="https://github.com/${GITHUB_USER}"
MODULE_PREFIX="ola_server_"

# Modules to clone. Repo = ${GITHUB_BASE}/${MODULE_PREFIX}<name>; cloned into $HOME/<name>
MODULES=(
  "OLA65_w_mysql_class"
  "ola_autostart"
  "healthcheck"
  "install_menu"
)

MYSQL_CNF="/etc/mysql/mysql.conf.d/mysqld.cnf"
MYSQL_DEFAULTS="/etc/mysql/my.cnf"
MYSQL_DATADIR="/var/lib/mysql"
MYSQL_ERRLOG="/var/log/mysql/error.log"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
C_INFO=$'\033[1;34m'; C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_RST=$'\033[0m'
log()  { printf '%s\n' "${C_INFO}==>${C_RST} $*"; }
ok()   { printf '%s\n' "${C_OK}  ✓${C_RST} $*"; }
warn() { printf '%s\n' "${C_WARN}  !${C_RST} $*" >&2; }
die()  { printf '%s\n' "${C_ERR}  ✗ $*${C_RST}" >&2; exit 1; }

confirm() {
  local prompt="${1:-Continue?}" reply
  read -r -p "${prompt} [y/N] " reply </dev/tty || true
  [[ "${reply}" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# 0. Preflight: root + identify the real (non-root) user and their home
# ---------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
  log "Re-running with sudo -i ..."
  exec sudo -E bash "$0" "$@"
fi

REAL_USER="${SUDO_USER:-${USER}}"
if [[ "${REAL_USER}" == "root" ]]; then
  warn "No non-root invoking user detected; falling back to 'root' for clone/menu steps."
  REAL_HOME="/root"
else
  REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"
fi
[[ -n "${REAL_HOME}" && -d "${REAL_HOME}" ]] || die "Could not resolve home directory for ${REAL_USER}"

# Run a command as the invoking user (preserving their environment/home)
as_user() { sudo -u "${REAL_USER}" -H bash -c "$*"; }

log "Installer running as root; modules go to ${REAL_HOME} (user: ${REAL_USER})"

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  [[ "${VERSION_ID:-}" == "24.04" ]] || warn "Expected Ubuntu 24.04, found ${PRETTY_NAME:-unknown}. Continuing anyway."
fi

# ---------------------------------------------------------------------------
# 1. Extra tools
# ---------------------------------------------------------------------------
log "Updating apt and installing extra tools"
export DEBIAN_FRONTEND=noninteractive

# Disable any CD-ROM apt source — on a server with no install media mounted it
# fails with "no longer has a Release file" and breaks apt-get update.
log "Disabling CD-ROM apt sources (if any)"
sed -i -E '/^[^#].*cdrom:/ s/^/# /' /etc/apt/sources.list 2>/dev/null || true
for f in /etc/apt/sources.list.d/*.list; do
  [[ -e "${f}" ]] || continue
  sed -i -E '/^[^#].*cdrom:/ s/^/# /' "${f}" 2>/dev/null || true
done
for f in /etc/apt/sources.list.d/*.sources; do
  [[ -e "${f}" ]] || continue
  if grep -qiE 'file:/+cdrom|cdrom:' "${f}"; then
    mv "${f}" "${f}.disabled" && warn "Disabled CD-ROM source: ${f}"
  fi
done

apt-get update -y || warn "apt-get update reported errors (continuing)"
apt-get install -y nano fio nginx smartmontools htop git python3 wget ca-certificates
ok "Base tools installed"

# Java — keep openjdk-25-jdk as requested, with an Adoptium (Temurin) fallback.
log "Installing Java (openjdk-25-jdk)"
if apt-get install -y openjdk-25-jdk; then
  ok "openjdk-25-jdk installed from Ubuntu repos"
else
  warn "openjdk-25-jdk not available in Ubuntu repos; trying Adoptium Temurin 25"
  install -d -m 0755 /etc/apt/keyrings
  wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public \
    | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg
  echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(. /etc/os-release && echo "${VERSION_CODENAME}") main" \
    > /etc/apt/sources.list.d/adoptium.list
  apt-get update -y
  if apt-get install -y temurin-25-jdk; then
    ok "temurin-25-jdk installed from Adoptium"
  else
    warn "Could not install JDK 25 from Adoptium either; falling back to openjdk-21-jdk"
    apt-get install -y openjdk-21-jdk && ok "openjdk-21-jdk installed (fallback)" \
      || warn "No JDK installed — install Java manually before running OLA"
  fi
fi

# MySQL server
log "Installing MySQL server"
apt-get install -y mysql-server
ok "mysql-server installed"

# ---------------------------------------------------------------------------
# 2. Clone modules into the invoking user's home
# ---------------------------------------------------------------------------
log "Cloning OLA server modules into ${REAL_HOME}"
for mod in "${MODULES[@]}"; do
  repo_url="${GITHUB_BASE}/${MODULE_PREFIX}${mod}.git"
  dest="${REAL_HOME}/${mod}"
  if [[ -d "${dest}/.git" ]]; then
    log "  ${mod}: already cloned, pulling latest"
    as_user "git -C '${dest}' pull --ff-only" || warn "  ${mod}: pull failed, using existing checkout"
  elif [[ -d "${dest}" ]] && [[ -n "$(ls -A "${dest}" 2>/dev/null)" ]]; then
    warn "  ${mod}: ${dest} already exists and is not a git checkout — using it as-is (skipping clone)"
  else
    log "  ${mod}: git clone ${repo_url}"
    as_user "git clone '${repo_url}' '${dest}'" \
      || die "Failed to clone ${repo_url} — does the repo '${MODULE_PREFIX}${mod}' exist?"
  fi
done
ok "Modules cloned"

# ---------------------------------------------------------------------------
# 3. Deploy OLA65_w_mysql_class to /opt
# ---------------------------------------------------------------------------
log "Deploying OLA65_w_mysql_class to /opt"
( cd "${REAL_HOME}/OLA65_w_mysql_class/" && cp -R . /opt/ )
ok "Copied OLA65_w_mysql_class -> /opt"

# ---------------------------------------------------------------------------
# 4. Autostart systemd service
# ---------------------------------------------------------------------------
log "Installing ola10mila autostart service"
SERVICE_SRC="${REAL_HOME}/ola_autostart/ola10mila.service"
[[ -f "${SERVICE_SRC}" ]] || die "Missing ${SERVICE_SRC}"
cp "${SERVICE_SRC}" /etc/systemd/system/
systemctl daemon-reload
systemctl enable ola10mila
ok "ola10mila service installed and enabled"

# ---------------------------------------------------------------------------
# 5. Healthcheck installer
# ---------------------------------------------------------------------------
log "Running healthcheck installer"
HEALTHCHECK_DIR="${REAL_HOME}/healthcheck"
if [[ -f "${HEALTHCHECK_DIR}/install.sh" ]]; then
  ( cd "${HEALTHCHECK_DIR}" && bash install.sh )
  ok "Healthcheck installed"
else
  warn "No ${HEALTHCHECK_DIR}/install.sh found — skipping"
fi

# ---------------------------------------------------------------------------
# 6. Re-initialize MySQL with lower_case_table_names=1  (DESTRUCTIVE)
# ---------------------------------------------------------------------------
log "MySQL: configuring lower_case_table_names=1 (requires a fresh data directory)"
warn "This step DELETES ${MYSQL_DATADIR} and re-initializes MySQL from scratch."
if confirm "Proceed with destructive MySQL re-initialization?"; then
  # Stop service
  systemctl stop mysql 2>/dev/null || service mysql stop 2>/dev/null || true

  # Wipe + recreate data dir (delete is not enough; the dir must be recreated empty)
  rm -rf "${MYSQL_DATADIR}"
  mkdir -p "${MYSQL_DATADIR}"
  chown mysql:mysql "${MYSQL_DATADIR}"
  chmod 700 "${MYSQL_DATADIR}"

  # Ensure lower_case_table_names = 1 in the [mysqld] section
  if grep -qE '^\s*lower_case_table_names' "${MYSQL_CNF}"; then
    sed -i -E 's/^\s*lower_case_table_names.*/lower_case_table_names = 1/' "${MYSQL_CNF}"
  else
    sed -i '/^\[mysqld\]/a lower_case_table_names = 1' "${MYSQL_CNF}"
  fi
  ok "lower_case_table_names = 1 set in ${MYSQL_CNF}"

  # Re-initialize (generates a temporary root password in the error log)
  rm -f "${MYSQL_ERRLOG}" 2>/dev/null || true
  log "Initializing MySQL data directory ..."
  mysqld --defaults-file="${MYSQL_DEFAULTS}" --initialize \
         --lower_case_table_names=1 --user=mysql --console || true

  # Start service
  systemctl start mysql 2>/dev/null || service mysql start

  # Retrieve the generated temporary password
  TEMP_PASS=""
  for _ in $(seq 1 10); do
    TEMP_PASS="$(grep 'temporary password' "${MYSQL_ERRLOG}" 2>/dev/null | tail -n1 | awk '{print $NF}')"
    [[ -n "${TEMP_PASS}" ]] && break
    sleep 1
  done

  # ---- Prompt for a new root password ----
  NEW_PASS=""; NEW_PASS2="x"
  while [[ "${NEW_PASS}" != "${NEW_PASS2}" || -z "${NEW_PASS}" ]]; do
    read -r -s -p "Enter NEW MySQL root password: " NEW_PASS </dev/tty; echo
    read -r -s -p "Confirm NEW MySQL root password: " NEW_PASS2 </dev/tty; echo
    [[ "${NEW_PASS}" == "${NEW_PASS2}" ]] || warn "Passwords do not match, try again."
  done

  if [[ -n "${TEMP_PASS}" ]]; then
    log "Setting new root password using the temporary password"
    mysql --connect-expired-password -u root -p"${TEMP_PASS}" \
      -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${NEW_PASS}';" \
      && ok "MySQL root password updated" \
      || warn "Automatic password change failed — run: sudo mysql -u root -p (temp pw: ${TEMP_PASS})"
  else
    warn "Could not find a temporary password in ${MYSQL_ERRLOG}."
    warn "MySQL may use auth_socket. Trying socket-based password change ..."
    mysql -u root \
      -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${NEW_PASS}';" \
      && ok "MySQL root password updated via auth_socket" \
      || warn "Set the root password manually: sudo mysql_secure_installation"
  fi

  # Verify lower_case_table_names
  log "Verifying lower_case_table_names setting"
  mysql -u root -p"${NEW_PASS}" -e "SHOW VARIABLES LIKE 'lower_case_%';" || \
    warn "Could not verify (check manually): SHOW VARIABLES LIKE 'lower_case_%';"
else
  warn "Skipped MySQL re-initialization. lower_case_table_names was NOT changed."
fi

# ---------------------------------------------------------------------------
# 7. install_menu — run for both the user and root
# ---------------------------------------------------------------------------
log "Running install_menu (setup.py) for user and root"
MENU_DIR="${REAL_HOME}/install_menu"
if [[ -f "${MENU_DIR}/setup.py" ]]; then
  log "  install_menu as ${REAL_USER}"
  as_user "cd '${MENU_DIR}' && python3 setup.py" || warn "  install_menu (user) returned non-zero"
  log "  install_menu as root"
  ( cd "${MENU_DIR}" && python3 setup.py ) || warn "  install_menu (root) returned non-zero"
  ok "install_menu completed"
else
  warn "No ${MENU_DIR}/setup.py found — skipping install_menu"
fi

# ---------------------------------------------------------------------------
# 8. Console-only mode + ignore the physical power button
# ---------------------------------------------------------------------------
log "Disabling desktop UI (boot to console)"
systemctl set-default multi-user.target
ok "Default boot target set to multi-user (console)"

# Disable any installed graphical display manager so the GUI does not start
for dm in gdm3 gdm lightdm sddm lxdm nodm; do
  if systemctl list-unit-files "${dm}.service" >/dev/null 2>&1 \
     && systemctl list-unit-files "${dm}.service" | grep -q "${dm}.service"; then
    systemctl disable --now "${dm}.service" 2>/dev/null && ok "Disabled display manager: ${dm}" || true
  fi
done

log "Ignoring the physical power button"
install -d -m 0755 /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/10-ola-power.conf <<'EOF'
# Installed by OLA setup.sh — do not power off the server from the chassis button.
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=ignore
EOF
# Apply now (also takes effect after the reboot at the end of this script)
systemctl restart systemd-logind 2>/dev/null || true
ok "Physical power button set to 'ignore'"

# ---------------------------------------------------------------------------
# 9. Show IP on the console at boot (no login required)
# ---------------------------------------------------------------------------
log "Configuring boot-time IP display on the console"
cat > /usr/local/bin/show-ip-on-console.sh <<'EOF'
#!/usr/bin/env bash
# Regenerate /etc/issue with hostname + current IPv4 addresses so they appear
# on the local console login screen without requiring a login.
{
  echo "Ubuntu \\n \\l"
  echo ""
  echo "Hostname: $(hostname)"
  echo "IP addresses:"
  ip -4 -brief address show scope global | awk '{printf "  %-10s %s\n", $1, $3}'
  echo ""
} > /etc/issue
EOF
chmod +x /usr/local/bin/show-ip-on-console.sh

cat > /etc/systemd/system/show-ip-on-console.service <<'EOF'
[Unit]
Description=Show host IP addresses on the console login screen
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/show-ip-on-console.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable show-ip-on-console.service
/usr/local/bin/show-ip-on-console.sh || true
ok "IP will be displayed on the console at boot"

# ---------------------------------------------------------------------------
# 10. Reboot
# ---------------------------------------------------------------------------
ok "Installation complete."
log "A reboot is required to finish setup."
if confirm "Reboot now?"; then
  reboot
else
  warn "Remember to reboot manually: sudo reboot"
fi
