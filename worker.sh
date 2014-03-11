#!/bin/bash --login

BASE_DIR=/opt/mediator

LOCK_FILE=$BASE_DIR/worker.lock

LOG_FILE=$BASE_DIR/log/worker.log

echo "Starting Billing Worker..."

touch $LOG_FILE

cd $BASE_DIR

date >> $LOG_FILE

# node app </dev/null >>$LOG_FILE 2>&1 & pid=$!
rake resque:work QUEUE=customer_billing TERM_CHILD=1 $* </dev/null >>$LOG_FILE 2>&1 & pid=$! 

echo $pid > $LOCK_FILE

echo "Billing Worker started successfully with PID $pid"


