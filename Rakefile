# encoding: utf-8

require 'resque/tasks'
require 'resque'

require './lib/customer_bill_job.rb'

Resque.logger = Logger.new(STDOUT)
Resque.logger.level = Logger::INFO
Resque.logger.level = Logger::DEBUG if (ENV["DEBUG"]||'').strip.downcase =~ /(1|yes|on)/



