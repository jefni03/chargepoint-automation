#!/usr/bin/env bash

set -u
set -o pipefail

CHARGEPOINT_USER=""
CHARGEPOINT_PASSWD=""
CHARGEPOINT_WAITLIST_ID=""
CHARGEPOINT_UNTIL_TIME=23

readonly PACIFIC_TIMEZONE="America/Los_Angeles"
readonly COOKIE_JAR="$(mktemp /tmp/chargepoint-cookie-jar.XXXXXX)"

cleanup() {
    rm -f "$COOKIE_JAR"
}

trap cleanup EXIT

print_usage() {
    echo
    echo "Usage: $0 -u <username> -p <password> -l <waitlist-id> [-t <until-time>]"
    echo
    echo "  -u <username>    ChargePoint username"
    echo "  -p <password>    ChargePoint password"
    echo "  -l <waitlist-id> ChargePoint waitlist/region ID"
    echo "  -t <until-time>  Hour to remain eligible, from 0 through 23"
    echo "  -h               Show this help message"
    echo
}

is_number() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

error_exit() {
    echo "Error: $1"
    print_usage
    exit 1
}

validate_cmd_args() {
    [[ -n "$CHARGEPOINT_USER" ]] ||
        error_exit "Username is empty"

    [[ -n "$CHARGEPOINT_PASSWD" ]] ||
        error_exit "Password is empty"

    [[ -n "$CHARGEPOINT_WAITLIST_ID" ]] ||
        error_exit "Waitlist ID is empty"

    is_number "$CHARGEPOINT_WAITLIST_ID" ||
        error_exit "Waitlist ID must be numeric"

    is_number "$CHARGEPOINT_UNTIL_TIME" ||
        error_exit "Until time must be numeric"

    if (( CHARGEPOINT_UNTIL_TIME < 0 || CHARGEPOINT_UNTIL_TIME > 23 )); then
        error_exit "Until time must be from 0 through 23"
    fi
}

pacific_date() {
    TZ="$PACIFIC_TIMEZONE" date "$@"
}

target_epoch_today() {
    local target_time="$1"
    local today

    today="$(pacific_date +%F)"

    TZ="$PACIFIC_TIMEZONE" date \
        --date="$today $target_time" \
        +%s
}

wait_until() {
    local target_time="$1"
    local target_epoch
    local current_epoch
    local wait_seconds

    target_epoch="$(target_epoch_today "$target_time")"
    current_epoch="$(date +%s)"

    if (( current_epoch >= target_epoch )); then
        echo "Target time $target_time has already passed."
        return 1
    fi

    wait_seconds=$((target_epoch - current_epoch))

    echo "Current Pacific time: $(pacific_date)"
    echo "Waiting until $target_time Pacific."
    echo "Sleeping for $wait_seconds seconds."

    sleep "$wait_seconds"
    return 0
}

chargepoint_login() {
    local response
    local authenticated

    rm -f "$COOKIE_JAR"

    response="$(
        curl 'https://na.chargepoint.com/users/validate' \
            --silent \
            --show-error \
            --compressed \
            --cookie-jar "$COOKIE_JAR" \
            --header 'origin: https://na.chargepoint.com' \
            --header 'x-requested-with: XMLHttpRequest' \
            --header 'content-type: application/x-www-form-urlencoded; charset=UTF-8' \
            --header 'accept: */*' \
            --header 'referer: https://na.chargepoint.com/home' \
            --header 'user-agent: Mozilla/5.0' \
            --data-urlencode "user_name=$CHARGEPOINT_USER" \
            --data-urlencode "user_password=$CHARGEPOINT_PASSWD" \
            --data-urlencode 'auth_code=' \
            --data-urlencode 'recaptcha_response_field=' \
            --data-urlencode 'timezone_offset=420' \
            --data-urlencode 'timezone=PDT' \
            --data-urlencode 'timezone_name='
    )" || {
        echo "Login request failed."
        return 1
    }

    authenticated="$(
        printf '%s' "$response" |
            jq -r '.auth // false' 2>/dev/null
    )"

    if [[ "$authenticated" != "true" ]]; then
        echo "ChargePoint login was rejected."
        return 1
    fi

    echo "ChargePoint login successful at $(pacific_date)"
    return 0
}

