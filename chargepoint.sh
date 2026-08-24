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
    echo "  -l <waitlist-id> ChargePoint waitlist ID"
    echo "  -t <until-time>  Hour to stay on waitlist [0-23]"
    echo "  -h               Show help"
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

target_epoch_for_attempt() {
    local target_time="$1"
    local current_hour
    local target_date

    current_hour="$(pacific_date +%H)"

    # Workflow normally starts around 11:40 PM.
    # In that case, midnight belongs to the next calendar day.
    if (( 10#$current_hour >= 20 )); then
        target_date="$(
            TZ="$PACIFIC_TIMEZONE" date \
                --date="tomorrow" \
                +%F
        )"
    else
        target_date="$(pacific_date +%F)"
    fi

    TZ="$PACIFIC_TIMEZONE" date \
        --date="$target_date $target_time" \
        +%s
}

wait_until() {
    local target_time="$1"
    local target_epoch
    local current_epoch
    local wait_seconds

    target_epoch="$(target_epoch_for_attempt "$target_time")"
    current_epoch="$(date +%s)"

    if (( current_epoch >= target_epoch )); then
        return 1
    fi

    wait_seconds=$((target_epoch - current_epoch))

    echo
    echo "Current Pacific time: $(pacific_date)"
    echo "Waiting until $target_time Pacific"
    echo "Sleeping $wait_seconds seconds"

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
        echo "ChargePoint login request failed."
        return 1
    }

    authenticated="$(
        printf '%s' "$response" |
            jq -r '.auth // false' 2>/dev/null
    )"

    if [[ "$authenticated" != "true" ]]; then
        echo "ChargePoint login rejected."
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
    echo "======================================"
    echo "Waitlist attempt: $label"
    echo "Actual Pacific time: $(pacific_date)"
    echo "======================================"

    if ! chargepoint_login; then
        echo "Login failed."
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
        echo
        echo "SUCCESS: Waitlist request accepted."
        return 0
    fi

    if grep -qiE \
        'already.*waitlist|already.*active|already.*activated|currently.*waitlist' \
        <<<"$message"; then

        echo
        echo "SUCCESS: Already on the waitlist."
        return 0
    fi

    echo
    echo "Attempt was not accepted."

    return 1
}

run_attempts() {
    local attempt_times=(
        "00:00:02"
        "00:00:15"
        "00:00:30"
    )

    local attempt_time
    local target_epoch
    local current_epoch
    local attempted_any=0

    for attempt_time in "${attempt_times[@]}"; do

        target_epoch="$(target_epoch_for_attempt "$attempt_time")"
        current_epoch="$(date +%s)"

        if (( current_epoch >= target_epoch )); then
            echo "Skipping past attempt: $attempt_time"
            continue
        fi

        attempted_any=1

        wait_until "$attempt_time"

        if attempt_join "$attempt_time"; then
            echo
            echo "Stopping. No more waitlist requests will be sent."
            return 0
        fi
    done

    # If GitHub itself started late and midnight already passed,
    # make ONE request immediately.
    if (( attempted_any == 0 )); then

        echo
        echo "GitHub started after the midnight attempts."
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

    echo
    echo "ChargePoint waitlist automation started."
    echo "Pacific start time: $(pacific_date)"
    echo
    echo "Planned attempts:"
    echo "  12:00:02 AM"
    echo "  12:00:15 AM"
    echo "  12:00:30 AM"
    echo
    echo "Days: Monday through Thursday"

    if run_attempts; then
        echo
        echo "ChargePoint automation completed successfully."
        exit 0
    fi

    echo
    echo "No waitlist attempt was accepted."
    exit 1
}

main
