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
	core_gateways: nil
)

class OpenStruct
	def config
		yield self
	end
end

require File.join(File.realpath(File.dirname(__FILE__)), "../config/configuration.rb")

