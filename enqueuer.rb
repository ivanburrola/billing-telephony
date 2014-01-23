#!/usr/bin/env ruby

require 'pp'
require 'pry'
require 'resque'

require './lib/queuer'

Queuer.work
