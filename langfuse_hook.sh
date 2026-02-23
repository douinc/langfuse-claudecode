#!/usr/bin/env bash
#
# Claude Code -> Langfuse hook (Pure Shell Implementation)
#
# Sends Claude Code conversation turns to Langfuse as traces with spans,
# generations, and tool observations. Runs on the "Stop" hook (after each
# assistant turn) and reads the JSONL transcript incrementally.
#
# Setup
# =====
#
# 1. Register the hook in ~/.claude/settings.json:
#
#    {
#      "hooks": {
#        "Stop": [
#          {
#            "hooks": [
#              {
#                "type": "command",
#                "command": "~/.claude/hooks/langfuse-claudecode/langfuse_hook.sh"
#              }
#            ]
#          }
#        ]
#      }
#    }
#
# 2. Add credentials in .claude/settings.local.json (gitignored):
#
#    {
#      "env": {
#        "TRACE_TO_LANGFUSE": "true",
#        "LANGFUSE_PUBLIC_KEY": "pk-lf-...",
#        "LANGFUSE_SECRET_KEY": "sk-lf-...",
#        "LANGFUSE_BASE_URL": "https://cloud.langfuse.com",
#        "CC_LANGFUSE_USER_ID": "user@example.com",
#        "CC_LANGFUSE_ENVIRONMENT": "my-project"
#      }
#    }
#
# Environment variables
# =====================
#
# Required:
#   TRACE_TO_LANGFUSE       Set to "true" to enable tracing.
#   LANGFUSE_PUBLIC_KEY     Langfuse project public key.
#   LANGFUSE_SECRET_KEY     Langfuse project secret key.
#
# Optional:
#   LANGFUSE_BASE_URL       Langfuse host (default: https://cloud.langfuse.com).
#   CC_LANGFUSE_USER_ID     User ID attached to all traces (e.g. email).
#   CC_LANGFUSE_ENVIRONMENT Environment name for Langfuse.
#   CC_LANGFUSE_DEBUG       Set to "true" for verbose logging.
#   CC_LANGFUSE_MAX_CHARS   Max characters before truncation (default: 20000).
#

set -euo pipefail

# --- Paths ---
STATE_DIR="${HOME}/.claude/state"
LOG_FILE="${STATE_DIR}/langfuse_hook.log"
STATE_FILE="${STATE_DIR}/langfuse_state.json"
LOCK_FILE="${STATE_DIR}/langfuse_state.lock"

# --- Configuration ---
DEBUG="${CC_LANGFUSE_DEBUG:-false}"
MAX_CHARS="${CC_LANGFUSE_MAX_CHARS:-20000}"
BASE_URL="${LANGFUSE_BASE_URL:-https://cloud.langfuse.com}"

# --- Logging ---
log() {
    local level="$1"
    shift
    local message="$*"

    mkdir -p "$STATE_DIR" 2>/dev/null || true
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} [${level}] ${message}" >> "$LOG_FILE" 2>/dev/null || true
}

debug() {
    [[ "$DEBUG" == "true" ]] && log "DEBUG" "$@"
}

info() {
    log "INFO" "$@"
}

warn() {
    log "WARN" "$@"
}

error() {
    log "ERROR" "$@"
}

# --- Fail-open wrapper ---
# All errors result in exit 0 to never block Claude Code
fail_open() {
    debug "Exiting (fail-open): $*"
    exit 0
}

# --- Check prerequisites ---
check_prerequisites() {
    if [[ "${TRACE_TO_LANGFUSE:-}" != "true" ]]; then
        fail_open "TRACE_TO_LANGFUSE not set to 'true'"
    fi

    if [[ -z "${LANGFUSE_PUBLIC_KEY:-}" ]]; then
        fail_open "LANGFUSE_PUBLIC_KEY not set"
    fi

    if [[ -z "${LANGFUSE_SECRET_KEY:-}" ]]; then
        fail_open "LANGFUSE_SECRET_KEY not set"
    fi

    if ! command -v jq &>/dev/null; then
        fail_open "jq not found in PATH"
    fi

    if ! command -v curl &>/dev/null; then
        fail_open "curl not found in PATH"
    fi
}

