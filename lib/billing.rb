# encoding: utf-8

require './lib/utils'
require './lib/telephony_customer_biller.rb'

module Customer
  class Base
    include CustomerLogger
    extend CustomerLogger
  end
end

class CustomerBillError < Exception
  # Do nothing
end

class CustomerBilling < Customer::Base
  def initialize(options={})
    @customer_id, @customer_name, @year, @month = options["customer_id"].strip.to_i, options["customer_name"].strip, options["year"].to_i, options["month"].to_i
    @requested_on = Time.now
  end

  def bill
    log "Voice Billing #{self.inspect}..."
    tcb = TelephonyCustomerBiller.new(customer_id: @customer_id, year: @year, month: @month)
    tcb.fetch_billing_info
    filenames = tcb.process
    log "File names generated:"
    filenames.each do |filename|
      log "> #{filename}"
    end
    log "Voice Billing Done."
    log "\n"
  end
end



