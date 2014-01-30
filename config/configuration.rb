# encoding: utf-8

require 'yaml'
require 'pry'

Configuration.config do |config|
	# Local database configuration
	config.local.hostname = '127.0.0.1'
	config.local.username = 'billing'
	config.local.password = 'itfp534U'
	config.local.database = 'billing'

	# Remote database configuration
	config.remote.hostname = '201.174.2.48'
	config.remote.username = 'billing'
	config.remote.password = 'TT3.0rc1'
	config.remote.database = 'mvtspro'

	config.toll_free_regexp = "(^1(800|811|822|833|844|855|866|877|880|881|882|883|884|885|886|887|888|889|899)[0-9]|^52(800))"

	config.core_gateways = [
		"Genpact MX-Gw1",
		"Genpact MX-Gw2",
		"Genpact US-Gw2",
		"Genpact US1",
		"Genpact US2",
		"Core-Verizon 2way 1",
		"Core-Verizon 2way 2",
		"Core-Yate-MX",
		"Core-Yate-US"
	]

	config.call_types[:americana] = [
		:us_local,
		:us_nationalld,
		:us_mexicold,
		:us_mexicomobilejrz,
		:us_mexicomobile,
		:us_mexicojuarez,
		:us_tollfree,
		:us_mexicotollfree
	]

	config.call_types[:mexicana] = [
		:mx_locales,
		:mx_cellocal,
		:mx_celnacional,
		:mx_ldnacional,
		:mx_uscanada,
		:mx_tollfreemx,
		:mx_tollfreeus
	]
end