chargepoint_join_waitlist() {
    curl 'https://na.chargepoint.com/community/activateRegion' \
        --silent \
        --show-error \
        --compressed \
        --cookie "$COOKIE_JAR" \
        --header 'origin: https://na.chargepoint.com' \
        --header 'x-requested-with: XMLHttpRequest' \
        --header 'content-type: application/x-www-form-urlencoded; charset=UTF-8' \
        --header 'accept: application/json, text/javascript, */*; q=0.01' \
        --header 'referer: https://na.chargepoint.com/dashboard_driver' \
        --header 'user-agent: Mozilla/5.0' \
        --data-urlencode "regionIds=$CHARGEPOINT_WAITLIST_ID" \
        --data-urlencode "untilTime=$CHARGEPOINT_UNTIL_TIME"
}

attempt_join() {
    local label="$1"
    local response
    local status
    local message

    echo
    echo "Attempt: $label"
    echo "Actual Pacific time: $(pacific_date)"

    if ! chargepoint_login; then
        return 1
    fi

    response="$(chargepoint_join_waitlist)" || {
        echo "Waitlist request failed."
        return 1
    }

    status="$(
        printf '%s' "$response" |
            jq -r '.status // 0' 2>/dev/null
    )"

    message="$(
        printf '%s' "$response" |
            jq -r '.response.message // .message // "No message returned"' \
            2>/dev/null
    )"

    echo "ChargePoint response: $message"

    if [[ "$status" == "1" ]]; then
        echo "Waitlist request accepted."
        return 0
    fi

    if grep -qiE \
        'already.*waitlist|already.*active|already.*activated|currently.*waitlist' \
        <<<"$message"; then

        echo "Already on the waitlist."
        return 0
    fi

    return 1
}

run_attempts() {
    local attempt_times=(
        "08:59:50"
        "09:00:05"
        "09:00:20"
    )

    local attempt_time
    local target_epoch
    local current_epoch
    local future_attempt_found=0

    for attempt_time in "${attempt_times[@]}"; do
        target_epoch="$(target_epoch_today "$attempt_time")"
        current_epoch="$(date +%s)"

        if (( current_epoch >= target_epoch )); then
            echo "Skipping past attempt: $attempt_time Pacific"
            continue
        fi

        future_attempt_found=1
        wait_until "$attempt_time"

        if attempt_join "$attempt_time"; then
            echo "Stopping after successful response."
            return 0
        fi
    done

    if (( future_attempt_found == 0 )); then
        echo
        echo "GitHub started after all scheduled attempts."
        echo "Making one immediate fallback attempt."

        if attempt_join "late fallback"; then
            return 0
        fi
    fi

    return 1
}

while getopts ':u:p:l:t:h' option; do
    case "$option" in
        u)
            CHARGEPOINT_USER="$OPTARG"
            ;;
        p)
            CHARGEPOINT_PASSWD="$OPTARG"
            ;;
        l)
            CHARGEPOINT_WAITLIST_ID="$OPTARG"
            ;;
        t)
            CHARGEPOINT_UNTIL_TIME="$OPTARG"
            ;;
        h)
            print_usage
            exit 0
            ;;
        *)
            print_usage
            exit 1
            ;;
    esac
done

main() {
    validate_cmd_args

    echo "ChargePoint waitlist automation started."
    echo "Pacific start time: $(pacific_date)"
    echo "Planned attempts: 8:59:50, 9:00:05, and 9:00:20 AM Pacific."

    if run_attempts; then
        echo "ChargePoint automation completed successfully."
        exit 0
    fi

    echo "No waitlist attempt was accepted."
    exit 1
}

main