# --- UUID generation ---
generate_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        # Fallback: generate pseudo-UUID using /dev/urandom
        local N B T
        for (( N=0; N < 16; ++N )); do
            B=$(( RANDOM % 256 ))
            case $N in
                6) printf '4%x' $(( B % 16 )) ;;
                8) printf '%x%x' $(( (B & 0x3F) | 0x80 )) $(( RANDOM % 16 )) ;;
                3|5|7|9) printf '%02x-' $B ;;
                *) printf '%02x' $B ;;
            esac
        done
        echo
    fi
}

# --- State management ---
load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo '{}'
    fi
}

save_state() {
    local state="$1"
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    local tmp_file="${STATE_FILE}.tmp"
    echo "$state" | jq '.' > "$tmp_file" 2>/dev/null || {
        debug "Failed to save state"
        return 1
    }
    mv "$tmp_file" "$STATE_FILE" 2>/dev/null || true
}

state_key() {
    local session_id="$1"
    local transcript_path="$2"
    local raw="${session_id}::${transcript_path}"

    # Try sha256sum (Linux), then shasum (macOS), then fallback
    if command -v sha256sum &>/dev/null; then
        echo -n "$raw" | sha256sum | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        echo -n "$raw" | shasum -a 256 | awk '{print $1}'
    else
        # Fallback: simple hash using cksum
        echo -n "$raw" | cksum | awk '{print $1}'
    fi
}

get_session_state() {
    local state="$1"
    local key="$2"
    echo "$state" | jq -r --arg key "$key" '.[$key] // {offset: 0, buffer: "", turn_count: 0, updated: ""}'
}

update_session_state() {
    local state="$1"
    local key="$2"
    local offset="$3"
    local buffer="$4"
    local turn_count="$5"

    local updated
    # Try GNU date format, fallback to BSD date
    if date --version &>/dev/null 2>&1; then
        # GNU date
        updated=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    else
        # BSD date (macOS)
        updated=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    fi

    echo "$state" | jq --arg key "$key" \
        --argjson offset "$offset" \
        --arg buffer "$buffer" \
        --argjson turn_count "$turn_count" \
        --arg updated "$updated" \
        '.[$key] = {offset: $offset, buffer: $buffer, turn_count: $turn_count, updated: $updated}'
}

# --- Read hook payload from stdin ---
read_hook_payload() {
    local payload
    payload=$(cat 2>/dev/null || echo '{}')
    if [[ -z "$payload" ]]; then
        echo '{}'
    else
        echo "$payload"
    fi
}

# --- Extract session and transcript from payload ---
extract_session_and_transcript() {
    local payload="$1"

    local session_id
    session_id=$(echo "$payload" | jq -r '.sessionId // .session_id // .session.id // ""')

    local transcript_path
    transcript_path=$(echo "$payload" | jq -r '.transcriptPath // .transcript_path // .transcript.path // ""')

    if [[ -z "$session_id" ]] || [[ -z "$transcript_path" ]]; then
        fail_open "Missing sessionId or transcriptPath in hook payload"
    fi

    # Expand ~ and resolve path
    transcript_path="${transcript_path/#\~/$HOME}"

    if [[ ! -f "$transcript_path" ]]; then
        fail_open "Transcript file not found: $transcript_path"
    fi

    echo "$session_id"
    echo "$transcript_path"
}

