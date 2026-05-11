#!/usr/bin/env bash
# install_panther.sh — One-command installer for the Panther-Veza OAA integration
#
# Usage (interactive — must run with sudo):
#   sudo bash install_panther.sh
#
# Usage (non-interactive / CI):
#   VEZA_URL=https://myco.veza.com \
#   VEZA_API_KEY=... \
#   PANTHER_BASE_URL=https://api.myco.runpanther.net \
#   PANTHER_TOKEN_URL=https://myco.auth.us-east-1.amazoncognito.com/oauth2/token \
#   PANTHER_CLIENT_ID=... \
#   PANTHER_CLIENT_SECRET=... \
#   PANTHER_SCOPE=panther:api \
#   sudo bash install_panther.sh --non-interactive
#
# Flags:
#   --non-interactive   Skip all prompts; read values from environment variables
#   --overwrite-env     Overwrite an existing .env file without asking
#   --install-dir <path>  Override the default install directory
#   --repo-url <url>    Override the GitHub repository URL
#   --branch <name>     Override the branch to clone from (default: main)

set -uo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
REPO_URL="${REPO_URL:-https://github.com/SmurfitWestrock/Panther-3250}"
BRANCH="${BRANCH:-main}"
INTEGRATION_SUBDIR="integrations/panther"
DEFAULT_INSTALL_DIR="/opt/VEZA/panther-veza"
SCRIPTS_DIR=""
LOGS_DIR=""
NON_INTERACTIVE=false
OVERWRITE_ENV=false

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

step() {
    local num="$1"; shift
    echo -e "\n${BOLD}━━━ Step ${num}: $* ━━━${NC}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=true ;;
        --overwrite-env)   OVERWRITE_ENV=true ;;
        --install-dir)     DEFAULT_INSTALL_DIR="$2"; shift ;;
        --repo-url)        REPO_URL="$2"; shift ;;
        --branch)          BRANCH="$2"; shift ;;
        *) warn "Unknown flag: $1" ;;
    esac
    shift
done

SCRIPTS_DIR="${DEFAULT_INSTALL_DIR}/scripts"
LOGS_DIR="${DEFAULT_INSTALL_DIR}/logs"

# ---------------------------------------------------------------------------
# Sudo / privilege check
# ---------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    die "This installer must be run with sudo:\n       sudo bash install_panther.sh"
fi

# Capture the real invoking user so ownership can be restored after root operations
REAL_USER="${SUDO_USER:-}"
if [[ -z "${REAL_USER}" ]]; then
    warn "SUDO_USER is not set — all created files will be owned by root"
else
    info "Running as root on behalf of: ${REAL_USER}"
fi

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
OS_ID=""
PKG_MGR=""

if [[ -f /etc/os-release ]]; then
    OS_ID=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
fi

if command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
elif command -v yum &>/dev/null; then
    PKG_MGR="yum"
elif command -v apt-get &>/dev/null; then
    PKG_MGR="apt-get"
else
    warn "Could not detect a supported package manager (dnf/yum/apt-get)."
    warn "You may need to install missing system packages manually."
fi

# ---------------------------------------------------------------------------
# Package installer helper — installs ONE package at a time with pre-check
# ---------------------------------------------------------------------------
_install_pkg() {
    local pkg="$1"
    info "Installing system package: ${pkg}"
    case "${PKG_MGR}" in
        dnf|yum) "${PKG_MGR}" install -y "${pkg}" >/dev/null 2>&1 || warn "Could not install ${pkg} — continuing" ;;
        apt-get) apt-get install -y "${pkg}" >/dev/null 2>&1 || warn "Could not install ${pkg} — continuing" ;;
        *) warn "No supported package manager found — skipping ${pkg}" ;;
    esac
}

# ---------------------------------------------------------------------------
# Step 1 — System prerequisites
# ---------------------------------------------------------------------------
step 1 "System prerequisites"

# git
if command -v git &>/dev/null; then
    success "git is present: $(git --version)"
else
    [[ -z "${PKG_MGR}" ]] && die "git is required but not installed and no package manager was detected."
    _install_pkg git
    command -v git &>/dev/null || die "git installation failed."
    success "git installed"
fi

# curl — skip on Amazon Linux if curl-minimal is present to avoid conflicts
if command -v curl &>/dev/null; then
    success "curl is present"
else
    if [[ "${OS_ID}" == "amzn" ]]; then
        warn "Skipping curl install on Amazon Linux (curl-minimal conflict)"
    else
        _install_pkg curl
        command -v curl &>/dev/null || warn "curl could not be installed — some checks may fail"
    fi
fi

# python3
if command -v python3 &>/dev/null; then
    success "python3 is present: $(python3 --version)"
else
    _install_pkg python3
    command -v python3 &>/dev/null || die "Python 3 is required but could not be installed."
fi

# pip3
if python3 -m pip --version &>/dev/null; then
    success "pip3 is present"
