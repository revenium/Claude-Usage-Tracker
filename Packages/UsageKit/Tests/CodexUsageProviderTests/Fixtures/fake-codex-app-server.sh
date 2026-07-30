#!/bin/sh

extract_id() {
    printf '%s\n' "$1" \
        | /usr/bin/sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p'
}

read_line() {
    IFS= read -r received_line
}

initialize_response() {
    printf '{"id":%s,"result":{"codexHome":"/fake","platformFamily":"unix","platformOs":"macos","userAgent":"fake"}}\n' "$1"
}

scenario="${TEST_SCENARIO:-happy}"

read_line || exit 10
initialize_line="$received_line"
initialize_id="$(extract_id "$initialize_line")"

case "$initialize_line" in
    *'"method":"initialize"'*) ;;
    *) exit 11 ;;
esac

if [ "$scenario" = "startup_timeout" ]; then
    read_line
    exit 0
fi

if [ "$scenario" = "early_exit_startup" ]; then
    exit 16
fi

if [ "$scenario" = "fragmented_initialize" ]; then
    printf '{"id":'
    printf '%s,"result":{"codexHome":"/fake",' "$initialize_id"
    printf '"platformFamily":"unix","platformOs":"macos","userAgent":"fake"}}'
    printf '\n'
else
    initialize_response "$initialize_id"
fi

read_line || exit 12
initialized_line="$received_line"
case "$initialized_line" in
    *'"method":"initialized"'*)
        case "$initialized_line" in
            *'"id"'*) exit 13 ;;
        esac
        ;;
    *) exit 14 ;;
esac

if [ "$scenario" = "blocked_stdin" ]; then
    trap '' TERM
    while :; do
        :
    done
fi

read_line || exit 15
request_line="$received_line"
request_id="$(extract_id "$request_line")"

case "$scenario" in
    happy|fragmented_initialize)
        printf '{"id":%s,"result":{"ok":true}}\n' "$request_id"
        ;;
    fragmented_response)
        printf '{"id":'
        printf '%s,"result":' "$request_id"
        printf '{"ok":'
        printf 'true}}\n'
        ;;
    interleaved_notifications)
        printf '{"method":"account/updated","params":{"authMode":"chatgpt"}}\n'
        printf '{"method":"account/rateLimits/updated","params":{"sequence":1}}\n'
        printf '{"id":%s,"result":{"ok":true}}\n' "$request_id"
        ;;
    two_requests)
        printf '{"id":%s,"result":{"sequence":1}}\n' "$request_id"
        read_line || exit 20
        second_id="$(extract_id "$received_line")"
        if [ "$second_id" -le "$request_id" ]; then
            exit 21
        fi
        printf '{"id":%s,"result":{"sequence":2}}\n' "$second_id"
        ;;
    duplicate_response)
        printf '{"id":%s,"result":{"sequence":1}}\n' "$request_id"
        printf '{"id":%s,"result":{"duplicate":true}}\n' "$request_id"
        read_line || exit 22
        ;;
    mismatched_integer_id)
        wrong_id=$((request_id + 40))
        printf '{"id":%s,"result":{}}\n' "$wrong_id"
        ;;
    mismatched_string_id)
        printf '{"id":"super-secret-request-id","result":{}}\n'
        ;;
    malformed)
        printf '{not-json}\n'
        ;;
    oversized_line)
        printf '{"method":"'
        i=0
        while [ "$i" -lt 400 ]; do
            printf 'x'
            i=$((i + 1))
        done
        printf '"}\n'
        ;;
    stdout_overflow)
        i=0
        while [ "$i" -lt 30 ]; do
            printf '{"method":"notice","params":{"value":"xxxxxxxxxxxxxxxx"}}\n'
            i=$((i + 1))
        done
        ;;
    stderr_overflow)
        i=0
        while [ "$i" -lt 400 ]; do
            printf 's' >&2
            i=$((i + 1))
        done
        read_line
        ;;
    request_timeout|cancellation)
        read_line
        ;;
    ignore_termination)
        trap '' TERM
        while :; do
            :
        done
        ;;
    early_exit_request)
        exit 17
        ;;
    stdout_eof)
        exec 1>&-
        read_line
        ;;
    rpc_error)
        printf '{"id":%s,"error":{"code":401,"message":"super-secret-rpc-message","data":{"token":"super-secret-token"}}}\n' "$request_id"
        ;;
    stderr_redaction)
        printf 'super-secret-stderr-value\n' >&2
        exit 18
        ;;
    environment)
        codex_home_matches=false
        safe_flag_matches=false
        parent_home_absent=false
        if [ "${CODEX_HOME:-}" = "${EXPECTED_CODEX_HOME:-}" ]; then
            codex_home_matches=true
        fi
        if [ "${SAFE_FLAG:-}" = "allowed" ]; then
            safe_flag_matches=true
        fi
        if [ -z "${HOME+x}" ]; then
            parent_home_absent=true
        fi
        printf '{"id":%s,"result":{"codexHomeMatches":%s,"safeFlagMatches":%s,"parentHomeAbsent":%s}}\n' \
            "$request_id" "$codex_home_matches" "$safe_flag_matches" "$parent_home_absent"
        ;;
    *)
        exit 99
        ;;
esac
