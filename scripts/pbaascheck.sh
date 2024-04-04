#!/bin/bash
##
## © verus.io 2018-2024, released under MIT license
## Script written in 2023 by Oink.vrsc@
## Script maintained by Oink.vrsc@

# check if script is already running
if [ -f /tmp/pbaascheck.pid ]
then
  echo "script is already running"
  exit 1
else
  touch /tmp/pbaascheck.pid
fi

## default settings
VERUS=/home/verus/bin/verus      # complete path to (and including) the verus RPC client
MAIN_CHAIN=VRSC                  # main hashing chain
REDIS_NAME=verus                 # name you assigned the coin in `/home/pool/s-nomp/coins/*.json`
REDIS_HOST=localhost             # If you run this script on another system, alter the IP address of your Redis server
REDIS_PORT=6379                  # If you use a different REDIS port, alter the port accordingly
#REDIS_PASS=examplepass           # Remove the # if no password

## Set script folder
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

## check if the Verus binary is found.
## If Verus exists in the PATH environment, use it.
## If not, fall back to predefined location in this script.
if ! command -v verus &>/dev/null
then
  echo "verus not found in your PATH environment. Using location from line 9 in this script."
  if ! command -v $VERUS &>/dev/null
  then
    echo "Verus could not be found. Make sure it's in your path and/or in line 9 of this script."
    echo "exiting..."
    exit 1
  fi
else
  VERUS=$(which verus)
fi


## Dependencies: jq, tr, cut, redis-cli/keydb-cli
## jq
if ! command -v jq &>/dev/null ; then
    echo "jq not found. please install using your package manager."
    exit 1
else
    JQ=$(which jq)
fi
## tr
if ! command -v tr &>/dev/null ; then
    echo "tr not found. please install using your package manager."
    exit 1
else
    TR=$(which tr)
fi
## cut
if ! command -v cut &>/dev/null ; then
    echo "cut not found. please install using your package manager."
    exit 1
else
    CUT=$(which cut)
fi
## redis-cli and/or keydb-cli
if ! command -v redis-cli &>/dev/null ; then
    if ! command -v keydb-cli &>/dev/null ; then
       echo "Both redis-cli or keydb-cli not found. Please install one using your package manager."
       exit 1
    fi
    REDIS_CLI="$(which keydb-cli) -h $REDIS_HOST -p $REDIS_PORT"
else
    REDIS_CLI="$(which redis-cli) -h $REDIS_HOST -p $REDIS_PORT"
fi

# Check if a Redis password is provided
if [[ ! -z "$REDIS_PASS" ]]; then
    REDIS_CLI="$REDIS_CLI -a $REDIS_PASS"
fi

## Can we connect to Redis?
if [[ "$($REDIS_CLI ping)" != "PONG" ]]
then
  echo "cannot connect to redis server"
  exit 1
fi

echo "Successfully authenticated and connected to the Redis server."

## Is main chain active?
count=$(${VERUS} -chain=$MAIN_CHAIN getconnectioncount 2>/dev/null)
case $count in
  ''|*[!0-9]*) DAEMON_ACTIVE=0 ;;
  *) DAEMON_ACTIVE=1 ;;
esac
if [[ "$DAEMON_ACTIVE" != "1" ]]
then
  echo "$MAIN_CHAIN daemon is not running and connected. Start your $MAIN_CHAIN daemon and wait for it to be connected."
  exit 1
fi

## Return a list of found PBaaS hashes:
HASHLIST=$($REDIS_CLI smembers $REDIS_NAME:pbaasPending | $CUT -d' ' -f2-)
## return a list on found shares per miner
SHARELIST=$($REDIS_CLI hgetall $REDIS_NAME:shares:roundCurrent| $CUT -d' ' -f2-)
## get list of active chains in ecosystem
PBAAS_CHAINS=$($VERUS -chain=$MAIN_CHAIN listcurrencies '{"systemtype":"pbaas"}' | jq --arg MAIN_CHAIN "${MAIN_CHAIN}" -r '.[].currencydefinition | select (.name != "$MAIN_CHAIN") | .name')
## determine chains active on this system
for i in $PBAAS_CHAINS
do
  count=$(${VERUS} -chain=$i getconnectioncount 2>/dev/null)
  case $count in
    ''|*[!0-9]*) DAEMON_ACTIVE=0 ;;
    *) DAEMON_ACTIVE=1 ;;
  esac
  if [[ "$DAEMON_ACTIVE" = "1" ]]
  then
    ACTIVE_CHAINS="$ACTIVE_CHAINS $i"
  fi
done

## copy shares
for j in $ACTIVE_CHAINS
do
  if [[ "$(echo $j | $TR '[:upper:]' '[:lower:]')" != "$(echo $MAIN_CHAIN | $TR '[:upper:]' '[:lower:]')" ]]
  then
    $REDIS_CLI hset $(echo $j | $TR '[:upper:]' '[:lower:]'):shares:roundCurrent $SHARELIST 1>/dev/null
  fi
done

## Check each hash on all chains
for i in $HASHLIST
do
  for j in $ACTIVE_CHAINS
  ## put in break for non-running chains
  do
    CHECK=$($VERUS -chain=$j getblock $(echo $i | $CUT -d':' -f1) 2 2>/dev/null)
    if [[ "$CHECK" =~ "$(echo $i | cut -d':' -f1)"  ]]
    then
      TRANSACTION=$(echo "$CHECK" | $JQ -r '.tx[0].txid')
      BLOCK=$(echo "$CHECK" | $JQ  '.height')
      echo "$j contains blockhash $(echo $i | cut -d':' -f1), TXID: $TRANSACTION"
      REDIS_NEW_PENDING="${i:0:65}"$TRANSACTION:$BLOCK:"${i:65}"
      if [[ "$(echo $j | $TR '[:upper:]' '[:lower:]')" != "$(echo $MAIN_CHAIN | $TR '[:upper:]' '[:lower:]')" ]]
      then
        $REDIS_CLI sadd $(echo $j | $TR '[:upper:]' '[:lower:]'):blocksPending $REDIS_NEW_PENDING 1>/dev/null
        ## if no shares are known for this round yet, add them
        SHARES_AVAILABLE="$($REDIS_CLI hgetall $(echo $j | tr '[:upper:]' '[:lower:]'):shares:round$BLOCK)"
        if [[ "$SHARES_AVAILABLE" == "" ]]
        then
          $REDIS_CLI hset $(echo $j | tr '[:upper:]' '[:lower:]'):shares:round$BLOCK $SHARELIST 1>/dev/null
        fi
      fi
    fi
  done
done

UNKNOWN_HASHLIST=$($REDIS_CLI smembers $REDIS_NAME:pbaasPending | $CUT -d' ' -f2-)
if [ -f $SCRIPT_DIR/unknown_hashlist.4 ]
then
  while read -r LINE
  do
    if [[ "$UNKNOWN_HASHLIST" == *"$LINE"* ]]
    then
      echo "removing $LINE from REDIS"
      $REDIS_CLI srem $REDIS_NAME:pbaasPending $LINE 1>/dev/null
    fi
  done < $SCRIPT_DIR/unknown_hashlist.4
  rm $SCRIPT_DIR/unknown_hashlist.4
fi

for i in {3..1}
do
  if [ -f $SCRIPT_DIR/unknown_hashlist.$i ]
  then
    mv $SCRIPT_DIR/unknown_hashlist.$i $SCRIPT_DIR/unknown_hashlist.$((i+1))
  fi
done

for i in $UNKNOWN_HASHLIST
do
  echo $i >> $SCRIPT_DIR/unknown_hashlist.1
done
