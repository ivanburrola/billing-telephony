#!/usr/local/rvm/rubies/ruby-2.0.0-p353/bin/ruby

RVM_GLOBAL="ruby-2.0.0-p353@global"
RVM_STRING="ruby-2.0.0-p353@mediator"

ENV["rvm_use_flag"]="1"
ENV["GEM_HOME"]="/usr/local/rvm/gems/"+RVM_STRING
ENV["PATH"]="/usr/local/rvm/gems/"+RVM_STRING+"/bin:"+(ENV["PATH"]||'')
ENV["rvm_env_string"]=RVM_STRING
ENV["GEM_PATH"]="/usr/local/rvm/gems/"+RVM_STRING+":/usr/local/rvm/gems/"+RVM_GLOBAL

require 'fileutils'

FileUtils.cd('/opt/mediator')

require 'pp'
require 'pry'
require 'resque'

require './lib/queuer_voice'

customer_ids = ENV["CUSTOMER_IDS"] ? ENV["CUSTOMER_IDS"].split(/,/).map{ |id| id.strip.to_i } : nil

puts Time.now.strftime("%Y-%m-%d %H:%M:%S")
puts "=================================="

if ENV["YEAR"] and ENV["MONTH"]
	QueuerVoice.work(customer_ids: customer_ids, year: ENV["YEAR"].strip.to_i, month: ENV["MONTH"].strip.to_i)
else
	QueuerVoice.work(customer_ids: customer_ids)
end

puts
puts

