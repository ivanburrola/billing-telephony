# encoding: utf-8

require './lib/net_suite'
require 'yaml'
require 'pp'

class TelephonyCustomerBillerError < Exception
end

class TelephonyCustomerBiller
	def initialize(options)
		raise TelephonyCustomerBillerError.new("invalid options, you must provide a hash") if options.class != Hash
		raise TelephonyCustomerBillerError.new("invalid options, you must provide a customer_id") if !options[:customer_id]
		current_time = Time.now
		options[:year] = current_time.year unless options[:year]
		options[:month] = current_time.month unless options[:month]
		@customer_id, @year, @month = options[:customer_id], options[:year], options[:month]
	end

	def fetch_billing_info
		response = NetSuite.call(action: "customer", customer_id: @customer_id)
		puts response.data.to_yaml
		exit
		if response.status == :ok
			@customer = response.data[:billing_info][:customer]
			@origins = response.data[:billing_info][:origins]
			@rates = response.data[:billing_info][:rates]
			@trunk_types = response.data[:billing_info][:trunk_types]
			@global_rates = response.data[:billing_info][:global_rates]
			return true
		else
			raise TelephonyCustomerBillerError.new("error fetching configuration for customer #{@customer_id} : #{respose.inspect}")
		end
	end

	private

end

tcb = TelephonyCustomerBiller.new(customer_id: 4941)
tcb.fetch_billing_info
pp tcb




__END__
