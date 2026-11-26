#!/bin/bash
# IMPORTANT: this script must live in the folder that the sandbox should mount.
# A symbolic link to the script is sufficient.
# The sandbox name is "<agent>-<name of the current working directory>", with '_' and ' ' replaced by '-'.

# Install into a project (run by hand in a terminal, not by the IDE):
#   acp.sh install [claude|junie] [project-dir]      (project-dir defaults to $PWD)
# Links this script into the project as ./acp.sh, ignores ./acp/ in ./.gitignore (created
# if missing, even without a git repo) and prints
# the acp.json entry to add. An existing real file ./acp.sh is never overwritten.
if [ "${1:-}" = "install" ]; then
    # Resolve symbolic links portably (readlink -f is missing on older macOS).
    REAL="$0"
    while [ -L "${REAL}" ]; do
        LINK_TARGET="$(readlink "${REAL}")"
        case "${LINK_TARGET}" in
            /*) REAL="${LINK_TARGET}" ;;
            *) REAL="$(dirname "${REAL}")/${LINK_TARGET}" ;;
        esac
    done
    REAL="$(cd "$(dirname "${REAL}")" && pwd)/$(basename "${REAL}")"
    AGENT_NAME="${2:-claude}"
    case "${AGENT_NAME}" in claude | junie) ;; *) echo "unsupported agent '${AGENT_NAME}' (claude, junie)" >&2; exit 1 ;; esac
    PROJECT="$(cd "${3:-$PWD}" && pwd)" || exit 1
    if [ -e "${PROJECT}/acp.sh" ] && [ ! -L "${PROJECT}/acp.sh" ]; then
        echo "${PROJECT}/acp.sh is a regular file, not touching it" >&2
        exit 1
    fi
    if [ "${PROJECT}/acp.sh" != "${REAL}" ]; then
        ln -sfn "${REAL}" "${PROJECT}/acp.sh" || exit 1
    fi
    echo "linked ${PROJECT}/acp.sh -> ${REAL}"
    if ! grep -qxE '/?acp/?' "${PROJECT}/.gitignore" 2> /dev/null; then
        printf '/acp/\n' >> "${PROJECT}/.gitignore"
        echo "added /acp/ to ${PROJECT}/.gitignore (created if missing)"
    fi
    NAME="$(basename "${PROJECT}" | tr '_' ' ')"
    echo
    echo "Add this to the IDE's acp.json (the entry name decides the sandbox name):"
    printf '\n"%s": {\n  "command": "%s/acp.sh",\n  "args": ["%s"]\n}\n' "${NAME}" "${PROJECT}" "${AGENT_NAME}"
    exit 0
fi

# Script directory = directory of $0 (without the script name). When called via a
# symbolic link, $0 is the link path, so everything ends up next to the link.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# All files acp.sh produces (logs, generated login scripts) live in ./acp.
ACP_DIR="${SCRIPT_DIR}/acp"
LOGDIR="${ACP_DIR}/logs"
mkdir -p "${LOGDIR}"
LOGFILE="${LOGDIR}/acp.log"

# Standard log format: <ISO-8601 timestamp> [<LEVEL>] [pid <PID>] <message>
log() {
    local level="$1"
    shift
    printf '%s [%s] [pid %s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${level}" "$$" "$*" >> "${LOGFILE}"
}

SANDBOX="${1}-$(basename "$PWD" | tr '_ ' '-')"
# Optional second arg "no-central-login": install central, but do not log in.
CENTRAL_LOGIN=1
if [ "${2:-}" = "no-central-login" ]; then
    CENTRAL_LOGIN=0
fi
# Meta information: arguments and working directory
log INFO "---- acp.sh start ----"
log INFO "script: $0"
log INFO "script dir: ${SCRIPT_DIR}"
log INFO "arg count: $#"
i=1
for arg in "$@"; do
    log INFO "arg ${i}: ${arg}"
    i=$((i + 1))
done
log INFO "working directory: ${PWD}"
log INFO "sandbox name: ${SANDBOX}"

# stdout is reserved for the ACP JSON protocol -> send all stderr to the log.
exec 2>> "${LOGFILE}"

# The IDE starts this script in its own cache directory, so mount the script's
# directory (the project, or wherever the symlink lives) instead of $PWD.
WORKSPACE="${SCRIPT_DIR}"
log INFO "workspace: ${WORKSPACE}"

AGENT="${1}"

# Create the sandbox if it does not exist yet.
# usage: ensure_sandbox <image> [extra sbx create args...]
ensure_sandbox() {
    local image="$1"
    shift
    if sbx ls -q 2>> "${LOGFILE}" | grep -Fxq "${SANDBOX}"; then
        log INFO "sandbox ${SANDBOX} already exists"
        return 0
    fi
    log INFO "sandbox ${SANDBOX} not found, creating it (image: ${image} $*)"
    if ! sbx create --no-input --name "${SANDBOX}" "${image}" "$@" "${WORKSPACE}" >> "${LOGFILE}" 2>&1; then
        log ERROR "failed to create sandbox ${SANDBOX}"
        exit 1
    fi
    log INFO "sandbox ${SANDBOX} created"
}

# Default model and effort for Claude Code. Passed as environment variables, so
# they survive `central add` rewriting ~/.claude/settings.json in the sandbox.
CLAUDE_DEFAULT_MODEL="claude-sonnet-5-5"
CLAUDE_DEFAULT_EFFORT="medium"

# Kits (mixins), see kits/<name>/<name>.yaml:
#   openspec - installs the OpenSpec CLI
#   central  - installs the central CLI and allows its network hosts
# Default: unpinned git references (follow the default branch of this repo).
# If KIT_LOCAL is set, it is taken as the directory that contains the kit
# directories (<KIT_LOCAL>/openspec, <KIT_LOCAL>/central), e.g. KIT_LOCAL=~/bin/kits.
KIT_GIT_BASE="git+https://github.com/Gepardec/agent-sandbox.git#dir=kits"
if [ -n "${KIT_LOCAL:-}" ]; then
    OPENSPEC_KIT="${KIT_LOCAL%/}/openspec"
    CENTRAL_KIT="${KIT_LOCAL%/}/central"
else
    OPENSPEC_KIT="${KIT_GIT_BASE}/openspec"
    CENTRAL_KIT="${KIT_GIT_BASE}/central"
fi
log INFO "openspec kit: ${OPENSPEC_KIT}"
log INFO "central kit: ${CENTRAL_KIT}"

# Keep Claude's session transcripts and memory (~/.claude/projects) outside the
# sandbox: ./acp/claude-projects is part of the mounted workspace, so it survives
# `sbx rm`. ~/.claude/projects in the sandbox becomes a symlink to it. An existing
# directory is copied over first. Only projects/ is moved; auth and kit config stay.
persist_claude_state() {
    local target="${ACP_DIR}/claude-projects"
    mkdir -p "${target}"
    if sbx_run "if [ -L ~/.claude/projects ]; then ln -sfn '${target}' ~/.claude/projects; elif [ -d ~/.claude/projects ]; then cp -a ~/.claude/projects/. '${target}'/ && rm -rf ~/.claude/projects && ln -s '${target}' ~/.claude/projects; else mkdir -p ~/.claude && ln -s '${target}' ~/.claude/projects; fi"; then
        log INFO "claude state persisted: ~/.claude/projects -> ${target}"
    else
        log WARN "could not link ~/.claude/projects to ${target}; sessions are lost on sandbox removal"
    fi
}

# Claude Code: run claude-agent-acp in the sandbox (ACP over stdio).
run_claude() {
    ensure_sandbox sbx/claude:latest --kit sbx/claude-acp:latest --kit "${OPENSPEC_KIT}" --kit "${CENTRAL_KIT}"
    persist_claude_state
    ensure_central
    add_intellij_mcp
    log INFO "connecting: sbx exec -i ${SANDBOX} claude-agent-acp (model ${CLAUDE_DEFAULT_MODEL}, effort ${CLAUDE_DEFAULT_EFFORT})"
    exec sbx exec -i "${SANDBOX}" env \
        ANTHROPIC_MODEL="${CLAUDE_DEFAULT_MODEL}" \
        CLAUDE_CODE_EFFORT_LEVEL="${CLAUDE_DEFAULT_EFFORT}" \
        claude-agent-acp
}

# Junie: run junie in ACP mode in the sandbox (ACP over stdio).
run_junie() {
    ensure_sandbox sbx/junie:latest --kit "${OPENSPEC_KIT}" --kit "${CENTRAL_KIT}"
    ensure_central
    add_intellij_mcp
    log INFO "connecting: sbx exec -i ${SANDBOX} junie --acp=true"
    exec sbx exec -i "${SANDBOX}" junie --acp=true
}

# Run a non-interactive command inside the sandbox. stdin is detached and stdout
# goes to the log, so nothing interferes with the ACP stream of the IDE.
# central installs to ~/.local/bin, which is not always on PATH for sbx exec.
sbx_run() {
    sbx exec -t "${SANDBOX}" bash -lc "export PATH=\"\$HOME/.local/bin:\$PATH\"; $*" < /dev/null >> "${LOGFILE}" 2>&1
}

# IntelliJ MCP server (built-in IDE server), added to sbx after `central add`.
INTELLIJ_MCP_NAME="intellij"
INTELLIJ_MCP_URL="http://127.0.0.1:64342/stream"

# Path of the generated, agent-specific login script (see write_central_login).
CENTRAL_LOGIN_SCRIPT="${ACP_DIR}/central-login-${AGENT}.sh"

# Generate a login script with agent and sandbox name hard coded, so it can be
# run from a terminal without arguments. Regenerated on every start, so it
# always matches the sandbox the IDE actually uses.
write_central_login() {
    {
        echo '#!/bin/bash'
        echo "# Generated by acp.sh on $(date '+%Y-%m-%dT%H:%M:%S%z') - do not edit, changes are overwritten."
        echo "# Interactive JetBrains Air (central) login for agent ${AGENT} in sandbox ${SANDBOX}."
        echo "sbx exec -it '${SANDBOX}' bash -lc 'export PATH=\"\$HOME/.local/bin:\$PATH\"; central login && central add ${AGENT} && central status'"
    } > "${CENTRAL_LOGIN_SCRIPT}" && chmod +x "${CENTRAL_LOGIN_SCRIPT}" \
        && log INFO "login script written: ${CENTRAL_LOGIN_SCRIPT}" \
        || log WARN "could not write login script ${CENTRAL_LOGIN_SCRIPT}"
}

# Register the IntelliJ MCP server in sbx and load it into the sandbox.
# Failures (e.g. server already registered) are logged, not fatal.
add_intellij_mcp() {
    if sbx mcp add "${INTELLIJ_MCP_NAME}" --url "${INTELLIJ_MCP_URL}" < /dev/null >> "${LOGFILE}" 2>&1; then
        log INFO "mcp server added: ${INTELLIJ_MCP_NAME} (${INTELLIJ_MCP_URL})"
    else
        log WARN "could not add mcp server ${INTELLIJ_MCP_NAME} (maybe it already exists)"
    fi
    if sbx mcp load "${INTELLIJ_MCP_NAME}" --sandbox="${SANDBOX}" < /dev/null >> "${LOGFILE}" 2>&1; then
        log INFO "mcp server ${INTELLIJ_MCP_NAME} loaded in ${SANDBOX}"
    else
        log WARN "could not load mcp server ${INTELLIJ_MCP_NAME} in ${SANDBOX}"
    fi
}

# Write a big, hard to miss message to the log: the user has to log in.
# (stdout is reserved for the ACP protocol, so the log is the only place.)
log_login_banner() {
    local line
    while IFS= read -r line; do
        log WARN "${line}"
    done <<EOF
################################################################################
##                                                                            ##
##   LOGIN REQUIRED: central is not logged in in sandbox ${SANDBOX}
##                                                                            ##
##   The agent will not work until you log in. Trigger the login by running   ##
##   this script in a terminal:                                               ##
##                                                                            ##
##       ${CENTRAL_LOGIN_SCRIPT}
##                                                                            ##
##   Then restart the agent in the IDE.                                       ##
##                                                                            ##
################################################################################
EOF
}

# Remove ANSI escape sequences (CSI, OSC) and carriage returns from stdin.
strip_ansi() {
    sed -E $'s/\x1b\\[[0-9;?]*[ -\\/]*[@-~]//g; s/\x1b\\][^\x07\x1b]*(\x07|\x1b\\\\)//g; s/\x1b[@-Z\\\\-_]//g; s/\r//g'
}

# Make sure central (installed by the central kit) is configured in the sandbox.
# Login is interactive and cannot happen here -> a login script with hard coded
# values is generated (see write_central_login).
ensure_central() {
    write_central_login
    # central itself is installed (and its network hosts allowed) by the central kit.
    # A sandbox created before the kit existed has neither -> recreate it.
    if sbx_run "command -v central"; then
        log INFO "central installed in ${SANDBOX}"
    else
        log ERROR "central not found in ${SANDBOX}: it is provided by the central kit; remove the sandbox (sbx rm ${SANDBOX}) so it is recreated with the kit"
        exit 1
    fi

    # Set analytics consent explicitly, otherwise `central login` asks for it
    # interactively on the first run (it only asks while the value is "not set").
    if sbx_run "central config set google-analytics off"; then
        log INFO "central analytics/error reports turned off"
    else
        log WARN "could not turn off central analytics in ${SANDBOX}"
    fi

    # Login and agent setup run inside the sandbox; the login script generated
    # above does the same interactively from a terminal.
    if [ "${CENTRAL_LOGIN}" -eq 0 ]; then
        log INFO "no-central-login given: central is installed, skipping login, add and status check"
        return 0
    fi
    sbx_run "central login && central add ${AGENT}" \
        || log WARN "central login/add failed in ${SANDBOX}"

    # Without a tty central status prints nothing to the log, so capture its
    # output into a variable and write it line by line.
    local status_out status_rc status_line
    # central emits ANSI colors and terminal queries (OSC/CSI sequences), which
    # show up as garbage in the log -> disable colors and strip what is left.
    status_out="$(sbx exec "${SANDBOX}" bash -lc 'export PATH="$HOME/.local/bin:$PATH"; NO_COLOR=1 TERM=dumb central status' < /dev/null 2>&1)"
    status_rc=$?
    status_out="$(printf '%s' "${status_out}" | strip_ansi)"
    while IFS= read -r status_line; do
        log INFO "central status: ${status_line}"
    done <<< "${status_out}"
    if [ "${status_rc}" -ne 0 ]; then
        log_login_banner
    fi
}

SUPPORTED_AGENTS="claude, junie"

case "${AGENT}" in
    claude)
        run_claude
        ;;
    junie)
        run_junie
        ;;
    "")
        log ERROR "no agent given (arg 1), expected one of: ${SUPPORTED_AGENTS}"
        exit 1
        ;;
    *)
        log ERROR "unsupported agent '${AGENT}', expected one of: ${SUPPORTED_AGENTS}"
        exit 1
        ;;
esac
