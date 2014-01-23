#!/usr/bin/env ruby

# encoding: utf-8

require 'yaml'

require "./lib/net_suite"

res = NetSuite.call(action: "customer", customer_id: 14487)

if res.status == :ok
	puts res.data.to_yaml
else
	puts "Error: "
	pp res
end


