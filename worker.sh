#!/bin/bash

rake resque:work QUEUE=customer_billing TERM_CHILD=1 $*





