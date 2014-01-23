#!/usr/bin/env ruby

# encoding: utf-8

require "./lib/net_suite"

res = NetSuite.call(action: "customer", customer_id: 14487)

if res.status == :ok
	pp res.data
else
	puts "Error: "
	pp res
end


