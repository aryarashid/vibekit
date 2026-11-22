#!/bin/bash
# Vibe Kit lid sleep helper, version 1
set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
umask 077

config=${VIBEKIT_LID_CONFIG:-/Library/Application Support/Vibe Kit/lid-sleep-minutes}
fake=${VIBEKIT_LID_FAKE_DIR-}
if [[ ${VIBEKIT_LID_FAKE_DIR+x} && -z $fake ]]; then exit 2; fi
# Written by the installer, root's like this script: the app this helper belongs to.
app_file=${VIBEKIT_LID_APP_FILE:-/Library/Application Support/Vibe Kit/app-path}
closed_at='' fired=0 fired_at='' slept=0 last_tick='' flag='' last_minutes='' docked=0
real_flag=''

read_minutes() {
    # The folder is root's, so the user can change this file's text but cannot swap it for a
    # link or a pipe. Still refuse anything but a plain file.
    [[ -f $config && ! -L $config ]] || return
    # One read of at most 17 bytes, as hex, so a file that grows meanwhile cannot make root
    # read more and NUL bytes are not silently dropped the way bash drops them.
    local hex byte text=''
    hex=$(/usr/bin/od -An -v -tx1 -N 17 -- "$config" 2>/dev/null) || return
    # od prints 16 bytes a line, and read takes one line, so join them first.
    read -r -a bytes <<< "${hex//$'\n'/ }"
    (( ${#bytes[@]} <= 16 )) || return
    for byte in "${bytes[@]}"; do
        case $byte in
            3[0-9]) text+=${byte:1} ;;
            20|09|0a|0d) text+=' ' ;;
            *) return ;;
        esac
    done
    [[ $text =~ ^\ *(0|15|30|45|60)\ *$ ]] && printf '%s' "${BASH_REMATCH[1]}"
}

