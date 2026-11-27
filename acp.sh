#!/bin/bash
# IMPORTANT: this script must live in the folder that the sandbox should mount.
# A symbolic link to the script is sufficient.
# The sandbox name is "<name of the project folder containing sbx-acp/acp.sh>-<agent>", with '_' and ' ' replaced by '-'.

# Download/update this script from GitHub into ./sbx-acp/ of a project (run by hand, not by the IDE):
#   cd /path/to/your/project && curl -fsSL https://raw.githubusercontent.com/Gepardec/agent-sandbox/main/acp.sh | bash -s self-install
#   ./sbx-acp/acp.sh self-install [project-dir]     (update, once downloaded)
# project-dir defaults to $PWD. Always downloads (when piped there is no file to copy).
# Override (environment): ACP_REF  branch, tag or commit to fetch (default: main)
if [ "${1:-}" = "self-install" ]; then
    set -eu
    PROJECT="$(cd "${2:-$PWD}" && pwd)"
    DEST_DIR="${PROJECT}/sbx-acp"
    URL="https://raw.githubusercontent.com/Gepardec/agent-sandbox/${ACP_REF:-main}/acp.sh"
    mkdir -p "${DEST_DIR}"
    TMP="$(mktemp "${DEST_DIR}/.acp.sh.XXXXXX")"
    trap 'rm -f "${TMP}"' EXIT
    echo "Downloading ${URL}"
    curl -fsSL "${URL}" -o "${TMP}" < /dev/null
    # Sanity check before replacing a working copy: a bash script that parses.
    head -n 1 "${TMP}" | grep -q '^#!/bin/bash' || { echo "Download is not acp.sh, aborting" >&2; exit 1; }
    bash -n "${TMP}" || { echo "Downloaded acp.sh has syntax errors, aborting" >&2; exit 1; }
    chmod 755 "${TMP}"
    mv -f "${TMP}" "${DEST_DIR}/acp.sh"
    trap - EXIT
    echo "Installed ${DEST_DIR}/acp.sh"
    echo
    echo "Next: ${DEST_DIR}/acp.sh init claude"
    exit 0
fi

