#!/usr/local/bin/ruby

# encoding: utf-8

#
# SAMPLE CALL:
# =====================================================================
#
# NetSuite.call(
#   action: "fetch",
#   record_type: "customrecord_location_cost",
#   record_id: 1
# )
#
# NetSuite.call(
# 	action: "search",
# 	record_type: "customrecord_location_cost",
# 	filters: [
# 		[ "custrecord_location_cost_address", "anyOf", [ 731, 25, 213 ] ]
# 	],
# 	columns: [
# 		"custrecord_location_cost_title",
# 		"custrecord_location_cost_address"
# 	]
# )
#

require 'net/http'
require 'json'
require 'ostruct'
require 'pp'

require './lib/utils'

# == \NetSuite API Client
#
# This would be the long description.
#
class NetSuite

	# Call \NetSuite API
	#
	# === Parameters:
	#
	# +params+:: The set of paramaters to be sent to \NetSuite API web service.
	#            at least +:action+ (which can be +:fetch+ or +:search+) and +:record_type+
	#            most be specified.
	#
	#            *_Examples_*:
	#
	#            For single record fetch:
	#                { action: :fetch, record_type: :item }
	#            For multiple record fetch, with filters and columns lists:
	#                { action: :search, record_type: :item, filters: [ [ :name, :anyOf, "inventory" ] ], columns: [ "name" ] }
	# === Returns:
	#
	# +data+:: A Hash containing two keys, +:status+ and +:data+.
	#
	#          *_Example:_*:
	#
	#          For successfull fetch:
	#              { status: :ok, data: ... }
	#          For unsuccessfull calls:
	#              { status: :error, data: ... }
	#
	def self.call(params)
		netsuite_account_number = 3461650
		netsuite_restlet_url = "https://rest.netsuite.com/app/site/hosting/restlet.nl"
		netsuite_email = "gmm@transtelco.net"
		netsuite_password = "J@rrit05"
		netsuite_role = "3" # Administrator

		uri = URI(netsuite_restlet_url)
		uri.query = URI.encode_www_form(script: 348, deploy: 1)
		req = Net::HTTP::Post.new(uri)

		res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
			req["Authorization"] = "NLAuth nlauth_account=#{netsuite_account_number}, nlauth_email=#{netsuite_email}, nlauth_signature=#{netsuite_password}, nlauth_role=#{netsuite_role}"
			req["Accept"] = "*/*"
			req["Content-Type"] = "application/json"
			req.body = params.to_json
			http.request(req)
		end

		if res.is_a?(Net::HTTPSuccess)
			results = res.body =~ /^\s*null\s*$/ ? [] : JSON.parse(res.body)
			results = results.symboliser
			return OpenStruct.new(status: :ok, data: results)
		else
			results = JSON.parse(res.body)
			return OpenStruct.new(status: :error, data: results, response: res)
		end
	end
end





