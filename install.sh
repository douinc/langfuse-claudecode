#!/usr/bin/env bash
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/douinc/langfuse-claudecode/main"

# Global install location
GLOBAL_HOOK_DIR="${HOME}/.claude/hooks/langfuse-claudecode"
GLOBAL_HOOK_PATH="${GLOBAL_HOOK_DIR}/langfuse_hook.sh"
GLOBAL_SETTINGS="${HOME}/.claude/settings.json"

# Project-level (credentials only)
SETTINGS_LOCAL_FILE=".claude/settings.local.json"
GITIGNORE_FILE=".gitignore"

# Hook command uses fully-expanded $HOME (no tilde in JSON)
HOOK_COMMAND="${GLOBAL_HOOK_PATH}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "${BLUE}%s${NC}\n" "$*"; }
ok()    { printf "${GREEN}%s${NC}\n" "$*"; }
warn()  { printf "${YELLOW}%s${NC}\n" "$*"; }
err()   { printf "${RED}%s${NC}\n" "$*" >&2; }

# ── Parse flags ───────────────────────────────────────────────────────

SETUP_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --setup|--setup-only) SETUP_ONLY=true ;;
    esac
done

# ── Preflight ─────────────────────────────────────────────────────────

# Check and auto-install jq if missing
if ! command -v jq &> /dev/null; then
    warn "jq is not installed. Attempting to install..."

    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        if command -v brew &> /dev/null; then
            info "Installing jq via Homebrew..."
            brew install jq || {
                err "Failed to install jq via brew. Please install manually:"
                echo "  brew install jq"
                exit 1
            }
        else
            err "Homebrew not found. Please install jq manually:"
            echo "  brew install jq"
            echo "Or install Homebrew first: https://brew.sh"
            exit 1
        fi
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        if command -v apt-get &> /dev/null; then
            info "Installing jq via apt-get..."
            sudo apt-get update && sudo apt-get install -y jq || {
                err "Failed to install jq via apt-get. Please install manually:"
                echo "  sudo apt-get install jq"
                exit 1
            }
        elif command -v yum &> /dev/null; then
            info "Installing jq via yum..."
            sudo yum install -y jq || {
                err "Failed to install jq via yum. Please install manually:"
                echo "  sudo yum install jq"
                exit 1
            }
        elif command -v dnf &> /dev/null; then
            info "Installing jq via dnf..."
            sudo dnf install -y jq || {
                err "Failed to install jq via dnf. Please install manually:"
                echo "  sudo dnf install jq"
                exit 1
            }
        else
            err "No package manager found. Please install jq manually:"
            echo "  https://jqlang.github.io/jq/download/"
            exit 1
        fi
    else
        err "Unsupported OS. Please install jq manually:"
        echo "  https://jqlang.github.io/jq/download/"
        exit 1
    fi

    # Verify installation
    if ! command -v jq &> /dev/null; then
        err "jq installation failed. Please install manually and try again."
        exit 1
    fi

    ok "jq installed successfully"
fi

# Check and auto-install curl if missing
if ! command -v curl &> /dev/null; then
    warn "curl is not installed. Attempting to install..."

    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS (curl is usually pre-installed)
        err "curl not found. This is unusual on macOS. Please install via:"
        echo "  brew install curl"
        exit 1
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        if command -v apt-get &> /dev/null; then
            info "Installing curl via apt-get..."
            sudo apt-get update && sudo apt-get install -y curl || {
                err "Failed to install curl via apt-get. Please install manually:"
                echo "  sudo apt-get install curl"
                exit 1
            }
        elif command -v yum &> /dev/null; then
            info "Installing curl via yum..."
            sudo yum install -y curl || {
                err "Failed to install curl via yum. Please install manually:"
                echo "  sudo yum install curl"
                exit 1
            }
        elif command -v dnf &> /dev/null; then
            info "Installing curl via dnf..."
            sudo dnf install -y curl || {
                err "Failed to install curl via dnf. Please install manually:"
                echo "  sudo dnf install curl"
                exit 1
            }
        else
            err "No package manager found. Please install curl manually."
            exit 1
        fi
    else
        err "Unsupported OS. Please install curl manually."
        exit 1
    fi

    # Verify installation
    if ! command -v curl &> /dev/null; then
        err "curl installation failed. Please install manually and try again."
        exit 1
    fi

    ok "curl installed successfully"
