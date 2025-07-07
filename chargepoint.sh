#!/bin/bash

readonly CHARGEPOINT_COOKIE_JAR="/tmp/chargepoint-session-cookie-jar"

CHARGEPOINT_USER=
CHARGEPOINT_PASSWD=
CHARGEPOINT_WAITLIST_ID=
CHARGEPOINT_UNTIL_TIME=23

print_usage() {
    echo
    echo "Usage: $0 -u <username> -p <password> -l <waitlist-id> [-t <until-time>]"
    echo
    echo "  -u <username>:    User name of your Chargepoint account"
    echo "  -p <password>:    Password of your Chargepoint account"
    echo "  -l <waitlist-id>: Region/Waitlist you want to join"
    echo "  -t <until-time>:  Until what time of day to stay on the list [0-23]. The default is 23."
    echo "  -h:               Print this help message."
    echo
    echo "Example: $0 -u username -p passwd -l 6170941 -t 20"
    echo
}

is_number() {
    [[ $1 =~ ^[0-9]+$ ]]
}

error_exit() {
    local error_msg=$1
    echo "Error: $error_msg"

    print_usage && exit 1
}

validate_cmd_args() {
    [ -z "$CHARGEPOINT_USER" ] && error_exit "Empty username!"
    [ -z "$CHARGEPOINT_PASSWD" ] && error_exit "Empty password!"

    [ -z "$CHARGEPOINT_WAITLIST_ID" ] && error_exit "Empty waitlist ID!"
    is_number $CHARGEPOINT_WAITLIST_ID || error_exit "Waitlist ID must be a numeric value!"

    is_number "$CHARGEPOINT_UNTIL_TIME" || error_exit "Time must be a numeric value!"
    [ $CHARGEPOINT_UNTIL_TIME -lt 0 -o $CHARGEPOINT_UNTIL_TIME -ge 24 ] && error_exit "Time must be in the range of [0-23]!"
}

chargepoint_login() {
    echo -n "`date` "

    curl 'https://na.chargepoint.com/users/validate' \
		-H 'origin: https://na.chargepoint.com' \
		-H 'accept-encoding: gzip, deflate, br' \
		-H 'accept-language: en-US,en;q=0.9,zh;q=0.8,zh-CN;q=0.7,zh-TW;q=0.6' \
		-H 'x-requested-with: XMLHttpRequest' \
		-H 'pragma: no-cache' \
		-H 'user-agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_4) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/73.0.3683.103 Safari/537.36' \
		-H 'content-type: application/x-www-form-urlencoded; charset=UTF-8' \
		-H 'accept: */*' \
		-H 'cache-control: no-cache' \
		-H 'authority: na.chargepoint.com' \
		-H 'referer: https://na.chargepoint.com/home' \
		-H 'dnt: 1' \
        --cookie-jar $CHARGEPOINT_COOKIE_JAR \
        --data "user_name=$CHARGEPOINT_USER&user_password=$CHARGEPOINT_PASSWD&auth_code=&recaptcha_response_field=&timezone_offset=420&timezone=PDT&timezone_name=" \
        --silent --compressed

    echo
}

chargepoint_join_waitlist() {
    echo -n "`date` "

    curl 'https://na.chargepoint.com/community/activateRegion' \
        -H 'origin: https://na.chargepoint.com' \
        -H 'accept-encoding: gzip, deflate, br' \
        -H 'accept-language: en-US,en;q=0.9,zh;q=0.8,zh-CN;q=0.7,zh-TW;q=0.6' \
        -H 'x-requested-with: XMLHttpRequest' \
        -H 'pragma: no-cache' \
        -H 'user-agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_4) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/73.0.3683.103 Safari/537.36' \
        -H 'content-type: application/x-www-form-urlencoded; charset=UTF-8' \
        -H 'accept: application/json, text/javascript, */*; q=0.01' \
        -H 'cache-control: no-cache' \
        -H 'authority: na.chargepoint.com' \
        -H 'referer: https://na.chargepoint.com/dashboard_driver' \
        -H 'dnt: 1' \
        --cookie $CHARGEPOINT_COOKIE_JAR \
        --data "regionIds=$CHARGEPOINT_WAITLIST_ID&untilTime=$CHARGEPOINT_UNTIL_TIME" \
        --silent --compressed

    echo
}

while getopts ":u:p:l:t:h" OPTION; do
  case $OPTION in
     u) CHARGEPOINT_USER=$OPTARG;;
     p) CHARGEPOINT_PASSWD=$OPTARG;;
     l) CHARGEPOINT_WAITLIST_ID=$OPTARG;;
     t) CHARGEPOINT_UNTIL_TIME=$OPTARG;;
     h) print_usage && exit;;
     ?) print_usage && exit;;
  esac
done

main() {
    validate_cmd_args

    chargepoint_login
    chargepoint_join_waitlist
}

main
