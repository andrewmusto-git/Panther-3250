#!/usr/bin/env bash
# preflight_panther.sh — Pre-deployment validation for the Panther-Veza OAA connector
#
# Usage:
#   bash preflight_panther.sh          # interactive menu
#   bash preflight_panther.sh --all    # run all checks non-interactively
#
# Flags:
#   --all   Run all checks and exit 0 (all pass) or 1 (any failure)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/preflight_$(date +%Y%m%d_%H%M%S).log"
ENV_FILE="${SCRIPT_DIR}/.env"

# ---------------------------------------------------------------------------
# Colors and counters
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_WARNING=0

print_success() { echo -e "${GREEN}✓${NC} $1" | tee -a "${LOG_FILE}"; ((TESTS_PASSED++)); }
print_fail()    { echo -e "${RED}✗${NC} $1"   | tee -a "${LOG_FILE}"; ((TESTS_FAILED++)); }
print_warning() { echo -e "${YELLOW}⚠${NC} $1" | tee -a "${LOG_FILE}"; ((TESTS_WARNING++)); }
print_info()    { echo -e "${BLUE}ℹ${NC} $1"   | tee -a "${LOG_FILE}"; }
print_header()  { echo -e "\n${BOLD}━━━ $1 ━━━${NC}" | tee -a "${LOG_FILE}"; }
print_debug()   { echo -e "  [DEBUG] $1" | tee -a "${LOG_FILE}"; }

# ---------------------------------------------------------------------------
# Section 1 — System Requirements
# ---------------------------------------------------------------------------
check_system_requirements() {
    print_header "1. System Requirements"

    # Python version — require >= 3.9
    if command -v python3 &>/dev/null; then
        PY_VER=$(python3 --version 2>&1 | awk '{print $2}')
        PY_MAJOR=$(echo "${PY_VER}" | cut -d. -f1)
        PY_MINOR=$(echo "${PY_VER}" | cut -d. -f2)
        if [[ "${PY_MAJOR}" -ge 3 ]] && [[ "${PY_MINOR}" -ge 9 ]]; then
            print_success "Python ${PY_VER} (>= 3.9 required)"
        else
            print_fail "Python ${PY_VER} found — 3.9 or later is required"
        fi
    else
        print_fail "python3 not found"
    fi

    # pip3
    if python3 -m pip --version &>/dev/null 2>&1; then
        PIP_VER=$(python3 -m pip --version 2>&1 | awk '{print $2}')
        print_success "pip3 ${PIP_VER}"
    else
        print_fail "pip3 not available (python3 -m pip failed)"
    fi

    # Virtual environment detection
    if [[ -n "${VIRTUAL_ENV:-}" ]]; then
        print_success "Running inside virtual environment: ${VIRTUAL_ENV}"
    elif [[ -d "${SCRIPT_DIR}/venv" ]]; then
        print_info "Local venv found at ${SCRIPT_DIR}/venv (not activated)"
    else
        print_warning "Not running inside a virtual environment — recommended to activate venv first"
    fi

    # OS detection
    if [[ -f /etc/os-release ]]; then
        OS_NAME=$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
        print_info "OS: ${OS_NAME}"
    elif [[ "$(uname)" == "Darwin" ]]; then
        print_info "OS: macOS $(sw_vers -productVersion)"
    else
        print_info "OS: unknown"
    fi

    # curl
    if command -v curl &>/dev/null; then
        print_success "curl: $(curl --version | head -1)"
    else
        print_fail "curl not found — required for API authentication tests"
    fi

    # jq (optional)
    if command -v jq &>/dev/null; then
        print_success "jq: $(jq --version)"
    else
        print_warning "jq not found (optional — install with: dnf install jq  or  apt-get install jq)"
    fi
}