fi

# Set download function (prefer curl, fallback to wget)
if command -v curl &> /dev/null; then
    download() { curl -fsSL "$1"; }
elif command -v wget &> /dev/null; then
    download() { wget -qO- "$1"; }
else
    err "Error: neither 'curl' nor 'wget' found."
    exit 1
fi

IN_PROJECT=true
if [ ! -d ".git" ] && [ ! -d ".claude" ]; then
    if [ "$SETUP_ONLY" = true ]; then
        warn "Warning: not in a git repository root."
        echo "Run --setup from your project root directory to configure credentials."
        read -rp "Continue anyway? [y/N] " confirm < /dev/tty
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        IN_PROJECT=false
        warn "Note: not in a git repository root."
        echo "  Global hook will be installed, but project credentials will be skipped."
        echo "  Run 'curl -fsSL .../install.sh | bash -s -- --setup' from a project root later."
        echo ""
    fi
fi

echo ""
printf "${BOLD}langfuse-claudecode installer${NC}\n"
echo "https://github.com/douinc/langfuse-claudecode"
echo ""

if [ "$SETUP_ONLY" = true ]; then
    info "Mode: --setup (project credentials only)"
    echo ""
fi

# ── Download hook files to global location (skip if --setup) ──────────

if [ "$SETUP_ONLY" = false ]; then
    info "Downloading hook script to ${GLOBAL_HOOK_DIR} ..."
    mkdir -p "${GLOBAL_HOOK_DIR}"

    download "${REPO_RAW}/langfuse_hook.sh" > "${GLOBAL_HOOK_PATH}"
    chmod +x "${GLOBAL_HOOK_PATH}"
    ok "  -> langfuse_hook.sh"
fi

# ── Register hook in ~/.claude/settings.json (skip if --setup) ────────

