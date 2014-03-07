# encoding: utf-8

require 'pry'

require 'axlsx'
require 'yaml'
require 'pp'

require './lib/utils'
require './lib/configuration'
require './lib/net_suite'
require './lib/billing_mongo'
require './lib/telephony_customer_biller_printer'

class CallPlan
  def initialize(plan_def)
    @plan_def = plan_def
    @plan_def[:per_call] = [ :us_local, :mx_locales ].include?(plan_def[:call_type])
    @totals = nil
    @usage = 0
  end

  def consume(record, rec_info)
    retValue = nil
    if @plan_def[:call_type] == rec_info[:call_type]
      if @usage < @plan_def[:volume]
        if @plan_def[:per_call]
          @usage += 1
        else
          @usage += (record["duration"]/60.0).ceil
        end
        retValue = @plan_def.merge(volume_used: @usage)
      end
    end
    retValue
  end
end

class TelephonyCustomerBillerError < Exception
end

class TelephonyCustomerBiller
	def initialize(options)
		raise TelephonyCustomerBillerError.new("invalid options, you must provide a hash") if options.class != Hash
    raise TelephonyCustomerBillerError.new("invalid options, you must provide a customer_id") if !options[:customer_id]
    raise TelephonyCustomerBillerError.new("invalid options, you must provide a year") if !options[:year]
    raise TelephonyCustomerBillerError.new("invalid options, you must provide a month") if !options[:month]
		@customer_id, @year, @month = options[:customer_id], options[:year], options[:month]
	end

	def fetch_billing_info
    local_test_data_fname = File.join(File.dirname(__FILE__), '..', 'config', 'test_local_netsuite_data.yml')

    if (ENV["UPDATE"]||'').strip.downcase =~ /^1|yes|on|true|fetch|update|get$/
      print "Updating saved local test NetSuite data from remote... "
      response = NetSuite.call(action: "customer", customer_id: @customer_id)
      open(local_test_data_fname, "w") do |f|
        f.write(response[:data].to_yaml)
      end
      puts "Local Test Data Updated, exiting."
      exit(0)
    end

    if (ENV["LOCALDEBUG"]||'').strip.downcase =~ /^1|yes|on|true$/
      print "Loading Local Test Data... "
      response = OpenStruct.new(status: :ok, data: YAML.load(open(local_test_data_fname).read))
      puts "Loaded."
    else
      print "Fetching customer's billing definition from NetSuite... "
      response = NetSuite.call(action: "customer", customer_id: @customer_id)
      puts "Fetched."
    end

		if response.status == :ok
			@customer = response.data[:billing_info][:customer]
			@origins = response.data[:billing_info][:origins]
			@rates = response.data[:billing_info][:rates]
			@trunk_types = response.data[:billing_info][:trunk_types]
			@global_rates = response.data[:billing_info][:global_rates]
      normalize_billing_info
      true
    else
      raise TelephonyCustomerBillerError.new("error fetching configuration for customer #{@customer_id} : #{response.inspect}")
    end
  end

  def process
    puts "Transtelco - Call Detail Record Pricing"
    puts "\tProcessing on #{Time.now.strftime('%Y-%m-%d %H:%M:%S %:z')}"
    puts ("\tProcessing for %04i/%02i" % [ @year, @month ])
    puts "\t[#{@customer[:id]}] :: #{@customer[:name]}"
    clear_existing_customer_cdrs
    @origins.each do |origin_id, origin|
      puts "\t\tOrigin name: #{origin[:name]}"
      if (ENV["SKIP_IDENT"]||'').strip.downcase =~ /^1|yes|on|true$/
        puts "\t\tSkipping identification and pricing."
      else
        identify_customer_and_origin(origin)
      end

      if (ENV["SKIP_PRICING"]||'').strip.downcase =~ /^1|yes|on|true$/
        puts "\t\tSkipping identification and pricing."
      else
        price(origin)
      end

      if (ENV["SKIP_PRINTING"]||'').strip.downcase =~ /^1|yes|on|true$/
        puts "\t\tSkipping printing of Excel files."
      else
        print_invoice(origin)
      end

      if (ENV["SKIP_NSUPDATE"]||'').strip.downcase =~ /^1|yes|on|true$/
        puts "\t\tSkipping updating of NetSuite invoices."
      else
        update_netsuite(origin)
      end
    end
    return @origins.map{ |origin_id, origin| origin[:printed_file_name] }
  end

  # ------------------------- PRIVATE STARTS HERE -------------------------
	private

  def update_netsuite(origin)
    puts "\t\t\tCreating MongDB Invoice Record..."
    inserted_row = @mongo.invoices.insert(
      file_path: origin[:printed_file_name],
      file_name: File.basename(origin[:printed_file_name]),
      total: origin[:total],
      subtotals: origin[:subtotals]
    )
    origin[:invoice_object_id] = inserted_row.to_s
    puts "\t\t\tDone."

    puts "\t\t\tCalling NetSuite for invoice information upload..."
    netsuite_return = NetSuite.call(
      action: :add_invoice,
      custrecord_tiv_origin: origin[:internal_id],
      custrecord_tiv_year: @year,
      custrecord_tiv_month: @month,
      custrecord_tiv_gen_date: Time.now.strftime("%Y/%m/%d %H:%M:%S %z"),
      custrecord_tiv_total: origin[:total],
      custrecord_tiv_currency: @rates[origin[:rate][:internal_id]][:currency][:internal_id],
      custrecord_tiv_invoice_object_id: origin[:invoice_object_id],
      custrecord_tiv_link: "http://itserver.transtelco.net/telephony_invoices/"+origin[:invoice_object_id]+"/download",
      custrecord_tiv_us_nationalld: (((origin[:subtotals]||{})[:us_nationalld]||{})[:amount]||0.0),
      custrecord_tiv_us_local: (((origin[:subtotals]||{})[:us_local]||{})[:amount]||0.0),
      custrecord_tiv_us_mexicold: (((origin[:subtotals]||{})[:us_mexicold]||{})[:amount]||0.0),
      custrecord_tiv_us_mexicomobilejrz: (((origin[:subtotals]||{})[:us_mexicomobilejrz]||{})[:amount]||0.0),
      custrecord_tiv_us_mexicomobile: (((origin[:subtotals]||{})[:us_mexicomobile]||{})[:amount]||0.0),
      custrecord_tiv_us_mexicojuarez: (((origin[:subtotals]||{})[:us_mexicojuarez]||{})[:amount]||0.0),
      custrecord_tiv_us_tollfree: (((origin[:subtotals]||{})[:us_tollfree]||{})[:amount]||0.0),
      custrecord_tiv_us_mexicotollfree: (((origin[:subtotals]||{})[:us_mexicotollfree]||{})[:amount]||0.0),
      custrecord_tiv_mx_locales: (((origin[:subtotals]||{})[:mx_locales]||{})[:amount]||0.0),
      custrecord_tiv_mx_cellocal: (((origin[:subtotals]||{})[:mx_cellocal]||{})[:amount]||0.0),
      custrecord_tiv_mx_celnacional: (((origin[:subtotals]||{})[:mx_celnacional]||{})[:amount]||0.0),
      custrecord_tiv_mx_ldnacional: (((origin[:subtotals]||{})[:mx_ldnacional]||{})[:amount]||0.0),
      custrecord_tiv_mx_uscanada: (((origin[:subtotals]||{})[:mx_uscanada]||{})[:amount]||0.0),
      custrecord_tiv_mx_tollfreemx: (((origin[:subtotals]||{})[:mx_tollfreemx]||{})[:amount]||0.0),
      custrecord_tiv_mx_tollfreeus: (((origin[:subtotals]||{})[:mx_tollfreeus]||{})[:amount]||0.0),
      custrecord_tiv_international: (((origin[:subtotals]||{})[:international]||{})[:amount]||0.0),
      custrecord_tiv_inbound: (((origin[:subtotals]||{})[:inbound]||{})[:amount]||0.0)
    )

    output = ""
    PP.pp(netsuite_return, output)
    output = output.split(/\n/).map{|s|"\t\t\t"+s}.join("\n")
    puts output
    puts "\t\t\tDone."
  end

  def print_invoice(origin)
    puts "\t\t\tPrinting invoice..."
    printer = TelephonyCustomerBillerPrinter.new(@customer, origin, @year, @month, cdrs)
    origin[:printed_file_name] = printer.print
    origin[:subtotals] = (printer.totals||[]).map{ |t| { t["pricing.final_pricing.call_type"].to_sym => t.except("pricing.final_pricing.call_type").symboliser } }.inject({}){ |i, j| i.merge(j) }
    origin[:total] = origin[:subtotals].values.map{ |st| st[:amount] }.inject(0.0){ |i, j| i+j }
    puts "\t\t\tDone."
    printer
  end

  def clear_existing_customer_cdrs
    puts "\t\tClearing previously priced CDRs..."
    cdrs.update({ "billing.customer_id" => @customer[:id].to_i }, { "$unset" => { billing: true, pricing: true }}, { multi: true })
    puts "\t\tExisting CDRs cleared."
  end

  def price(origin)
    currency = @trunk_types[origin[:trunk_type][:internal_id]][:currency][:name]
    local_prefix = @rates[origin[:rate][:internal_id]][:local_prefix]
    trunk_type = origin[:trunk_type][:name].downcase.to_sym
    rates = @rates[origin[:rate][:internal_id]]
    plans = origin[:plans].map{ |plan| CallPlan.new(plan) }
    inbound_defs = (origin[:inbound_rates]||{}).values
    records = fetch_origin_cdrs(@customer_id, origin[:internal_id])
    records_total = records.count
    records_count = 0
    t = Time.now
    records.each do |record|
      records_count += 1
      rec_info = identify_record_call_type(trunk_type, record, inbound_defs)

      rate_override = nil
      prefix_override = nil
      regular_rate = nil
      international_rate = nil
      inbound_rate = nil
      plan_info = nil

      if rec_info
        if rec_info[:call_type] == :inbound
          inbound_rate = rec_info
        elsif rec_info[:call_type] == :international
          prefix_override = find_in_prefix_hash(record["destination"], origin[:prefix_overrides])
          international_rate = rec_info
        elsif Configuration.call_types[rec_info[:trunk_type]].include?(rec_info[:call_type])
          prefix_override = find_in_prefix_hash(record["destination"], origin[:prefix_overrides])
          rate_override = find_rate(origin[:rate_overrides], rec_info[:call_type])
          regular_rate = find_rate(@rates[origin[:rate][:internal_id]], rec_info[:call_type])
        end
        plan_info = apply_plans(plans, record, rec_info) unless inbound_rate
      end

      # TODO: See if we have an inbound billing charge, and use it.

      minutes = (record["duration"] / 60.0).ceil
      final_pricing = { minutes: minutes, call_type: rec_info[:call_type], trunk_type: trunk_type, currency: currency }
      if inbound_rate
        final_pricing.merge!(method: :inbound, total: minutes * rec_info[:price])
      elsif plan_info
        final_pricing.merge!(method: :plan, total: 0.0)
      elsif prefix_override
        final_pricing.merge!(method: :prefix_override, total: prefix_override[:info][:price] * (rec_info[:per_call] ? 1 : minutes))
      elsif rate_override
        final_pricing.merge!(method: :rate_override, total: rate_override[:price] * (rec_info[:per_call] ? 1 : minutes))
      elsif regular_rate
        final_pricing.merge!(method: :regular_rate, total: regular_rate[:price] * (rec_info[:per_call] ? 1 : minutes))
      elsif international_rate
        final_pricing.merge!(method: :international_rate, total: international_rate[:price] * (rec_info[:per_call] ? 1 : minutes))
      else
        final_pricing.merge!(method: :unbillable, total: 0.0)
      end

      update_hash = {
        plan_info: plan_info,
        prefix_override: prefix_override,
        rate_override: rate_override,
        regular_rate: regular_rate,
        international_rate: international_rate,
        inbound_rate: inbound_rate,
        final_pricing: final_pricing,
      }

      cdrs.update(
        { _id: record["_id"] },
        { "$set" => { pricing: update_hash } }
      )

      print_progress(records_total, records_count, t)
    end
    puts "\x0d\t\t\tProcessed #{records_total} records in #{seconds_to_time(t)}                                             "
  end

  def print_progress(records_total, records_count, t)
    print "\x0d\t\t\tProcessing call #{records_count} of #{records_total} (#{'%8.4f' % [ 100.0*records_count.to_f/records_total.to_f ]}%) in #{seconds_to_time(t)}         " if (records_count % 50) == 0 or records_count >= records_total
  end

  def apply_plans(plans, record, rec_info)
    retValue = nil
    plans.each do |plan|
      retValue = plan.consume(record, rec_info)
      break if retValue # break == consecutive plan usage, remove for concurrent plan usage (per call_type).
    end
    retValue
  end

  def find_rate(rate_definition, call_type)
    wrk = rate_definition[call_type]
    wrk = { call_type: call_type, price: wrk } if wrk
    wrk
  end

  def fetch_origin_cdrs(customer_id, origin_id)
    cdrs.find(
      { "billing.customer_id" => customer_id, "billing.origin_id" => origin_id },
      { fields: [ :destination, :duration ] }
    ).sort(call_date: Mongo::ASCENDING)
  end

  def identify_record_call_type(trunk_type, record, inbound_defs)
    destination = record["destination"]
    retValue = nil

    # Find toll-free inbound calls
    unless retValue
      inbound_defs.each do |inbound_def|
        rx_list = (inbound_def[:did_regexp]||"").split(/;/).map{ |r| (r||'').strip.length > 0 ? Regexp.new("^#{r.strip}$") : nil }.compact
        if rx_list.map{ |rx| destination =~ rx }.compact.size > 0
          retValue = {
            prefix: (inbound_def[:did_regexp]||""),
            name: "Inbound",
            trunk_type: trunk_type,
            call_type: :inbound,
            price: (inbound_def[:minute_price]||"999999999.99").to_f,
            per_call: false
          }
          break
        end
      end
    end

    # Find in familiar categories first
    unless retValue
      RATE_PREFIXES[trunk_type].each do |call_type, prefixes|
        match = find_in_prefix_hash(destination, prefixes)
        if match
          retValue = {
            prefix: match[:prefix],
            name: match[:info],
            trunk_type: trunk_type,
            call_type: call_type,
            price: nil,
            per_call: [ :us_local, :mx_locales ].include?(call_type)
          }
          break
        end
      end
    end

    # Find in international list
    unless retValue
      match = find_in_prefix_hash(destination, @global_rates[trunk_type][:rates])
      if match
        retValue = {
          prefix: match[:prefix],
          name: match[:info][:name],
          trunk_type: trunk_type,
          call_type: :international,
          price: match[:info][:minute_price],
          per_call: false
        }
      end
    end

    retValue
  end

  def find_in_prefix_hash(number, prefix_hash)
    match = (0..(number.length-1)).map{ |n| number[0..n] }       # Map to all possible prefixes [ "1", "19", "191", "1915", ..., "19154002903" ]
    match = match.sort{ |i, j| -(i.size <=> j.size) }            # Sort it from longest to shortest
    match = match.map{ |p| { prefix: p, info: prefix_hash[p] } } # Convert to prefix_hash values
    match = match.select{ |match| !match[:info].nil? }           # Remove non-matches
    match = match.first                                          # We only need one, the longest (we sorted it before)
    match
  end

  def identify_customer_and_origin(origin)
    filter = build_filter(origin)
    t = Time.now
    puts "\t\t\tIdentifying #{cdrs.find(filter).count} calls"
    cdrs.update(filter, { "$set" => { billing: { customer_id: @customer_id, origin_id: origin[:internal_id] } } }, multi: true)
    puts "\t\t\tCalls identified in #{seconds_to_time(t)}."
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

  def build_filter(origin)
    filter = nil
    inbound = build_inbound_filter(origin)
    outbound = build_outbound_filter(origin)
    if inbound and outbound
      filter = { "$or" => [ inbound, outbound ] }
    elsif inbound and !outbound
      filter = inbound
    elsif outbound and !inbound
      filter = outbound
    end
    filter
  end

  def build_outbound_filter(origin)
    filter = nil
    if origin[:identifiers] and origin[:identifiers].size > 0
      singles = []
      origin[:identifiers].values.map{ |d| d.except(:internal_id) }.each do |id_def|
        singles << criterize_definition(id_def)
      end
      singles.compact!
      if singles.size > 0
        if singles.size > 1
          filter = { "$or" => singles }
        else
          filter = singles.first
        end
      else
        filter = nil
      end
    else
      filter = nil
    end
    filter
  end

  def build_inbound_filter(origin)
    filter = nil
    inbound_definitions = get_inbound_definitions(origin)
    regexpset = inbound_definitions.map{|id|id[:did_regexp]}.flatten
    filter = { "$or" => regexpset.map{|rx| { destination: Regexp.new(rx) } } } unless regexpset.empty?
    filter
  end

  def get_inbound_definitions(origin)
    origin[:inbound_rates].values.map { |i|
      {
        did_regexp: i[:did_regexp].split(/;/).map{ |r| "^#{r.strip}$" }, # May come as
        minute_price: i[:minute_price].to_f
      }
    }
  end

  def criterize_definition(id_def)
    filter = nil
    andrs  = []
    andrs << criterize_element(id_def[:rxlist_ipaddr], :host)
    andrs << criterize_element(id_def[:eq_name], :gateway)
    andrs << criterize_element(id_def[:rxlist_srcnumbers], :identifier)
    andrs.compact!
    if andrs.size > 0
      if andrs.size > 1
        filter = { "$and" => andrs }
      else
        filter = andrs.first
      end
    else
      filter = { "_id" => { "$exists" =>  1 } }
    end
    filter
  end

  def criterize_element(string_list, key_symbol)
    string_list ||= ''
    criteria = string_list.split(/;/).map{ |d| d ? d.strip.length > 0 ? { key_symbol => Regexp.new("^#{d.strip}$") } : nil : nil }.compact
    if criteria.size > 0
      if criteria.size > 1
        { "$or" => criteria }
      else
        criteria.first
      end
    else
      nil
    end
  end

  def cdrs
    @mongo ||= BillingMongo.new(year: @year, month: @month)
    @mongo.cdrs
  end

  def normalize_billing_info
    normalize_global_rates
    normalize_trunk_types
    normalize_origins_prefix_overrides
    normalize_plans
  end

  def normalize_global_rates
      # Normalize global rates
      wrk = @global_rates
      wrk = wrk.
            values.
            map{ |rates_def| { rates_def[:trunkTypeName].downcase.to_sym => rates_def } }.
            hashes_merge
      @global_rates= wrk
  end

  def normalize_trunk_types
    # Normalize trunk_type's rates
    @global_rates.keys.each do |trunk_type|
      wrk = @global_rates[trunk_type][:rates]
      wrk = wrk.
            map{ |r| { r[:prefix] => r.except(:prefix, :internal_id) } }.
            hashes_merge
      @global_rates[trunk_type][:rates] = wrk
    end
  end

  def normalize_origins_prefix_overrides
    # Normalize each origin's prefix overrides.
    @origins.keys.each do |origin_internal_id|
      wrk = @origins[origin_internal_id][:prefix_overrides]
      wrk = wrk.values.
            map{ |v| { v[:prefix] => v.except(:internal_id, :prefix) } }.
            hashes_merge
      @origins[origin_internal_id][:prefix_overrides] = wrk
    end
  end

  def normalize_plans
    @origins.keys.each do |origin_internal_id|
      normalized_plans = []
      @origins[origin_internal_id][:plans].keys.each do |plan_internal_id|
        wrk = @origins[origin_internal_id][:plans][plan_internal_id]
        call_type = wrk[:call_type][:internal_id].to_i
        normalized_plans << {
          volume: wrk[:volume],
          call_type: NETSUITE_CALL_TYPES[:netsuite_call_types][call_type],
          name: wrk[:call_type][:name]
        }
      end
      @origins[origin_internal_id][:plans] = normalized_plans
    end
  end
end

# Sample callling of this classes:
#
# tcb = TelephonyCustomerBiller.new(customer_id: 4941, year: 2013, month: 12)
# tcb.fetch_billing_info
# tcb.process
