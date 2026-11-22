#!/bin/bash
# Vibe Kit lid sleep helper, version 1
set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
umask 077

config=${VIBEKIT_LID_CONFIG:-/Library/Application Support/Vibe Kit/lid-sleep-minutes}
fake=${VIBEKIT_LID_FAKE_DIR-}
if [[ ${VIBEKIT_LID_FAKE_DIR+x} && -z $fake ]]; then exit 2; fi
closed_at='' fired=0 flag='' last_minutes='' docked=0

read_minutes() {
    # The folder is root's, so the user can change this file's text but cannot swap it for a
    # link or a pipe. Still refuse anything but a small plain file.
    [[ -f $config && ! -L $config ]] || return
    local size other text
    size=$(/usr/bin/stat -f %z -- "$config" 2>/dev/null) || return
    [[ $size =~ ^[0-9]{1,2}$ ]] && (( 10#$size <= 16 )) || return
    # Bash drops NUL bytes when it reads a file, so count every byte that is not a digit or
    # space first, NULs included, and refuse the file if there are any.
    other=$(/usr/bin/tr -d '0-9[:space:]' < "$config" | /usr/bin/wc -c) || return
    (( other == 0 )) || return
    text=$(< "$config")
    [[ $text =~ ^[[:space:]]*(0|15|30|45|60)[[:space:]]*$ ]] && printf '%s' "${BASH_REMATCH[1]}"
}

log_change() {
    if [[ -n $fake ]]; then
        printf '%s\n' "$*" >> "$fake/log"
    else
        /usr/bin/logger -t vibekit-lid-sleep "$*"
    fi
}

action() {
    if [[ -n $fake ]]; then
        printf '%s\n' "$*" >> "$fake/actions"
    elif [[ $1 == disablesleep ]]; then
        /usr/bin/pmset -a "$@"
    else
        /usr/bin/pmset "$@"
    fi
}

set_flag() {
    [[ $flag == "$1" ]] && return 0
    action disablesleep "$1" && flag=$1
}

read_lid() {
    if [[ -n $fake ]]; then
        lid=$(<"$fake/lid")
        causes=$(<"$fake/causes")
    else
        local report lid_pattern='"AppleClamshellState" = (Yes|No)'
        local causes_pattern='"AppleClamshellCausesSleep" = (Yes|No)'
        report=$(/usr/sbin/ioreg -r -k AppleClamshellState -d 1)
        [[ $report =~ $lid_pattern ]] && lid=${BASH_REMATCH[1]}
        [[ $report =~ $causes_pattern ]] && causes=${BASH_REMATCH[1]}
    fi
}

low_battery() {
    local percent report
    if [[ -n $fake ]]; then
        [[ $(<"$fake/power") == Battery ]] || return 1
        percent=$(<"$fake/percent")
    else
        report=$(/usr/bin/pmset -g batt)
        [[ $report == *"drawing from 'Battery Power'"* && $report =~ ([0-9]{1,3})% ]] || return 1
        percent=${BASH_REMATCH[1]}
    fi
    [[ $percent =~ ^[0-9]{1,3}$ ]] && (( 10#$percent <= 15 ))
}

tick() {
    local minutes lid='' causes='' now reason
    minutes=$(read_minutes)
    minutes=${minutes:-0}
    if [[ $minutes != "$last_minutes" ]]; then
        log_change "Delay set to $minutes minutes"
        last_minutes=$minutes
    fi
    if [[ $minutes == 0 ]]; then
        closed_at='' fired=0 docked=0
        set_flag 0
        return
    fi

    read_lid
    if [[ $lid == No ]]; then
        closed_at='' fired=0 docked=0
        set_flag 1
    elif [[ $lid == Yes && $causes == No ]]; then
        [[ $docked == 1 ]] || log_change "Lid closed while docked"
        closed_at='' docked=1
        set_flag 1
    elif [[ $lid != Yes || $causes != Yes || $fired == 1 ]]; then
        # Allow normal sleep if the sensor is unavailable or a dark wake occurs.
        set_flag 0
    else
        docked=0
        if [[ -n $fake ]]; then now=$(<"$fake/now"); else now=$(/bin/date +%s); fi
        [[ $now =~ ^[0-9]{1,12}$ ]] || { set_flag 0; return; }
        if [[ -z $closed_at ]]; then
            closed_at=$now
            log_change "Lid closed. Timer started."
        fi
        if low_battery; then
            reason="low battery"
        elif (( 10#$now - 10#$closed_at >= minutes * 60 )); then
            reason="timer expired"
        else
            set_flag 1
            return
        fi
        if set_flag 0 && action sleepnow; then
            fired=1
            log_change "Requested sleep ($reason)"
        fi
    fi
}

load_state() {
    local line
    while IFS= read -r line || [[ -n $line ]]; do
        case "$line" in
            closed_at=*) [[ ${line#*=} =~ ^[0-9]{1,12}$ ]] && closed_at=${line#*=} ;;
            fired=[01]) fired=${line#*=} ;;
            flag=[01]) flag=${line#*=} ;;
            docked=[01]) docked=${line#*=} ;;
            last_minutes=0|last_minutes=15|last_minutes=30|last_minutes=45|last_minutes=60)
                last_minutes=${line#*=} ;;
        esac
    done < "$1"
}

if [[ $# == 1 && $1 == --off ]]; then
    action disablesleep 0
    exit 0
elif [[ $# == 2 && $1 == --tick ]]; then
    [[ ! -f $2 ]] || load_state "$2"
    tick
    {
        [[ -z $closed_at ]] || printf 'closed_at=%s\n' "$closed_at"
        [[ -z $flag ]] || printf 'flag=%s\n' "$flag"
        printf 'fired=%s\ndocked=%s\nlast_minutes=%s\n' "$fired" "$docked" "$last_minutes"
    } > "$2"
    exit $?
elif (( $# != 0 )); then
    exit 2
fi

sleeper=
cleanup() {
    trap '' TERM INT HUP
    [[ -z $sleeper ]] || kill "$sleeper" 2>/dev/null
    action disablesleep 0
}
trap cleanup EXIT
trap 'exit 0' TERM INT HUP
while :; do
    tick
    /bin/sleep "${VIBEKIT_LID_INTERVAL:-10}" &
    sleeper=$!
    wait "$sleeper"
    sleeper=
done
