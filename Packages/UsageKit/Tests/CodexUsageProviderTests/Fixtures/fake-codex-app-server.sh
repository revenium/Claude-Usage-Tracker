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
        printf '{"id":%s,"result":{"type":"chatgpt","loginId":"redact-login-id","authUrl":"https://super-secret-user:super-secret-password@chatgpt.com/login?access_token=super-secret-token"}}\n' "$request_id"
        ;;
    *)
        exit 99
        ;;
esac

# Provider fixtures model the real app-server's long-lived process. Keep the
# protocol stream open until the request-scoped client explicitly closes it.
case "$scenario" in
    provider_*) read_line ;;
esac
