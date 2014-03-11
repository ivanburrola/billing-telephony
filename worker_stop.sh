#!/bin/bash

LOCK_FILE=/opt/mediator/worker.lock

pid=`cat $LOCK_FILE`

echo "Attempting to stop Billing Worker application"

kill -9 $pid >/dev/null 2>&1

cat /dev/null > $LOCK_FILE

echo "Done."




