# encoding: utf-8

require './lib/utils'

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
  end

  def bill
    log "Billing #{self.inspect}"
    # TODO: Build actual billing process...
  end
end