# ---------------------------------------------------------------------------
# Section 2 — Python Dependencies
# ---------------------------------------------------------------------------
check_python_dependencies() {
    print_header "2. Python Dependencies"

    # Prefer local venv python
    if [[ -x "${SCRIPT_DIR}/venv/bin/python3" ]]; then
        PYTHON="${SCRIPT_DIR}/venv/bin/python3"
        print_info "Using venv python: ${PYTHON}"
    else
        PYTHON="python3"
        print_info "Using system python: $(command -v python3)"
    fi

    REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements.txt"
    if [[ ! -f "${REQUIREMENTS_FILE}" ]]; then
        print_fail "requirements.txt not found at ${REQUIREMENTS_FILE}"
        return
    fi

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Strip comments and blank lines
        pkg=$(echo "${line}" | sed 's/#.*//' | tr -d '[:space:]')
        [[ -z "${pkg}" ]] && continue

        # Extract the bare package name for import testing
        pkg_name=$(echo "${pkg}" | sed 's/[><=!].*//' | tr -d '[:space:]')
        # Map install name → import name for known divergences
        case "${pkg_name}" in
            python-dotenv)  import_name="dotenv" ;;
            oaaclient)      import_name="oaaclient" ;;
            urllib3)        import_name="urllib3" ;;
            *)              import_name="${pkg_name//-/_}" ;;
        esac

        if "${PYTHON}" -c "import ${import_name}" 2>/dev/null; then
            pkg_ver=$("${PYTHON}" -c "import ${import_name}; v=getattr(${import_name},'__version__',None) or getattr(${import_name},'VERSION','unknown'); print(v)" 2>/dev/null || echo "unknown")
            print_success "${pkg_name} (${pkg_ver})"
        else
            print_fail "${pkg_name} not importable — run: ${SCRIPT_DIR}/venv/bin/pip install -r requirements.txt"
        fi
    done < "${REQUIREMENTS_FILE}"
}

# ---------------------------------------------------------------------------
# Section 3 — Configuration File
# ---------------------------------------------------------------------------
check_configuration() {
    print_header "3. Configuration File"

    if [[ ! -f "${ENV_FILE}" ]]; then
        print_fail ".env not found at ${ENV_FILE} — copy .env.example and populate values"
        return
    fi
    print_success ".env file exists: ${ENV_FILE}"

    # Check file permissions — must be 600
    if [[ "$(uname)" == "Linux" ]]; then
        perms=$(stat -c "%a" "${ENV_FILE}" 2>/dev/null || echo "unknown")
    else
        perms=$(stat -f "%A" "${ENV_FILE}" 2>/dev/null || echo "unknown")
    fi

    if [[ "${perms}" == "600" ]]; then
        print_success ".env permissions: 600"
    else
        print_warning ".env permissions: ${perms} — should be 600. Fix: chmod 600 ${ENV_FILE}"
    fi

    # Source .env and validate required variables
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}" 2>/dev/null || true
    set +a

    _check_env_var() {
        local var_name="$1"
        local is_secret="${2:-false}"
        local val="${!var_name:-}"

        if [[ -z "${val}" ]]; then
            print_fail "${var_name} is not set"
        elif echo "${val}" | grep -qiE '^(your_|https://your-)'; then
            print_fail "${var_name} still contains placeholder value: ${val}"
        else
            if [[ "${is_secret}" == "true" ]]; then
                masked="${val:0:8}..."
                print_success "${var_name}=${masked}  (masked)"
            else
                print_success "${var_name}=${val}"
            fi
        fi
    }

    _check_env_var "PANTHER_BASE_URL"
    _check_env_var "PANTHER_TOKEN_URL"
    _check_env_var "PANTHER_CLIENT_ID"    "true"
    _check_env_var "PANTHER_CLIENT_SECRET" "true"

    # PANTHER_SCOPE is optional
    if [[ -n "${PANTHER_SCOPE:-}" ]]; then
        print_success "PANTHER_SCOPE=${PANTHER_SCOPE}"
    else
        print_info "PANTHER_SCOPE is empty (optional — OK if your IdP does not require a scope)"
    fi

    _check_env_var "VEZA_URL"
    _check_env_var "VEZA_API_KEY"         "true"
}

