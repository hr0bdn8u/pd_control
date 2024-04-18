#!/bin/bash
#
# Script to monitor/control chassis fan speed using PD control based on
# average drive temperatures.
#
# Example output:
# Apr 29 10:04:37  !28 !29 35 36 !29 33 35 !30 36  35.0  0.0   0 100  668
# Apr 29 10:09:38  !28 !29 35 36 !29 33 35 !30 36  35.0  0.0   0 100  672
# Apr 29 10:14:38  !28 !29 35 36 !29 33 35 !30 36  35.0  0.0   0 100  671
# Apr 29 10:19:39  !28 !29 35 36 !29 34 35 !30 36  35.2 +0.2  +4 104  707
# Apr 29 10:24:39  !28 !29 35 36 !29 33 35 !30 36  35.0  0.0  -2 102  682
# Apr 29 10:29:39  !29 !29 35 36 !29 33 35 !30 36  35.0  0.0   0 102  695
# Apr 29 10:34:40  !28 !29 35 36 !29 33 35 !30 36  35.0  0.0   0 102  680
#

# Configuration constants
readonly VERSION='0.99 (15/12/2023)'
readonly PWM1='/sys/class/hwmon/hwmon1/pwm1'
#readonly PWM1='/sys/class/hwmon/hwmon2/pwm1'
#readonly PWM4='/sys/class/hwmon/hwmon2/pwm4'
#readonly SENSORS_FAN_ID_REGEX='^CHA3: '
readonly SP=32       # Setpoint mean drive temperature (C)
#readonly SP=34       # Setpoint mean drive temperature (C)
#readonly KP=8
#readonly KD=40         # Derivative tunable constant (for drives)
readonly KP=10         # Proportional tunable constant (for drives)
readonly KD=50         # Derivative tunable constant (for drives)
readonly INTERVAL=5    # Time interval (minutes).  Drives change temperature slowly.
readonly TMAX=40       # Maximum allowed drive temperature
readonly PWM_MIN=60    # Fan minimum speed
readonly PWM_MAX=250   # Fan maximum speed (to avoid overutilization)
readonly PURE_MONITORING_MODE=0
readonly ENABLE_LOGGING=1
readonly LOG_PATH="${PWD}/$(basename ${0})-$(date +'%Y%m%dT%H%M%S').log"
#readonly UNMONITORED_DRIVES=""
readonly MONITORED_DRIVES="sd[bcdef]"
#readonly MONITORED_DEVICES="sd[cdfgi]" # not used currently

block_devices=""
log_line=""
t_avg=0
error_current=0

get_block_devices() {
    lsblk -Sdno NAME
}

get_block_device_count() {
    lsblk -Sdno NAME | wc -l
}

initialize() {
    pd=0
    t_avg=0
    main_loop_sleep_time=$(($INTERVAL*60))
    block_devices="$(get_block_devices)"
}

get_fan_speed_pwm() {
    cat "${PWM1}"
}

get_fan_speed_rpm() {
# TODO: change ^fan1: regex into constant variable SENSORS_FAN_ID_REGEX
    sensors 2> /dev/null | awk '/^fan1: / {print $2}'
}

get_drive_temp() {
    /usr/sbin/smartctl -A /dev/$1 | awk '/^190 / { print $10 ; exit }'
#   /usr/sbin/smartctl -A /dev/$1 | awk 'NR==1 /^19[04] / { print $10 ; exit }'
    # sudo /usr/sbin/smartctl -A /dev/$1 | awk '/ Temperature_Cel/ {print $10}'
}

get_temps() {
    local -i t_drive
    local -i t_sum
    local -i i
    t_sum=0
    t_avg=0
    i=0

    log_line="$(date +'%b %d %H:%M:%S')  "
    for dev_id in ${block_devices}; do
        t_drive=$(get_drive_temp "$dev_id")
        if [[ "${dev_id}" =~ ${UNMONITORED_DRIVES} ]]; then
            log_line+="!"
        else
            (( t_sum+=t_drive ))
            (( i++ ))
        fi
        log_line+="${t_drive} "
    done
   t_avg=$(echo "scale=1; $t_sum / $i" | bc)
#   t_avg=$(echo "scale=2; $t_sum / $i" | bc)
    log_line+=" ${t_avg}"
}

get_temps_2() {
    local -i t_drive
    local -i t_sum
    local -i i
    t_sum=0
    t_avg=0
    i=0

    log_line="$(date +'%b %d %H:%M:%S')  "
    for dev_id in ${block_devices}; do
        t_drive=$(get_drive_temp "$dev_id")
        if [[ "${dev_id}" =~ ${MONITORED_DRIVES} ]]; then
            (( t_sum+=t_drive ))
            (( i++ ))
        else
            log_line+="!"
        fi
        log_line+="${t_drive} "
    done
   #t_avg=$(echo "scale=2; $t_sum / $i" | bc)
#   t_avg=$(echo "scale=2; $t_sum / $i" | bc)
#    log_line+=" ${t_avg}"
    t_avg=$(echo "$t_sum / $i" | bc -l)
    log_line+=$(printf ' %5g' $t_avg)
}