# Set up a project (run by hand in a terminal, not by the IDE):
#   acp.sh init [claude|junie] [project-dir]      (project-dir defaults to $PWD)
# Links this script into the project as ./sbx-acp/acp.sh, ignores ./sbx-acp/ in ./.gitignore (created
# if missing, even without a git repo) and
# writes ./sbx-acp/readme.adoc, adds the entry to ~/.jetbrains/acp.json (skipped if already present). An existing real file ./sbx-acp/acp.sh is never overwritten.
if [ "${1:-}" = "init" ]; then
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
    mkdir -p "${PROJECT}/sbx-acp" || exit 1
    LINK="${PROJECT}/sbx-acp/acp.sh"
    if [ "${LINK}" != "${REAL}" ] && [ -e "${LINK}" ] && [ ! -L "${LINK}" ]; then
        echo "${LINK} is a regular file, not touching it" >&2
        exit 1
    fi
    if [ "${LINK}" != "${REAL}" ]; then
        ln -sfn "${REAL}" "${LINK}" || exit 1
    fi
    echo "linked ${LINK} -> ${REAL}"
    if ! grep -qxE '/?sbx-acp/?' "${PROJECT}/.gitignore" 2> /dev/null; then
        printf '/sbx-acp/\n' >> "${PROJECT}/.gitignore"
        echo "added /sbx-acp/ to ${PROJECT}/.gitignore (created if missing)"
    fi
    NAME="$(basename "${PROJECT}" | tr "_" " ")-${AGENT_NAME}"
    # Cheat sheet with hard-coded sandbox names (<project folder>-<agent>) for all agent variants.
    PROJECT_SLUG="$(basename "${PROJECT}" | tr '_ ' '-')"
    {
        for README_AGENT in claude junie; do
            printf 'Bash in Sandbox (%s)\n[source,shell]\n----\nsbx exec -it "%s-%s" bash\n----\n\n' \
                "${README_AGENT}" "${PROJECT_SLUG}" "${README_AGENT}"
        done
        for README_AGENT in claude junie; do
            printf 'Delete Sandbox (%s): removes the sandbox and everything installed in it, e.g. `central` and its login; the mounted project directory is not affected\n[source,shell]\n----\nsbx rm -f "%s-%s"\n----\n\n' \
                "${README_AGENT}" "${PROJECT_SLUG}" "${README_AGENT}"
        done
    } > "${PROJECT}/sbx-acp/readme.adoc"
    echo "wrote ${PROJECT}/sbx-acp/readme.adoc"
    # Register the agent in the JetBrains acp.json (JSON with // comments, so no jq):
    # skipped if an entry with this name already exists; file and the sections
    # default_mcp_settings / agent_servers are created if missing.
    ACP_JSON="${HOME}/.jetbrains/acp.json"
    ENTRY_CMD="${PROJECT}/sbx-acp/acp.sh"
    mkdir -p "$(dirname "${ACP_JSON}")" || exit 1
    if [ ! -s "${ACP_JSON}" ]; then
        printf '{\n}\n' > "${ACP_JSON}" || exit 1
    fi
    # Add a missing top-level section right after the opening "{" of the file.
    ensure_section() {
        local key="$1" block="$2" tmp
        grep -v '^[[:space:]]*//' "${ACP_JSON}" | grep -q "\"${key}\"" && return 0
        tmp="$(mktemp "${ACP_JSON}.XXXXXX")" || return 1
        awk -v block="${block}" '
            { line[NR] = $0 }
            END {
                for (i = 1; i <= NR; i++) {
                    print line[i]
                    if (!done && line[i] ~ /^[[:space:]]*\{[[:space:]]*$/) {
                        done = 1
                        nxt = ""
                        for (j = i + 1; j <= NR; j++) {
                            if (line[j] ~ /^[[:space:]]*$/ || line[j] ~ /^[[:space:]]*\/\//) continue
                            nxt = line[j]; break
                        }
                        print block ((nxt ~ /^[[:space:]]*\}/) ? "" : ",")
                    }
                }
                if (!done) exit 1
            }' "${ACP_JSON}" > "${tmp}" || { rm -f "${tmp}"; return 1; }
        mv -f "${tmp}" "${ACP_JSON}" || return 1
        echo "added \"${key}\" section to ${ACP_JSON}"
    }
    ensure_section agent_servers '  "agent_servers": {
  }' || { echo "could not patch ${ACP_JSON}, fix it by hand" >&2; exit 1; }
    ensure_section default_mcp_settings '  "default_mcp_settings": {
    "use_custom_mcp": false,
    "use_idea_mcp": false
  }' || { echo "could not patch ${ACP_JSON}, fix it by hand" >&2; exit 1; }
    if grep -v '^[[:space:]]*//' "${ACP_JSON}" | grep -qF "\"${NAME}\""; then
        echo "${ACP_JSON} already has \"${NAME}\", skipped"
    else
        TMP_JSON="$(mktemp "${ACP_JSON}.XXXXXX")" || exit 1
        # Insert the entry right after the line opening agent_servers; add a comma
        # unless the next real line closes the object.
        awk -v name="${NAME}" -v cmd="${ENTRY_CMD}" -v agent="${AGENT_NAME}" '
            { line[NR] = $0 }
            END {
                done = 0
                for (i = 1; i <= NR; i++) {
                    print line[i]
                    if (!done && line[i] ~ /"agent_servers"/ && line[i] ~ /\{[[:space:]]*$/) {
                        done = 1
                        nxt = ""
                        for (j = i + 1; j <= NR; j++) {
                            if (line[j] ~ /^[[:space:]]*$/ || line[j] ~ /^[[:space:]]*\/\//) continue
                            nxt = line[j]; break
                        }
                        sep = (nxt ~ /^[[:space:]]*\}/) ? "" : ","
                        printf "    \"%s\": {\n      \"command\": \"%s\",\n      \"args\": [\"%s\"]\n    }%s\n", name, cmd, agent, sep
                    }
                }
                if (!done) exit 1
            }' "${ACP_JSON}" > "${TMP_JSON}" || { rm -f "${TMP_JSON}"; echo "could not patch ${ACP_JSON}, add \"${NAME}\" by hand" >&2; exit 1; }
        mv -f "${TMP_JSON}" "${ACP_JSON}" || exit 1
        echo "added \"${NAME}\" to ${ACP_JSON}"
    fi
    exit 0
fi

# Script directory = directory of $0 (without the script name). When called via a
# symbolic link, $0 is the link path, so everything ends up next to the link.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Called via ./sbx-acp/acp.sh: the project root is the parent folder.
if [ "$(basename "${SCRIPT_DIR}")" = "sbx-acp" ]; then
    SCRIPT_DIR="$(dirname "${SCRIPT_DIR}")"
fi
# All files acp.sh produces (logs, generated login scripts) live in ./sbx-acp.
ACP_DIR="${SCRIPT_DIR}/sbx-acp"
LOGDIR="${ACP_DIR}/logs"
mkdir -p "${LOGDIR}"
LOGFILE="${LOGDIR}/acp.log"

# Standard log format: <ISO-8601 timestamp> [<LEVEL>] [pid <PID>] <message>
log() {
    local level="$1"
    shift
    printf '%s [%s] [pid %s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${level}" "$$" "$*" >> "${LOGFILE}"
}

SANDBOX="$(basename "${SCRIPT_DIR}" | tr '_ ' '-')-${1}"
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
# sandbox: ./sbx-acp/claude-projects is part of the mounted workspace, so it survives
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
