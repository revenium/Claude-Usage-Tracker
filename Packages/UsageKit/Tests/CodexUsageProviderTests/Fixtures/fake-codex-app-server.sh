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

if [ -n "${PID_FILE:-}" ]; then
    printf '%s\n' "$$" > "$PID_FILE"
fi
if [ -n "${PROCESS_LOG:-}" ]; then
    printf '%s\n' "$$" >> "$PROCESS_LOG"
fi

read_line || exit 10
initialize_line="$received_line"
initialize_id="$(extract_id "$initialize_line")"
if [ -n "${INITIALIZATION_LOG:-}" ]; then
    printf '%s\n' "$initialize_line" >> "$INITIALIZATION_LOG"
fi

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
    if [ -n "${BLOCKED_STDIN_READY_FILE:-}" ]; then
        printf 'ready\n' > "$BLOCKED_STDIN_READY_FILE"
    fi
    trap '' TERM
    while :; do
        /bin/sleep 1
    done
fi

while :; do
read_line || exit 0
request_line="$received_line"
request_id="$(extract_id "$request_line")"

if [ -n "${REQUEST_LOG:-}" ]; then
    printf '%s\n' "$request_line" >> "$REQUEST_LOG"
fi

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
    multi_inflight_out_of_order)
        first_line="$request_line"
        first_id="$request_id"
        read_line || exit 23
        second_line="$received_line"
        second_id="$(extract_id "$second_line")"
        if [ -n "${REQUEST_LOG:-}" ]; then
            printf '%s\n' "$second_line" >> "$REQUEST_LOG"
        fi
        case "$first_line" in
            *'"method":"account/read"'*|*'"method":"account\/read"'*)
                first_label=account
                ;;
            *)
                first_label=usage
                ;;
        esac
        case "$second_line" in
            *'"method":"account/read"'*|*'"method":"account\/read"'*)
                second_label=account
                ;;
            *)
                second_label=usage
                ;;
        esac
        printf '{"method":"account/updated","params":{"phase":"between"}}\n'
        printf '{"id":"%s","result":{"request":"%s"}}\n' \
            "$second_id" "$second_label"
        printf '{"method":"account/rateLimits/updated","params":{"phase":"after-second"}}\n'
        printf '{"id":%s,"result":{"request":"%s"}}\n' \
            "$first_id" "$first_label"
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
            /bin/sleep 1
        done
        ;;
    queued_notification_wait_for_close)
        printf '{"method":"account/updated","params":{"queued":true}}\n'
        printf '{"id":%s,"result":{"ok":true}}\n' "$request_id"
        while read_line; do :; done
        ;;
    descendant_tree)
        (
            trap '' TERM
            (
                trap '' TERM
                while :; do
                    /bin/sleep 1
                done
            ) &
            grandchild_pid=$!
            if [ -n "${GRANDCHILD_PID_FILE:-}" ]; then
                printf '%s\n' "$grandchild_pid" > "$GRANDCHILD_PID_FILE"
            fi
            wait "$grandchild_pid"
        ) &
        child_pid=$!
        if [ -n "${CHILD_PID_FILE:-}" ]; then
            printf '%s\n' "$child_pid" > "$CHILD_PID_FILE"
        fi
        trap '' TERM
        while :; do
            /bin/sleep 1
        done
        ;;
    descendant_after_root_exit)
        root_pid=$$
        (
            child_term() {
                # The production teardown signals known descendants before the
                # root. Wait until the root has actually exited so this child
                # creates a process that a root-only escalation census cannot
                # discover.
                while kill -0 "$root_pid" 2>/dev/null; do
                    /bin/sleep 0.005
                done
                (
                    trap '' TERM
                    while :; do
                        /bin/sleep 1
                    done
                ) &
                late_descendant_pid=$!
                if [ -n "${LATE_DESCENDANT_PID_FILE:-}" ]; then
                    printf '%s\n' "$late_descendant_pid" \
                        > "$LATE_DESCENDANT_PID_FILE"
                fi
                trap '' TERM
            }

            trap 'child_term' TERM
            if [ -n "${CHILD_PID_FILE:-}" ]; then
                printf '%s\n' "$$" > "$CHILD_PID_FILE"
            fi
            while :; do
                /bin/sleep 1
            done
        ) &
        trap 'exit 0' TERM
        while :; do
            /bin/sleep 1
        done
        ;;
    early_exit_request)
        exit 17
        ;;
    exit_after_buffered_frames)
        printf '{"id":%s,"result":{"buffered":true}}\n' "$request_id"
        printf '{"method":"account/updated","params":{"sequence":1}}\n'
        printf '{"method":"account/rateLimits/updated","params":{"sequence":2}}\n'
        exit 0
        ;;
    stdout_eof)
        exec 1>&-
        read_line
        ;;
    rpc_error)
        printf '{"id":%s,"error":{"code":401,"message":"redaction-sentinel","data":{"opaque":"sensitive-sentinel"}}}\n' "$request_id"
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
    provider_current)
        case "$request_line" in
            *'"method":"account/read"'*|*'"method":"account\/read"'*)
                printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":"person@example.com","planType":"pro","futureAccountField":{"value":1}},"requiresOpenaiAuth":true,"futureRoot":true}}\n' "$request_id"
                ;;
            *'"method":"account/rateLimits/read"'*|*'"method":"account\/rateLimits\/read"'*)
                printf '{"id":%s,"result":{"rateLimits":{"limitId":"legacy","primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":"Codex","planType":"pro","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1785380400},"secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1785808800},"credits":{"hasCredits":true,"unlimited":false,"balance":"75.5"},"futureSnapshotField":true},"reviews":{"limitId":"reviews","limitName":"Code review","primary":{"usedPercent":7,"windowDurationMins":1440,"resetsAt":1785384000}}},"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"opaque-reset-id","resetType":"codexRateLimits","status":"available","grantedAt":1785000000,"expiresAt":1786000000,"title":"Reset","description":"Display only"}]},"futureRoot":{"version":2}}}\n' "$request_id"
                ;;
            *'"method":"account/usage/read"'*|*'"method":"account\/usage\/read"'*)
                printf '{"id":%s,"result":{"summary":{"lifetimeTokens":1234567,"peakDailyTokens":45678,"longestRunningTurnSec":540,"currentStreakDays":8,"longestStreakDays":14,"futureMetric":1},"dailyUsageBuckets":[{"startDate":"2026-06-18","tokens":12345},{"startDate":"2026-06-19","tokens":23456}],"futureUsageField":true}}\n' "$request_id"
                ;;
            *) exit 30 ;;
        esac
        ;;
    provider_usage_unavailable)
        case "$request_line" in
            *'"method":"account/read"'*|*'"method":"account\/read"'*)
                printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":null,"planType":"plus"},"requiresOpenaiAuth":true}}\n' "$request_id"
                ;;
            *'"method":"account/rateLimits/read"'*|*'"method":"account\/rateLimits\/read"'*)
                printf '{"id":%s,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":5}}}}\n' "$request_id"
                ;;
            *'"method":"account/usage/read"'*|*'"method":"account\/usage\/read"'*)
                printf '{"id":%s,"error":{"code":-32601,"message":"method unavailable secret-body"}}\n' "$request_id"
                ;;
            *) exit 31 ;;
        esac
        ;;
    provider_usage_empty)
        case "$request_line" in
            *'"method":"account/read"'*|*'"method":"account\/read"'*)
                printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":null,"planType":"plus"},"requiresOpenaiAuth":true}}\n' "$request_id"
                ;;
            *'"method":"account/rateLimits/read"'*|*'"method":"account\/rateLimits\/read"'*)
                printf '{"id":%s,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":5}}}}\n' "$request_id"
                ;;
            *'"method":"account/usage/read"'*|*'"method":"account\/usage\/read"'*)
                printf '{"id":%s,"result":{"futureOnly":true}}\n' "$request_id"
                ;;
            *) exit 32 ;;
        esac
        ;;
    provider_usage_malformed)
        case "$request_line" in
            *'"method":"account/read"'*|*'"method":"account\/read"'*)
                printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":null,"planType":"plus"},"requiresOpenaiAuth":true}}\n' "$request_id"
                ;;
            *'"method":"account/rateLimits/read"'*|*'"method":"account\/rateLimits\/read"'*)
                printf '{"id":%s,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":37}}}}\n' "$request_id"
                ;;
            *'"method":"account/usage/read"'*|*'"method":"account\/usage\/read"'*)
                printf '{"id":%s,"result":{"dailyUsageBuckets":[{"startDate":"2026-07-30","tokens":-1}]}}\n' "$request_id"
                ;;
            *) exit 46 ;;
        esac
        ;;
    provider_legacy_additive)
        case "$request_line" in
            *'"method":"account/read"'*|*'"method":"account\/read"'*)
                printf '{"id":%s,"result":{"account":{"type":"chatgpt","planType":"future_plan","unknown":"ignored"},"requiresOpenaiAuth":true}}\n' "$request_id"
                ;;
            *'"method":"account/rateLimits/read"'*|*'"method":"account\/rateLimits\/read"'*)
                printf '{"id":%s,"result":{"rateLimits":{"limitId":"legacy bucket","limitName":"Legacy bucket","primary":{"usedPercent":"12.5","windowDurationMins":"60","resetsAt":"1785380400"},"secondary":null,"unknown":"ignored"},"unknownRoot":42}}\n' "$request_id"
                ;;
            *'"method":"account/usage/read"'*|*'"method":"account\/usage\/read"'*)
                printf '{"id":%s,"result":{"summary":{"lifetimeTokens":null,"peakDailyTokens":null},"dailyUsageBuckets":null,"unknown":"ignored"}}\n' "$request_id"
                ;;
            *) exit 33 ;;
        esac
        ;;
    provider_lossy_dynamic)
        case "$request_line" in
            *'"method":"account/read"'*|*'"method":"account\/read"'*)
                printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":null,"planType":"team"},"requiresOpenaiAuth":true}}\n' "$request_id"
                ;;
            *'"method":"account/rateLimits/read"'*|*'"method":"account\/rateLimits\/read"'*)
                printf '{"id":%s,"result":{"rateLimits":{"limitId":"legacy","primary":{"usedPercent":88}},"rateLimitsByLimitId":{"valid":{"limitId":"valid","primary":{"usedPercent":11}},"malformed":{"limitId":"malformed","primary":{"usedPercent":"not-a-number"}}}}}\n' "$request_id"
                ;;
            *'"method":"account/usage/read"'*|*'"method":"account\/usage\/read"'*)
                printf '{"id":%s,"result":{}}\n' "$request_id"
                ;;
            *) exit 34 ;;
        esac
        ;;
    provider_malformed_account)
        printf '{"id":%s,"result":{"account":{"type":"chatgpt","planType":"plus"}}}\n' "$request_id"
        ;;
    provider_malformed_rate)
        case "$request_line" in
            *'"method":"account/read"'*|*'"method":"account\/read"'*)
                printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":null,"planType":"plus"},"requiresOpenaiAuth":true}}\n' "$request_id"
                ;;
            *'"method":"account/rateLimits/read"'*|*'"method":"account\/rateLimits\/read"'*)
                printf '{"id":%s,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":"not-a-number"}}}}\n' "$request_id"
                ;;
            *) exit 35 ;;
        esac
        ;;
    provider_credit_matrix)
        case "$request_line" in
            *'"method":"account/read"'*|*'"method":"account\/read"'*)
                printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":null,"planType":"pro"},"requiresOpenaiAuth":true}}\n' "$request_id"
                ;;
            *'"method":"account/rateLimits/read"'*|*'"method":"account\/rateLimits\/read"'*)
                printf '{"id":%s,"result":{"rateLimits":{"limitId":"finite","primary":{"usedPercent":1}},"rateLimitsByLimitId":{"finite":{"limitId":"finite","primary":{"usedPercent":1},"credits":{"hasCredits":true,"unlimited":false,"balance":"12.5"}},"disabled":{"limitId":"disabled","primary":{"usedPercent":2},"credits":{"hasCredits":false,"unlimited":false,"balance":"999"}},"unlimited":{"limitId":"unlimited","primary":{"usedPercent":3},"credits":{"hasCredits":true,"unlimited":true,"balance":"999"}}}}}\n' "$request_id"
                ;;
            *'"method":"account/usage/read"'*|*'"method":"account\/usage\/read"'*)
                printf '{"id":%s,"result":{}}\n' "$request_id"
                ;;
            *) exit 40 ;;
        esac
        ;;
    provider_daily_dst)
        case "$request_line" in
            *'"method":"account/read"'*|*'"method":"account\/read"'*)
                printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":null,"planType":"plus"},"requiresOpenaiAuth":true}}\n' "$request_id"
                ;;
            *'"method":"account/rateLimits/read"'*|*'"method":"account\/rateLimits\/read"'*)
                printf '{"id":%s,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":5}}}}\n' "$request_id"
                ;;
            *'"method":"account/usage/read"'*|*'"method":"account\/usage\/read"'*)
                printf '{"id":%s,"result":{"dailyUsageBuckets":[{"startDate":"2026-03-08","tokens":100}]}}\n' "$request_id"
                ;;
            *) exit 41 ;;
        esac
        ;;
    provider_refresh_overall_timeout)
        case "$request_line" in
            *'"method":"account/read"'*|*'"method":"account\/read"'*)
                sleep 0.5
                printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":null,"planType":"plus"},"requiresOpenaiAuth":true}}\n' "$request_id"
                ;;
            *'"method":"account/rateLimits/read"'*|*'"method":"account\/rateLimits\/read"'*)
                sleep 0.5
                printf '{"id":%s,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":5}}}}\n' "$request_id"
                ;;
            *'"method":"account/usage/read"'*|*'"method":"account\/usage\/read"'*)
                read_line
                ;;
            *) exit 43 ;;
        esac
        ;;
    provider_health_rate_rpc_failure|provider_health_rate_malformed)
        case "$request_line" in
            *'"method":"account/read"'*|*'"method":"account\/read"'*)
                printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":null,"planType":"plus"},"requiresOpenaiAuth":true}}\n' "$request_id"
                ;;
            *'"method":"account/rateLimits/read"'*|*'"method":"account\/rateLimits\/read"'*)
                if [ "$scenario" = "provider_health_rate_rpc_failure" ]; then
                    printf '{"id":%s,"error":{"code":-32601,"message":"required endpoint missing"}}\n' "$request_id"
                else
                    printf '{"id":%s,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":"invalid"}}}}\n' "$request_id"
                fi
                ;;
            *) exit 42 ;;
        esac
        ;;
    provider_api_key)
        printf '{"id":%s,"result":{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}}\n' "$request_id"
        ;;
    provider_bedrock)
        printf '{"id":%s,"result":{"account":{"type":"amazonBedrock","usesCodexManagedCredentials":false},"requiresOpenaiAuth":false}}\n' "$request_id"
        ;;
    provider_unknown_account)
        printf '{"id":%s,"result":{"account":{"type":"futureAuthMode","opaque":"value"},"requiresOpenaiAuth":false}}\n' "$request_id"
        ;;
    provider_unauthenticated)
        printf '{"id":%s,"result":{"account":null,"requiresOpenaiAuth":true}}\n' "$request_id"
        ;;
    provider_no_openai_account)
        printf '{"id":%s,"result":{"account":null,"requiresOpenaiAuth":false}}\n' "$request_id"
        ;;
    provider_login_browser)
        case "$request_line" in
            *'"method":"account/login/start"'*|*'"method":"account\/login\/start"'*)
                printf '{"id":%s,"result":{"type":"chatgpt","loginId":"browser-login-id","authUrl":"https://chatgpt.com/login?flow=codex","future":true}}\n' "$request_id"
                printf '{"method":"account/login/completed","params":{"loginId":"browser-login-id","success":true,"error":null,"future":true}}\n'
                ;;
            *) exit 36 ;;
        esac
        ;;
    provider_login_device)
        case "$request_line" in
            *'"method":"account/login/start"'*|*'"method":"account\/login\/start"'*)
                printf '{"id":%s,"result":{"type":"chatgptDeviceCode","loginId":"device-login-id","verificationUrl":"https://auth.openai.com/codex/device","userCode":"ABCD-1234"}}\n' "$request_id"
                printf '{"method":"account/login/completed","params":{"loginId":"device-login-id","success":true,"error":null}}\n'
                ;;
            *) exit 37 ;;
        esac
        ;;
    provider_login_already_authenticated)
        case "$request_line" in
            *'"method":"account/read"'*|*'"method":"account\/read"'*)
                printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":"already@example.com","planType":"plus"},"requiresOpenaiAuth":true}}\n' "$request_id"
                ;;
            *)
                # The provider must short-circuit before login/start once the
                # supported account preflight reports authenticated.
                exit 44
                ;;
        esac
        ;;
    provider_login_server_error)
        case "$request_line" in
            *'"method":"account/login/start"'*|*'"method":"account\/login\/start"'*)
                printf '{"id":%s,"error":{"code":500,"message":"synthetic login service failure"}}\n' "$request_id"
                ;;
            *)
                exit 45
                ;;
        esac
        ;;
    provider_login_cancel)
        printf '{"id":%s,"result":{"type":"chatgpt","loginId":"cancel-login-id","authUrl":"https://chatgpt.com/login"}}\n' "$request_id"
        read_line || exit 38
        cancel_line="$received_line"
        cancel_id="$(extract_id "$cancel_line")"
        if [ -n "${REQUEST_LOG:-}" ]; then
            printf '%s\n' "$cancel_line" >> "$REQUEST_LOG"
        fi
        case "$cancel_line" in
            *'"method":"account/login/cancel"'*|*'"method":"account\/login\/cancel"'*)
                printf '{"id":%s,"result":{"status":"canceled"}}\n' "$cancel_id"
                printf '{"method":"account/login/completed","params":{"loginId":"cancel-login-id","success":false,"error":"canceled by user"}}\n'
                ;;
            *) exit 39 ;;
        esac
        ;;
    provider_login_timeout|provider_disconnect)
        printf '{"id":%s,"result":{"type":"chatgpt","loginId":"pending-login-id","authUrl":"https://chatgpt.com/login"}}\n' "$request_id"
        read_line
        if [ -n "${received_line:-}" ] && [ -n "${REQUEST_LOG:-}" ]; then
            printf '%s\n' "$received_line" >> "$REQUEST_LOG"
        fi
        ;;
    provider_login_redaction)
        printf '{"id":%s,"result":{"type":"chatgpt","loginId":"redact-login-id","authUrl":"https://redaction-user:redaction-password@example.com/login?sensitive=redaction-sentinel"}}\n' "$request_id"
        ;;
    *)
        exit 99
        ;;
esac

# Usage refresh and health fixtures model several sequential RPCs in one
# request-scoped app-server. Login fixtures keep their existing specialized
# protocol handling and then wait for the client to close.
case "$scenario" in
    provider_current|provider_usage_unavailable|provider_usage_empty|\
    provider_usage_malformed|\
    provider_legacy_additive|provider_lossy_dynamic|provider_malformed_rate|\
    provider_credit_matrix|provider_daily_dst|provider_health_rate_rpc_failure|\
    provider_health_rate_malformed|provider_refresh_overall_timeout)
        continue
        ;;
    provider_*)
        read_line
        break
        ;;
    *)
        break
        ;;
esac
done
