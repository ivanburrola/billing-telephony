require 'ostruct'

Configuration = OpenStruct.new(
	local: OpenStruct.new(
		hostname: nil,
		username: nil,
		password: nil,
		database: nil
	),
	remote: OpenStruct.new(
		hostname: nil,
		username: nil,
		password: nil,
		database: nil
	),
	toll_free_regexp: nil,
	core_gateways: nil,
	rate_prefixes: OpenStruct.new(
		american_trunk: nil,
		mexican_trunk: nil
	),
	call_types: {
		americana: [],
		mexicana: []
	}
)

class OpenStruct
	def config
		yield self
	end
end

require File.join(File.realpath(File.dirname(__FILE__)), "../config/configuration.rb")

RATE_PREFIXES={
	mexicana: YAML.load(open("./config/rate_prefixes_mexican_trunks.yml").read),
	americana: YAML.load(open("./config/rate_prefixes_american_trunks.yml").read)
}

NETSUITE_CALL_TYPES=YAML.load(open("./config/netsuite_call_types.yml").read)