# --- Read incremental transcript ---
read_incremental() {
    local file="$1"
    local offset="$2"
    local buffer="$3"

    local content
    if [[ "$offset" -eq 0 ]]; then
        content=$(cat "$file" 2>/dev/null || echo "")
    else
        # Read from offset (byte position)
        content=$(tail -c "+$((offset + 1))" "$file" 2>/dev/null || echo "")
    fi

    # Prepend buffer (incomplete last line from previous read)
    if [[ -n "$buffer" ]]; then
        content="${buffer}${content}"
    fi

    # Split into complete lines
    local lines
    lines=$(echo "$content" | sed '$d' 2>/dev/null || echo "")

    # Save incomplete last line
    local new_buffer
    new_buffer=$(echo "$content" | tail -n 1)

    # Check if last line is complete (ends with newline)
    if [[ "$content" == *$'\n' ]]; then
        new_buffer=""
    fi

    # Calculate new offset
    local new_offset
    new_offset=$((offset + ${#content} - ${#new_buffer}))

    echo "$new_offset"
    echo "$new_buffer"
    echo "$lines"
}

# --- Truncate text if needed ---
truncate_text() {
    local text="$1"
    local max_chars="${2:-$MAX_CHARS}"

    local len=${#text}
    if [[ $len -le $max_chars ]]; then
        echo "$text"
        echo "false"
        echo "$len"
        echo "$len"
        echo ""
    else
        local truncated="${text:0:$max_chars}"
        local sha
        # Try sha256sum (Linux), then shasum (macOS), then fallback
        if command -v sha256sum &>/dev/null; then
            sha=$(echo -n "$text" | sha256sum | awk '{print $1}')
        elif command -v shasum &>/dev/null; then
            sha=$(echo -n "$text" | shasum -a 256 | awk '{print $1}')
        else
            sha=$(echo -n "$text" | cksum | awk '{print $1}')
        fi
        echo "$truncated"
        echo "true"
        echo "$len"
        echo "$max_chars"
        echo "$sha"
    fi
}

# --- Get host metadata ---
get_host_metadata() {
    local host_ip
    host_ip=$(curl -s --max-time 2 https://api.ipify.org 2>/dev/null || echo "")

    local host_name
    host_name=$(hostname 2>/dev/null || echo "")

    local host_cwd
    host_cwd=$(pwd 2>/dev/null || echo "")

    jq -n \
        --arg ip "$host_ip" \
        --arg name "$host_name" \
        --arg cwd "$host_cwd" \
        '{host_ip: $ip, host_name: $name, host_cwd: $cwd}'
}

# --- Parse transcript and group into turns ---
parse_turns() {
    local lines="$1"

    # Parse each line as JSON and group by turns
    # A turn is: user message → assistant message(s) → tool results

    local turns='[]'
    local current_turn='{}'
    local in_turn=false

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local msg_type
        msg_type=$(echo "$line" | jq -r '.type // ""')

        local role
        role=$(echo "$line" | jq -r '.message.role // ""')

        if [[ "$msg_type" == "user" ]] && [[ "$role" == "user" ]]; then
            # Check if this is tool_result
            local is_tool_result
            is_tool_result=$(echo "$line" | jq '[.message.content[]? | select(.type == "tool_result")] | length > 0')

            if [[ "$is_tool_result" == "true" ]]; then
                # Append to current turn's tool_results
                current_turn=$(echo "$current_turn" | jq --argjson msg "$line" \
                    '.tool_results += [$msg]')
            else
                # Start new turn
                if [[ "$in_turn" == "true" ]]; then
                    turns=$(echo "$turns" | jq --argjson turn "$current_turn" '. += [$turn]')
                fi
                current_turn=$(echo "$line" | jq '{user_message: .}')
                in_turn=true
            fi
        elif [[ "$msg_type" == "assistant" ]] && [[ "$role" == "assistant" ]]; then
            # Append to current turn's assistant_messages
            current_turn=$(echo "$current_turn" | jq --argjson msg "$line" \
                '.assistant_messages += [$msg]')
        fi
    done <<< "$lines"

    # Add last turn
    if [[ "$in_turn" == "true" ]]; then
        turns=$(echo "$turns" | jq --argjson turn "$current_turn" '. += [$turn]')
    fi

    echo "$turns"
}

# --- Build Langfuse events for a single turn ---
build_turn_events() {
    local turn="$1"
    local session_id="$2"
    local user_id="$3"
    local turn_number="$4"
    local transcript_path="$5"
    local host_meta="$6"

    local trace_id
    trace_id=$(generate_uuid)

    local timestamp
    # Try GNU date format, fallback to BSD date
    if date --version &>/dev/null 2>&1; then
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    else
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    fi

    # Extract user text
    local user_text
    user_text=$(echo "$turn" | jq -r '.user_message.message.content | if type == "array" then [.[] | select(.type == "text") | .text] | join("\n") elif type == "string" then . else "" end')

    # Extract assistant text and tools
    local assistant_text=""
    local tools='[]'
    local model=""

    local assistant_messages
    assistant_messages=$(echo "$turn" | jq -c '.assistant_messages[]? // empty')

    while IFS= read -r assistant_msg; do
        [[ -z "$assistant_msg" ]] && continue

        # Extract model
        if [[ -z "$model" ]]; then
            model=$(echo "$assistant_msg" | jq -r '.message.model // ""')
        fi

        # Extract text content
        local text_blocks
        text_blocks=$(echo "$assistant_msg" | jq -r '[.message.content[]? | select(.type == "text") | .text] | join("\n")')
        if [[ -n "$text_blocks" ]]; then
            assistant_text="${assistant_text}${text_blocks}\n"
        fi

        # Extract tool uses
        local tool_uses
        tool_uses=$(echo "$assistant_msg" | jq -c '[.message.content[]? | select(.type == "tool_use")]')
        if [[ "$tool_uses" != "[]" ]]; then
            tools=$(echo "$tools" | jq --argjson new "$tool_uses" '. += $new')
        fi
    done <<< "$assistant_messages"

    # Process tool results
    local tool_results='[]'
    local tool_result_msgs
    tool_result_msgs=$(echo "$turn" | jq -c '.tool_results[]? // empty')

    while IFS= read -r tool_result_msg; do
        [[ -z "$tool_result_msg" ]] && continue

        local results
        results=$(echo "$tool_result_msg" | jq -c '[.message.content[]? | select(.type == "tool_result")]')
        tool_results=$(echo "$tool_results" | jq --argjson new "$results" '. += $new')
    done <<< "$tool_result_msgs"

    # Truncate texts
    local user_text_truncated user_truncated user_orig_len user_kept_len user_sha
    read -r user_text_truncated user_truncated user_orig_len user_kept_len user_sha <<< "$(truncate_text "$user_text")"

    local assistant_text_truncated assistant_truncated assistant_orig_len assistant_kept_len assistant_sha
    read -r assistant_text_truncated assistant_truncated assistant_orig_len assistant_kept_len assistant_sha <<< "$(truncate_text "$assistant_text")"

    # Build metadata
    local user_text_meta
    user_text_meta=$(jq -n \
        --arg truncated "$user_truncated" \
        --argjson orig_len "$user_orig_len" \
        --argjson kept_len "$user_kept_len" \
        --arg sha "$user_sha" \
        '{truncated: ($truncated == "true"), orig_len: $orig_len, kept_len: $kept_len, sha256: $sha}')

    local assistant_text_meta
    assistant_text_meta=$(jq -n \
        --arg truncated "$assistant_truncated" \
        --argjson orig_len "$assistant_orig_len" \
        --argjson kept_len "$assistant_kept_len" \
        --arg sha "$assistant_sha" \
        '{truncated: ($truncated == "true"), orig_len: $orig_len, kept_len: $kept_len, sha256: $sha}')

    local tool_count
    tool_count=$(echo "$tools" | jq 'length')

    # Build trace event
    local trace_event
    trace_event=$(jq -n \
        --arg id "$(generate_uuid)" \
        --arg timestamp "$timestamp" \
        --arg trace_id "$trace_id" \
        --arg name "Claude Code - Turn $turn_number" \
        --arg session_id "$session_id" \
        --arg user_id "$user_id" \
        --argjson host_meta "$host_meta" \
        '{
            id: $id,
            type: "trace-create",
            timestamp: $timestamp,
            body: {
                id: $trace_id,
                timestamp: $timestamp,
                name: $name,
                session_id: $session_id,
                user_id: $user_id,
                tags: ["claude-code"],
                metadata: $host_meta
            }
        }')

    # Build span event
    local span_metadata
    span_metadata=$(echo "$host_meta" | jq \
        --arg source "claude-code" \
        --arg session_id "$session_id" \
        --argjson turn_number "$turn_number" \
        --arg transcript_path "$transcript_path" \
        --argjson user_text_meta "$user_text_meta" \
        '. + {
            source: $source,
            session_id: $session_id,
            turn_number: $turn_number,
            transcript_path: $transcript_path,
            user_text: $user_text_meta
        }')

    local span_event
    span_event=$(jq -n \
        --arg id "$(generate_uuid)" \
        --arg timestamp "$timestamp" \
        --arg trace_id "$trace_id" \
        --arg name "Claude Code - Turn $turn_number" \
        --arg user_text "$user_text_truncated" \
        --arg assistant_text "$assistant_text_truncated" \
        --argjson metadata "$span_metadata" \
        '{
            id: $id,
            type: "observation-create",
            timestamp: $timestamp,
            body: {
                id: $id,
                trace_id: $trace_id,
                type: "span",
                name: $name,
                start_time: $timestamp,
                end_time: $timestamp,
                input: {role: "user", content: $user_text},
                output: {role: "assistant", content: $assistant_text},
                metadata: $metadata
            }
        }')

    # Build generation event
    local generation_event
    generation_event=$(jq -n \
        --arg id "$(generate_uuid)" \
        --arg timestamp "$timestamp" \
        --arg trace_id "$trace_id" \
        --arg model "$model" \
        --arg user_text "$user_text_truncated" \
        --arg assistant_text "$assistant_text_truncated" \
        --argjson assistant_text_meta "$assistant_text_meta" \
        --argjson tool_count "$tool_count" \
        '{
            id: $id,
            type: "observation-create",
            timestamp: $timestamp,
            body: {
                id: $id,
                trace_id: $trace_id,
                type: "generation",
                name: "Claude Response",
                model: $model,
                start_time: $timestamp,
                end_time: $timestamp,
                input: {role: "user", content: $user_text},
                output: {role: "assistant", content: $assistant_text},
                metadata: {
                    assistant_text: $assistant_text_meta,
                    tool_count: $tool_count
                }
            }
        }')

    # Build tool events
    local tool_events='[]'
    local i=0
    local tool_count_int
    tool_count_int=$(echo "$tools" | jq 'length')

    while [[ $i -lt $tool_count_int ]]; do
        local tool
        tool=$(echo "$tools" | jq -c ".[$i]")

        local tool_name
        tool_name=$(echo "$tool" | jq -r '.name // ""')

        local tool_id
        tool_id=$(echo "$tool" | jq -r '.id // ""')

        local tool_input
        tool_input=$(echo "$tool" | jq -c '.input // {}')

        # Find matching tool result
        local tool_result
        tool_result=$(echo "$tool_results" | jq -c --arg id "$tool_id" '.[] | select(.tool_use_id == $id) // empty' | head -n 1)

        local tool_output
        if [[ -n "$tool_result" ]]; then
            tool_output=$(echo "$tool_result" | jq -c '.content // ""')
        else
            tool_output='""'
        fi

        # Truncate tool input/output
        local tool_input_str
        tool_input_str=$(echo "$tool_input" | jq -r 'tostring')

        local tool_output_str
        tool_output_str=$(echo "$tool_output" | jq -r 'if type == "string" then . else tostring end')

        local input_truncated input_trunc input_orig input_kept input_sha
        read -r input_truncated input_trunc input_orig input_kept input_sha <<< "$(truncate_text "$tool_input_str")"

        local output_truncated output_trunc output_orig output_kept output_sha
        read -r output_truncated output_trunc output_orig output_kept output_sha <<< "$(truncate_text "$tool_output_str")"

        local input_meta
        input_meta=$(jq -n \
            --arg truncated "$input_trunc" \
            --argjson orig_len "$input_orig" \
            --argjson kept_len "$input_kept" \
            --arg sha "$input_sha" \
            '{truncated: ($truncated == "true"), orig_len: $orig_len, kept_len: $kept_len, sha256: $sha}')

        local output_meta
        output_meta=$(jq -n \
            --arg truncated "$output_trunc" \
            --argjson orig_len "$output_orig" \
            --argjson kept_len "$output_kept" \
            --arg sha "$output_sha" \
            '{truncated: ($truncated == "true"), orig_len: $orig_len, kept_len: $kept_len, sha256: $sha}')

        local tool_event
        tool_event=$(jq -n \
            --arg id "$(generate_uuid)" \
            --arg timestamp "$timestamp" \
            --arg trace_id "$trace_id" \
            --arg name "Tool: $tool_name" \
            --arg tool_name "$tool_name" \
            --arg tool_id "$tool_id" \
            --arg input "$input_truncated" \
            --arg output "$output_truncated" \
            --argjson input_meta "$input_meta" \
            --argjson output_meta "$output_meta" \
            '{
                id: $id,
                type: "observation-create",
                timestamp: $timestamp,
                body: {
                    id: $id,
                    trace_id: $trace_id,
                    type: "tool",
                    name: $name,
                    start_time: $timestamp,
                    end_time: $timestamp,
                    input: $input,
                    output: $output,
                    metadata: {
                        tool_name: $tool_name,
                        tool_id: $tool_id,
                        input_meta: $input_meta,
                        output_meta: $output_meta
                    }
                }
            }')

        tool_events=$(echo "$tool_events" | jq --argjson event "$tool_event" '. += [$event]')
        i=$((i + 1))
    done

    # Combine all events
    jq -n \
        --argjson trace "$trace_event" \
        --argjson span "$span_event" \
        --argjson generation "$generation_event" \
        --argjson tools "$tool_events" \
        '[$trace, $span, $generation] + $tools'
}

# --- Send batch to Langfuse ---
send_batch() {
    local events="$1"

    local batch
    batch=$(jq -n --argjson events "$events" '{batch: $events}')

    local auth_header
    auth_header=$(echo -n "${LANGFUSE_PUBLIC_KEY}:${LANGFUSE_SECRET_KEY}" | base64)

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Authorization: Basic ${auth_header}" \
        -H "Content-Type: application/json" \
        -d "$batch" \
        "${BASE_URL}/api/public/ingestion" 2>&1) || {
        debug "Curl failed: $response"
        return 1
    }

    local http_code
    http_code=$(echo "$response" | tail -n 1)

    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" =~ ^(200|207)$ ]]; then
        debug "Batch sent successfully: HTTP $http_code"
        return 0
    else
        debug "Batch send failed: HTTP $http_code, body: $body"
        return 1
    fi
}

# --- Main ---
main() {
    check_prerequisites

    # Read hook payload
    local payload
    payload=$(read_hook_payload)

    debug "Hook payload: $payload"

    # Extract session and transcript
    local session_id transcript_path
    read -r session_id < <(extract_session_and_transcript "$payload" | head -n 1)
    read -r transcript_path < <(extract_session_and_transcript "$payload" | tail -n 1)

    debug "Session ID: $session_id"
    debug "Transcript: $transcript_path"

    # Acquire lock (best effort, fail-open if flock not available)
    exec 200>"$LOCK_FILE" 2>/dev/null || true
    if command -v flock &>/dev/null; then
        if ! flock -w 2 200 2>/dev/null; then
            debug "Failed to acquire lock, proceeding without it"
        fi
    else
        debug "flock not available, proceeding without file locking"
    fi

    # Load state
    local state
    state=$(load_state)

    local key
    key=$(state_key "$session_id" "$transcript_path")

    local session_state
    session_state=$(get_session_state "$state" "$key")

    local offset
    offset=$(echo "$session_state" | jq -r '.offset // 0')

    local buffer
    buffer=$(echo "$session_state" | jq -r '.buffer // ""')

    local turn_count
    turn_count=$(echo "$session_state" | jq -r '.turn_count // 0')

    debug "State loaded: offset=$offset, buffer_len=${#buffer}, turn_count=$turn_count"

    # Read incremental transcript
    local new_offset new_buffer lines
    {
        read -r new_offset
        read -r new_buffer
        lines=$(cat)
    } < <(read_incremental "$transcript_path" "$offset" "$buffer")

    debug "Read incremental: new_offset=$new_offset, lines_count=$(echo "$lines" | wc -l)"

    # Parse turns
    local turns
    turns=$(parse_turns "$lines")

    local turns_count
    turns_count=$(echo "$turns" | jq 'length')

    debug "Parsed $turns_count turns"

    # Get host metadata
    local host_meta
    host_meta=$(get_host_metadata)

    # Process each turn
    local i=0
    while [[ $i -lt $turns_count ]]; do
        local turn
        turn=$(echo "$turns" | jq -c ".[$i]")

        local turn_number
        turn_number=$((turn_count + i + 1))

        debug "Processing turn $turn_number"

        # Build events
        local events
        events=$(build_turn_events "$turn" "$session_id" "${CC_LANGFUSE_USER_ID:-}" "$turn_number" "$transcript_path" "$host_meta") || {
            error "Failed to build events for turn $turn_number"
            i=$((i + 1))
            continue
        }

        # Send batch
        if ! send_batch "$events"; then
            error "Failed to send batch for turn $turn_number"
        fi

        i=$((i + 1))
    done

    # Update state
    local new_turn_count
    new_turn_count=$((turn_count + turns_count))

    local updated_state
    updated_state=$(update_session_state "$state" "$key" "$new_offset" "$new_buffer" "$new_turn_count")

    save_state "$updated_state"

    debug "State saved: offset=$new_offset, turn_count=$new_turn_count"

    # Release lock
    if command -v flock &>/dev/null; then
        flock -u 200 2>/dev/null || true
    fi

    info "Processed $turns_count turns for session $session_id"
}

# Run main and always exit 0 (fail-open)
main || fail_open "Script failed"
exit 0