if [ "$SETUP_ONLY" = false ]; then
    echo ""
    info "Configuring ${GLOBAL_SETTINGS} ..."

    mkdir -p "$(dirname "${GLOBAL_SETTINGS}")"

    # Load or create settings
    if [ -f "${GLOBAL_SETTINGS}" ]; then
        SETTINGS=$(cat "${GLOBAL_SETTINGS}")
    else
        SETTINGS='{}'
    fi

    # Check if langfuse hook already exists
    EXISTING_HOOK=$(echo "$SETTINGS" | jq -r '
        [.hooks.Stop[]?.hooks[]? | select(.command | contains("langfuse_hook"))] | length
    ' 2>/dev/null || echo "0")

    if [ "$EXISTING_HOOK" -gt 0 ]; then
        # Update existing hook command
        SETTINGS=$(echo "$SETTINGS" | jq --arg cmd "$HOOK_COMMAND" '
            .hooks.Stop |= map(
                .hooks |= map(
                    if .command | contains("langfuse_hook") then
                        .command = $cmd
                    else
                        .
                    end
                )
            )
        ')
    else
        # Add new hook entry
        SETTINGS=$(echo "$SETTINGS" | jq --arg cmd "$HOOK_COMMAND" '
            .hooks.Stop += [{
                hooks: [{
                    type: "command",
                    command: $cmd
                }]
            }]
        ')
    fi

    # Save settings
    echo "$SETTINGS" | jq '.' > "${GLOBAL_SETTINGS}"

    ok "  -> Stop hook registered (user-wide)"
fi

# ── Migrate old project-level installation (skip if --setup) ──────────

if [ "$SETUP_ONLY" = false ] && [ -f ".claude/hooks/langfuse_hook.py" ]; then
    echo ""
    warn "Found old project-level hook at .claude/hooks/langfuse_hook.py"
    read -rp "  Remove old project-level hook file? [Y/n] " confirm < /dev/tty
    if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
        rm -f ".claude/hooks/langfuse_hook.py"
        ok "  -> Removed .claude/hooks/langfuse_hook.py"
    fi

    # Remove langfuse hook entry from project-level .claude/settings.json
    if [ -f ".claude/settings.json" ]; then
        PROJECT_SETTINGS=$(cat ".claude/settings.json")

        # Filter out langfuse_hook entries
        PROJECT_SETTINGS=$(echo "$PROJECT_SETTINGS" | jq '
            .hooks.Stop = [
                .hooks.Stop[]? |
                .hooks = [.hooks[]? | select(.command | contains("langfuse_hook") | not)] |
                select(.hooks | length > 0)
            ] |
            if .hooks.Stop | length == 0 then
                del(.hooks.Stop)
            else
                .
            end |
            if .hooks == {} then
                del(.hooks)
            else
                .
            end
        ')

        echo "$PROJECT_SETTINGS" | jq '.' > ".claude/settings.json"
        ok "  -> Cleaned langfuse hook from project .claude/settings.json"
    fi
fi

# ── Interactive credential prompts (skip if --setup with no project) ──

# Check if credentials already exist
CREDS_EXIST=false
if [ -f "${SETTINGS_LOCAL_FILE}" ]; then
    EXISTING_PK=$(jq -r '.env.LANGFUSE_PUBLIC_KEY // ""' "${SETTINGS_LOCAL_FILE}" 2>/dev/null || echo "")
    EXISTING_SK=$(jq -r '.env.LANGFUSE_SECRET_KEY // ""' "${SETTINGS_LOCAL_FILE}" 2>/dev/null || echo "")
    if [ -n "$EXISTING_PK" ] && [ -n "$EXISTING_SK" ]; then
        CREDS_EXIST=true
    fi
fi

if [ "$SETUP_ONLY" = true ] || [ "$IN_PROJECT" = true ]; then

    # Skip credential prompts if already configured (unless --setup forces reconfiguration)
    if [ "$CREDS_EXIST" = true ] && [ "$SETUP_ONLY" = false ]; then
        echo ""
        ok "Credentials already configured in ${SETTINGS_LOCAL_FILE} (skipping)"
    else

    echo ""
    info "Configure Langfuse credentials"
    echo "  (stored in ${SETTINGS_LOCAL_FILE}, which will be gitignored)"
    echo ""

    # Support non-interactive mode: skip prompts for pre-set env vars
    if [ -z "${LANGFUSE_PUBLIC_KEY:-}" ]; then
        read -rp "  LANGFUSE_PUBLIC_KEY (pk-lf-...): " LANGFUSE_PUBLIC_KEY < /dev/tty
    fi
    if [ -z "${LANGFUSE_PUBLIC_KEY:-}" ]; then
        err "Error: LANGFUSE_PUBLIC_KEY is required."
        exit 1
    fi

    if [ -z "${LANGFUSE_SECRET_KEY:-}" ]; then
        read -rp "  LANGFUSE_SECRET_KEY (sk-lf-...): " LANGFUSE_SECRET_KEY < /dev/tty
    fi
    if [ -z "${LANGFUSE_SECRET_KEY:-}" ]; then
        err "Error: LANGFUSE_SECRET_KEY is required."
        exit 1
    fi

    if [ -z "${LANGFUSE_BASE_URL:-}" ]; then
        read -rp "  LANGFUSE_BASE_URL [https://cloud.langfuse.com]: " LANGFUSE_BASE_URL < /dev/tty
    fi
    LANGFUSE_BASE_URL="${LANGFUSE_BASE_URL:-https://cloud.langfuse.com}"

    if [ -z "${CC_LANGFUSE_USER_ID:-}" ]; then
        read -rp "  CC_LANGFUSE_USER_ID (e.g. your email, optional): " CC_LANGFUSE_USER_ID < /dev/tty
    fi

    if [ -z "${CC_LANGFUSE_ENVIRONMENT:-}" ]; then
        read -rp "  CC_LANGFUSE_ENVIRONMENT (e.g. project name, optional): " CC_LANGFUSE_ENVIRONMENT < /dev/tty
    fi

    # ── Merge .claude/settings.local.json ─────────────────────────────

    info "Configuring ${SETTINGS_LOCAL_FILE} ..."
    mkdir -p "$(dirname "${SETTINGS_LOCAL_FILE}")"

    # Load or create settings.local.json
    if [ -f "${SETTINGS_LOCAL_FILE}" ]; then
        LOCAL_SETTINGS=$(cat "${SETTINGS_LOCAL_FILE}")
    else
        LOCAL_SETTINGS='{}'
    fi

    # Build env object
    LOCAL_SETTINGS=$(echo "$LOCAL_SETTINGS" | jq \
        --arg pk "$LANGFUSE_PUBLIC_KEY" \
        --arg sk "$LANGFUSE_SECRET_KEY" \
        --arg url "$LANGFUSE_BASE_URL" \
        --arg uid "${CC_LANGFUSE_USER_ID:-}" \
        --arg env "${CC_LANGFUSE_ENVIRONMENT:-}" \
        '
        .env.TRACE_TO_LANGFUSE = "true" |
        .env.LANGFUSE_PUBLIC_KEY = $pk |
        .env.LANGFUSE_SECRET_KEY = $sk |
        .env.LANGFUSE_BASE_URL = $url |
        if $uid != "" then
            .env.CC_LANGFUSE_USER_ID = $uid
        else
            .
        end |
        if $env != "" then
            .env.CC_LANGFUSE_ENVIRONMENT = $env
        else
            .
        end
    ')

    # Save settings
    echo "$LOCAL_SETTINGS" | jq '.' > "${SETTINGS_LOCAL_FILE}"

    ok "  -> Credentials saved"

    # ── Update .gitignore ─────────────────────────────────────────────

    if [ ! -f "${GITIGNORE_FILE}" ]; then
        echo ".claude/settings.local.json" > "${GITIGNORE_FILE}"
        ok "  -> Created ${GITIGNORE_FILE}"
    elif ! grep -qxF ".claude/settings.local.json" "${GITIGNORE_FILE}"; then
        printf "\n# Claude Code local settings (contains secrets)\n.claude/settings.local.json\n" >> "${GITIGNORE_FILE}"
        ok "  -> Added to ${GITIGNORE_FILE}"
    else
        ok "  -> ${GITIGNORE_FILE} already up to date"
    fi

    fi # end of credential prompts (skipped when CREDS_EXIST=true)
fi

# ── Done ──────────────────────────────────────────────────────────────

echo ""
printf "${GREEN}${BOLD}Installation complete!${NC}\n"
echo ""

if [ "$SETUP_ONLY" = true ]; then
    echo "  Secrets:  ${SETTINGS_LOCAL_FILE}"
else
    echo "  Hook:     ${GLOBAL_HOOK_PATH}"
    echo "  Settings: ${GLOBAL_SETTINGS}"
    if [ "$IN_PROJECT" = true ]; then
        echo "  Secrets:  ${SETTINGS_LOCAL_FILE}"
    fi
fi
echo ""
echo "Next steps:"
echo "  1. Start Claude Code in this project directory"
echo "  2. Have a conversation - traces will appear in Langfuse"
if [ -n "${LANGFUSE_BASE_URL:-}" ]; then
    echo "  3. View traces at: ${LANGFUSE_BASE_URL}"
fi
echo ""
echo "To add tracing to another project:"
echo "  curl -fsSL https://raw.githubusercontent.com/douinc/langfuse-claudecode/main/install.sh | bash -s -- --setup"
echo ""
echo "Troubleshooting:"
echo "  - Logs:  tail -f ~/.claude/state/langfuse_hook.log"
echo "  - Debug: add \"CC_LANGFUSE_DEBUG\": \"true\" to ${SETTINGS_LOCAL_FILE}"
echo "  - Test:  echo '{}' | ${GLOBAL_HOOK_PATH}"
echo ""
