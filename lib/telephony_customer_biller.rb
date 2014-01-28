# encoding: utf-8

class TelephonyCustomerBillerError < Exception
end

class TelephonyCustomerBiller
	def initialize(options={})

		raise TelephonyCustomerBillerError.new("Papas") unless @customer_id =~ /^\d+$/ and  @year =~ /^(19|20)[0-9][0-9]$/ and @month =~ /^([1-9]|1[0-2])$/

		@customer_id = (options[:customer_id]||'').to_s.strip
		@year = (options[:year]||'').to_s.strip
		@month = (options[:year]||'').to_s.strip

		raise TelephonyCustomerBillerError.new("Papas") unless @customer_id =~ /^\d+$/ and  @year =~ /^(19|20)[0-9][0-9]$/ and @month =~ /^([1-9]|1[0-2])$/

		@customer_id, @year, @month = @customer_id.to_i, @year.to_i, @month.to_i

		pp @customer_id, @year, @month

	end

	private

	def check_options(options={})
		time_now = Time.now

		options[:customer_id] ||= ""
		options[:year] ||= ""
		options[:month] ||= ""

		if !options[:year] and !options[:month]
			if time_now == 1
				options[:year] = time_now.year-1
				options[:month] = 12
			else
				options[:year] = time_now.year
				options[:month] = time_now.month-1
			end
		end


		raise TelephonyCustomerBillerError.new("options is not a hash (#{options.class.to_s} :: #{options.inspect})") unless options.class == Hash
		raise TelephonyCustomerBillerError.new("invalid customer_id") unless options[:customer_id].to_s.strip =~ /^\d+$/
		raise TelephonyCustomerBillerError.new("invalid year") unless options[:year].to_s.strip =~ /^(19|2[0-2])\d\d$/
		raise TelephonyCustomerBillerError.new("invalid month ") unless  (options[:customer_id]||'').to_s.strip =~ /^([1-9]|1[0-2])$/
		raise TelephonyCustomerBillerError.new("") unless
		raise TelephonyCustomerBillerError.new("") unless
		raise TelephonyCustomerBillerError.new("") unless
		raise TelephonyCustomerBillerError.new("") unless
		raise TelephonyCustomerBillerError.new("") unless
		raise TelephonyCustomerBillerError.new("") unless

	end

end


TelephonyCustomerBiller.new(14487)
