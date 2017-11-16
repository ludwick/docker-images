#!/bin/bash
# Copyright 2017 Ismail KABOUBI
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Interface assumptions!
#
# Environment variables:
# - REDIS_SENTINEL_SERVICE_HOST and REDIS_SENTINEL_SERVICE_PORT let us talk to the sentinel.
# - REDIS_MASTER_NAME optionally is set and overrides master name.
#
# Volume mounts:
# - If /etc/config/redis-primary.conf exists, it will be used for master.
# - If /etc/config/redis-backup.conf exists, it will be used for slaves.
# - If /etc/config/redis-sentinel.conf exists, it will be used for sentinels.
#
# In redis backup and sentinel conf files, the strings %master-ip% and %master-port%
# are replaced with the host/port retrieved by querying a sentinel for those values.
# A sentinel instance will default to localhost and port 6379 if it can't query the
# sentinel service.

typeset CONFIG_DIR="/etc/config"

typeset MASTER_NAME="${REDIS_MASTER_NAME:-mymaster}"
typeset MASTER_HOST=""
typeset MASTER_PORT=""
typeset DEFAULT_MASTER_PORT=6379

function querySentinelForMaster() {
  typeset line=$(timeout -t 10 redis-cli -h "${REDIS_SENTINEL_SERVICE_HOST}" -p "${REDIS_SENTINEL_SERVICE_PORT}" --csv SENTINEL get-master-addr-by-name "$MASTER_NAME")
  if [ $? -ne 0 ]; then
    echo "Query to sentinel ${REDIS_SENTINEL_SERVICE_HOST}:${REDIS_SENTINEL_SERVICE_PORT} exited with $?, output $line"
    return 1
  fi
  echo "Queried sentinel ${REDIS_SENTINEL_SERVICE_HOST}:${REDIS_SENTINEL_SERVICE_PORT} for master, returned: $line."
  while IFS="," read -r host port; do
    MASTER_HOST="${host//\"}"
    MASTER_PORT="${port//\"}"
  done <<< "$line"

  if [ -z "$MASTER_HOST" ] || [ -z "$MASTER_PORT" ]; then 
    return 1
  fi
  return 0
}

function launchslave() {
  retries=0
  while true; do
    querySentinelForMaster
    if [ $? -ne 0 ] || [ -z "$MASTER_HOST" ]; then
      if [ $retries -lt 3 ]; then
        echo "Failed to find master. Retrying after 10 seconds."
        sleep 10
        retries=$((retries+1))
        continue
      fi
      echo "Failed to find master. Exiting after 30 seconds."
      sleep 30
      exit 1
    fi
    redis-cli -h "${MASTER_HOST}" -p "$MASTER_PORT" INFO
    if [ $? -eq 0 ]; then
      break
    fi
    echo "Connecting to master at $MASTER_HOST:$MASTER_PORT failed.  Waiting..."
    sleep 10
  done

  if [[ ! -e /redis-data ]]; then
    echo "Redis data dir doesn't exist, data won't be persistent!"
    mkdir /redis-data
  fi

  typeset slave_conf="/redis-slave/redis.conf"

  if [ -r "${CONFIG_DIR}/redis-server.conf" ]; then
    cp "${CONFIG_DIR}/redis-server.conf" $slave_conf
  else
    echo "No configuration in ${CONFIG_DIR}. Slave is starting up with defaults."
  fi

  echo >> $slave_conf
  echo "slaveof %master-ip% %master-port%" >> $slave_conf

  sed -i "s/%master-ip%/${MASTER_HOST}/" $slave_conf
  sed -i "s/%master-port%/${MASTER_PORT}/" $slave_conf

  echo "Starting slave with configuration:"
  cat $slave_conf
  redis-server $slave_conf --protected-mode no
}

function launchmaster() {
  # Even when launching a master, if it turns out that the master is alrady set
  # due to failover, then we should launch in slave mode.
  querySentinelForMaster
  if [ $? -eq 0 ] && [ ! -z "$MASTER_HOST" ]; then
    echo "Sentinels returned master host $MASTER_HOST:$MASTER_PORT, starting as slave"
    launchslave
    return
  fi

  echo "This instance ($POD_NAME) is master."
  if [[ ! -e /redis-data ]]; then
    echo "Redis data dir doesn't exist, data won't be persistent!"
    mkdir /redis-data
  fi

  typeset master_conf="/redis-master/redis.conf"

  if [ -r "${CONFIG_DIR}/redis-server.conf" ]; then
    cp "${CONFIG_DIR}/redis-server.conf" $master_conf
  else
    echo "No configuration in ${CONFIG_DIR}. Master is starting up with defaults."
  fi

  echo "Starting master with configuration:"
  cat $master_conf
  redis-server $master_conf --protected-mode no
}

# Launch master when `SENTINEL` environment variable is set
function launchsentinel() {
  echo "Launching sentinel $POD_NAME after querying for current master"
  while true; do
    querySentinelForMaster
    if [ $? -ne 0 ] || [ -z "$MASTER_HOST" ]; then
      echo "No sentinel knows master, defaulting to ${DEFAULT_MASTER}"
      MASTER_HOST=${DEFAULT_MASTER}.${SERVICE_NAME}
      MASTER_PORT=${DEFAULT_MASTER_PORT}
    fi

    redis-cli -h "${MASTER_HOST}" -p "$MASTER_PORT" INFO
    if [ $? -eq 0 ]; then
      break
    fi
    echo "Connecting to master at $MASTER_HOST:$MASTER_PORT failed.  Waiting..."
    sleep 10
  done

  echo "Master found at $MASTER_HOST:$MASTER_PORT. Starting slave instance."
  typeset sentinel_conf=sentinel.conf

  if [ -r "${CONFIG_DIR}/redis-sentinel.conf" ]; then
    cp "${CONFIG_DIR}/redis-sentinel.conf" $sentinel_conf
    sed -i "s/%master-ip%/${MASTER_HOST}/" $sentinel_conf
    sed -i "s/%master-port%/${MASTER_PORT}/" $sentinel_conf
  else
    echo "No configuration in ${CONFIG_DIR}. Sentinel is starting up with defaults."

    echo "\nsentinel monitor $MASTER_NAME ${MASTER_HOST} ${MASTER_PORT} 2" > ${sentinel_conf}
    echo "sentinel down-after-milliseconds $MASTER_NAME 60000" >> ${sentinel_conf}
    echo "sentinel failover-timeout $MASTER_NAME 180000" >> ${sentinel_conf}
    echo "sentinel parallel-syncs $MASTER_NAME 1" >> ${sentinel_conf}
    echo "bind 0.0.0.0"
  fi

  echo "Starting sentinel with configuration:"
  cat $sentinel_conf
  redis-sentinel ${sentinel_conf} --protected-mode no
}

# Both master and slaves have REDIS_NODE set to true. The default master
# is given so that at startup the first time, it can try to be master.
if [[ "${REDIS_NODE}" == "true" ]]; then
  if  [[ "${DEFAULT_MASTER}" == "${POD_NAME}" ]]; then
    echo "Appear to be on master, trying master mode"
    launchmaster
  else
    echo "Appear to be on slave, launching slave mode"
    launchslave
  fi
  exit 0
fi

# Launch slave if nothing is set
launchsentinel
