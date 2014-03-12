# encoding: utf-8

require './lib/utils'
require './lib/data_billing.rb'

module DataCommon
  class Base
    include DataLogger
    extend DataLogger
  end
end

class DataBillerError < Exception
  # Do nothing
end

class DataBiller < DataCommon::Base
  def initialize(options={})
    @customer_id, @customer_name, @currency, @year, @month, @graph_def, @pricing_def = options["customer_id"].strip.to_i, options["customer_name"].strip, options["currency"], options["year"].to_i, options["month"].to_i, options["graph_def"], options["pricing_def"]
    @requested_on = Time.now
  end

  def bill
    log "Data Billing #{self.inspect}..."
    dbi = DataBilling.new(customer_id: @customer_id, customer_name: @customer_name, currency: @currency, year: @year, month: @month, graph_def: @graph_def, pricing_def: @pricing_def)
    dbi.fetch_billing_info
    filename = dbi.process
    log "File name generated: #{filename}"
    log "Data Billing Done."
    log "\n"
  end
end



