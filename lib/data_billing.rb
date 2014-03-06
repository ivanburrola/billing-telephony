# encoding: utf-8

require 'pp'
require 'pry'
require 'yaml'
require 'logger'
require './lib/utils'
require './lib/net_suite'
require './lib/cacti'
require './lib/data_billing_printer'

class DataBillingError < Exception
end

class DataBilling

  CACTI_URI = "http://graphs.transtelco.net"
  CACTI_LOGIN = "admin"
  CACTI_PASSWORD = "TT3.0rc1"

  COLUMN_TYPES = { "d" => :date, "i" => :inbound, "o" => :outbound }

  attr_accessor :logger

  def initialize(options)
    @customer_id = options[:customer_id]
    @customer_name = options[:customer_name]

    @graph_def = (options[:graph_def]||'').strip.downcase
    @pricing_def = (options[:pricing_def]||'').strip.downcase

    @year = (options[:year]||'').to_s.strip.downcase
    @month = (options[:month]||'').to_s.strip.downcase
    @logger = options[:logger].nil? ? Logger.new(STDOUT) : options[:logger]

    raise DataBillingError.new("no valid graph_def provided (\"#{@graph_def}\").") unless @graph_def =~ /^\d+:d(:[iox])+$/
    raise DataBillingError.new("no valid pricing_def provided (\"#{@pricing_def}\").") unless @pricing_def =~ /^\d+(\.\d+)?(\s+<\d+:\d+(.\d+)?)*$/
    raise DataBillingError.new("no valid year provided (\"#{@year}\").") unless @year =~ /^\d+$/
    raise DataBillingError.new("no valid month provided (\"#{@month}\").") unless @month =~ /^(0?[1-9]|1[0-2])$/
    raise DataBillingError.new("no valid logger provided (\"#{@pricing_def}\").") unless @logger.is_a?(Logger)

    @year = @year.to_i
    @month = @month.to_i

    raise DataBillingError.new("no valid year provided (\"#{@year}\") must be between 2012 and 2099.") unless (2012..2099).include?(@year)
    raise DataBillingError.new("no valid month provided (\"#{@month}\") must be between 1 (or 01) and 12.") unless (1..12).include?(@month)

    @year = ("%04i" % [ @year ])
    @month = ("%02i" % [ @month ])

    @graph_time_from = Time.new(@year.to_i, @month.to_i, 1, 0, 0, 0).utc
    @graph_time_to = Time.new(@year.to_i, @month.to_i, month_days(@year.to_i, @month.to_i), 23, 59, 59).utc

    @graph_def = deconstruct_graph_def(@graph_def)
    @pricing_def = deconstruct_pricing_def(@pricing_def)

    @graph_id, @inbound_columns, @outbound_columns = @graph_def[:graph_id], @graph_def[:inbound], @graph_def[:outbound]
    @default_price, @pricing_steps = @pricing_def[:default_price], @pricing_def[:pricing_steps]

    @collection_name = "data_billing_"+SecureRandom.uuid.gsub(/-/,'_').upcase

    @mongo_client = Mongo::MongoClient.new("localhost", 27017, pool_size: 15, pool_timeout: 10, logger: @mongo_logger)
    @mongo_db = @mongo_client.db("data_billing")
    @mongo_records = @mongo_db.collection(@collection_name)
    @fetched = false
  end

  def fetch_billing_info
    cacti = CactiExtract.new(CACTI_URI, CACTI_LOGIN, CACTI_PASSWORD, @mongo_records)
    @title, @headers = cacti.fetch(@graph_time_from, @graph_time_to, @graph_id)
    @fetched = true
  end

  def process
    results = analyze
    printer = DataBillingPrinter.new(
      customer_id: @customer_id,
      customer_name: @customer_name,
      year: @year,
      month: @month,
      graph_def: @graph_def,
      pricing_def: @pricing_def,
      graph_id: @graph_id,
      records: @mongo_records,
      title: @title,
      headers: @headers,
      inbound_columns: @inbound_columns,
      outbound_columns: @outbound_columns,
      results: results
    )

    final_output = printer.print

    @mongo_records.drop

    update_netsuite

    return final_output
  end

  # ------------------------- PRIVATE STARTS HERE -------------------------
  private

  def update_netsuite
    # Update NetSuite here...
  end

  def analyze
    totalize
    ennumerate
    ninety_fifth_percentil = (@mongo_records.count * 0.95).ceil

    bps = @mongo_records.find(
      { row_number: ninety_fifth_percentil },
      fields: { "_id" => 0, "subtotals.outbound" => 1 }
    ).first["subtotals"]["outbound"]

    mbs = bps / 1024.0 / 1024.0

    price_per_mb = find_price_for_volume(mbs)

    total = mbs * price_per_mb

    { mbs: mbs, price_per_mb: price_per_mb, total: total }
  end

  def ennumerate
    puts "Ennumerating"
    t = @mongo_records.count
    c = 0
    s = Time.now
    @mongo_records.find({}, fields: [ "_id" ]).sort("subtotals.outbound" => Mongo::ASCENDING).each do |record|
      c += 1
      @mongo_records.update({ "_id" => record["_id"] }, { "$set" => { row_number: c } })
      print "\x0d\tEnnumerated record #{c} of #{t} in #{Time.now-s} seconds.       "
    end
    puts
    @mongo_records.ensure_index("row_number" => Mongo::ASCENDING)
    puts "Ennumerated"
  end

  def totalize
    puts "Totalizing..."
    raise DataBillingError.new("record have not been fetched") unless @fetched
    inbound_columns = @graph_def[:inbound].map{|n|@headers[n][:id]}
    outbound_columns = @graph_def[:outbound].map{|n|@headers[n][:id]}
    t = @mongo_records.count()
    c = 0
    s = Time.now
    @mongo_records.find.sort("_id" => Mongo::ASCENDING).each do |record|
      c += 1
      print ("\x0d\tProcessing record %6i of %6i (%8.4f%%, %i seconds %s)       " % [ c, t, (100.0 * c.to_f / t.to_f), (Time.now-s), seconds_to_time(s) ])
      subtotal_inbound = inbound_columns.map{|id|record[id]}.inject(0){|i,j|i+j}
      subtotal_outbound = outbound_columns.map{|id|record[id]}.inject(0){|i,j|i+j}
      @mongo_records.update(
        { "_id" => record["_id"]},
        {
          "$set" => {
            subtotals: {
              inbound: subtotal_inbound,
              outbound: subtotal_outbound
            }
          }
        }
      )
    end
    @mongo_records.ensure_index("subtotals.inbound" => Mongo::ASCENDING)
    @mongo_records.ensure_index("subtotals.outbound" => Mongo::ASCENDING)
    puts
    puts "Totalized."
  end

  def seconds_to_time(time_dif)
    t = Time.now-time_dif
    seconds = (t % 60)
    minutes = ((t % 3600) - seconds) / 60
    hours = (t - minutes * 60 - seconds) / 3600
    milliseconds = ((t-t.to_i)*1000).ceil
    #"%i:%02i:%02i.%04i (%i seconds)" % [ hours, minutes, seconds, milliseconds, t ]
    "%i:%02i:%02i (%i seconds)" % [ hours, minutes, seconds, t ]
  end

  def find_price_for_volume(volume)
    price = @default_price
    @pricing_steps.each do |price_def|
      if volume <= price_def[:up_to]
        price = price_def[:price]
        break
      end
    end
    price
  end

  def deconstruct_graph_def(graph_def)
    parts = graph_def.split(/:/).map(&:strip)
    start_def = { graph_id: parts.shift.to_i, inbound: [], outbound: [] }
    retValue = (0..parts.size-1).
                map{ |n|
                  [ "i", "o" ].include?(parts[n]) ? { column_index: n, column_type: COLUMN_TYPES[parts[n]] } : nil
                }.
                compact.
                inject(start_def){ |result, column_def|
                  result[column_def[:column_type]] << column_def[:column_index];
                  result
                }
    retValue
  end

  def deconstruct_pricing_def(pricing_def)
    parts = pricing_def.split(/\s+/).map(&:strip)
    default_price = parts.shift.to_f
    pricing_steps = parts.map{ |d| d.gsub(/^</, '').split(/:/) }.map{ |d| { up_to: d[0].to_i, price: d[1].to_f } }.sort{ |i, j| i[:up_to] <=> j[:up_to] }
    { default_price: default_price, pricing_steps: pricing_steps }
  end

  def month_days(year, month)
    [ 31, (year % 4 == 0 && year % 100 != 0 || year % 400 == 0) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 ][month-1]
  end
end

# dbi = DataBilling.new(customer_id: 10000, customer_name: "CFE", graph_def: "6181:d:i:o:x:o:i:o:i:o", pricing_def: "19.00 <2500:20.00 <5000:19.80 <7500:19.50", year: 2014, month: 1)
# dbi = DataBilling.new(customer_id: 10000, customer_name: "CFE", year: 2014, month: 1)
# dbi.fetch_billing_info
# pp dbi.process