else
    case "${OS_ID}" in
        amzn) _install_pkg python3-pip ;;
        *) _install_pkg python3-pip ;;
    esac
fi

# venv support — python3-venv is not a separate package on Amazon Linux 2023 / RHEL 9+
if python3 -m venv --help &>/dev/null 2>&1; then
    success "python3 venv module available"
else
    case "${PKG_MGR}" in
        dnf|yum) _install_pkg python3-virtualenv ;;
        apt-get) _install_pkg python3-venv ;;
    esac
fi

# Python version check — require >= 3.9
PY_MAJOR=$(python3 -c "import sys; print(sys.version_info.major)")
PY_MINOR=$(python3 -c "import sys; print(sys.version_info.minor)")
if [[ "${PY_MAJOR}" -lt 3 ]] || { [[ "${PY_MAJOR}" -eq 3 ]] && [[ "${PY_MINOR}" -lt 9 ]]; }; then
    die "Python 3.9 or later is required (found Python ${PY_MAJOR}.${PY_MINOR})."
fi
success "Python version: ${PY_MAJOR}.${PY_MINOR}"

# ---------------------------------------------------------------------------
# Step 2 — Create directory layout
# ---------------------------------------------------------------------------
step 2 "Creating directory layout"

mkdir -p "${SCRIPTS_DIR}" "${LOGS_DIR}" \
    || die "Could not create directories under ${DEFAULT_INSTALL_DIR}"

# Restore ownership so the invoking user can read/write without sudo
if [[ -n "${REAL_USER}" ]]; then
    chown -R "${REAL_USER}:" "${DEFAULT_INSTALL_DIR}"
    chmod -R u+rwX "${DEFAULT_INSTALL_DIR}"
    success "Ownership of ${DEFAULT_INSTALL_DIR} transferred to ${REAL_USER}"
fi

success "Directories created"
info "  Scripts : ${SCRIPTS_DIR}"
info "  Logs    : ${LOGS_DIR}"

# ---------------------------------------------------------------------------
# Step 3 — Clone repository and copy integration files
# ---------------------------------------------------------------------------
step 3 "Cloning repository and copying integration files"

tmp_dir=$(mktemp -d)
info "Cloning ${REPO_URL} (branch: ${BRANCH}) ..."

GIT_TERMINAL_PROMPT=0 git clone \
    --branch "${BRANCH}" \
    --depth 1 \
    --single-branch \
    "${REPO_URL}" "${tmp_dir}" \
    || die "git clone failed — check that ${REPO_URL} is accessible."

src="${tmp_dir}/${INTEGRATION_SUBDIR}"
[[ -d "${src}" ]] || die "Integration sub-directory not found in cloned repo: ${src}"

cp -f "${src}/panther.py"        "${SCRIPTS_DIR}/"
cp -f "${src}/requirements.txt"  "${SCRIPTS_DIR}/"

if [[ -f "${src}/preflight_panther.sh" ]]; then
    cp -f "${src}/preflight_panther.sh" "${SCRIPTS_DIR}/"
    chmod +x "${SCRIPTS_DIR}/preflight_panther.sh"
fi

rm -rf "${tmp_dir}"
success "Files copied to ${SCRIPTS_DIR}"

# ---------------------------------------------------------------------------
# Step 4 — Python virtual environment and dependencies
# ---------------------------------------------------------------------------
step 4 "Setting up Python virtual environment"

VENV_DIR="${SCRIPTS_DIR}/venv"

if [[ -d "${VENV_DIR}" ]]; then
    info "Existing venv found at ${VENV_DIR} — reusing"
else
    python3 -m venv "${VENV_DIR}" || die "Failed to create virtual environment"
    success "Virtual environment created at ${VENV_DIR}"
fi

info "Installing Python dependencies from requirements.txt ..."
"${VENV_DIR}/bin/pip" install --quiet --upgrade pip
"${VENV_DIR}/bin/pip" install --quiet -r "${SCRIPTS_DIR}/requirements.txt" \
    || die "Failed to install dependencies"
success "Python dependencies installed"

# pip may create root-owned files inside the venv — restore ownership
if [[ -n "${REAL_USER}" ]]; then
    chown -R "${REAL_USER}:" "${SCRIPTS_DIR}"
fi

# ---------------------------------------------------------------------------
# Step 5 — Generate .env configuration file
# ---------------------------------------------------------------------------
step 5 "Generating .env configuration"

ENV_FILE="${SCRIPTS_DIR}/.env"

if [[ -f "${ENV_FILE}" ]] && [[ "${OVERWRITE_ENV}" == "false" ]]; then
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        warn ".env already exists — skipping (use --overwrite-env to replace)"
    else
        read -r -p ".env already exists. Overwrite? [y/N] " choice </dev/tty
        [[ "${choice,,}" == "y" ]] || { info "Keeping existing .env"; }
        [[ "${choice,,}" == "y" ]] && OVERWRITE_ENV=true
    fi