calculate_pid() {
    local -r error_previous=$error_current
    error_current=$(echo "scale=3; ($t_avg - $SP) / 1" | bc)
    p=$(echo "scale=3; ($KP * $error_current) / 1" | bc)
    d=$(echo "scale=4; $KD * ($error_current - $error_previous) / $INTERVAL" | bc)
    pd=$(echo "($p + $d)" | bc)
    # add leading 0 if needed, round for printing. 0.1f for 5 drives, .2f for 4 drives or more
    pd=$(printf %0.0f "$pd") # needed for conditional statements (without bc) later on
    if (( $(echo "$error_current > 0" | bc -l) )); then
        log_line+=$(printf ' %4s' $(printf '%+0.2f' $error_current))
    else
        log_line+=$(printf ' %4s' $(printf '%0.2f' $error_current))
    fi
    if [[ $pd -gt 0 ]]; then
        log_line+=$(printf ' %3s' $(printf '%+0.0f' $pd))
    else
        log_line+=$(printf ' %3s' $(printf '%0.0f' $pd))
    fi
}

calculate_pid_2() {
    local -r error_previous=$error_current
    #error_current=$(echo "scale=3; ($t_avg - $SP) / 1" | bc)
    error_current=$(echo "$t_avg - $SP" | bc)
    error_current=$(printf '%0.1f' $error_current)
    if (( $(echo "$error_current != 0" | bc) || $(echo "$error_previous != 0" | bc) )); then
        p=$(echo "scale=3; ($KP * $error_current) / 1" | bc)
        d=$(echo "scale=4; $KD * ($error_current - $error_previous) / $INTERVAL" | bc)
        pd=$(printf '%0.0f' $(echo "$p + $d" | bc))
        if (( $(echo "$error_current > 0" | bc -l) )); then
            error_current=$(printf '%+0.1f' $error_current)
        fi
        if (( $(echo "$pd > 0" | bc) )); then
            pd=$(printf '%+0.0f' $pd)
        fi
    fi
    log_line+=$(printf ' %4s %3s' $error_current $pd)
    pd=$(printf '%0.0f' $pd)
    error_current=$(printf '%0.1f' $error_current)
}

calculate_pid_3() {
    local -r error_previous=$error_current
    error_current=$(printf '%0.1f' $(echo "$t_avg - $SP" | bc))
    if (( $(echo "$error_previous == 0" | bc) && $(echo "$error_current == 0" | bc) )); then
        : # do nothing
    else
        p=$(echo "scale=3; ($KP * $error_current) / 1" | bc)
        d=$(echo "scale=4; $KD * ($error_current - $error_previous) / $INTERVAL" | bc)
        pd=$(printf '%0.0f' $(echo "$p + $d" | bc))
        if (( $(echo "$error_current > 0" | bc -l) )); then
            error_current=$(printf '%+0.1f' $error_current)
        fi
        if (( $(echo "$pd > 0" | bc) )); then
            pd=$(printf '%+0.0f' $pd)
        fi   
    fi
    log_line+=$(printf ' %4s %3s' $error_current $pd)
    pd=$(printf '%0.0f' $pd)
    error_current=$(printf '%0.1f' $error_current)
}

calculate_pid_4() {
    local -r error_previous=$error_current
    error_current=$(printf '%0.1f' $(echo "$t_avg - $SP" | bc))
    if [[ "$error_current" == "0.0" && "$error_previous" == "0.0" ]]; then
        log_line+=$(printf ' %4s %3s' $error_current $pd)
    else
        p=$(echo "scale=3; ($KP * $error_current) / 1" | bc)
        d=$(echo "scale=4; $KD * ($error_current - $error_previous) / $INTERVAL" | bc)
        pd=$(printf '%0.0f' $(echo "$p + $d" | bc))
        if (( $(echo "$error_current > 0" | bc) )); then
            error_current=$(printf '%+0.1f' $error_current)
        fi
        if (( $(echo "$pd > 0" | bc) )); then
            pd=$(printf '%+0.0f' $pd)
        fi
        log_line+=$(printf ' %4s %3s' $error_current $pd)
        error_current=$(printf '%0.1f' $error_current)
        pd=$(printf '%0.0f' $pd)
    fi
}

