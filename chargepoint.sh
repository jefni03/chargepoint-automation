#!/usr/bin/env bash

set -u
set -o pipefail

CHARGEPOINT_USER=""
CHARGEPOINT_PASSWD=""
CHARGEPOINT_WAITLIST_ID=""
CHARGEPOINT_UNTIL_TIME=23

readonly PACIFIC_TIMEZONE="America/Los_Angeles"

CHARGEPOINT_COOKIE_JAR="$(mktemp /tmp/chargepoint-cookie-jar.XXXXXX)"

cleanup() {
    rm -f "$CHARGEPOINT_COOKIE_JAR"
}

trap cleanup EXIT

print_usage() {
    echo
    echo "Usage: $0 -u <username> -p <password> -l <waitlist-id> [-t <until-time>]"
    echo
    echo "  -u <username>:    ChargePoint account username"
    echo "  -p <password>:    ChargePoint account password"
    echo "  -l <waitlist-id>: ChargePoint region/waitlist ID"
    echo "  -t <until-time>:  Hour to remain on the list, from 0 through 23"
    echo "  -h:               Print this help message"
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
        error_exit "Empty username"

    [[ -n "$CHARGEPOINT_PASSWD" ]] ||
        error_exit "Empty password"

    [[ -n "$CHARGEPOINT_WAITLIST_ID" ]] ||
        error_exit "Empty waitlist ID"

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

chargepoint_login() {
    local response
    local authenticated

    rm -f "$CHARGEPOINT_COOKIE_JAR"

    response="$(
        curl 'https://na.chargepoint.com/users/validate' \
            --silent \
            --show-error \
            --compressed \
            --cookie-jar "$CHARGEPOINT_COOKIE_JAR" \
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
        echo "$(pacific_date): ChargePoint login request failed"
        return 1
    }

    authenticated="$(
        printf '%s' "$response" |
            jq -r '.auth // false' 2>/dev/null
    )"

    if [[ "$authenticated" != "true" ]]; then
        echo "$(pacific_date): ChargePoint login was rejected"
        return 1
    fi

    echo "$(pacific_date): ChargePoint login successful"
    return 0
}

chargepoint_join_waitlist() {
    curl 'https://na.chargepoint.com/community/activateRegion' \
        --silent \
        --show-error \
        --compressed \
        --cookie "$CHARGEPOINT_COOKIE_JAR" \
        --header 'origin: https://na.chargepoint.com' \
        --header 'x-requested-with: XMLHttpRequest' \
        --header 'content-type: application/x-www-form-urlencoded; charset=UTF-8' \
        --header 'accept: application/json, text/javascript, */*; q=0.01' \
        --header 'referer: https://na.chargepoint.com/dashboard_driver' \
        --header 'user-agent: Mozilla/5.0' \
        --data-urlencode "regionIds=$CHARGEPOINT_WAITLIST_ID" \
        --data-urlencode "untilTime=$CHARGEPOINT_UNTIL_TIME"
}

target_epoch_for_today() {
    local target_time="$1"
    local today

    today="$(pacific_date +%F)"

    TZ="$PACIFIC_TIMEZONE" date \
        --date="$today $target_time" \
        +%s
}

wait_until_time() {
    local target_time="$1"
    local target_epoch
    local current_epoch
    local wait_seconds

    target_epoch="$(target_epoch_for_today "$target_time")"
    current_epoch="$(date +%s)"

    if (( current_epoch >= target_epoch )); then
        return 1
    fi

    wait_seconds=$((target_epoch - current_epoch))

    echo "Waiting until $target_time Pacific"
    echo "Current Pacific time: $(pacific_date)"
    echo "Waiting $wait_seconds seconds"

    sleep "$wait_seconds"
    return 0
}

attempt_join() {
    local scheduled_time="$1"
    local response
    local status
    local message

    echo
    echo "Attempting waitlist join for the $scheduled_time slot"
    echo "Actual attempt time: $(pacific_date)"

    if ! chargepoint_login; then
        echo "Login failed for the $scheduled_time attempt"
        return 1
    fi

    response="$(chargepoint_join_waitlist)" || {
        echo "Waitlist request failed"
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
        echo "ChargePoint accepted the waitlist request."
        return 0
    fi

    if grep -qiE \
        'already.*waitlist|already.*active|already.*activated|currently.*waitlist' \
        <<<"$message"; then

        echo "You are already on the waitlist."
        return 0
    fi

    echo "The $scheduled_time attempt was not accepted."
    return 1
}

run_scheduled_attempts() {
    local join_times=("06:30" "07:00" "07:30")
    local join_time
    local attempts_made=0
    local current_epoch
    local target_epoch

    for join_time in "${join_times[@]}"; do
        current_epoch="$(date +%s)"
        target_epoch="$(target_epoch_for_today "$join_time")"

        # Skip past slots instead of immediately sending several requests.
        if (( current_epoch >= target_epoch )); then
            echo "Skipping past time slot: $join_time Pacific"
            continue
        fi

        wait_until_time "$join_time"
        attempts_made=$((attempts_made + 1))

        if attempt_join "$join_time"; then
            echo "Stopping because the waitlist request succeeded."
            return 0
        fi
    done

    # If GitHub started extremely late, try once immediately.
    if (( attempts_made == 0 )); then
        echo
        echo "All scheduled slots have passed."
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

    echo "ChargePoint waitlist automation started"
    echo "Pacific start time: $(pacific_date)"
    echo "Join times: 6:30 AM, 7:00 AM, and 7:30 AM Pacific"

    if run_scheduled_attempts; then
        echo "ChargePoint automation completed successfully."
        exit 0
    fi

    echo "None of the waitlist attempts succeeded."
    exit 1
}

main
