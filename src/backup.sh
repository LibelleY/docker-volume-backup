#!/bin/bash
# Cronjobs don't inherit their env, so load from file

source env.sh

function info {
  bold="\033[1m"
  reset="\033[0m"
  echo -e "\n$bold[INFO] $1$reset\n"
}

function container_stop {
  echo "$CONTAINERS_TOTAL containers running on host in total"
  echo "$CONTAINERS_TO_STOP_TOTAL containers marked to be stopped during backup"

  if [ "$CONTAINERS_TO_STOP_TOTAL" != "0" ]; then
    info "Stopping containers"
    docker stop $CONTAINERS_TO_STOP
  else
    echo "No containers marked to stop"
  fi
}

function container_start {
  if [ "$CONTAINERS_TO_STOP_TOTAL" != "0" ]; then
    info "Stopping containers"
    docker start $CONTAINERS_TO_STOP
  fi
}

function service_stop {
  if [ "$CONTAINERS_TO_STOP_TOTAL" != "0" ]; then
    TEMPFILE="$(mktemp)"

    for cont in $CONTAINERS_TO_STOP; do
      docker container inspect --format '{{index .Config.Labels "com.docker.swarm.service.name"}}' $cont >> "$TEMPFILE"
    done

    SERVICES_TO_STOP="$(cat $TEMPFILE | tr '\n' ' ')"
    rm "$TEMPFILE"
    echo "Stopping the following Services: $SERVICES_TO_STOP"

    for cont in $SERVICES_TO_STOP; do
      MODE="$(docker service ls -f mode=replicated --format {{.Name}} |grep $cont)"
      if [ -n "$MODE" ]; then
        info "Stopping service $cont"
        docker service scale $cont=0
        sleep 3
      fi
    done
  fi
}

function service_start {
  if [ "$CONTAINERS_TO_STOP_TOTAL" != "0" ]; then
    for cont in $SERVICES_TO_STOP; do
      info "Starting Service $cont with $SWARM_REPLICAS Replicas:"
      docker service scale $cont=$SWARM_REPLICAS
      sleep 3
    done
  fi
}

function pre_exec {
  if [ -S "$DOCKER_SOCK" ]; then
    TEMPFILE="$(mktemp)"
    docker ps \
      --filter "label=docker-volume-backup.exec-backup.ident=$BACKUP_IDENT" \
      --filter "label=docker-volume-backup.exec-pre-backup" \
      --format '{{.ID}} {{.Label "docker-volume-backup.exec-pre-backup"}}' \
        > "$TEMPFILE"
    CONTAINER_TO_EXEC="$(cat $TEMPFILE | wc -l)"
    echo "$CONTAINER_TO_EXEC containers have Pre-Backup commands"
    if [ $CONTAINER_TO_EXEC -gt 0 ]; then
      while read line; do
         PRECMD=( $(IFS=" " echo "$line") )
         COMMAND=${PRECMD[@]:1:100}
         echo "executing Pre-Backup command \"${COMMAND}\" on container \"${PRECMD[0]}\" for ident \"$BACKUP_IDENT:\""
         docker exec $line
      done < "$TEMPFILE"
      rm "$TEMPFILE"
    fi
  else
    echo "Cannot access \"$DOCKER_SOCK\", won't look for pre-exec commands"
  fi
}

function post_exec {
  if [ -S "$DOCKER_SOCK" ]; then
    TEMPFILE="$(mktemp)"
    docker ps \
      --filter "label=docker-volume-backup.exec-backup.ident=$BACKUP_IDENT" \
      --filter "label=docker-volume-backup.exec-post-backup" \
      --format '{{.ID}} {{.Label "docker-volume-backup.exec-post-backup"}}' \
        > "$TEMPFILE"
    CONTAINER_TO_EXEC="$(cat $TEMPFILE | wc -l)"
    echo "$CONTAINER_TO_EXEC containers have Post-Backup commands"

    if [ $CONTAINER_TO_EXEC -gt 0 ]; then
      while read line; do
         POSTCMD=( $(IFS=" " echo "$line") )
         COMMAND=${POSTCMD[@]:1:100}
         echo "executing Post-Backup command \"${COMMAND}\" on container \"${POSTCMD[0]}\" for ident \"$BACKUP_IDENT:\""
         docker exec $line
      done < "$TEMPFILE"
      rm "$TEMPFILE"
    fi
  else
    echo "Cannot access \"$DOCKER_SOCK\", won't look for post-exec commands"
  fi
}

