# encoding: utf-8

require './lib/utils.rb'
require './lib/net_suite.rb'
require './lib/customer_bill_job.rb'

class QueuerError < Exception
end

class Queuer
  def self.work(options={})

    options[:year] = Time.now.year unless options[:year]
    options[:month] = Time.now.month unless options[:month]

    puts
    puts "TELEFONY BILLING ENQUEUING PROCESS"
    puts "=================================="

    customers = NetSuite.call(
        action: "search",
        record_type: "customer",
        filters: [
            [ "custentity_telephony_billable", "is", "T" ]
        ],
        columns: [
            "internalId",
            "entityid"
        ]
    )

    if customers.status == :ok
      customer_list = customers.data.symboliser
      if customer_list.size > 0
        customer_list.each do |customer|
          puts "Enqueuing Customer ID: #{customer[:id]} - #{customer[:columns][:entityid]} for #{"%04i" % options[:year]}/#{"%02i" % options[:month]}"
          Resque.enqueue CustomerBillJob, customer_id: customer[:id], customer_name: customer[:columns][:entityid], year: options[:year], month: options[:month]
        end
        puts "Done."
      else
        puts "No customers for invoicing found."
      end
    else
      raise QueuerError.new("Error fetching customer list: "+customers.data["error"]["code"]+" - "+customers.data["error"]["message"])
    end
    puts
  end
end
