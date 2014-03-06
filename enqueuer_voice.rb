#!/usr/bin/env ruby

require 'pp'
require 'pry'
require 'resque'

require './lib/queuer_voice'

customer_ids = ENV["CUSTOMER_IDS"] ? ENV["CUSTOMER_IDS"].split(/,/).map{ |id| id.strip.to_i } : nil

if ENV["YEAR"] and ENV["MONTH"]
	QueuerVoice.work(customer_ids: customer_ids, year: ENV["YEAR"].strip.to_i, month: ENV["MONTH"].strip.to_i)
else
	QueuerVoice.work(customer_ids: customer_ids)
end
