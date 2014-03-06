# encoding: utf-8

require './lib/data'

class DataBillJob < DataCommon::Base
  @queue = :customer_billing

  def self.perform(options={})
    log "Creating DATA billing process for #{options.inspect}..."
    DataBiller.new(options).bill
    log "Done DATA billing process for #{options}..."
  end
end

