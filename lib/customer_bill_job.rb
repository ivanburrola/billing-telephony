# encoding: utf-8

require './lib/billing'

class CustomerBillJob < Customer::Base
  @queue = :customer_billing

  def self.perform(options={})
    log "Creating VOICE billing process for #{options.inspect}..."
    CustomerBilling.new(options).bill
    log "Done VOICE billing process for #{options}..."
  end
end