info "Backup starting"

TIME_START="$(date +%s.%N)"
DOCKER_SOCK="/var/run/docker.sock"

if [ -S "$DOCKER_SOCK" ]; then
  TEMPFILE="$(mktemp)"
  docker ps --format "{{.ID}}" --filter "label=docker-volume-backup.stop-during-backup=$BACKUP_IDENT" > "$TEMPFILE"
  CONTAINERS_TO_STOP="$(cat $TEMPFILE | tr '\n' ' ')"
  CONTAINERS_TO_STOP_TOTAL="$(cat $TEMPFILE | wc -l)"
  CONTAINERS_TOTAL="$(docker ps --format "{{.ID}}" | wc -l)"
  rm "$TEMPFILE"
else
  CONTAINERS_TO_STOP_TOTAL="0"
  CONTAINERS_TOTAL="0"
  echo "Cannot access \"$DOCKER_SOCK\", won't look for containers to stop"
fi

info "Looking for pre-exec commands:"
pre_exec

if [ "$SWARM_REPLICAS" -gt "0" ]; then
  info "Swarm Mode with $SWARM_REPLICAS Replicas set, looking for services to stop:"
  service_stop
else
  info "No Swarm Mode set, looking for containers to stop:"
  container_stop
fi

info "Creating backup"
BACKUP_FILENAME=$(date +"$BACKUP_FILENAME_TEMPLATE")
TIME_BACK_UP="$(date +%s.%N)"
echo "Creating Backup from the following sources: $BACKUP_SOURCES"
tar -czf $BACKUP_FILENAME $BACKUP_SOURCES # allow the var to expand, in case we have multiple sources
BACKUP_SIZE="$(du --bytes $BACKUP_FILENAME | sed 's/\s.*$//')"
TIME_BACKED_UP="$(date +%s.%N)"

info "Waiting before processing"
echo "Sleeping $BACKUP_WAIT_SECONDS seconds..."
sleep "$BACKUP_WAIT_SECONDS"

if [ "$SWARM_REPLICAS" -gt "0" ]; then
  service_start
else
  container_start
fi


info "Looking for post-exec commands:"
post_exec

TIME_UPLOAD="0"
TIME_UPLOADED="0"

if [ ! -z "$AWS_S3_BUCKET_NAME" ]; then
  info "Uploading backup to S3"
  echo "Will upload to bucket \"$AWS_S3_BUCKET_NAME\""
  TIME_UPLOAD="$(date +%s.%N)"
  aws $AWS_EXTRA_ARGS s3 cp --only-show-errors "$BACKUP_FILENAME" "s3://$AWS_S3_BUCKET_NAME/"
  echo "Upload finished"
  TIME_UPLOADED="$(date +%s.%N)"
fi

if [ -d "$BACKUP_ARCHIVE" ]; then
  info "Archiving backup"
  mv -v "$BACKUP_FILENAME" "$BACKUP_ARCHIVE/$BACKUP_FILENAME"
fi

if [ -f "$BACKUP_FILENAME" ]; then
  info "Cleaning up"
  rm -vf "$BACKUP_FILENAME"
fi

info "Collecting metrics"
TIME_FINISH="$(date +%s.%N)"
INFLUX_LINE="$INFLUXDB_MEASUREMENT\
,host=$BACKUP_HOSTNAME\
\
 size_compressed_bytes=$BACKUP_SIZE\
,containers_total=$CONTAINERS_TOTAL\
,containers_stopped=$CONTAINERS_TO_STOP_TOTAL\
,time_wall=$(perl -E "say $TIME_FINISH - $TIME_START")\
,time_total=$(perl -E "say $TIME_FINISH - $TIME_START - $BACKUP_WAIT_SECONDS")\
,time_compress=$(perl -E "say $TIME_BACKED_UP - $TIME_BACK_UP")\
,time_upload=$(perl -E "say $TIME_UPLOADED - $TIME_UPLOAD")\
"
echo "$INFLUX_LINE" | sed 's/ /,/g' | tr , '\n'

if [ ! -z "$INFLUXDB_URL" ]; then
  info "Shipping metrics"
  curl \
    --silent \
    --include \
    --request POST \
    --user "$INFLUXDB_CREDENTIALS" \
    "$INFLUXDB_URL/write?db=$INFLUXDB_DB" \
    --data-binary "$INFLUX_LINE"
fi

info "Backup finished"
echo "Will wait for next scheduled backup"