app_present() {
    # If Vibe Kit was moved to the Trash, stop keeping the Mac awake rather than outlive it.
    [[ -f $app_file && ! -L $app_file ]] || return 0
    local app
    app=$(/usr/bin/head -c 1024 -- "$app_file" 2>/dev/null)
    [[ -z $app || -d $app ]]
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
    # Trust what powerd reports over what this script last set, in case something else changed it.
    [[ -n $real_flag ]] && flag=$real_flag
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
        local flag_pattern='"SleepDisabled" = (Yes|No)'
        report=$(/usr/sbin/ioreg -r -k AppleClamshellState -d 1)
        [[ $report =~ $lid_pattern ]] && lid=${BASH_REMATCH[1]}
        [[ $report =~ $causes_pattern ]] && causes=${BASH_REMATCH[1]}
        real_flag=''
        if [[ $report =~ $flag_pattern ]]; then
            if [[ ${BASH_REMATCH[1]} == Yes ]]; then real_flag=1; else real_flag=0; fi
        fi
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
    app_present || minutes=0
    if [[ $minutes != "$last_minutes" ]]; then
        log_change "Delay set to $minutes minutes"
        last_minutes=$minutes
    fi
    read_lid
    if [[ $minutes == 0 ]]; then
        closed_at='' fired=0 docked=0
        set_flag 0
        return
    fi

    if [[ -n $fake ]]; then now=$(<"$fake/now"); else now=$(/bin/date +%s); fi
    [[ $now =~ ^[0-9]{1,12}$ ]] || { set_flag 0; return; }
    now=$((10#$now))
    # A gap much longer than one poll means the Mac was asleep in between.
    if [[ -n $last_tick ]] && (( now - last_tick > 60 || now < last_tick )); then slept=1; fi
    # A clock set backwards must not stretch the delay: move the start back by the same step,
    # so the time already spent with the lid closed still counts.
    if [[ -n $last_tick && -n $closed_at ]] && (( now < last_tick )); then
        closed_at=$(( closed_at - (last_tick - now) ))
        (( closed_at >= 0 )) || closed_at=0
    fi
    last_tick=$now

    if [[ $lid == No ]]; then
        closed_at='' fired=0 docked=0
        set_flag 1
    elif [[ $lid == Yes && $causes == No ]]; then
        [[ $docked == 1 ]] || log_change "Lid closed while docked"
        # Docking is a fresh start: unplugging later starts a new timer.
        closed_at='' fired=0 docked=1
        set_flag 1
    elif [[ $lid != Yes || $causes != Yes ]]; then
        # Sleep normally if the sensor is unavailable.
        set_flag 0
    elif [[ $fired == 1 ]]; then
        # Wakes with the lid still closed never start the timer again. If the Mac never went
        # to sleep after the request, ask again each minute.
        set_flag 0
        if [[ $slept == 0 ]] && (( now - ${fired_at:-0} >= 60 )); then
            action sleepnow && fired_at=$now
            log_change "Requested sleep again"
        fi
    else
        docked=0
        if [[ -z $closed_at ]]; then
            closed_at=$now
            log_change "Lid closed. Timer started."
            # Only the system stays awake. The lid already darkens the built-in screen; this
            # makes sure of it, and locks the screen if the Mac asks for a password on wake.
            action displaysleepnow
        elif (( now < closed_at )); then
            closed_at=$now
        fi
        if low_battery; then
            reason="low battery"
        elif (( now - closed_at >= minutes * 60 )); then
            reason="timer expired"
        else
            set_flag 1
            return
        fi
        if set_flag 0 && action sleepnow; then
            fired=1 fired_at=$now slept=0
            log_change "Requested sleep ($reason)"
        fi
    fi
}

load_state() {
    local line
    while IFS= read -r line || [[ -n $line ]]; do
        case "$line" in
            closed_at=*) [[ ${line#*=} =~ ^[0-9]{1,12}$ ]] && closed_at=${line#*=} ;;
            fired_at=*) [[ ${line#*=} =~ ^[0-9]{1,12}$ ]] && fired_at=${line#*=} ;;
            last_tick=*) [[ ${line#*=} =~ ^[0-9]{1,12}$ ]] && last_tick=${line#*=} ;;
            fired=[01]) fired=${line#*=} ;;
            slept=[01]) slept=${line#*=} ;;
            flag=[01]) flag=${line#*=} ;;
            docked=[01]) docked=${line#*=} ;;
            last_minutes=0|last_minutes=15|last_minutes=30|last_minutes=45|last_minutes=60)
                last_minutes=${line#*=} ;;
        esac
    done < "$1"
}

save_state() {
    [[ -z $closed_at ]] || printf 'closed_at=%s\n' "$closed_at"
    [[ -z $flag ]] || printf 'flag=%s\n' "$flag"
    [[ -z $fired_at ]] || printf 'fired_at=%s\n' "$fired_at"
    [[ -z $last_tick ]] || printf 'last_tick=%s\n' "$last_tick"
    printf 'fired=%s\nslept=%s\ndocked=%s\nlast_minutes=%s\n' "$fired" "$slept" "$docked" "$last_minutes"
}

if [[ $# == 1 && $1 == --off ]]; then
    action disablesleep 0
    exit 0
elif [[ $# == 2 && $1 == --tick ]]; then
    [[ ! -f $2 ]] || load_state "$2"
    tick
    save_state > "$2"
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
# Keep the timer across restarts and updates, so one with the lid closed carries on counting
# rather than starting over or losing track. /var/run is root's and is emptied at boot.
state_file=${VIBEKIT_LID_STATE:-/var/run/dev.vibekit.lid-sleep.state}
[[ -f $state_file && ! -L $state_file ]] && load_state "$state_file"
saved=$(save_state)
while :; do
    tick
    state=$(save_state)
    if [[ $state != "$saved" ]]; then
        [[ -L $state_file ]] || printf '%s\n' "$state" > "$state_file"
        saved=$state
    fi
    /bin/sleep "${VIBEKIT_LID_INTERVAL:-10}" &
    sleeper=$!
    wait "$sleeper"
    sleeper=
done
