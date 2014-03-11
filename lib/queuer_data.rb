# encoding: utf-8

require './lib/utils.rb'
require './lib/net_suite.rb'
require './lib/data_billing_job.rb'

class QueuerDataError < Exception
end

class QueuerData
  def self.work(options={})

    if !options[:year] or !options[:month]
        puts "Overriding year/month combination."
        currdate = Time.now
        if currdate.month == 1
            options[:year] = currdate.year - 1
            options[:month] = 12
        else
            options[:year] = currdate.year
            options[:month] = currdate.month - 1
        end
        puts "Set year/month to #{options[:year]}/#{options[:month]}"
    end

    options[:year] = Time.now.year unless options[:year]
    options[:month] = Time.now.month unless options[:month]
    options[:customer_ids] = nil unless options[:customer_ids]

    puts
    puts "DATA BILLING QUEUEING PROCESS"
    puts "============================="

    if options[:customer_ids]
      filters = [
        [ "internalId", "anyOf", options[:customer_ids] ]
      ]
    else
      filters = [
        [ "custentity_tdata_enable", "is", "T" ]
      ]
    end

    customers = NetSuite.call(
        action: "search",
        record_type: "customer",
        filters: filters,
        columns: [
            "internalId",
            "entityid",
            "custentity_tdata_cacti_ids",
            "custentity_tdata_price_per_mb_def"
        ]
    )

    if customers.status == :ok
      customer_list = customers.data.symboliser
      if customer_list.size > 0
        customer_list.each do |customer|
          puts "Enqueuing DATA Customer ID: #{customer[:id]} - #{customer[:columns][:entityid]} for #{"%04i" % options[:year]}/#{"%02i" % options[:month]}"
          Resque.enqueue DataBillJob, customer_id: customer[:id], customer_name: customer[:columns][:entityid], year: options[:year], month: options[:month], graph_def: customer[:columns][:custentity_tdata_cacti_ids], pricing_def: CGI.unescape_html(customer[:columns][:custentity_tdata_price_per_mb_def])
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
