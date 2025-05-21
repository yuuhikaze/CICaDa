#!/usr/bin/env bash

set -uo pipefail
IFS=$'\n'

SCRIPT_NAME="$(basename "$0" ".${0##*.}")"
PROJECT=$(dirname "$(readlink -f "$0")" | grep -Po '[^/]*$') # make this be customizable

SERVICE="$1"
declare -a OLD_CONTAINERS
declare -a OLD_IMAGES
HEALTH_BAR="$(mktemp "/tmp/$SCRIPT_NAME".XXXXXX)"
BUILD_VERSION="$(git rev-parse --short HEAD)"
export TAG="$BUILD_VERSION"

cleanup() {
    rm -f "$HEALTH_BAR"
}

print_and_log() {
    local YMDHMS
    YMDHMS="$(date -u +'%Y-%m-%d %H:%M:%S+00')"
    level="$1"
    message="$2"
    case "${level,,}" in
        error) tput setaf 1 ;;
        warn) tput setaf 3 ;;
        info)
            if grep -qi "success" <<< "$message"; then
                tput setaf 2
            else
                tput setaf 4
            fi
            ;;
    esac
    identifier="[$YMDHMS] [$PROJECT.$SERVICE]"
    echo -e "$identifier\n[$level] $message" >&2
    # echo -ne "$identifier\n[$level] $message" | tr '\n' ' ' >> "$BACKUP_PATH/status.log" # make logfile path be customizable
    # echo >> "$BACKUP_PATH/status.log"
    tput sgr0
}

check_old_containers() {
    mapfile -t OLD_CONTAINERS < <(docker compose ps --quiet "$SERVICE")
    mapfile -t OLD_IMAGES < <(docker compose images --quiet "$SERVICE")
    if [ -z "${OLD_CONTAINERS[*]}" ]; then
        print_and_log "INFO" "No previous containers were found. Spinning up the first one"
        if docker image inspect "${SERVICE}:${TAG}" &> /dev/null; then
            print_and_log "INFO" "Image was not found. Building it"
            COMPOSE_BAKE=true docker compose build "$SERVICE"
        fi
        docker compose up --detach --no-recreate "$SERVICE"
        exit 0
    fi
}

check_health() {
    local id="$1" interval retries
    interval="$(docker inspect --format='{{.Config.Healthcheck.Interval}}' "$id" | sed 's/s//g')"
    retries="$(docker inspect --format='{{.Config.Healthcheck.Retries}}' "$id")"
    for ((i = 0; i < retries; i++)); do
        health_status=$(docker inspect --format='{{.State.Health.Status}}' "$id")
        if [ "$health_status" = "healthy" ]; then
            echo -n "1" >> "$HEALTH_BAR"
            return
        elif [ "$health_status" = "unhealthy" ]; then
            break
        fi
        sleep "$interval"
    done
    echo -n "0" >> "$HEALTH_BAR"
}

rollout() {
    print_and_log "INFO" "Releasing version: $BUILD_VERSION"
    git pull
    print_and_log "INFO" "Building service"
    COMPOSE_BAKE=true docker compose build "$SERVICE"
    # Scale the containers to twice the current number of instances
    local n_old_containers="${#OLD_CONTAINERS[@]}"
    local scale=$((n_old_containers * 2))
    print_and_log "INFO" "Scaling up containers"
    PRIORITY=10 docker compose up --detach --scale "$SERVICE=$scale" --no-recreate "$SERVICE"
    print_and_log "INFO" "Checking health of new containers"
    all_containers=$(docker compose ps --quiet "$SERVICE")
    new_containers=$(grep -Fxv -f <(echo "${OLD_CONTAINERS[*]}") <(echo "${all_containers[*]}"))
    # Perform health checks to new containers
    pids=()
    for new_container in "${new_containers[@]}"; do
        check_health "$new_container" &
        pids+=($!)
    done
    # Wait for health checks to finish
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    # Analize health checks
    local health_bar
    health_bar=$(< "$HEALTH_BAR")
    if grep -q 0 <<< "$health_bar"; then
        print_and_log "ERROR" "New containers were not healthy. Rolling back"
        docker stop "${new_containers[@]}"
        docker rm "${new_containers[@]}"
    else
        print_and_log "INFO" "Health check was successful for new containers!"
        docker stop "${OLD_CONTAINERS[@]}" > /dev/null
        docker rm "${OLD_CONTAINERS[@]}" > /dev/null
        docker rmi "${OLD_IMAGES[@]}" &> /dev/null
    fi
}

trap cleanup EXIT
check_old_containers
rollout