calculate_pid_5() {
    local -r error_previous=$error_current
    error_current=$(echo "$t_avg - $SP" | bc)
    # p=$(echo "scale=3; ($KP * $error_current) / 1" | bc)
    # d=$(echo "scale=4; $KD * ($error_current - $error_previous) / $INTERVAL" | bc)
    p=$(echo "$KP * $error_current" | bc)
    d=$(echo "$KD * ($error_current - $error_previous) / $INTERVAL" | bc)
    pd=$(printf '%g' $(echo "$p + $d" | bc))
    # if (( $(echo "$error_current != 0" | bc) )); then
    #     log_line+=$(printf ' %4s' $(printf '%+0.1f' $error_current))
    # else
    #     log_line+=$(printf ' %4s' $(printf '%0.1f' $error_current))
    # fi
    # if [[ $pd -ne 0 ]]; then
    #     log_line+=$(printf ' %3s' $(printf '%+0.0f' $pd))
    # else
    #     log_line+=$(printf ' %3s' $(printf '%0.0f' $pd))
    # fi
    log_line+=$(printf ' %5g %3g' $error_current $pd)

}

calculate_pid_6() {
    local -r error_previous=$error_current
    error_current=$(echo "$t_avg - $SP" | bc)
    p=$(echo "$KP * $error_current" | bc)
    d=$(echo "$KD * ($error_current - $error_previous) / $INTERVAL" | bc)
    pd=$(printf '%g' $(echo "$p + $d" | bc))
    log_line+=$(printf ' %5g %5g' $error_current $pd)
}

manage_fan_speed() {
    local -r current_pwm=$(get_fan_speed_pwm)
    local new_pwm=$current_pwm
    # Constrain between PWM_MIN and PWM_MAX
    if [[ $pd -ne 0 ]]; then
        ((new_pwm=current_pwm+pd<PWM_MIN?PWM_MIN:((current_pwm+pd>PWM_MAX?PWM_MAX:current_pwm+pd))))
    fi
    log_line+=$(printf ' %3s' $new_pwm)
    if [[ $pd -ne 0 ]]; then
        if [[ $PURE_MONITORING_MODE -eq 0 ]]; then
            # : means do nothing, in terms of output. It will run the command but not show output
            : $(echo -n $new_pwm > $PWM3)
            sleep 5
            main_loop_sleep_time=$(($INTERVAL*60-5)) # -5 to keep sleeping + get_fan_speed total to 5 minutes         
        fi
    fi
    log_line+=$(printf ' %4s ' $(get_fan_speed_rpm))
    # log_line+=$(printf ' %3s' $new_pwm)
}

manage_fan_speed_2() {
    local -r current_pwm=$(get_fan_speed_pwm)
    local new_pwm=$current_pwm
    if [[ $PURE_MONITORING_MODE -eq 0 ]]; then
        if [[ $pd -ne 0 ]]; then
            # Constrain between PWM_MIN and PWM_MAX
            ((new_pwm=current_pwm+pd<PWM_MIN?PWM_MIN:((current_pwm+pd>PWM_MAX?PWM_MAX:current_pwm+pd))))
            # : means do nothing, in terms of output. It will run the command but not show output
            : $(echo -n $new_pwm > $PWM1)
            sleep 5
            main_loop_sleep_time=$(($INTERVAL*60-5)) # -5 to keep sleeping + get_fan_speed total to 5 minutes         
        fi
    fi
    log_line+=$(printf ' %3s %4s ' $new_pwm $(get_fan_speed_rpm))
}

print_startup_2() {
    local device_list=""
    for dev_id in ${block_devices}; do
        if ! [[ "${dev_id}" =~ ${MONITORED_DRIVES} ]]; then
            device_list+="!"
        fi
        device_list+="${dev_id} "
    done
    printf "Disktemp v${VERSION}\n"
    printf "\n"
    printf "  Block devices: ${device_list} (! not monitored)\n"
    printf "  SP=${SP}, KP=${KP}, KD=${KD}, INTERVAL=${INTERVAL}, TMAX=${TMAX}, PWM_RANGE=${PWM_MIN}-${PWM_MAX}, LOG=${ENABLE_LOGGING}, "
    [[ $PURE_MONITORING_MODE -eq 1 ]] && printf "read-only\n" || printf "read-write\n"
    printf "  PWM1=${PWM1}\n"
    [[ $ENABLE_LOGGING -eq 1 ]] && printf "  LOG_PATH=${LOG_PATH}\n"
}

# print_header() {
#     printf "\nDate/time    [sd]" 
#     for dev_id in ${block_devices}; do
#         if [[ "${dev_id}" =~ ${UNMONITORED_DRIVES} ]]; then
#             printf "  %s " "${dev_id:0-1}"
#         else
#             printf " %s " "${dev_id:0-1}"
#         fi
#             done
#     printf " %4s  %3s %3s %3s %4s" "AVG" "ERR" "PD" "PWM" "RPM"
# }

print_update() {
    printf "\n${log_line}"
}

# Main loop
main() {
    [[ $ENABLE_LOGGING -eq 1 ]] && exec > >(tee -a -i $LOG_PATH) 2>&1
    initialize
    print_startup_2
    while true ; do
        initialize
        get_temps_2
        calculate_pid_5
        manage_fan_speed_2
        print_update
        sleep $main_loop_sleep_time 
    done
}

main