fi

if [[ ! -f "${ENV_FILE}" ]] || [[ "${OVERWRITE_ENV}" == "true" ]]; then
    # Collect values — from env vars (non-interactive) or interactive prompts
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        val_panther_base_url="${PANTHER_BASE_URL:-}"
        val_panther_token_url="${PANTHER_TOKEN_URL:-}"
        val_panther_client_id="${PANTHER_CLIENT_ID:-}"
        val_panther_client_secret="${PANTHER_CLIENT_SECRET:-}"
        val_panther_scope="${PANTHER_SCOPE:-}"
        val_veza_url="${VEZA_URL:-}"
        val_veza_api_key="${VEZA_API_KEY:-}"
    else
        echo ""
        info "Enter your Panther connection details (press Enter to skip optional fields):"
        IFS= read -r -p "  Panther API Base URL       : " val_panther_base_url </dev/tty
        IFS= read -r -p "  OAuth2 Token URL           : " val_panther_token_url </dev/tty
        IFS= read -r -p "  OAuth2 Client ID           : " val_panther_client_id </dev/tty
        IFS= read -r -s -p "  OAuth2 Client Secret       : " val_panther_client_secret </dev/tty
        echo >/dev/tty
        IFS= read -r -p "  OAuth2 Scope (optional)    : " val_panther_scope </dev/tty
        echo ""
        info "Enter your Veza connection details:"
        IFS= read -r -p "  Veza URL                   : " val_veza_url </dev/tty
        IFS= read -r -s -p "  Veza API Key               : " val_veza_api_key </dev/tty
        echo >/dev/tty
    fi

    cat > "${ENV_FILE}" <<EOF
# ============================================================
# Panther → Veza OAA Integration — Environment Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Permissions: 600 (this file contains secrets — do not commit)
# ============================================================

# ------------------------------------------------------------
# Panther OAuth2 Connection Settings
# ------------------------------------------------------------
# Base URL for the Panther REST API (v1 path is appended automatically)
PANTHER_BASE_URL=${val_panther_base_url}

# OAuth2 token endpoint (client credentials grant)
PANTHER_TOKEN_URL=${val_panther_token_url}

# OAuth2 client credentials
PANTHER_CLIENT_ID=${val_panther_client_id}
PANTHER_CLIENT_SECRET=${val_panther_client_secret}

# OAuth2 scope (leave empty if your IdP does not require a scope)
PANTHER_SCOPE=${val_panther_scope}

# ------------------------------------------------------------
# Veza Configuration
# ------------------------------------------------------------
VEZA_URL=${val_veza_url}
VEZA_API_KEY=${val_veza_api_key}

# ------------------------------------------------------------
# OAA Provider Settings (optional overrides)
# ------------------------------------------------------------
# PROVIDER_NAME=Panther
# DATASOURCE_NAME=panther-prod
EOF

    chmod 600 "${ENV_FILE}"
    # Ensure the .env file is owned by the invoking user, not root
    if [[ -n "${REAL_USER}" ]]; then
        chown "${REAL_USER}:" "${ENV_FILE}"
    fi
    success ".env file created at ${ENV_FILE} (permissions: 600, owner: ${REAL_USER:-root})"
fi

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
echo ""
# Final ownership pass — catch anything created by intermediate steps
if [[ -n "${REAL_USER}" ]]; then
    chown -R "${REAL_USER}:" "${DEFAULT_INSTALL_DIR}"
fi

echo -e "${BOLD}${GREEN}━━━ Installation Complete ━━━${NC}"
echo ""
echo "  Install directory : ${DEFAULT_INSTALL_DIR}"
echo "  Scripts           : ${SCRIPTS_DIR}"
echo "  Virtual env       : ${VENV_DIR}"
echo "  Environment file  : ${ENV_FILE}"
echo "  Log output        : ${LOGS_DIR}"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo ""
echo "  1. Review and complete the .env file:"
echo "       ${ENV_FILE}"
echo ""
echo "  2. Run a dry-run to validate connectivity and payload:"
echo "       cd ${SCRIPTS_DIR}"
echo "       source venv/bin/activate"
echo "       python3 panther.py --dry-run --save-json --log-level DEBUG"
echo ""
echo "  3. Once validated, run a live push:"
echo "       python3 panther.py --env-file .env"
echo ""
echo "  4. Schedule with cron (example — daily at 02:00 AM):"
echo "       crontab -e"
echo "       0 2 * * * ${SCRIPTS_DIR}/venv/bin/python3 ${SCRIPTS_DIR}/panther.py >> ${LOGS_DIR}/cron.log 2>&1"
echo ""
if [[ -n "${REAL_USER}" ]]; then
    echo "  All files are owned by: ${REAL_USER}"
fi
echo ""