# ---------------------------------------------------------------------------
# Section 4 — Network Connectivity
# ---------------------------------------------------------------------------
check_network_connectivity() {
    print_header "4. Network Connectivity"

    set -a
    [[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}" 2>/dev/null || true
    set +a

    _tcp_check() {
        local label="$1"
        local host="$2"
        local port="${3:-443}"
        print_debug "TCP check: ${host}:${port}"
        if command -v nc &>/dev/null; then
            if nc -zw 5 "${host}" "${port}" 2>/dev/null; then
                print_success "TCP ${label} (${host}:${port}) — reachable"
            else
                print_fail "TCP ${label} (${host}:${port}) — unreachable"
            fi
        elif (echo >/dev/tcp/"${host}"/"${port}") 2>/dev/null; then
            print_success "TCP ${label} (${host}:${port}) — reachable (bash fallback)"
        else
            print_fail "TCP ${label} (${host}:${port}) — unreachable"
        fi
    }

    _https_check() {
        local label="$1"
        local url="$2"
        print_debug "HTTPS check: ${url}"
        if ! command -v curl &>/dev/null; then
            print_warning "curl not available — skipping HTTPS check for ${label}"
            return
        fi
        result=$(curl -s -o /dev/null -w "%{http_code}|%{time_total}" -m 10 "${url}" 2>/dev/null || echo "000|0")
        http_code=$(echo "${result}" | cut -d'|' -f1)
        latency=$(echo "${result}" | cut -d'|' -f2)

        if [[ "${http_code}" =~ ^[2-4][0-9][0-9]$ ]]; then
            print_success "HTTPS ${label} — HTTP ${http_code} (${latency}s)"
        else
            print_fail "HTTPS ${label} — HTTP ${http_code} (${latency}s)"
        fi
    }

    # Panther base URL
    if [[ -n "${PANTHER_BASE_URL:-}" ]]; then
        PANTHER_HOST=$(echo "${PANTHER_BASE_URL}" | sed -E 's|https?://([^/:]+).*|\1|')
        _tcp_check "Panther API" "${PANTHER_HOST}" "443"
        _https_check "Panther API" "${PANTHER_BASE_URL}/v1/roles?limit=1"
    else
        print_warning "PANTHER_BASE_URL not set — skipping Panther connectivity check"
    fi

    # OAuth2 token URL
    if [[ -n "${PANTHER_TOKEN_URL:-}" ]]; then
        TOKEN_HOST=$(echo "${PANTHER_TOKEN_URL}" | sed -E 's|https?://([^/:]+).*|\1|')
        _tcp_check "OAuth2 Token URL" "${TOKEN_HOST}" "443"
        _https_check "OAuth2 Token URL (HEAD)" "${PANTHER_TOKEN_URL}"
    else
        print_warning "PANTHER_TOKEN_URL not set — skipping OAuth2 connectivity check"
    fi

    # Veza URL
    if [[ -n "${VEZA_URL:-}" ]]; then
        VEZA_HOST=$(echo "${VEZA_URL}" | sed -E 's|https?://([^/:]+).*|\1|')
        _tcp_check "Veza" "${VEZA_HOST}" "443"
        _https_check "Veza" "${VEZA_URL}"
    else
        print_warning "VEZA_URL not set — skipping Veza connectivity check"
    fi
}

# ---------------------------------------------------------------------------
# Section 5 — API Authentication
# ---------------------------------------------------------------------------
check_api_authentication() {
    print_header "5. API Authentication"

    set -a
    [[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}" 2>/dev/null || true
    set +a

    if [[ -z "${PANTHER_TOKEN_URL:-}" ]] || [[ -z "${PANTHER_CLIENT_ID:-}" ]] || [[ -z "${PANTHER_CLIENT_SECRET:-}" ]]; then
        print_warning "Panther OAuth2 credentials not set — skipping authentication test"
    else
        print_debug "Requesting OAuth2 token from ${PANTHER_TOKEN_URL}"
        print_debug "Client ID: ${PANTHER_CLIENT_ID:0:8}..."

        SCOPE_PARAM=""
        [[ -n "${PANTHER_SCOPE:-}" ]] && SCOPE_PARAM="&scope=${PANTHER_SCOPE}"

        TOKEN_RESP=$(curl -s -w "\n%{http_code}" -X POST "${PANTHER_TOKEN_URL}" \
            -u "${PANTHER_CLIENT_ID}:${PANTHER_CLIENT_SECRET}" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "grant_type=client_credentials${SCOPE_PARAM}" \
            -m 20 2>/dev/null || echo -e "\n000")

        HTTP_CODE=$(echo "${TOKEN_RESP}" | tail -1)
        TOKEN_BODY=$(echo "${TOKEN_RESP}" | head -n -1)

        if [[ "${HTTP_CODE}" == "200" ]]; then
            TOKEN_TYPE=$(echo "${TOKEN_BODY}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token_type','unknown'))" 2>/dev/null || echo "unknown")
            EXPIRES_IN=$(echo "${TOKEN_BODY}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('expires_in','unknown'))" 2>/dev/null || echo "unknown")
            print_success "OAuth2 token obtained (type=${TOKEN_TYPE}, expires_in=${EXPIRES_IN}s)"

            # Use the access token to test the Panther API
            ACCESS_TOKEN=$(echo "${TOKEN_BODY}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null || echo "")
            if [[ -n "${ACCESS_TOKEN}" ]] && [[ -n "${PANTHER_BASE_URL:-}" ]]; then
                print_debug "Testing Panther API GET /v1/roles with Bearer token"
                API_RESP=$(curl -s -o /dev/null -w "%{http_code}" \
                    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
                    -H "Accept: application/json" \
                    -m 15 \
                    "${PANTHER_BASE_URL}/v1/roles?limit=1" 2>/dev/null || echo "000")

                if [[ "${API_RESP}" == "200" ]]; then
                    print_success "Panther API /v1/roles — HTTP 200 (token is valid)"
                else
                    print_fail "Panther API /v1/roles — HTTP ${API_RESP} (check scope / permissions)"
                fi
            fi
        else
            print_fail "OAuth2 token request returned HTTP ${HTTP_CODE}"
            print_debug "Response body: ${TOKEN_BODY:0:300}"
        fi
    fi

    # Veza API key test
    if [[ -z "${VEZA_URL:-}" ]] || [[ -z "${VEZA_API_KEY:-}" ]]; then
        print_warning "VEZA_URL or VEZA_API_KEY not set — skipping Veza auth test"
    else
        print_debug "Testing Veza API key against ${VEZA_URL}/api/v1/providers"
        VEZA_RESP=$(curl -s -o /dev/null -w "%{http_code}" \
            -H "Authorization: Bearer ${VEZA_API_KEY}" \
            -H "Accept: application/json" \
            -m 15 \
            "${VEZA_URL}/api/v1/providers" 2>/dev/null || echo "000")

        if [[ "${VEZA_RESP}" == "200" ]]; then
            print_success "Veza API key valid — GET /api/v1/providers returned HTTP 200"
        else
            print_fail "Veza API key test failed — HTTP ${VEZA_RESP} (check key and URL)"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Section 6 — API Endpoint Accessibility
# ---------------------------------------------------------------------------
check_api_endpoints() {
    print_header "6. API Endpoint Accessibility"

    set -a
    [[ -f "${ENV_FILE}" ]] && source "${ENV_FILE}" 2>/dev/null || true
    set +a

    # Veza query endpoint
    if [[ -n "${VEZA_URL:-}" ]] && [[ -n "${VEZA_API_KEY:-}" ]]; then
        print_debug "Testing Veza query endpoint"
        QUERY_BODY='{"query":"nodes{InstanceId first:1}"}'
        QUERY_RESP=$(curl -s -w "\n%{http_code}" -X POST \
            "${VEZA_URL}/api/v1/assessments/query_spec:nodes" \
            -H "Authorization: Bearer ${VEZA_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "${QUERY_BODY}" \
            -m 15 2>/dev/null || echo -e "\n000")

        QUERY_CODE=$(echo "${QUERY_RESP}" | tail -1)
        QUERY_BODY_RESP=$(echo "${QUERY_RESP}" | head -n -1)

        if [[ "${QUERY_CODE}" == "200" ]]; then
            print_success "Veza query endpoint accessible — HTTP 200"
        else
            print_fail "Veza query endpoint returned HTTP ${QUERY_CODE}"
            print_debug "Response: ${QUERY_BODY_RESP:0:300}"
        fi
    else
        print_warning "Veza credentials not set — skipping query endpoint check"
    fi

    # Panther /v1/users endpoint (unauthenticated check for reachability only)
    if [[ -n "${PANTHER_BASE_URL:-}" ]]; then
        USERS_CHECK=$(curl -s -o /dev/null -w "%{http_code}" -m 10 \
            "${PANTHER_BASE_URL}/v1/users" 2>/dev/null || echo "000")
        # 401 is expected without auth — means the endpoint exists
        if [[ "${USERS_CHECK}" =~ ^(200|401|403)$ ]]; then
            print_success "Panther /v1/users endpoint reachable (HTTP ${USERS_CHECK})"
        else
            print_fail "Panther /v1/users endpoint returned HTTP ${USERS_CHECK}"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Section 7 — Deployment Structure
# ---------------------------------------------------------------------------
check_deployment_structure() {
    print_header "7. Deployment Structure"

    # Main script
    MAIN_SCRIPT="${SCRIPT_DIR}/panther.py"
    if [[ -f "${MAIN_SCRIPT}" ]] && [[ -r "${MAIN_SCRIPT}" ]]; then
        print_success "panther.py exists and is readable"
    else
        print_fail "panther.py not found at ${MAIN_SCRIPT}"
    fi

    # requirements.txt
    if [[ -f "${SCRIPT_DIR}/requirements.txt" ]]; then
        print_success "requirements.txt present"
    else
        print_fail "requirements.txt not found"
    fi

    # logs/ directory
    if [[ -d "${SCRIPT_DIR}/logs" ]]; then
        if [[ -w "${SCRIPT_DIR}/logs" ]]; then
            print_success "logs/ directory exists and is writable"
        else
            print_warning "logs/ directory exists but is not writable — fix permissions"
        fi
    else
        print_info "logs/ directory not found — it will be created automatically on first run"
    fi

    # Recommended install path
    RECOMMENDED="/opt/VEZA/panther-veza/scripts"
    if [[ "${SCRIPT_DIR}" == "${RECOMMENDED}" ]]; then
        print_success "Running from recommended path: ${RECOMMENDED}"
    else
        print_info "Running from ${SCRIPT_DIR} (recommended: ${RECOMMENDED})"
    fi

    # Current user
    CURRENT_USER=$(whoami 2>/dev/null || id -un)
    EXPECTED_USER="panther-veza"
    if [[ "${CURRENT_USER}" == "${EXPECTED_USER}" ]]; then
        print_success "Running as service account: ${CURRENT_USER}"
    else
        print_warning "Running as ${CURRENT_USER} — recommended to run as '${EXPECTED_USER}' service account in production"
    fi

    # --help smoke test
    if [[ -f "${SCRIPT_DIR}/venv/bin/python3" ]]; then
        HELP_PY="${SCRIPT_DIR}/venv/bin/python3"
    else
        HELP_PY="python3"
    fi

    if "${HELP_PY}" "${MAIN_SCRIPT}" --help &>/dev/null 2>&1; then
        print_success "python3 panther.py --help executes without errors"
    else
        print_fail "python3 panther.py --help returned a non-zero exit code"
    fi
}

# ---------------------------------------------------------------------------
# Section 8 — Summary
# ---------------------------------------------------------------------------
print_summary() {
    print_header "Validation Summary"
    echo -e "${GREEN}Passed  :${NC}  ${TESTS_PASSED}" | tee -a "${LOG_FILE}"
    echo -e "${RED}Failed  :${NC}  ${TESTS_FAILED}"   | tee -a "${LOG_FILE}"
    echo -e "${YELLOW}Warnings:${NC}  ${TESTS_WARNING}" | tee -a "${LOG_FILE}"
    echo ""
    echo "Log file: ${LOG_FILE}"
    echo ""

    if [[ "${TESTS_FAILED}" -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}All checks passed.${NC} Recommended next step:"
        echo ""
        echo "  cd ${SCRIPT_DIR}"
        echo "  source venv/bin/activate"
        echo "  python3 panther.py --dry-run --save-json --log-level DEBUG"
        echo ""
    else
        echo -e "${RED}✗ Some checks failed. Please address the issues above before deployment.${NC}"
    fi
}

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------
display_current_config() {
    echo -e "\n${BOLD}Current Configuration (.env)${NC}"
    if [[ -f "${ENV_FILE}" ]]; then
        while IFS= read -r line; do
            key=$(echo "${line}" | cut -d= -f1)
            val=$(echo "${line}" | cut -d= -f2-)
            if echo "${key}" | grep -qiE '(SECRET|KEY|TOKEN|PASSWORD)'; then
                echo "  ${key}=${val:0:8}..."
            else
                echo "  ${line}"
            fi
        done < <(grep -v '^\s*#' "${ENV_FILE}" | grep -v '^\s*$')
    else
        echo "  .env not found"
    fi
}

generate_env_template() {
    TEMPLATE="${SCRIPT_DIR}/.env.generated.$(date +%Y%m%d_%H%M%S)"
    cat > "${TEMPLATE}" <<'ENVEOF'
# Panther → Veza OAA Integration — Environment Configuration
PANTHER_BASE_URL=https://your-panther-api-host.runpanther.net
PANTHER_TOKEN_URL=https://your-idp.auth.us-east-1.amazoncognito.com/oauth2/token
PANTHER_CLIENT_ID=your_client_id_here
PANTHER_CLIENT_SECRET=your_client_secret_here
PANTHER_SCOPE=panther:api
VEZA_URL=https://your-company.veza.com
VEZA_API_KEY=your_veza_api_key_here
ENVEOF
    chmod 600 "${TEMPLATE}"
    echo "Template created: ${TEMPLATE}"
}

install_dependencies() {
    VENV_DIR="${SCRIPT_DIR}/venv"
    if [[ ! -d "${VENV_DIR}" ]]; then
        echo "Creating virtual environment..."
        python3 -m venv "${VENV_DIR}"
    fi
    echo "Installing dependencies..."
    "${VENV_DIR}/bin/pip" install --quiet -r "${SCRIPT_DIR}/requirements.txt"
    echo "Done."
}

# ---------------------------------------------------------------------------
# Main — interactive menu or --all mode
# ---------------------------------------------------------------------------
RUN_ALL=false
[[ "${1:-}" == "--all" ]] && RUN_ALL=true

{
    echo "Panther-Veza OAA Preflight Validation"
    echo "Started: $(date)"
    echo "Script dir: ${SCRIPT_DIR}"
} >> "${LOG_FILE}"

if [[ "${RUN_ALL}" == "true" ]]; then
    check_system_requirements
    check_python_dependencies
    check_configuration
    check_network_connectivity
    check_api_authentication
    check_api_endpoints
    check_deployment_structure
    print_summary

    [[ "${TESTS_FAILED}" -eq 0 ]]
    exit $?
fi

# Interactive menu
while true; do
    echo ""
    echo -e "${BOLD}Panther-Veza OAA Preflight Validation${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  1) System Requirements"
    echo "  2) Python Dependencies"
    echo "  3) Configuration File"
    echo "  4) Network Connectivity"
    echo "  5) API Authentication"
    echo "  6) API Endpoint Accessibility"
    echo "  7) Deployment Structure"
    echo "  8) Run All Checks"
    echo "  ─────────────────────────────────────"
    echo "  9) Display current config"
    echo " 10) Generate .env template"
    echo " 11) Install dependencies"
    echo "  q) Quit"
    echo ""
    read -r -p "Choose option: " choice

    TESTS_PASSED=0; TESTS_FAILED=0; TESTS_WARNING=0

    case "${choice}" in
        1) check_system_requirements ;;
        2) check_python_dependencies ;;
        3) check_configuration ;;
        4) check_network_connectivity ;;
        5) check_api_authentication ;;
        6) check_api_endpoints ;;
        7) check_deployment_structure ;;
        8)
            check_system_requirements
            check_python_dependencies
            check_configuration
            check_network_connectivity
            check_api_authentication
            check_api_endpoints
            check_deployment_structure
            print_summary
            ;;
        9)  display_current_config ;;
        10) generate_env_template ;;
        11) install_dependencies ;;
        q|Q) echo "Exiting."; exit 0 ;;
        *) echo "Invalid option: ${choice}" ;;
    esac
done
