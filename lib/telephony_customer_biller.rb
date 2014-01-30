# encoding: utf-8

require 'pry'

require './lib/configuration'
require './lib/net_suite'
require './lib/billing_mongo'
require 'yaml'
require 'pp'

class Hash
  def except(*keys)
    return self.select{ |k, v| !keys.include?(k) }
  end
end

class Array
  def hashes_merge
    self.inject({}){ |i, j| i.merge(j) }
  end
end

class CallPlan
  def initialize(plan_def)
    @plan_def = plan_def
    @plan_def[:per_call] = [ :us_local, :mx_locales ].include?(plan_def[:call_type])
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
		# response = NetSuite.call(action: "customer", customer_id: @customer_id)
    # puts response[:data].to_yaml
    # exit
    response = OpenStruct.new(status: :ok, data: YAML.load(DATA))
		if response.status == :ok
			@customer = response.data[:billing_info][:customer]
			@origins = response.data[:billing_info][:origins]
			@rates = response.data[:billing_info][:rates]
			@trunk_types = response.data[:billing_info][:trunk_types]
			@global_rates = response.data[:billing_info][:global_rates]
      normalize_billing_info
      return true
    else
      raise TelephonyCustomerBillerError.new("error fetching configuration for customer #{@customer_id} : #{response.inspect}")
    end
  end

  def process
    puts "Transtelco - Call Detail Record Pricing"
    puts "\tProcessing on #{Time.now.strftime('%Y-%m-%d %H:%M:%S %:z')}"
    puts ("\tProcessing for %04i/%02i" % [ @year, @month ])
    puts "\t[#{@customer[:id]}] :: #{@customer[:name]}"
    @origins.each do |origin_id, origin|
      puts "\t\tOrigin name: #{origin[:name]}"
      identify_customer_and_origin(origin)
      price(origin)
    end
    puts
  end

	private

  def price(origin)
    local_prefix = @rates[origin[:rate][:internal_id]][:local_prefix]
    trunk_type = origin[:trunk_type][:name].downcase.to_sym
    rates = @rates[origin[:rate][:internal_id]]
    plans = origin[:plans].map{ |plan| CallPlan.new(plan) }
    records = fetch_origin_cdrs(@customer_id, origin[:internal_id])
    records_total = records.count
    records_count = 0
    records.each do |record|
      records_count += 1
      print_progress(records_total, records_count)

      rec_info = identify_record_call_type(trunk_type, record)

      rate_override = nil
      prefix_override = nil
      regular_rate = nil
      international_rate = nil
      plan_info = nil

      if rec_info
        if rec_info[:call_type] == :international
          prefix_override = find_in_prefix_hash(record["destination"], origin[:prefix_overrides])
          international_rate = rec_info
        elsif Configuration.call_types[rec_info[:trunk_type]].include?(rec_info[:call_type])
          prefix_override = find_in_prefix_hash(record["destination"], origin[:prefix_overrides])
          rate_override = find_rate(origin[:rate_overrides], rec_info[:call_type])
          regular_rate = find_rate(@rates[origin[:rate][:internal_id]], rec_info[:call_type])
        end
        plan_info = apply_plans(plans, record, rec_info)
      end

      minutes = (record["duration"] / 60.0).ceil
      final_pricing = { minutes: minutes }
      if plan_info
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
        final_pricing: final_pricing
      }

      cdrs.update(
        { _id: record["_id"] },
        { "$set" => { billing: update_hash } }
      )
    end
    puts
  end

  def print_progress(records_total, records_count)
    print "\x0d\t\t\tProcessing call #{records_count} of #{records_total}          " if (records_count % 25) == 0 or records_count >= records_total
  end

  def apply_plans(plans, record, rec_info)
    retValue = nil
    plans.each do |plan|
      retValue = plan.consume(record, rec_info)
      break if retValue # break == consecutive plan usage, remove for concurrent plan usage (per call_type).
    end
    return retValue
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

  def identify_record_call_type(trunk_type, record)
    destination = record["destination"]
    retValue = nil

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

    return retValue
  end

  def find_in_prefix_hash(number, prefix_hash)
    match = (0..(number.length-1)).map{ |n| number[0..n] }       # Map to all possible prefixes [ "1", "19", "191", "1915", ..., "19154002903" ]
    match = match.sort{ |i, j| -(i.size <=> j.size) }            # Sort it from longest to shortest
    match = match.map{ |p| { prefix: p, info: prefix_hash[p] } } # Convert to prefix_hash values
    match = match.select{ |match| !match[:info].nil? }           # Remove non-matches
    match = match.first                                          # We only need one, the longest (we sorted it before)
    return match
  end

  def identify_customer_and_origin(origin)
    filter = build_filter(origin)
    puts "\t\t\tIdentifying #{cdrs.find(filter).count} calls"
    cdrs.update(filter, { "$set" => { billing: { customer_id: @customer_id, origin_id: origin[:internal_id] } } }, multi: true)
    puts "\t\t\tCalls identified."
  end

  def build_filter(origin)
    singles = []
    filter = nil
    origin[:identifiers].values.each do |identifier|
      single = []
      single << criterize(:gateway   , identifier[:eq_name          ]) if (identifier[:eq_name          ]||"").length > 0
      single << criterize(:host      , identifier[:rxlist_ipaddr    ]) if (identifier[:rxlist_ipaddr    ]||"").length > 0
      single << criterize(:identifier, identifier[:rxlist_srcnumbers]) if (identifier[:rxlist_srcnumbers]||"").length > 0
      singles << { "$and" => single }
    end
    if singles.size == 1
      filter = singles.first
    else
      filter = { "$or" => singles }
    end
    unless filter["$and"].map(&:keys).flatten.include?("$or")
      filter = filter["$and"].hashes_merge
    end
    return filter
  end

  def criterize(symbol_key, criteria_list)
    if criteria_list =~ /;/
      { "$or" => criteria_list.split(/;/).map(&:strip).map{ |v| { symbol_key => Regexp.new(v.to_s) } } }
    else
      { symbol_key => Regexp.new(criteria_list.strip) }
    end
  end

  def cdrs
    mongo ||= BillingMongo.new(year: @year, month: @month)
    mongo.cdrs
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

tcb = TelephonyCustomerBiller.new(customer_id: 4941, year: 2013, month: 12)
tcb.fetch_billing_info
tcb.process


__END__
:billing_info:
  :customer:
    :id: '4941'
    :name: Wistron México, S.A. de C.V. - IPM
  :origins:
    17:
      :internal_id: 17
      :name: Lineas Americanas
      :rate:
        :internal_id: 6
        :name: Americana 01
      :trunk_type:
        :internal_id: 2
        :name: Americana
      :invoice_group: Main Group
      :provisioned: true
      :completed_sales: true
      :rate_overrides:
        :us_local:
        :us_nationalld: 0.1
        :us_mexicold:
        :us_mexicomobilejrz:
        :us_mexicomobile:
        :us_mexicojuarez: 0
        :us_tollfree:
        :us_mexicotollfree:
      :prefix_overrides: {}
      :plans:
        13:
          :internal_id: 13
          :volume: 10
          :call_type:
            :internal_id: '8'
            :name: US/CA - Local (per call)
      :identifiers:
        13:
          :internal_id: 13
          :rxlist_ipaddr: 10.10.2.15
          :eq_name: ''
          :rxlist_srcnumbers: '9154000300'
    16:
      :internal_id: 16
      :name: Lineas Mexicanas
      :rate:
        :internal_id: 5
        :name: Mexicana 30
      :trunk_type:
        :internal_id: 1
        :name: Mexicana
      :invoice_group: Main Group
      :provisioned: true
      :completed_sales: true
      :rate_overrides:
        :mx_locales: 1.1
        :mx_cellocal:
        :mx_celnacional:
        :mx_ldnacional:
        :mx_uscanada: 0.97
        :mx_tollfreemx:
        :mx_tollfreeus:
      :prefix_overrides:
        7:
          :internal_id: 7
          :prefix: '4366'
          :per_call: true
          :price: 0.14
        6:
          :internal_id: 6
          :prefix: '43660'
          :per_call: false
          :price: 0.08
        5:
          :internal_id: 5
          :prefix: '526563'
          :per_call: false
          :price: 0.03
        4:
          :internal_id: 4
          :prefix: '5265632'
          :per_call: true
          :price: 0.01
      :plans:
        11:
          :internal_id: 11
          :volume: 20000
          :call_type:
            :internal_id: '1'
            :name: México - Locales (llamada)
        12:
          :internal_id: 12
          :volume: 2000
          :call_type:
            :internal_id: '4'
            :name: México - Larga Distancia Nacional
      :identifiers:
        12:
          :internal_id: 12
          :rxlist_ipaddr: 10.10.2.15
          :eq_name: ''
          :rxlist_srcnumbers: 6562570240;6561464400
  :rates:
    6:
      :internal_id: 6
      :name: Americana 01
      :currency:
        :internal_id: 1
        :name: USD
      :local_prefix: '1915'
      :trunk_type:
        :internal_id: '2'
        :name: Americana
      :us_local: 0
      :us_nationalld: 0
      :us_mexicold: 0.06
      :us_mexicomobilejrz: 0.4
      :us_mexicomobile: 0.4
      :us_mexicojuarez: 0.06
      :us_tollfree: 0
      :us_mexicotollfree: 0.06
    5:
      :internal_id: 5
      :name: Mexicana 30
      :currency:
        :internal_id: 5
        :name: MXN
      :local_prefix: '52656'
      :trunk_type:
        :internal_id: '1'
        :name: Mexicana
      :mx_locales: 0
      :mx_cellocal: 0.71
      :mx_celnacional: 2.35
      :mx_ldnacional: 1
      :mx_uscanada: 1.5
      :mx_tollfreemx: 0
      :mx_tollfreeus: 2
  :trunk_types:
    2:
      :internal_id: 2
      :name: Americana
      :currency:
        :internal_id: 1
        :name: USD
    1:
      :internal_id: 1
      :name: Mexicana
      :currency:
        :internal_id: 5
        :name: MXN
  :global_rates:
    2:
      :trunkTypeName: Americana
      :currencyId: 1
      :currencyName: USD
      :rates:
      - :internal_id: '2362'
        :name: Afghanistan (Islamic
        :minute_price: 0.47
        :prefix: '93'
      - :internal_id: '1520'
        :name: Albania (Republic of
        :minute_price: 0.32
        :prefix: '355'
      - :internal_id: '1267'
        :name: Algeria (People''s De
        :minute_price: 0.25
        :prefix: '213'
      - :internal_id: '1555'
        :name: Andorra (Principalit
        :minute_price: 0.08
        :prefix: '376'
      - :internal_id: '1556'
        :name: Andorra (Principalit
        :minute_price: 0.42
        :prefix: '3763'
      - :internal_id: '1557'
        :name: Andorra (Principalit
        :minute_price: 0.42
        :prefix: '3764'
      - :internal_id: '1558'
        :name: Andorra (Principalit
        :minute_price: 0.42
        :prefix: '3766'
      - :internal_id: '1305'
        :name: Angola (Republic of)
        :minute_price: 0.37
        :prefix: '244'
      - :internal_id: '2158'
        :name: Argentine Republic
        :minute_price: 0.04
        :prefix: '54'
      - :internal_id: '2182'
        :name: Argentine Republic
        :minute_price: 0.31
        :prefix: '549'
      - :internal_id: '2159'
        :name: Argentine Republic
        :minute_price: 0.02
        :prefix: '5411'
      - :internal_id: '2160'
        :name: Argentine Republic
        :minute_price: 0.02
        :prefix: '54221'
      - :internal_id: '2161'
        :name: Argentine Republic
        :minute_price: 0.02
        :prefix: '54223'
      - :internal_id: '2163'
        :name: Argentine Republic
        :minute_price: 0.04
        :prefix: '54230'
      - :internal_id: '2164'
        :name: Argentine Republic
        :minute_price: 0.03
        :prefix: '54232'
      - :internal_id: '2166'
        :name: Argentine Republic
        :minute_price: 0.04
        :prefix: '54237'
      - :internal_id: '2167'
        :name: Argentine Republic
        :minute_price: 0.02
        :prefix: '54261'
      - :internal_id: '2169'
        :name: Argentine Republic
        :minute_price: 0.03
        :prefix: '54291'
      - :internal_id: '2170'
        :name: Argentine Republic
        :minute_price: 0.04
        :prefix: '54299'
      - :internal_id: '2171'
        :name: Argentine Republic
        :minute_price: 0.02
        :prefix: '54341'
      - :internal_id: '2172'
        :name: Argentine Republic
        :minute_price: 0.04
        :prefix: '54342'
      - :internal_id: '2173'
        :name: Argentine Republic
        :minute_price: 0.03
        :prefix: '54348'
      - :internal_id: '2174'
        :name: Argentine Republic
        :minute_price: 0.02
        :prefix: '54351'
      - :internal_id: '2175'
        :name: Argentine Republic
        :minute_price: 0.04
        :prefix: '54353'
      - :internal_id: '2176'
        :name: Argentine Republic
        :minute_price: 0.04
        :prefix: '54354'
      - :internal_id: '2177'
        :name: Argentine Republic
        :minute_price: 0.04
        :prefix: '54358'
      - :internal_id: '2180'
        :name: Argentine Republic
        :minute_price: 0.04
        :prefix: '54381'
      - :internal_id: '2181'
        :name: Argentine Republic
        :minute_price: 0.04
        :prefix: '54387'
      - :internal_id: '2162'
        :name: Argentine Republic
        :minute_price: 0.04
        :prefix: '542293'
      - :internal_id: '2165'
        :name: Argentine Republic
        :minute_price: 0.04
        :prefix: '542362'
      - :internal_id: '2168'
        :name: Argentine Republic
        :minute_price: 0.04
        :prefix: '542652'
      - :internal_id: '2178'
        :name: Argentine Republic
        :minute_price: 0.04
        :prefix: '543722'
      - :internal_id: '2179'
        :name: Argentine Republic
        :minute_price: 0.04
        :prefix: '543752'
      - :internal_id: '1551'
        :name: Armenia (Republic of
        :minute_price: 0.15
        :prefix: '374'
      - :internal_id: '1552'
        :name: Armenia (Republic of
        :minute_price: 0.09
        :prefix: '3741'
      - :internal_id: '1553'
        :name: Armenia (Republic of
        :minute_price: 0.33
        :prefix: '3749'
      - :internal_id: '1358'
        :name: Aruba
        :minute_price: 0.34
        :prefix: '297'
      - :internal_id: '1308'
        :name: Ascension
        :minute_price: 1.4
        :prefix: '247'
      - :internal_id: '2238'
        :name: Australia
        :minute_price: 0.03
        :prefix: '61'
      - :internal_id: '2248'
        :name: Australia
        :minute_price: 0.27
        :prefix: '614'
      - :internal_id: '2239'
        :name: Australia
        :minute_price: 0.27
        :prefix: '6114'
      - :internal_id: '2240'
        :name: Australia
        :minute_price: 0.27
        :prefix: '6115'
      - :internal_id: '2241'
        :name: Australia
        :minute_price: 0.27
        :prefix: '6117'
      - :internal_id: '2242'
        :name: Australia
        :minute_price: 0.27
        :prefix: '6118'
      - :internal_id: '2243'
        :name: Australia
        :minute_price: 0.27
        :prefix: '6119'
      - :internal_id: '2244'
        :name: Australia
        :minute_price: 0.03
        :prefix: '6128'
      - :internal_id: '2245'
        :name: Australia
        :minute_price: 0.03
        :prefix: '6129'
      - :internal_id: '2246'
        :name: Australia
        :minute_price: 0.03
        :prefix: '6138'
      - :internal_id: '2247'
        :name: Australia
        :minute_price: 0.03
        :prefix: '6139'
      - :internal_id: '2260'
        :name: Australian External
        :minute_price: 1.01
        :prefix: '672'
      - :internal_id: '1632'
        :name: Austria
        :minute_price: 0.04
        :prefix: '43'
      - :internal_id: '1633'
        :name: Austria
        :minute_price: 0.04
        :prefix: '431'
      - :internal_id: '1651'
        :name: Austria
        :minute_price: 0.3
        :prefix: '438'
      - :internal_id: '1634'
        :name: Austria
        :minute_price: 0.35
        :prefix: '43650'
      - :internal_id: '1635'
        :name: Austria
        :minute_price: 0.35
        :prefix: '43660'
      - :internal_id: '1636'
        :name: Austria
        :minute_price: 0.26
        :prefix: '43664'
      - :internal_id: '1637'
        :name: Austria
        :minute_price: 0.35
        :prefix: '43676'
      - :internal_id: '1638'
        :name: Austria
        :minute_price: 0.35
        :prefix: '43677'
      - :internal_id: '1639'
        :name: Austria
        :minute_price: 0.35
        :prefix: '43678'
      - :internal_id: '1640'
        :name: Austria
        :minute_price: 0.35
        :prefix: '43680'
      - :internal_id: '1641'
        :name: Austria
        :minute_price: 0.35
        :prefix: '43681'
      - :internal_id: '1642'
        :name: Austria
        :minute_price: 0.35
        :prefix: '43688'
      - :internal_id: '1643'
        :name: Austria
        :minute_price: 0.35
        :prefix: '43699'
      - :internal_id: '1646'
        :name: Austria
        :minute_price: 0.35
        :prefix: '43711'
      - :internal_id: '1647'
        :name: Austria
        :minute_price: 0.35
        :prefix: '43720'
      - :internal_id: '1648'
        :name: Austria
        :minute_price: 0.35
        :prefix: '43730'
      - :internal_id: '1649'
        :name: Austria
        :minute_price: 0.35
        :prefix: '43740'
      - :internal_id: '1650'
        :name: Austria
        :minute_price: 0.35
        :prefix: '43780'
      - :internal_id: '1644'
        :name: Austria
        :minute_price: 0.35
        :prefix: '4369988'
      - :internal_id: '1645'
        :name: Austria
        :minute_price: 0.35
        :prefix: '4369989'
      - :internal_id: '2395'
        :name: Azerbaijani Republic
        :minute_price: 0.27
        :prefix: '994'
      - :internal_id: '2387'
        :name: Bahrain (State of)
        :minute_price: 0.23
        :prefix: '973'
      - :internal_id: '2352'
        :name: Bangladesh (People''s
        :minute_price: 0.12
        :prefix: '880'
      - :internal_id: '1554'
        :name: Belarus (Republic of
        :minute_price: 0.38
        :prefix: '375'
      - :internal_id: '1406'
        :name: Belgium
        :minute_price: 0.04
        :prefix: '32'
      - :internal_id: '1407'
        :name: Belgium
        :minute_price: 0.37
        :prefix: '3247'
      - :internal_id: '1408'
        :name: Belgium
        :minute_price: 0.42
        :prefix: '3248'
      - :internal_id: '1409'
        :name: Belgium
        :minute_price: 0.44
        :prefix: '3249'
      - :internal_id: '1862'
        :name: Belize
        :minute_price: 0.4
        :prefix: '501'
      - :internal_id: '1281'
        :name: Benin (Republic of)
        :minute_price: 0.14
        :prefix: '229'
      - :internal_id: '2389'
        :name: Bhutan (Kingdom of)
        :minute_price: 0.29
        :prefix: '975'
      - :internal_id: '2228'
        :name: Bolivia (Republic of
        :minute_price: 0.17
        :prefix: '591'
      - :internal_id: '1571'
        :name: Bosnia and Herzegovi
        :minute_price: 0.47
        :prefix: '387'
      - :internal_id: '1331'
        :name: Botswana (Republic o
        :minute_price: 0.33
        :prefix: '267'
      - :internal_id: '2183'
        :name: Brazil (Federative R
        :minute_price: 0.081
        :prefix: '55'
      - :internal_id: '2187'
        :name: Brazil (Federative R
        :minute_price: 0.2
        :prefix: '5501'
      - :internal_id: '2189'
        :name: Brazil (Federative R
        :minute_price: 0.03
        :prefix: '5511'
      - :internal_id: '2190'
        :name: Brazil (Federative R
        :minute_price: 0.05
        :prefix: '5519'
      - :internal_id: '2191'
        :name: Brazil (Federative R
        :minute_price: 0.03
        :prefix: '5521'
      - :internal_id: '2195'
        :name: Brazil (Federative R
        :minute_price: 0.04
        :prefix: '5527'
      - :internal_id: '2196'
        :name: Brazil (Federative R
        :minute_price: 0.04
        :prefix: '5531'
      - :internal_id: '2197'
        :name: Brazil (Federative R
        :minute_price: 0.05
        :prefix: '5533'
      - :internal_id: '2198'
        :name: Brazil (Federative R
        :minute_price: 0.04
        :prefix: '5541'
      - :internal_id: '2199'
        :name: Brazil (Federative R
        :minute_price: 0.05
        :prefix: '5543'
      - :internal_id: '2200'
        :name: Brazil (Federative R
        :minute_price: 0.05
        :prefix: '5544'
      - :internal_id: '2201'
        :name: Brazil (Federative R
        :minute_price: 0.05
        :prefix: '5548'
      - :internal_id: '2202'
        :name: Brazil (Federative R
        :minute_price: 0.04
        :prefix: '5551'
      - :internal_id: '2203'
        :name: Brazil (Federative R
        :minute_price: 0.04
        :prefix: '5561'
      - :internal_id: '2204'
        :name: Brazil (Federative R
        :minute_price: 0.05
        :prefix: '5562'
      - :internal_id: '2205'
        :name: Brazil (Federative R
        :minute_price: 0.06
        :prefix: '5567'
      - :internal_id: '2206'
        :name: Brazil (Federative R
        :minute_price: 0.04
        :prefix: '5571'
      - :internal_id: '2207'
        :name: Brazil (Federative R
        :minute_price: 0.04
        :prefix: '5581'
      - :internal_id: '2208'
        :name: Brazil (Federative R
        :minute_price: 0.04
        :prefix: '5585'
      - :internal_id: '2209'
        :name: Brazil (Federative R
        :minute_price: 0.05
        :prefix: '5591'
      - :internal_id: '2184'
        :name: Brazil (Federative R
        :minute_price: 0.2
        :prefix: '55007'
      - :internal_id: '2185'
        :name: Brazil (Federative R
        :minute_price: 0.2
        :prefix: '55008'
      - :internal_id: '2186'
        :name: Brazil (Federative R
        :minute_price: 0.2
        :prefix: '55009'
      - :internal_id: '2188'
        :name: Brazil (Federative R
        :minute_price: 0.2
        :prefix: '55017'
      - :internal_id: '2192'
        :name: Brazil (Federative R
        :minute_price: 0.17
        :prefix: '55217'
      - :internal_id: '2193'
        :name: Brazil (Federative R
        :minute_price: 0.17
        :prefix: '55218'
      - :internal_id: '2194'
        :name: Brazil (Federative R
        :minute_price: 0.17
        :prefix: '55219'
      - :internal_id: '2261'
        :name: Brunei Darussalam
        :minute_price: 0.07
        :prefix: '673'
      - :internal_id: '1524'
        :name: Bulgaria (Republic o
        :minute_price: 0.46
        :prefix: '359'
      - :internal_id: '1278'
        :name: Burkina Faso
        :minute_price: 0.35
        :prefix: '226'
      - :internal_id: '1318'
        :name: Burundi (Republic of
        :minute_price: 0.14
        :prefix: '257'
      - :internal_id: '2344'
        :name: Cambodia (Kingdom of
        :minute_price: 0.26
        :prefix: '855'
      - :internal_id: '1298'
        :name: Cameroon (Republic o
        :minute_price: 0.3
        :prefix: '237'
      - :internal_id: '1299'
        :name: Cape Verde (Republic
        :minute_price: 0.47
        :prefix: '238'
      - :internal_id: '1297'
        :name: Central African Repu
        :minute_price: 0.2
        :prefix: '236'
      - :internal_id: '1296'
        :name: Chad (Republic of)
        :minute_price: 0.51
        :prefix: '235'
      - :internal_id: '2210'
        :name: Chile
        :minute_price: 0.07
        :prefix: '56'
      - :internal_id: '2211'
        :name: Chile
        :minute_price: 0.03
        :prefix: '562'
      - :internal_id: '2212'
        :name: Chile
        :minute_price: 0.04
        :prefix: '56321'
      - :internal_id: '2213'
        :name: Chile
        :minute_price: 0.27
        :prefix: '565697'
      - :internal_id: '2214'
        :name: Chile
        :minute_price: 0.27
        :prefix: '565698'
      - :internal_id: '2215'
        :name: Chile
        :minute_price: 0.27
        :prefix: '565699'
      - :internal_id: '2346'
        :name: China (People''s Repu
        :minute_price: 0.03
        :prefix: '86'
      - :internal_id: '2216'
        :name: Colombia (Republic o
        :minute_price: 0.15
        :prefix: '57'
      - :internal_id: '1334'
        :name: Comoros (Islamic Fed
        :minute_price: 0.68
        :prefix: '269'
      - :internal_id: '1303'
        :name: Congo-Brazzaville (R
        :minute_price: 0.22
        :prefix: '242'
      - :internal_id: '1304'
        :name: Congo-Kinshasa (Demo
        :minute_price: 0.49
        :prefix: '243'
      - :internal_id: '2270'
        :name: Cook Islands
        :minute_price: 1.5
        :prefix: '682'
      - :internal_id: '1867'
        :name: Costa Rica
        :minute_price: 0.12
        :prefix: '506'
      - :internal_id: '1277'
        :name: Cote d''Ivoire (Repub
        :minute_price: 0.27
        :prefix: '225'
      - :internal_id: '1569'
        :name: Croatia (Republic of
        :minute_price: 0.33
        :prefix: '385'
      - :internal_id: '2125'
        :name: Cuba
        :minute_price: 1.3
        :prefix: '53'
      - :internal_id: '2156'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '538'
      - :internal_id: '2147'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '5375'
      - :internal_id: '2157'
        :name: Cuba
        :minute_price: 1.24
        :prefix: '5399'
      - :internal_id: '2126'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '53213'
      - :internal_id: '2127'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '53226'
      - :internal_id: '2128'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '53234'
      - :internal_id: '2129'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '53244'
      - :internal_id: '2130'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '53246'
      - :internal_id: '2131'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '53314'
      - :internal_id: '2132'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '53322'
      - :internal_id: '2133'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '53333'
      - :internal_id: '2134'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '53412'
      - :internal_id: '2135'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '53419'
      - :internal_id: '2136'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '53422'
      - :internal_id: '2137'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '53423'
      - :internal_id: '2138'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '53522'
      - :internal_id: '2139'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '53561'
      - :internal_id: '2140'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '53567'
      - :internal_id: '2141'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '53613'
      - :internal_id: '2146'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '53728'
      - :internal_id: '2148'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '53751'
      - :internal_id: '2149'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '53756'
      - :internal_id: '2142'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '537263'
      - :internal_id: '2143'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '537264'
      - :internal_id: '2144'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '537268'
      - :internal_id: '2145'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '537270'
      - :internal_id: '2150'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '537880'
      - :internal_id: '2151'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '537885'
      - :internal_id: '2152'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '537886'
      - :internal_id: '2153'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '537890'
      - :internal_id: '2154'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '537891'
      - :internal_id: '2155'
        :name: Cuba
        :minute_price: 1.45
        :prefix: '537892'
      - :internal_id: '1522'
        :name: Cyprus (Republic of)
        :minute_price: 0.09
        :prefix: '357'
      - :internal_id: '1590'
        :name: Czech Republic
        :minute_price: 0.04
        :prefix: '420'
      - :internal_id: '1591'
        :name: Czech Republic
        :minute_price: 0.04
        :prefix: '4202'
      - :internal_id: '1600'
        :name: Czech Republic
        :minute_price: 0.29
        :prefix: '42072'
      - :internal_id: '1601'
        :name: Czech Republic
        :minute_price: 0.29
        :prefix: '42073'
      - :internal_id: '1602'
        :name: Czech Republic
        :minute_price: 0.29
        :prefix: '42077'
      - :internal_id: '1603'
        :name: Czech Republic
        :minute_price: 0.29
        :prefix: '42093'
      - :internal_id: '1592'
        :name: Czech Republic
        :minute_price: 0.29
        :prefix: '420601'
      - :internal_id: '1593'
        :name: Czech Republic
        :minute_price: 0.29
        :prefix: '420602'
      - :internal_id: '1594'
        :name: Czech Republic
        :minute_price: 0.29
        :prefix: '420603'
      - :internal_id: '1595'
        :name: Czech Republic
        :minute_price: 0.29
        :prefix: '420604'
      - :internal_id: '1596'
        :name: Czech Republic
        :minute_price: 0.29
        :prefix: '420605'
      - :internal_id: '1597'
        :name: Czech Republic
        :minute_price: 0.29
        :prefix: '420606'
      - :internal_id: '1598'
        :name: Czech Republic
        :minute_price: 0.29
        :prefix: '420607'
      - :internal_id: '1599'
        :name: Czech Republic
        :minute_price: 0.29
        :prefix: '420608'
      - :internal_id: '1604'
        :name: Czech Republic
        :minute_price: 0.29
        :prefix: '420961'
      - :internal_id: '1605'
        :name: Czech Republic
        :minute_price: 0.29
        :prefix: '420962'
      - :internal_id: '1606'
        :name: Czech Republic
        :minute_price: 0.29
        :prefix: '420963'
      - :internal_id: '1607'
        :name: Czech Republic
        :minute_price: 0.29
        :prefix: '420964'
      - :internal_id: '1608'
        :name: Czech Republic
        :minute_price: 0.29
        :prefix: '420965'
      - :internal_id: '1609'
        :name: Czech Republic
        :minute_price: 0.29
        :prefix: '420966'
      - :internal_id: '1816'
        :name: Denmark
        :minute_price: 0.31
        :prefix: '45'
      - :internal_id: '1307'
        :name: Diego Garcia
        :minute_price: 2.23
        :prefix: '246'
      - :internal_id: '1314'
        :name: Djibouti (Republic o
        :minute_price: 0.71
        :prefix: '253'
      - :internal_id: '2259'
        :name: East Timor
        :minute_price: 1.1
        :prefix: '670'
      - :internal_id: '2230'
        :name: Ecuador
        :minute_price: 0.35
        :prefix: '593'
      - :internal_id: '1864'
        :name: El Salvador (Republi
        :minute_price: 0.18
        :prefix: '503'
      - :internal_id: '2360'
        :name: Emergency
        :minute_price: 0
        :prefix: '911'
      - :internal_id: '1301'
        :name: Equatorial Guinea (R
        :minute_price: 0.4
        :prefix: '240'
      - :internal_id: '1357'
        :name: Eritrea
        :minute_price: 0.5
        :prefix: '291'
      - :internal_id: '1542'
        :name: Estonia (Republic of
        :minute_price: 0.06
        :prefix: '372'
      - :internal_id: '1312'
        :name: Ethiopia (Federal De
        :minute_price: 0.46
        :prefix: '251'
      - :internal_id: '1861'
        :name: Falkland Islands (Ma
        :minute_price: 1.08
        :prefix: '500'
      - :internal_id: '1359'
        :name: Faroe Islands
        :minute_price: 0.26
        :prefix: '298'
      - :internal_id: '2267'
        :name: Fiji (Republic of)
        :minute_price: 0.41
        :prefix: '679'
      - :internal_id: '1523'
        :name: Finland
        :minute_price: 0.29
        :prefix: '358'
      - :internal_id: '1410'
        :name: France
        :minute_price: 0.03
        :prefix: '33'
      - :internal_id: '1411'
        :name: France
        :minute_price: 0.03
        :prefix: '331'
      - :internal_id: '1412'
        :name: France
        :minute_price: 0.26
        :prefix: '336'
      - :internal_id: '1423'
        :name: France
        :minute_price: 0.26
        :prefix: '3361'
      - :internal_id: '1424'
        :name: France
        :minute_price: 0.26
        :prefix: '3362'
      - :internal_id: '1439'
        :name: France
        :minute_price: 0.24
        :prefix: '3367'
      - :internal_id: '1440'
        :name: France
        :minute_price: 0.24
        :prefix: '3368'
      - :internal_id: '1419'
        :name: France
        :minute_price: 0.26
        :prefix: '33603'
      - :internal_id: '1420'
        :name: France
        :minute_price: 0.24
        :prefix: '33607'
      - :internal_id: '1421'
        :name: France
        :minute_price: 0.24
        :prefix: '33608'
      - :internal_id: '1422'
        :name: France
        :minute_price: 0.26
        :prefix: '33609'
      - :internal_id: '1425'
        :name: France
        :minute_price: 0.24
        :prefix: '33630'
      - :internal_id: '1426'
        :name: France
        :minute_price: 0.24
        :prefix: '33631'
      - :internal_id: '1427'
        :name: France
        :minute_price: 0.24
        :prefix: '33632'
      - :internal_id: '1428'
        :name: France
        :minute_price: 0.24
        :prefix: '33633'
      - :internal_id: '1429'
        :name: France
        :minute_price: 0.26
        :prefix: '33650'
      - :internal_id: '1430'
        :name: France
        :minute_price: 0.26
        :prefix: '33660'
      - :internal_id: '1431'
        :name: France
        :minute_price: 0.26
        :prefix: '33661'
      - :internal_id: '1432'
        :name: France
        :minute_price: 0.26
        :prefix: '33662'
      - :internal_id: '1433'
        :name: France
        :minute_price: 0.26
        :prefix: '33663'
      - :internal_id: '1434'
        :name: France
        :minute_price: 0.26
        :prefix: '33664'
      - :internal_id: '1435'
        :name: France
        :minute_price: 0.26
        :prefix: '33665'
      - :internal_id: '1436'
        :name: France
        :minute_price: 0.26
        :prefix: '33666'
      - :internal_id: '1437'
        :name: France
        :minute_price: 0.26
        :prefix: '33667'
      - :internal_id: '1438'
        :name: France
        :minute_price: 0.26
        :prefix: '33668'
      - :internal_id: '1441'
        :name: France
        :minute_price: 0.26
        :prefix: '33698'
      - :internal_id: '1442'
        :name: France
        :minute_price: 0.26
        :prefix: '33699'
      - :internal_id: '1413'
        :name: France
        :minute_price: 0.26
        :prefix: '336001'
      - :internal_id: '1414'
        :name: France
        :minute_price: 0.26
        :prefix: '336002'
      - :internal_id: '1415'
        :name: France
        :minute_price: 0.26
        :prefix: '336003'
      - :internal_id: '1416'
        :name: France
        :minute_price: 0.26
        :prefix: '336007'
      - :internal_id: '1417'
        :name: France
        :minute_price: 0.26
        :prefix: '336008'
      - :internal_id: '1418'
        :name: France
        :minute_price: 0.26
        :prefix: '336009'
      - :internal_id: '2231'
        :name: French Guiana (Frenc
        :minute_price: 0.35
        :prefix: '594'
      - :internal_id: '2276'
        :name: French Polynesia (Te
        :minute_price: 0.34
        :prefix: '689'
      - :internal_id: '1302'
        :name: Gabonese Republic
        :minute_price: 0.15
        :prefix: '241'
      - :internal_id: '1270'
        :name: Gambia (Republic of
        :minute_price: 0.45
        :prefix: '220'
      - :internal_id: '2396'
        :name: Georgia
        :minute_price: 0.11
        :prefix: '995'
      - :internal_id: '2397'
        :name: Georgia
        :minute_price: 0.1
        :prefix: '99532'
      - :internal_id: '2398'
        :name: Georgia
        :minute_price: 0.23
        :prefix: '99577'
      - :internal_id: '2399'
        :name: Georgia
        :minute_price: 0.23
        :prefix: '99593'
      - :internal_id: '2400'
        :name: Georgia
        :minute_price: 0.23
        :prefix: '99595'
      - :internal_id: '2401'
        :name: Georgia
        :minute_price: 0.23
        :prefix: '99597'
      - :internal_id: '2402'
        :name: Georgia
        :minute_price: 0.23
        :prefix: '99598'
      - :internal_id: '2403'
        :name: Georgia
        :minute_price: 0.23
        :prefix: '99599'
      - :internal_id: '1854'
        :name: Germany (Federal Rep
        :minute_price: 0.03
        :prefix: '49'
      - :internal_id: '1855'
        :name: Germany (Federal Rep
        :minute_price: 0.38
        :prefix: '4915'
      - :internal_id: '1856'
        :name: Germany (Federal Rep
        :minute_price: 0.38
        :prefix: '4916'
      - :internal_id: '1857'
        :name: Germany (Federal Rep
        :minute_price: 0.38
        :prefix: '4917'
      - :internal_id: '1858'
        :name: Germany (Federal Rep
        :minute_price: 0.38
        :prefix: '4918'
      - :internal_id: '1859'
        :name: Germany (Federal Rep
        :minute_price: 0.03
        :prefix: '4930'
      - :internal_id: '1860'
        :name: Germany (Federal Rep
        :minute_price: 0.03
        :prefix: '4969'
      - :internal_id: '1285'
        :name: Ghana
        :minute_price: 0.27
        :prefix: '233'
      - :internal_id: '1509'
        :name: Gibraltar
        :minute_price: 0.5
        :prefix: '350'
      - :internal_id: '2353'
        :name: Global Mobile Satell
        :minute_price: 5.05
        :prefix: '881'
      - :internal_id: '1361'
        :name: Greece
        :minute_price: 0.04
        :prefix: '30'
      - :internal_id: '1362'
        :name: Greece
        :minute_price: 0.03
        :prefix: '3021'
      - :internal_id: '1363'
        :name: Greece
        :minute_price: 0.04
        :prefix: '30231'
      - :internal_id: '1364'
        :name: Greece
        :minute_price: 0.28
        :prefix: '30693'
      - :internal_id: '1365'
        :name: Greece
        :minute_price: 0.28
        :prefix: '30694'
      - :internal_id: '1366'
        :name: Greece
        :minute_price: 0.3
        :prefix: '30697'
      - :internal_id: '1367'
        :name: Greece
        :minute_price: 0.3
        :prefix: '30699'
      - :internal_id: '1360'
        :name: Greenland (Denmark)
        :minute_price: 0.76
        :prefix: '299'
      - :internal_id: '2227'
        :name: Guadeloupe (French D
        :minute_price: 0.44
        :prefix: '590'
      - :internal_id: '1863'
        :name: Guatemala (Republic
        :minute_price: 0.2
        :prefix: '502'
      - :internal_id: '1276'
        :name: Guinea (Republic of)
        :minute_price: 0.21
        :prefix: '224'
      - :internal_id: '1306'
        :name: Guinea-Bissau (Repub
        :minute_price: 1.3
        :prefix: '245'
      - :internal_id: '2229'
        :name: Guyana
        :minute_price: 0.45
        :prefix: '592'
      - :internal_id: '1872'
        :name: Haiti (Republic of)
        :minute_price: 0.3
        :prefix: '509'
      - :internal_id: '1874'
        :name: Haiti (Republic of)
        :minute_price: 0.36
        :prefix: '5093'
      - :internal_id: '1875'
        :name: Haiti (Republic of)
        :minute_price: 0.39
        :prefix: '5094'
      - :internal_id: '1876'
        :name: Haiti (Republic of)
        :minute_price: 0.41
        :prefix: '5095'
      - :internal_id: '1877'
        :name: Haiti (Republic of)
        :minute_price: 0.38
        :prefix: '5097'
      - :internal_id: '1873'
        :name: Haiti (Republic of)
        :minute_price: 0.3
        :prefix: '50921'
      - :internal_id: '1865'
        :name: Honduras (Republic o
        :minute_price: 0.44
        :prefix: '504'
      - :internal_id: '2342'
        :name: Hong Kong (Special a
        :minute_price: 0.04
        :prefix: '852'
      - :internal_id: '1525'
        :name: Hungary (Republic of
        :minute_price: 0.04
        :prefix: '36'
      - :internal_id: '1526'
        :name: Hungary (Republic of
        :minute_price: 0.04
        :prefix: '361'
      - :internal_id: '1527'
        :name: Hungary (Republic of
        :minute_price: 0.36
        :prefix: '3620'
      - :internal_id: '1528'
        :name: Hungary (Republic of
        :minute_price: 0.36
        :prefix: '3630'
      - :internal_id: '1529'
        :name: Hungary (Republic of
        :minute_price: 0.36
        :prefix: '3670'
      - :internal_id: '1519'
        :name: Iceland
        :minute_price: 0.34
        :prefix: '354'
      - :internal_id: '2359'
        :name: India (Republic of)
        :minute_price: 0.2
        :prefix: '91'
      - :internal_id: '2249'
        :name: Indonesia (Republic
        :minute_price: 0.12
        :prefix: '62'
      - :internal_id: '2348'
        :name: Inmarsat Atlantic Oc
        :minute_price: 4.55
        :prefix: '871'
      - :internal_id: '2351'
        :name: Inmarsat Atlantic Oc
        :minute_price: 4.55
        :prefix: '874'
      - :internal_id: '2350'
        :name: Inmarsat Indian Ocea
        :minute_price: 5.6
        :prefix: '873'
      - :internal_id: '2349'
        :name: Inmarsat Pacific Oce
        :minute_price: 6.8
        :prefix: '872'
      - :internal_id: '2347'
        :name: Inmarsat Single Numb
        :minute_price: 4.04
        :prefix: '870'
      - :internal_id: '2354'
        :name: International Networ
        :minute_price: 4
        :prefix: '882'
      - :internal_id: '2392'
        :name: Iran (Islamic Republ
        :minute_price: 0.25
        :prefix: '98'
      - :internal_id: '2369'
        :name: Iraq (Republic of)
        :minute_price: 0.28
        :prefix: '964'
      - :internal_id: '1512'
        :name: Ireland
        :minute_price: 0.03
        :prefix: '353'
      - :internal_id: '1513'
        :name: Ireland
        :minute_price: 0.03
        :prefix: '3531'
      - :internal_id: '1514'
        :name: Ireland
        :minute_price: 0.31
        :prefix: '35383'
      - :internal_id: '1515'
        :name: Ireland
        :minute_price: 0.31
        :prefix: '35385'
      - :internal_id: '1516'
        :name: Ireland
        :minute_price: 0.31
        :prefix: '35386'
      - :internal_id: '1517'
        :name: Ireland
        :minute_price: 0.31
        :prefix: '35387'
      - :internal_id: '1518'
        :name: Ireland
        :minute_price: 0.31
        :prefix: '35388'
      - :internal_id: '2376'
        :name: Israel (State of)
        :minute_price: 0.04
        :prefix: '972'
      - :internal_id: '2377'
        :name: Israel (State of)
        :minute_price: 0.04
        :prefix: '9722'
      - :internal_id: '2378'
        :name: Israel (State of)
        :minute_price: 0.34
        :prefix: '97222'
      - :internal_id: '2379'
        :name: Israel (State of)
        :minute_price: 0.34
        :prefix: '97242'
      - :internal_id: '2380'
        :name: Israel (State of)
        :minute_price: 0.13
        :prefix: '97250'
      - :internal_id: '2381'
        :name: Israel (State of)
        :minute_price: 0.13
        :prefix: '97252'
      - :internal_id: '2382'
        :name: Israel (State of)
        :minute_price: 0.13
        :prefix: '97254'
      - :internal_id: '2383'
        :name: Israel (State of)
        :minute_price: 0.13
        :prefix: '97257'
      - :internal_id: '2384'
        :name: Israel (State of)
        :minute_price: 0.34
        :prefix: '97259'
      - :internal_id: '2385'
        :name: Israel (State of)
        :minute_price: 0.34
        :prefix: '97282'
      - :internal_id: '2386'
        :name: Israel (State of)
        :minute_price: 0.34
        :prefix: '97292'
      - :internal_id: '1573'
        :name: Italy
        :minute_price: 0.03
        :prefix: '39'
      - :internal_id: '1574'
        :name: Italy
        :minute_price: 0.39
        :prefix: '393'
      - :internal_id: '2334'
        :name: Japan
        :minute_price: 0.05
        :prefix: '81'
      - :internal_id: '2335'
        :name: Japan
        :minute_price: 0.05
        :prefix: '813'
      - :internal_id: '2336'
        :name: Japan
        :minute_price: 0.22
        :prefix: '8170'
      - :internal_id: '2337'
        :name: Japan
        :minute_price: 0.22
        :prefix: '8180'
      - :internal_id: '2338'
        :name: Japan
        :minute_price: 0.22
        :prefix: '8190'
      - :internal_id: '2367'
        :name: Jordan (Hashemite Ki
        :minute_price: 0.23
        :prefix: '962'
      - :internal_id: '1315'
        :name: Kenya (Republic of)
        :minute_price: 0.39
        :prefix: '254'
      - :internal_id: '2273'
        :name: Kiribati (Republic o
        :minute_price: 0.97
        :prefix: '686'
      - :internal_id: '2341'
        :name: Korea (Democratic Pe
        :minute_price: 0.84
        :prefix: '850'
      - :internal_id: '2339'
        :name: Korea (Republic of)
        :minute_price: 0.09
        :prefix: '82'
      - :internal_id: '2370'
        :name: Kuwait (State of)
        :minute_price: 0.15
        :prefix: '965'
      - :internal_id: '2404'
        :name: Kyrgyz Republic
        :minute_price: 0.16
        :prefix: '996'
      - :internal_id: '2345'
        :name: Lao People''s Democra
        :minute_price: 0.12
        :prefix: '856'
      - :internal_id: '1533'
        :name: Latvia (Republic of)
        :minute_price: 0.24
        :prefix: '371'
      - :internal_id: '1534'
        :name: Latvia (Republic of)
        :minute_price: 0.12
        :prefix: '3712'
      - :internal_id: '1538'
        :name: Latvia (Republic of)
        :minute_price: 0.33
        :prefix: '3716'
      - :internal_id: '1539'
        :name: Latvia (Republic of)
        :minute_price: 0.12
        :prefix: '3717'
      - :internal_id: '1540'
        :name: Latvia (Republic of)
        :minute_price: 0.33
        :prefix: '3718'
      - :internal_id: '1541'
        :name: Latvia (Republic of)
        :minute_price: 0.33
        :prefix: '3719'
      - :internal_id: '1535'
        :name: Latvia (Republic of)
        :minute_price: 0.33
        :prefix: '37155'
      - :internal_id: '1536'
        :name: Latvia (Republic of)
        :minute_price: 0.33
        :prefix: '37158'
      - :internal_id: '1537'
        :name: Latvia (Republic of)
        :minute_price: 0.33
        :prefix: '37159'
      - :internal_id: '2366'
        :name: Lebanon
        :minute_price: 0.37
        :prefix: '961'
      - :internal_id: '1330'
        :name: Lesotho (Kingdom of)
        :minute_price: 0.48
        :prefix: '266'
      - :internal_id: '1283'
        :name: Liberia (Republic of
        :minute_price: 0.4
        :prefix: '231'
      - :internal_id: '1269'
        :name: Libya (Socialist Peo
        :minute_price: 0.42
        :prefix: '218'
      - :internal_id: '1628'
        :name: Liechtenstein (Princ
        :minute_price: 0.08
        :prefix: '423'
      - :internal_id: '1629'
        :name: Liechtenstein (Princ
        :minute_price: 0.47
        :prefix: '4235'
      - :internal_id: '1630'
        :name: Liechtenstein (Princ
        :minute_price: 0.47
        :prefix: '4236'
      - :internal_id: '1631'
        :name: Liechtenstein (Princ
        :minute_price: 0.47
        :prefix: '4237'
      - :internal_id: '1530'
        :name: Lithuania (Republic
        :minute_price: 0.12
        :prefix: '370'
      - :internal_id: '1531'
        :name: Lithuania (Republic
        :minute_price: 0.3
        :prefix: '3706'
      - :internal_id: '1532'
        :name: Lithuania (Republic
        :minute_price: 0.3
        :prefix: '3709'
      - :internal_id: '1511'
        :name: Luxembourg
        :minute_price: 0.36
        :prefix: '352'
      - :internal_id: '2343'
        :name: Macao (Special admin
        :minute_price: 0.13
        :prefix: '853'
      - :internal_id: '1572'
        :name: Macedonia (The Forme
        :minute_price: 0.18
        :prefix: '389'
      - :internal_id: '1325'
        :name: Madagascar (Republic
        :minute_price: 0.36
        :prefix: '261'
      - :internal_id: '1329'
        :name: Malawi
        :minute_price: 0.09
        :prefix: '265'
      - :internal_id: '2237'
        :name: Malaysia
        :minute_price: 0.08
        :prefix: '60'
      - :internal_id: '2365'
        :name: Maldives (Republic o
        :minute_price: 0.37
        :prefix: '960'
      - :internal_id: '1275'
        :name: Mali (Republic of)
        :minute_price: 0.39
        :prefix: '223'
      - :internal_id: '1521'
        :name: Malta
        :minute_price: 0.53
        :prefix: '356'
      - :internal_id: '2279'
        :name: Marshall Islands (Re
        :minute_price: 0.46
        :prefix: '692'
      - :internal_id: '2233'
        :name: Martinique (French D
        :minute_price: 0.51
        :prefix: '596'
      - :internal_id: '1272'
        :name: Mauritania (Islamic
        :minute_price: 0.28
        :prefix: '222'
      - :internal_id: '1273'
        :name: Mauritania (Islamic
        :minute_price: 0.61
        :prefix: '22263'
      - :internal_id: '1274'
        :name: Mauritania (Islamic
        :minute_price: 0.61
        :prefix: '22264'
      - :internal_id: '1282'
        :name: Mauritius (Republic
        :minute_price: 0.28
        :prefix: '230'
      - :internal_id: '1909'
        :name: Mexico
        :minute_price: 0.15
        :prefix: '52'
      - :internal_id: '1939'
        :name: Mexico - Acaponeta
        :minute_price: 0.05
        :prefix: '52325'
      - :internal_id: '2054'
        :name: Mexico - Acapulco
        :minute_price: 0.05
        :prefix: '52744'
      - :internal_id: '2067'
        :name: Mexico - Actopan
        :minute_price: 0.05
        :prefix: '52772'
      - :internal_id: '1968'
        :name: Mexico - Aguascalien
        :minute_price: 0.04
        :prefix: '52449'
      - :internal_id: '2091'
        :name: Mexico - Allende
        :minute_price: 0.06
        :prefix: '52862'
      - :internal_id: '2046'
        :name: Mexico - Amayuca
        :minute_price: 0.13
        :prefix: '52731'
      - :internal_id: '1995'
        :name: Mexico - Amecamea
        :minute_price: 0.05
        :prefix: '52597'
      - :internal_id: '1971'
        :name: Mexico - Apatzingan
        :minute_price: 0.06
        :prefix: '52453'
      - :internal_id: '1919'
        :name: Mexico - Apizaco
        :minute_price: 0.05
        :prefix: '52241'
      - :internal_id: '2047'
        :name: Mexico - Arcelia
        :minute_price: 0.06
        :prefix: '52732'
      - :internal_id: '2010'
        :name: Mexico - Argua Priet
        :minute_price: 0.06
        :prefix: '52633'
      - :internal_id: '2037'
        :name: Mexico - Atlacomulco
        :minute_price: 0.06
        :prefix: '52712'
      - :internal_id: '1921'
        :name: Mexico - Atlixco
        :minute_price: 0.05
        :prefix: '52244'
      - :internal_id: '1953'
        :name: Mexico - Atotonilco
        :minute_price: 0.14
        :prefix: '52391'
      - :internal_id: '1935'
        :name: Mexico - Autlan
        :minute_price: 0.05
        :prefix: '52317'
      - :internal_id: '2065'
        :name: Mexico - Axochiapan
        :minute_price: 0.14
        :prefix: '52769'
      - :internal_id: '2013'
        :name: Mexico - Caborca
        :minute_price: 0.06
        :prefix: '52637'
      - :internal_id: '2081'
        :name: Mexico - Cadereyta
        :minute_price: 0.05
        :prefix: '52828'
      - :internal_id: '2116'
        :name: Mexico - Campeche
        :minute_price: 0.05
        :prefix: '52981'
      - :internal_id: '2019'
        :name: Mexico - Cananea
        :minute_price: 0.05
        :prefix: '52645'
      - :internal_id: '2123'
        :name: Mexico - Cancun
        :minute_price: 0.05
        :prefix: '52998'
      - :internal_id: '1930'
        :name: Mexico - Catemaco
        :minute_price: 0.05
        :prefix: '52294'
      - :internal_id: '2075'
        :name: Mexico - Cd. Sahagun
        :minute_price: 0.04
        :prefix: '52791'
      - :internal_id: '1972'
        :name: Mexico - Celaya
        :minute_price: 0.04
        :prefix: '52461'
      - :internal_id: '2099'
        :name: Mexico - Cerralvo
        :minute_price: 0.06
        :prefix: '52892'
      - :internal_id: '2117'
        :name: Mexico - Chetumal
        :minute_price: 0.06
        :prefix: '52983'
      - :internal_id: '1998'
        :name: Mexico - Chihuahua
        :minute_price: 0.06
        :prefix: '52614'
      - :internal_id: '2060'
        :name: Mexico - Chilapa
        :minute_price: 0.06
        :prefix: '52756'
      - :internal_id: '2055'
        :name: Mexico - Chilpancing
        :minute_price: 0.06
        :prefix: '52747'
      - :internal_id: '2079'
        :name: Mexico - China
        :minute_price: 0.06
        :prefix: '52823'
      - :internal_id: '2096'
        :name: Mexico - Ciudad Acun
        :minute_price: 0.05
        :prefix: '52877'
      - :internal_id: '2064'
        :name: Mexico - Ciudad Alta
        :minute_price: 0.06
        :prefix: '52767'
      - :internal_id: '2022'
        :name: Mexico - Ciudad Cama
        :minute_price: 0.06
        :prefix: '52648'
      - :internal_id: '2098'
        :name: Mexico - Ciudad Cama
        :minute_price: 0.05
        :prefix: '52891'
      - :internal_id: '1997'
        :name: Mexico - Ciudad Cons
        :minute_price: 0.05
        :prefix: '52613'
      - :internal_id: '2044'
        :name: Mexico - Ciudad De H
        :minute_price: 0.05
        :prefix: '52727'
      - :internal_id: '2105'
        :name: Mexico - Ciudad Del
        :minute_price: 0.06
        :prefix: '52938'
      - :internal_id: '2034'
        :name: Mexico - Ciudad Guad
        :minute_price: 0.06
        :prefix: '52676'
      - :internal_id: '1942'
        :name: Mexico - Ciudad Guzm
        :minute_price: 0.06
        :prefix: '52341'
      - :internal_id: '2074'
        :name: Mexico - Ciudad Hida
        :minute_price: 0.06
        :prefix: '52786'
      - :internal_id: '2024'
        :name: Mexico - Ciudad Juar
        :minute_price: 0.06
        :prefix: '52656'
      - :internal_id: '2083'
        :name: Mexico - Ciudad Mant
        :minute_price: 0.06
        :prefix: '52831'
      - :internal_id: '2018'
        :name: Mexico - Ciudad Obre
        :minute_price: 0.06
        :prefix: '52644'
      - :internal_id: '1985'
        :name: Mexico - Ciudad Vall
        :minute_price: 0.06
        :prefix: '52481'
      - :internal_id: '2103'
        :name: Mexico - Coatzacoalc
        :minute_price: 0.06
        :prefix: '52921'
      - :internal_id: '1932'
        :name: Mexico - Colima
        :minute_price: 0.05
        :prefix: '52312'
      - :internal_id: '2111'
        :name: Mexico - Comitan
        :minute_price: 0.14
        :prefix: '52963'
      - :internal_id: '1940'
        :name: Mexico - Compostela
        :minute_price: 0.14
        :prefix: '52327'
      - :internal_id: '1924'
        :name: Mexico - Cordoba
        :minute_price: 0.05
        :prefix: '52271'
      - :internal_id: '1956'
        :name: Mexico - Cortazar
        :minute_price: 0.14
        :prefix: '52411'
      - :internal_id: '2120'
        :name: Mexico - Cozumel
        :minute_price: 0.06
        :prefix: '52987'
      - :internal_id: '2005'
        :name: Mexico - Cuauhtemoc
        :minute_price: 0.06
        :prefix: '52625'
      - :internal_id: '2050'
        :name: Mexico - Cuautla
        :minute_price: 0.05
        :prefix: '52735'
      - :internal_id: '2070'
        :name: Mexico - Cuernavaca
        :minute_price: 0.04
        :prefix: '52777'
      - :internal_id: '2029'
        :name: Mexico - Culiacan
        :minute_price: 0.06
        :prefix: '52667'
      - :internal_id: '2015'
        :name: Mexico - Delicias
        :minute_price: 0.06
        :prefix: '52639'
      - :internal_id: '1958'
        :name: Mexico - Dolores Hid
        :minute_price: 0.14
        :prefix: '52418'
      - :internal_id: '2001'
        :name: Mexico - Durango
        :minute_price: 0.05
        :prefix: '52618'
      - :internal_id: '1982'
        :name: Mexico - Encarnacion
        :minute_price: 0.05
        :prefix: '52475'
      - :internal_id: '2020'
        :name: Mexico - Ensenada
        :minute_price: 0.05
        :prefix: '52646'
      - :internal_id: '1989'
        :name: Mexico - Fresnillo
        :minute_price: 0.06
        :prefix: '52493'
      - :internal_id: '1941'
        :name: Mexico - Guadalajara
        :minute_price: 0.03
        :prefix: '5233'
      - :internal_id: '2032'
        :name: Mexico - Guamuchil
        :minute_price: 0.06
        :prefix: '52673'
      - :internal_id: '1980'
        :name: Mexico - Guanajuato
        :minute_price: 0.04
        :prefix: '52473'
      - :internal_id: '2036'
        :name: Mexico - Guasave
        :minute_price: 0.06
        :prefix: '52687'
      - :internal_id: '2002'
        :name: Mexico - Guaymas
        :minute_price: 0.06
        :prefix: '52622'
      - :internal_id: '1999'
        :name: Mexico - Guerrero Ne
        :minute_price: 0.06
        :prefix: '52615'
      - :internal_id: '2026'
        :name: Mexico - Hermosillo
        :minute_price: 0.06
        :prefix: '52662'
      - :internal_id: '2082'
        :name: Mexico - Hidalgo
        :minute_price: 0.06
        :prefix: '52829'
      - :internal_id: '2107'
        :name: Mexico - Huajuapan
        :minute_price: 0.14
        :prefix: '52953'
      - :internal_id: '2021'
        :name: Mexico - Huatabampo
        :minute_price: 0.06
        :prefix: '52647'
      - :internal_id: '2108'
        :name: Mexico - Huatulco
        :minute_price: 0.06
        :prefix: '52958'
      - :internal_id: '1961'
        :name: Mexico - Huetamo
        :minute_price: 0.05
        :prefix: '52435'
      - :internal_id: '2102'
        :name: Mexico - Huimanguill
        :minute_price: 0.06
        :prefix: '52917'
      - :internal_id: '2048'
        :name: Mexico - Iguala
        :minute_price: 0.05
        :prefix: '52733'
      - :internal_id: '1973'
        :name: Mexico - Irapuato
        :minute_price: 0.04
        :prefix: '52462'
      - :internal_id: '1926'
        :name: Mexico - Isla
        :minute_price: 0.14
        :prefix: '52283'
      - :internal_id: '2041'
        :name: Mexico - Ixtapan De
        :minute_price: 0.05
        :prefix: '52721'
      - :internal_id: '1938'
        :name: Mexico - Ixtlan Del
        :minute_price: 0.05
        :prefix: '52324'
      - :internal_id: '1920'
        :name: Mexico - Izucar de M
        :minute_price: 0.05
        :prefix: '52243'
      - :internal_id: '1914'
        :name: Mexico - Jalapa
        :minute_price: 0.05
        :prefix: '52228'
      - :internal_id: '1974'
        :name: Mexico - Jalpa
        :minute_price: 0.05
        :prefix: '52463'
      - :internal_id: '1990'
        :name: Mexico - Jerez
        :minute_price: 0.06
        :prefix: '52494'
      - :internal_id: '2049'
        :name: Mexico - Jojutla
        :minute_price: 0.05
        :prefix: '52734'
      - :internal_id: '2115'
        :name: Mexico - Juachitan
        :minute_price: 0.06
        :prefix: '52971'
      - :internal_id: '1955'
        :name: Mexico - La Barca
        :minute_price: 0.05
        :prefix: '52393'
      - :internal_id: '1996'
        :name: Mexico - La Paz
        :minute_price: 0.05
        :prefix: '52612'
      - :internal_id: '1944'
        :name: Mexico - La Piedad
        :minute_price: 0.05
        :prefix: '52352'
      - :internal_id: '1981'
        :name: Mexico - Lagos De Mo
        :minute_price: 0.05
        :prefix: '52474'
      - :internal_id: '2057'
        :name: Mexico - Lazaro Card
        :minute_price: 0.06
        :prefix: '52753'
      - :internal_id: '1984'
        :name: Mexico - Leon
        :minute_price: 0.04
        :prefix: '52477'
      - :internal_id: '1927'
        :name: Mexico - Lerdo De Te
        :minute_price: 0.06
        :prefix: '52284'
      - :internal_id: '2045'
        :name: Mexico - Lerma
        :minute_price: 0.04
        :prefix: '52728'
      - :internal_id: '2078'
        :name: Mexico - Linares
        :minute_price: 0.06
        :prefix: '52821'
      - :internal_id: '2030'
        :name: Mexico - Los Mochis
        :minute_price: 0.06
        :prefix: '52668'
      - :internal_id: '1946'
        :name: Mexico - Los Reyes
        :minute_price: 0.05
        :prefix: '52354'
      - :internal_id: '2009'
        :name: Mexico - Magdalena
        :minute_price: 0.06
        :prefix: '52632'
      - :internal_id: '2086'
        :name: Mexico - Manuel
        :minute_price: 0.06
        :prefix: '52836'
      - :internal_id: '1934'
        :name: Mexico - Manzanillo
        :minute_price: 0.05
        :prefix: '52314'
      - :internal_id: '1917'
        :name: Mexico - Martinez de
        :minute_price: 0.05
        :prefix: '52232'
      - :internal_id: '2094'
        :name: Mexico - Matamoros
        :minute_price: 0.05
        :prefix: '52868'
      - :internal_id: '1987'
        :name: Mexico - Matehuala
        :minute_price: 0.05
        :prefix: '52488'
      - :internal_id: '2003'
        :name: Mexico - Mazatan
        :minute_price: 0.06
        :prefix: '52623'
      - :internal_id: '2031'
        :name: Mexico - Mazatlan
        :minute_price: 0.04
        :prefix: '52669'
      - :internal_id: '2124'
        :name: Mexico - Merida
        :minute_price: 0.05
        :prefix: '52999'
      - :internal_id: '2035'
        :name: Mexico - Mexicali
        :minute_price: 0.06
        :prefix: '52686'
      - :internal_id: '1992'
        :name: Mexico - Mexico City
        :minute_price: 0.03
        :prefix: '5255'
      - :internal_id: '2104'
        :name: Mexico - Minatitlan
        :minute_price: 0.06
        :prefix: '52922'
      - :internal_id: '1912'
        :name: Mexico - Mobile
        :minute_price: 0.4
        :prefix: '521'
      - :internal_id: '1911'
        :name: Mexico - Mobile
        :minute_price: 0.4
        :prefix: '52045'
      - :internal_id: '1910'
        :name: Mexico - Mobile - Juarez
        :minute_price: 0.4
        :prefix: '52044656'
      - :internal_id: '2092'
        :name: Mexico - Monclova
        :minute_price: 0.06
        :prefix: '52866'
      - :internal_id: '2080'
        :name: Mexico - Montemorelo
        :minute_price: 0.06
        :prefix: '52826'
      - :internal_id: '2077'
        :name: Mexico - Monterrey
        :minute_price: 0.03
        :prefix: '5281'
      - :internal_id: '1965'
        :name: Mexico - Morelia
        :minute_price: 0.05
        :prefix: '52443'
      - :internal_id: '1967'
        :name: Mexico - Moroleon
        :minute_price: 0.05
        :prefix: '52445'
      - :internal_id: '2011'
        :name: Mexico - Nacozari
        :minute_price: 0.06
        :prefix: '52634'
      - :internal_id: '2017'
        :name: Mexico - Navojoa
        :minute_price: 0.06
        :prefix: '52642'
      - :internal_id: '2008'
        :name: Mexico - Nogales
        :minute_price: 0.06
        :prefix: '52631'
      - :internal_id: '2012'
        :name: Mexico - Nuevo Casas
        :minute_price: 0.06
        :prefix: '52636'
      - :internal_id: '2093'
        :name: Mexico - Nuevo Lared
        :minute_price: 0.05
        :prefix: '52867'
      - :internal_id: '2106'
        :name: Mexico - Oaxaca
        :minute_price: 0.05
        :prefix: '52951'
      - :internal_id: '1954'
        :name: Mexico - Ocotlan
        :minute_price: 0.05
        :prefix: '52392'
      - :internal_id: '2114'
        :name: Mexico - Ocozocuautl
        :minute_price: 0.06
        :prefix: '52968'
      - :internal_id: '2006'
        :name: Mexico - Ojinaga
        :minute_price: 0.06
        :prefix: '52626'
      - :internal_id: '2052'
        :name: Mexico - Ometepec
        :minute_price: 0.05
        :prefix: '52741'
      - :internal_id: '1925'
        :name: Mexico - Orizaba
        :minute_price: 0.05
        :prefix: '52272'
      - :internal_id: '2066'
        :name: Mexico - Pachuca
        :minute_price: 0.05
        :prefix: '52771'
      - :internal_id: '2101'
        :name: Mexico - Palenque
        :minute_price: 0.06
        :prefix: '52916'
      - :internal_id: '2007'
        :name: Mexico - Parral
        :minute_price: 0.06
        :prefix: '52627'
      - :internal_id: '2088'
        :name: Mexico - Parras De L
        :minute_price: 0.04
        :prefix: '52842'
      - :internal_id: '1960'
        :name: Mexico - Patzcuaro
        :minute_price: 0.05
        :prefix: '52434'
      - :internal_id: '1978'
        :name: Mexico - Penjamo
        :minute_price: 0.05
        :prefix: '52469'
      - :internal_id: '2062'
        :name: Mexico - Petatlan
        :minute_price: 0.05
        :prefix: '52758'
      - :internal_id: '2097'
        :name: Mexico - Piedras Neg
        :minute_price: 0.06
        :prefix: '52878'
      - :internal_id: '2118'
        :name: Mexico - Playadel Ca
        :minute_price: 0.13
        :prefix: '52984'
      - :internal_id: '2072'
        :name: Mexico - Poza Rica
        :minute_price: 0.05
        :prefix: '52782'
      - :internal_id: '1913'
        :name: Mexico - Puebla
        :minute_price: 0.03
        :prefix: '52222'
      - :internal_id: '2014'
        :name: Mexico - Puerto Pena
        :minute_price: 0.06
        :prefix: '52638'
      - :internal_id: '1936'
        :name: Mexico - Puerto Vall
        :minute_price: 0.05
        :prefix: '52322'
      - :internal_id: '1963'
        :name: Mexico - Puruandiro
        :minute_price: 0.05
        :prefix: '52438'
      - :internal_id: '1964'
        :name: Mexico - Queretaro
        :minute_price: 0.03
        :prefix: '52442'
      - :internal_id: '2000'
        :name: Mexico - Quintin
        :minute_price: 0.06
        :prefix: '52616'
      - :internal_id: '2100'
        :name: Mexico - Reynosa
        :minute_price: 0.05
        :prefix: '52899'
      - :internal_id: '1991'
        :name: Mexico - Rio Grande
        :minute_price: 0.05
        :prefix: '52498'
      - :internal_id: '1986'
        :name: Mexico - Rio Verde
        :minute_price: 0.06
        :prefix: '52487'
      - :internal_id: '2025'
        :name: Mexico - Rosarito
        :minute_price: 0.06
        :prefix: '52661'
      - :internal_id: '2090'
        :name: Mexico - Sabinas
        :minute_price: 0.05
        :prefix: '52861'
      - :internal_id: '1945'
        :name: Mexico - Sahuayo
        :minute_price: 0.05
        :prefix: '52353'
      - :internal_id: '1975'
        :name: Mexico - Salamanca
        :minute_price: 0.05
        :prefix: '52464'
      - :internal_id: '2089'
        :name: Mexico - Saltillo
        :minute_price: 0.04
        :prefix: '52844'
      - :internal_id: '1976'
        :name: Mexico - Salvatierra
        :minute_price: 0.06
        :prefix: '52466'
      - :internal_id: '2113'
        :name: Mexico - San Cristob
        :minute_price: 0.06
        :prefix: '52967'
      - :internal_id: '2119'
        :name: Mexico - San Felipe
        :minute_price: 0.06
        :prefix: '52986'
      - :internal_id: '2087'
        :name: Mexico - San Fernand
        :minute_price: 0.06
        :prefix: '52841'
      - :internal_id: '1983'
        :name: Mexico - San Francis
        :minute_price: 0.14
        :prefix: '52476'
      - :internal_id: '2004'
        :name: Mexico - San Jose
        :minute_price: 0.06
        :prefix: '52624'
      - :internal_id: '1950'
        :name: Mexico - San Jose De
        :minute_price: 0.05
        :prefix: '52381'
      - :internal_id: '1959'
        :name: Mexico - San Juan De
        :minute_price: 0.05
        :prefix: '52427'
      - :internal_id: '1977'
        :name: Mexico - San Luis De
        :minute_price: 0.05
        :prefix: '52468'
      - :internal_id: '1966'
        :name: Mexico - San Luis Po
        :minute_price: 0.04
        :prefix: '52444'
      - :internal_id: '2023'
        :name: Mexico - San Luis Ri
        :minute_price: 0.06
        :prefix: '52653'
      - :internal_id: '1923'
        :name: Mexico - San Martin
        :minute_price: 0.14
        :prefix: '52248'
      - :internal_id: '1957'
        :name: Mexico - San Miguel
        :minute_price: 0.05
        :prefix: '52415'
      - :internal_id: '2016'
        :name: Mexico - Santa Ana
        :minute_price: 0.06
        :prefix: '52641'
      - :internal_id: '2038'
        :name: Mexico - Santiago
        :minute_price: 0.05
        :prefix: '52713'
      - :internal_id: '1937'
        :name: Mexico - Santiago Ix
        :minute_price: 0.06
        :prefix: '52323'
      - :internal_id: '2033'
        :name: Mexico - Santiago Pa
        :minute_price: 0.06
        :prefix: '52674'
      - :internal_id: '1979'
        :name: Mexico - Silao
        :minute_price: 0.05
        :prefix: '52472'
      - :internal_id: '1951'
        :name: Mexico - Tala
        :minute_price: 0.05
        :prefix: '52384'
      - :internal_id: '2084'
        :name: Mexico - Tampico
        :minute_price: 0.05
        :prefix: '52833'
      - :internal_id: '2110'
        :name: Mexico - Tapachula
        :minute_price: 0.06
        :prefix: '52962'
      - :internal_id: '2063'
        :name: Mexico - Taxco
        :minute_price: 0.05
        :prefix: '52762'
      - :internal_id: '2028'
        :name: Mexico - Tecate
        :minute_price: 0.06
        :prefix: '52665'
      - :internal_id: '1933'
        :name: Mexico - Tecoman
        :minute_price: 0.06
        :prefix: '52313'
      - :internal_id: '2053'
        :name: Mexico - Tecpan
        :minute_price: 0.06
        :prefix: '52742'
      - :internal_id: '1952'
        :name: Mexico - Tecuala
        :minute_price: 0.05
        :prefix: '52389'
      - :internal_id: '1918'
        :name: Mexico - Tehuacan
        :minute_price: 0.05
        :prefix: '52238'
      - :internal_id: '2051'
        :name: Mexico - Teloloapan
        :minute_price: 0.05
        :prefix: '52736'
      - :internal_id: '2039'
        :name: Mexico - Tenancingo
        :minute_price: 0.05
        :prefix: '52714'
      - :internal_id: '1949'
        :name: Mexico - Tepatitlan
        :minute_price: 0.05
        :prefix: '52378'
      - :internal_id: '1931'
        :name: Mexico - Tepic
        :minute_price: 0.04
        :prefix: '52311'
      - :internal_id: '1948'
        :name: Mexico - Tequila
        :minute_price: 0.05
        :prefix: '52374'
      - :internal_id: '1994'
        :name: Mexico - Texcoco
        :minute_price: 0.04
        :prefix: '52595'
      - :internal_id: '1916'
        :name: Mexico - Teziutlan
        :minute_price: 0.05
        :prefix: '52231'
      - :internal_id: '2122'
        :name: Mexico - Ticul
        :minute_price: 0.06
        :prefix: '52997'
      - :internal_id: '2027'
        :name: Mexico - Tijuana
        :minute_price: 0.04
        :prefix: '52664'
      - :internal_id: '2056'
        :name: Mexico - Tilzapotla
        :minute_price: 0.14
        :prefix: '52751'
      - :internal_id: '2058'
        :name: Mexico - Tixtla
        :minute_price: 0.05
        :prefix: '52754'
      - :internal_id: '2071'
        :name: Mexico - Tizayuca
        :minute_price: 0.05
        :prefix: '52779'
      - :internal_id: '1929'
        :name: Mexico - Tlacotalpan
        :minute_price: 0.05
        :prefix: '52288'
      - :internal_id: '2061'
        :name: Mexico - Tlalpa
        :minute_price: 0.05
        :prefix: '52757'
      - :internal_id: '1922'
        :name: Mexico - Tlaxcala
        :minute_price: 0.05
        :prefix: '52246'
      - :internal_id: '2076'
        :name: Mexico - Toll Free
        :minute_price: 0
        :prefix: '52800'
      - :internal_id: '2042'
        :name: Mexico - Toluca
        :minute_price: 0.04
        :prefix: '52722'
      - :internal_id: '2095'
        :name: Mexico - Torreon
        :minute_price: 0.04
        :prefix: '52871'
      - :internal_id: '2068'
        :name: Mexico - Tula
        :minute_price: 0.05
        :prefix: '52773'
      - :internal_id: '2069'
        :name: Mexico - Tulancingo
        :minute_price: 0.05
        :prefix: '52775'
      - :internal_id: '2073'
        :name: Mexico - Tuxpan
        :minute_price: 0.04
        :prefix: '52783'
      - :internal_id: '1928'
        :name: Mexico - Tuxtepec
        :minute_price: 0.06
        :prefix: '52287'
      - :internal_id: '2109'
        :name: Mexico - Tuxtla Guti
        :minute_price: 0.06
        :prefix: '52961'
      - :internal_id: '1970'
        :name: Mexico - Uruapan
        :minute_price: 0.05
        :prefix: '52452'
      - :internal_id: '2043'
        :name: Mexico - Valle De Br
        :minute_price: 0.05
        :prefix: '52726'
      - :internal_id: '1915'
        :name: Mexico - Veracruz
        :minute_price: 0.05
        :prefix: '52229'
      - :internal_id: '2085'
        :name: Mexico - Victoria
        :minute_price: 0.05
        :prefix: '52834'
      - :internal_id: '2112'
        :name: Mexico - Villa Flore
        :minute_price: 0.06
        :prefix: '52965'
      - :internal_id: '2121'
        :name: Mexico - Villahermos
        :minute_price: 0.05
        :prefix: '52993'
      - :internal_id: '1947'
        :name: Mexico - Yurecuaro
        :minute_price: 0.05
        :prefix: '52356'
      - :internal_id: '1962'
        :name: Mexico - Zacapu
        :minute_price: 0.06
        :prefix: '52436'
      - :internal_id: '1988'
        :name: Mexico - Zacatecas
        :minute_price: 0.05
        :prefix: '52492'
      - :internal_id: '1943'
        :name: Mexico - Zamora
        :minute_price: 0.05
        :prefix: '52351'
      - :internal_id: '2059'
        :name: Mexico - Zihuatanejo
        :minute_price: 0.05
        :prefix: '52755'
      - :internal_id: '1969'
        :name: Mexico - Zinapecuaro
        :minute_price: 0.05
        :prefix: '52451'
      - :internal_id: '2040'
        :name: Mexico - Zitacuaro
        :minute_price: 0.06
        :prefix: '52715'
      - :internal_id: '1993'
        :name: Mexico - Zumpango
        :minute_price: 0.04
        :prefix: '52591'
      - :internal_id: '2278'
        :name: Micronesia (Federate
        :minute_price: 0.49
        :prefix: '691'
      - :internal_id: '1543'
        :name: Moldova (Republic of
        :minute_price: 0.19
        :prefix: '373'
      - :internal_id: '1548'
        :name: Moldova (Republic of
        :minute_price: 0.23
        :prefix: '3735'
      - :internal_id: '1549'
        :name: Moldova (Republic of
        :minute_price: 0.32
        :prefix: '37369'
      - :internal_id: '1550'
        :name: Moldova (Republic of
        :minute_price: 0.32
        :prefix: '37379'
      - :internal_id: '1544'
        :name: Moldova (Republic of
        :minute_price: 0.23
        :prefix: '373210'
      - :internal_id: '1545'
        :name: Moldova (Republic of
        :minute_price: 0.23
        :prefix: '373215'
      - :internal_id: '1546'
        :name: Moldova (Republic of
        :minute_price: 0.23
        :prefix: '373216'
      - :internal_id: '1547'
        :name: Moldova (Republic of
        :minute_price: 0.23
        :prefix: '373219'
      - :internal_id: '1559'
        :name: Monaco (Principality
        :minute_price: 0.08
        :prefix: '377'
      - :internal_id: '1560'
        :name: Monaco (Principality
        :minute_price: 0.13
        :prefix: '3774'
      - :internal_id: '1564'
        :name: Monaco (Principality
        :minute_price: 0.13
        :prefix: '3776'
      - :internal_id: '1561'
        :name: Monaco (Principality
        :minute_price: 0.41
        :prefix: '37744'
      - :internal_id: '1562'
        :name: Monaco (Principality
        :minute_price: 0.41
        :prefix: '37745'
      - :internal_id: '1563'
        :name: Monaco (Principality
        :minute_price: 0.41
        :prefix: '37747'
      - :internal_id: '2390'
        :name: Mongolia
        :minute_price: 0.17
        :prefix: '976'
      - :internal_id: '1266'
        :name: Morocco (Kingdom of)
        :minute_price: 0.44
        :prefix: '212'
      - :internal_id: '1319'
        :name: Mozambique (Republic
        :minute_price: 0.32
        :prefix: '258'
      - :internal_id: '2364'
        :name: Myanmar (Union of)
        :minute_price: 0.5
        :prefix: '95'
      - :internal_id: '1328'
        :name: Namibia (Republic of
        :minute_price: 0.37
        :prefix: '264'
      - :internal_id: '2262'
        :name: Nauru (Republic of)
        :minute_price: 1.41
        :prefix: '674'
      - :internal_id: '2391'
        :name: Nepal
        :minute_price: 0.43
        :prefix: '977'
      - :internal_id: '1368'
        :name: Netherlands (Kingdom
        :minute_price: 0.03
        :prefix: '31'
      - :internal_id: '1404'
        :name: Netherlands (Kingdom
        :minute_price: 0.4
        :prefix: '3165'
      - :internal_id: '1369'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31610'
      - :internal_id: '1370'
        :name: Netherlands (Kingdom
        :minute_price: 0.4
        :prefix: '31611'
      - :internal_id: '1371'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31612'
      - :internal_id: '1372'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31613'
      - :internal_id: '1373'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31614'
      - :internal_id: '1374'
        :name: Netherlands (Kingdom
        :minute_price: 0.4
        :prefix: '31615'
      - :internal_id: '1375'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31616'
      - :internal_id: '1376'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31617'
      - :internal_id: '1377'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31618'
      - :internal_id: '1378'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31619'
      - :internal_id: '1379'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31620'
      - :internal_id: '1380'
        :name: Netherlands (Kingdom
        :minute_price: 0.4
        :prefix: '31621'
      - :internal_id: '1381'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31622'
      - :internal_id: '1382'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31623'
      - :internal_id: '1383'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31624'
      - :internal_id: '1384'
        :name: Netherlands (Kingdom
        :minute_price: 0.4
        :prefix: '31625'
      - :internal_id: '1385'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31626'
      - :internal_id: '1386'
        :name: Netherlands (Kingdom
        :minute_price: 0.4
        :prefix: '31627'
      - :internal_id: '1387'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31628'
      - :internal_id: '1388'
        :name: Netherlands (Kingdom
        :minute_price: 0.4
        :prefix: '31629'
      - :internal_id: '1389'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31630'
      - :internal_id: '1390'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31632'
      - :internal_id: '1391'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31633'
      - :internal_id: '1392'
        :name: Netherlands (Kingdom
        :minute_price: 0.4
        :prefix: '31636'
      - :internal_id: '1393'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31638'
      - :internal_id: '1394'
        :name: Netherlands (Kingdom
        :minute_price: 0.4
        :prefix: '31640'
      - :internal_id: '1395'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31641'
      - :internal_id: '1396'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31642'
      - :internal_id: '1397'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31643'
      - :internal_id: '1398'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31644'
      - :internal_id: '1399'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31645'
      - :internal_id: '1400'
        :name: Netherlands (Kingdom
        :minute_price: 0.4
        :prefix: '31646'
      - :internal_id: '1401'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31647'
      - :internal_id: '1402'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31648'
      - :internal_id: '1403'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31649'
      - :internal_id: '1405'
        :name: Netherlands (Kingdom
        :minute_price: 0.38
        :prefix: '31665'
      - :internal_id: '2236'
        :name: Netherlands Antilles
        :minute_price: 0.24
        :prefix: '599'
      - :internal_id: '2274'
        :name: New Caledonia (Terri
        :minute_price: 0.47
        :prefix: '687'
      - :internal_id: '2251'
        :name: New Zealand
        :minute_price: 0.04
        :prefix: '64'
      - :internal_id: '2252'
        :name: New Zealand
        :minute_price: 0.45
        :prefix: '642'
      - :internal_id: '1866'
        :name: Nicaragua
        :minute_price: 0.36
        :prefix: '505'
      - :internal_id: '1279'
        :name: Niger (Republic of t
        :minute_price: 0.24
        :prefix: '227'
      - :internal_id: '1286'
        :name: Nigeria (Federal Rep
        :minute_price: 0.16
        :prefix: '234'
      - :internal_id: '1287'
        :name: Nigeria (Federal Rep
        :minute_price: 0.08
        :prefix: '2341'
      - :internal_id: '1295'
        :name: Nigeria (Federal Rep
        :minute_price: 0.3
        :prefix: '23490'
      - :internal_id: '1288'
        :name: Nigeria (Federal Rep
        :minute_price: 0.25
        :prefix: '234802'
      - :internal_id: '1289'
        :name: Nigeria (Federal Rep
        :minute_price: 0.28
        :prefix: '234803'
      - :internal_id: '1290'
        :name: Nigeria (Federal Rep
        :minute_price: 0.29
        :prefix: '234804'
      - :internal_id: '1291'
        :name: Nigeria (Federal Rep
        :minute_price: 0.3
        :prefix: '234805'
      - :internal_id: '1292'
        :name: Nigeria (Federal Rep
        :minute_price: 0.28
        :prefix: '234806'
      - :internal_id: '1293'
        :name: Nigeria (Federal Rep
        :minute_price: 0.3
        :prefix: '234807'
      - :internal_id: '1294'
        :name: Nigeria (Federal Rep
        :minute_price: 0.25
        :prefix: '234808'
      - :internal_id: '2271'
        :name: Niue
        :minute_price: 1.44
        :prefix: '683'
      - :internal_id: '1842'
        :name: Norway
        :minute_price: 0.31
        :prefix: '47'
      - :internal_id: '2373'
        :name: Oman (Sultanate of)
        :minute_price: 0.3
        :prefix: '968'
      - :internal_id: '2361'
        :name: Pakistan (Islamic Re
        :minute_price: 0.22
        :prefix: '92'
      - :internal_id: '2268'
        :name: Palau (Republic of)
        :minute_price: 0.61
        :prefix: '680'
      - :internal_id: '2374'
        :name: Palestine (Occupied
        :minute_price: 0.44
        :prefix: '970'
      - :internal_id: '1868'
        :name: Panama (Republic of)
        :minute_price: 0.08
        :prefix: '507'
      - :internal_id: '1869'
        :name: Panama (Republic of)
        :minute_price: 0.04
        :prefix: '5072'
      - :internal_id: '1870'
        :name: Panama (Republic of)
        :minute_price: 0.22
        :prefix: '5076'
      - :internal_id: '2263'
        :name: Papua New Guinea
        :minute_price: 1.26
        :prefix: '675'
      - :internal_id: '2232'
        :name: Paraguay (Republic o
        :minute_price: 0.21
        :prefix: '595'
      - :internal_id: '1878'
        :name: Peru
        :minute_price: 0.07
        :prefix: '51'
      - :internal_id: '1879'
        :name: Peru
        :minute_price: 0.04
        :prefix: '5112'
      - :internal_id: '1880'
        :name: Peru
        :minute_price: 0.04
        :prefix: '5113'
      - :internal_id: '1881'
        :name: Peru
        :minute_price: 0.04
        :prefix: '5114'
      - :internal_id: '1882'
        :name: Peru
        :minute_price: 0.04
        :prefix: '5115'
      - :internal_id: '1883'
        :name: Peru
        :minute_price: 0.04
        :prefix: '5116'
      - :internal_id: '1884'
        :name: Peru
        :minute_price: 0.04
        :prefix: '5117'
      - :internal_id: '1885'
        :name: Peru
        :minute_price: 0.38
        :prefix: '5119'
      - :internal_id: '1886'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51419'
      - :internal_id: '1887'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51429'
      - :internal_id: '1888'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51439'
      - :internal_id: '1889'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51449'
      - :internal_id: '1890'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51519'
      - :internal_id: '1891'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51529'
      - :internal_id: '1892'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51539'
      - :internal_id: '1893'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51549'
      - :internal_id: '1894'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51569'
      - :internal_id: '1895'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51619'
      - :internal_id: '1896'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51629'
      - :internal_id: '1897'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51639'
      - :internal_id: '1898'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51649'
      - :internal_id: '1899'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51659'
      - :internal_id: '1900'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51669'
      - :internal_id: '1901'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51679'
      - :internal_id: '1902'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51729'
      - :internal_id: '1903'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51739'
      - :internal_id: '1904'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51749'
      - :internal_id: '1905'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51769'
      - :internal_id: '1906'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51829'
      - :internal_id: '1907'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51839'
      - :internal_id: '1908'
        :name: Peru
        :minute_price: 0.38
        :prefix: '51849'
      - :internal_id: '2250'
        :name: Philippines (Republi
        :minute_price: 0.26
        :prefix: '63'
      - :internal_id: '1843'
        :name: Poland (Republic of)
        :minute_price: 0.04
        :prefix: '48'
      - :internal_id: '1844'
        :name: Poland (Republic of)
        :minute_price: 0.37
        :prefix: '4822'
      - :internal_id: '1845'
        :name: Poland (Republic of)
        :minute_price: 0.37
        :prefix: '4850'
      - :internal_id: '1846'
        :name: Poland (Republic of)
        :minute_price: 0.37
        :prefix: '4851'
      - :internal_id: '1847'
        :name: Poland (Republic of)
        :minute_price: 0.37
        :prefix: '4860'
      - :internal_id: '1848'
        :name: Poland (Republic of)
        :minute_price: 0.37
        :prefix: '4866'
      - :internal_id: '1849'
        :name: Poland (Republic of)
        :minute_price: 0.37
        :prefix: '4869'
      - :internal_id: '1852'
        :name: Poland (Republic of)
        :minute_price: 0.37
        :prefix: '4888'
      - :internal_id: '1853'
        :name: Poland (Republic of)
        :minute_price: 0.37
        :prefix: '4890'
      - :internal_id: '1850'
        :name: Poland (Republic of)
        :minute_price: 0.37
        :prefix: '48787'
      - :internal_id: '1851'
        :name: Poland (Republic of)
        :minute_price: 0.37
        :prefix: '48789'
      - :internal_id: '1510'
        :name: Portugal
        :minute_price: 0.37
        :prefix: '351'
      - :internal_id: '2388'
        :name: Qatar (State of)
        :minute_price: 0.5
        :prefix: '974'
      - :internal_id: '1326'
        :name: Reunion (French Depa
        :minute_price: 0.42
        :prefix: '262'
      - :internal_id: '1575'
        :name: Romania
        :minute_price: 0.16
        :prefix: '40'
      - :internal_id: '1576'
        :name: Romania
        :minute_price: 0.13
        :prefix: '4021'
      - :internal_id: '1577'
        :name: Romania
        :minute_price: 0.28
        :prefix: '4072'
      - :internal_id: '1578'
        :name: Romania
        :minute_price: 0.28
        :prefix: '4074'
      - :internal_id: '1579'
        :name: Romania
        :minute_price: 0.28
        :prefix: '4076'
      - :internal_id: '1580'
        :name: Romania
        :minute_price: 0.28
        :prefix: '4078'
      - :internal_id: '2280'
        :name: Russian Federation
        :minute_price: 0.07
        :prefix: '7'
      - :internal_id: '2329'
        :name: Russian Federation
        :minute_price: 0.1
        :prefix: '790'
      - :internal_id: '2330'
        :name: Russian Federation
        :minute_price: 0.1
        :prefix: '791'
      - :internal_id: '2331'
        :name: Russian Federation
        :minute_price: 0.1
        :prefix: '792'
      - :internal_id: '2332'
        :name: Russian Federation
        :minute_price: 0.1
        :prefix: '795'
      - :internal_id: '2333'
        :name: Russian Federation
        :minute_price: 0.1
        :prefix: '796'
      - :internal_id: '2283'
        :name: Russian Federation
        :minute_price: 0.24
        :prefix: '7300'
      - :internal_id: '2284'
        :name: Russian Federation
        :minute_price: 0.19
        :prefix: '7310'
      - :internal_id: '2285'
        :name: Russian Federation
        :minute_price: 0.19
        :prefix: '7311'
      - :internal_id: '2286'
        :name: Russian Federation
        :minute_price: 0.19
        :prefix: '7312'
      - :internal_id: '2287'
        :name: Russian Federation
        :minute_price: 0.19
        :prefix: '7313'
      - :internal_id: '2288'
        :name: Russian Federation
        :minute_price: 0.19
        :prefix: '7314'
      - :internal_id: '2289'
        :name: Russian Federation
        :minute_price: 0.19
        :prefix: '7315'
      - :internal_id: '2290'
        :name: Russian Federation
        :minute_price: 0.19
        :prefix: '7316'
      - :internal_id: '2291'
        :name: Russian Federation
        :minute_price: 0.19
        :prefix: '7317'
      - :internal_id: '2292'
        :name: Russian Federation
        :minute_price: 0.19
        :prefix: '7318'
      - :internal_id: '2293'
        :name: Russian Federation
        :minute_price: 0.19
        :prefix: '7321'
      - :internal_id: '2294'
        :name: Russian Federation
        :minute_price: 0.19
        :prefix: '7322'
      - :internal_id: '2295'
        :name: Russian Federation
        :minute_price: 0.19
        :prefix: '7323'
      - :internal_id: '2296'
        :name: Russian Federation
        :minute_price: 0.19
        :prefix: '7324'
      - :internal_id: '2297'
        :name: Russian Federation
        :minute_price: 0.19
        :prefix: '7325'
      - :internal_id: '2298'
        :name: Russian Federation
        :minute_price: 0.19
        :prefix: '7326'
      - :internal_id: '2299'
        :name: Russian Federation
        :minute_price: 0.19
        :prefix: '7327'
      - :internal_id: '2301'
        :name: Russian Federation
        :minute_price: 0.19
        :prefix: '7328'
      - :internal_id: '2302'
        :name: Russian Federation
        :minute_price: 0.19
        :prefix: '7329'
      - :internal_id: '2303'
        :name: Russian Federation
        :minute_price: 0.24
        :prefix: '7333'
      - :internal_id: '2304'
        :name: Russian Federation
        :minute_price: 0.07
        :prefix: '7477'
      - :internal_id: '2305'
        :name: Russian Federation
        :minute_price: 0.07
        :prefix: '7478'
      - :internal_id: '2306'
        :name: Russian Federation
        :minute_price: 0.02
        :prefix: '7495'
      - :internal_id: '2307'
        :name: Russian Federation
        :minute_price: 0.05
        :prefix: '7496'
      - :internal_id: '2308'
        :name: Russian Federation
        :minute_price: 0.05
        :prefix: '7498'
      - :internal_id: '2309'
        :name: Russian Federation
        :minute_price: 0.02
        :prefix: '7499'
      - :internal_id: '2310'
        :name: Russian Federation
        :minute_price: 0.07
        :prefix: '7501'
      - :internal_id: '2311'
        :name: Russian Federation
        :minute_price: 0.07
        :prefix: '7502'
      - :internal_id: '2312'
        :name: Russian Federation
        :minute_price: 0.07
        :prefix: '7503'
      - :internal_id: '2313'
        :name: Russian Federation
        :minute_price: 0.07
        :prefix: '7504'
      - :internal_id: '2314'
        :name: Russian Federation
        :minute_price: 0.07
        :prefix: '7505'
      - :internal_id: '2315'
        :name: Russian Federation
        :minute_price: 0.07
        :prefix: '7509'
      - :internal_id: '2316'
        :name: Russian Federation
        :minute_price: 0.07
        :prefix: '7510'
      - :internal_id: '2317'
        :name: Russian Federation
        :minute_price: 0.07
        :prefix: '7511'
      - :internal_id: '2318'
        :name: Russian Federation
        :minute_price: 0.07
        :prefix: '7512'
      - :internal_id: '2319'
        :name: Russian Federation
        :minute_price: 0.07
        :prefix: '7513'
      - :internal_id: '2320'
        :name: Russian Federation
        :minute_price: 0.07
        :prefix: '7517'
      - :internal_id: '2321'
        :name: Russian Federation
        :minute_price: 0.07
        :prefix: '7543'
      - :internal_id: '2322'
        :name: Russian Federation
        :minute_price: 0.24
        :prefix: '7676'
      - :internal_id: '2323'
        :name: Russian Federation
        :minute_price: 0.24
        :prefix: '7700'
      - :internal_id: '2324'
        :name: Russian Federation
        :minute_price: 0.24
        :prefix: '7701'
      - :internal_id: '2325'
        :name: Russian Federation
        :minute_price: 0.24
        :prefix: '7702'
      - :internal_id: '2326'
        :name: Russian Federation
        :minute_price: 0.24
        :prefix: '7705'
      - :internal_id: '2327'
        :name: Russian Federation
        :minute_price: 0.02
        :prefix: '7812'
      - :internal_id: '2328'
        :name: Russian Federation
        :minute_price: 0.03
        :prefix: '7813'
      - :internal_id: '2281'
        :name: Russian Federation
        :minute_price: 0.07
        :prefix: '70971'
      - :internal_id: '2282'
        :name: Russian Federation
        :minute_price: 0.07
        :prefix: '70976'
      - :internal_id: '2300'
        :name: Russian Federation
        :minute_price: 0.07
        :prefix: '73272'
      - :internal_id: '1311'
        :name: Rwandese Republic
        :minute_price: 0.22
        :prefix: '250'
      - :internal_id: '1356'
        :name: Saint Helena
        :minute_price: 2
        :prefix: '290'
      - :internal_id: '1871'
        :name: Saint Pierre and Miq
        :minute_price: 0.31
        :prefix: '508'
      - :internal_id: '2272'
        :name: Samoa (Independent S
        :minute_price: 0.64
        :prefix: '685'
      - :internal_id: '1565'
        :name: San Marino (Republic
        :minute_price: 0.06
        :prefix: '378'
      - :internal_id: '1300'
        :name: Sao Tome and Princip
        :minute_price: 2
        :prefix: '239'
      - :internal_id: '2371'
        :name: Saudi Arabia (Kingdo
        :minute_price: 0.34
        :prefix: '966'
      - :internal_id: '1271'
        :name: Senegal (Republic of
        :minute_price: 0.35
        :prefix: '221'
      - :internal_id: '1568'
        :name: Serbia and Montenegr
        :minute_price: 0.39
        :prefix: '381'
      - :internal_id: '1309'
        :name: Seychelles (Republic
        :minute_price: 0.5
        :prefix: '248'
      - :internal_id: '1284'
        :name: Sierra Leone
        :minute_price: 0.31
        :prefix: '232'
      - :internal_id: '2253'
        :name: Singapore (Republic
        :minute_price: 0.02
        :prefix: '65'
      - :internal_id: '1610'
        :name: Slovak Republic
        :minute_price: 0.12
        :prefix: '421'
      - :internal_id: '1611'
        :name: Slovak Republic
        :minute_price: 0.34
        :prefix: '421901'
      - :internal_id: '1612'
        :name: Slovak Republic
        :minute_price: 0.34
        :prefix: '421902'
      - :internal_id: '1613'
        :name: Slovak Republic
        :minute_price: 0.34
        :prefix: '421903'
      - :internal_id: '1614'
        :name: Slovak Republic
        :minute_price: 0.34
        :prefix: '421904'
      - :internal_id: '1615'
        :name: Slovak Republic
        :minute_price: 0.34
        :prefix: '421905'
      - :internal_id: '1616'
        :name: Slovak Republic
        :minute_price: 0.34
        :prefix: '421906'
      - :internal_id: '1617'
        :name: Slovak Republic
        :minute_price: 0.34
        :prefix: '421907'
      - :internal_id: '1618'
        :name: Slovak Republic
        :minute_price: 0.34
        :prefix: '421908'
      - :internal_id: '1619'
        :name: Slovak Republic
        :minute_price: 0.34
        :prefix: '421909'
      - :internal_id: '1620'
        :name: Slovak Republic
        :minute_price: 0.34
        :prefix: '421910'
      - :internal_id: '1621'
        :name: Slovak Republic
        :minute_price: 0.34
        :prefix: '421911'
      - :internal_id: '1622'
        :name: Slovak Republic
        :minute_price: 0.34
        :prefix: '421912'
      - :internal_id: '1623'
        :name: Slovak Republic
        :minute_price: 0.34
        :prefix: '421914'
      - :internal_id: '1624'
        :name: Slovak Republic
        :minute_price: 0.34
        :prefix: '421915'
      - :internal_id: '1625'
        :name: Slovak Republic
        :minute_price: 0.34
        :prefix: '421916'
      - :internal_id: '1626'
        :name: Slovak Republic
        :minute_price: 0.34
        :prefix: '421918'
      - :internal_id: '1627'
        :name: Slovak Republic
        :minute_price: 0.34
        :prefix: '421919'
      - :internal_id: '1570'
        :name: Slovenia (Republic o
        :minute_price: 0.44
        :prefix: '386'
      - :internal_id: '2265'
        :name: Solomon Islands
        :minute_price: 1.38
        :prefix: '677'
      - :internal_id: '1313'
        :name: Somali Democratic Re
        :minute_price: 0.8
        :prefix: '252'
      - :internal_id: '1335'
        :name: South Africa (Republ
        :minute_price: 0.1
        :prefix: '27'
      - :internal_id: '1336'
        :name: South Africa (Republ
        :minute_price: 0.1
        :prefix: '2711'
      - :internal_id: '1337'
        :name: South Africa (Republ
        :minute_price: 0.1
        :prefix: '2721'
      - :internal_id: '1338'
        :name: South Africa (Republ
        :minute_price: 0.3
        :prefix: '2772'
      - :internal_id: '1339'
        :name: South Africa (Republ
        :minute_price: 0.3
        :prefix: '2773'
      - :internal_id: '1342'
        :name: South Africa (Republ
        :minute_price: 0.3
        :prefix: '2776'
      - :internal_id: '1349'
        :name: South Africa (Republ
        :minute_price: 0.3
        :prefix: '2782'
      - :internal_id: '1350'
        :name: South Africa (Republ
        :minute_price: 0.3
        :prefix: '2783'
      - :internal_id: '1351'
        :name: South Africa (Republ
        :minute_price: 0.3
        :prefix: '2784'
      - :internal_id: '1340'
        :name: South Africa (Republ
        :minute_price: 0.3
        :prefix: '27741'
      - :internal_id: '1341'
        :name: South Africa (Republ
        :minute_price: 0.3
        :prefix: '27742'
      - :internal_id: '1343'
        :name: South Africa (Republ
        :minute_price: 0.3
        :prefix: '27781'
      - :internal_id: '1344'
        :name: South Africa (Republ
        :minute_price: 0.3
        :prefix: '27782'
      - :internal_id: '1345'
        :name: South Africa (Republ
        :minute_price: 0.3
        :prefix: '27783'
      - :internal_id: '1346'
        :name: South Africa (Republ
        :minute_price: 0.3
        :prefix: '27784'
      - :internal_id: '1347'
        :name: South Africa (Republ
        :minute_price: 0.3
        :prefix: '27791'
      - :internal_id: '1348'
        :name: South Africa (Republ
        :minute_price: 0.3
        :prefix: '27792'
      - :internal_id: '1352'
        :name: South Africa (Republ
        :minute_price: 0.3
        :prefix: '27850'
      - :internal_id: '1353'
        :name: South Africa (Republ
        :minute_price: 0.3
        :prefix: '27851'
      - :internal_id: '1354'
        :name: South Africa (Republ
        :minute_price: 0.3
        :prefix: '27852'
      - :internal_id: '1355'
        :name: South Africa (Republ
        :minute_price: 0.3
        :prefix: '27853'
      - :internal_id: '1443'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34'
      - :internal_id: '1444'
        :name: Spain
        :minute_price: 0.36
        :prefix: '346'
      - :internal_id: '1445'
        :name: Spain
        :minute_price: 0.39
        :prefix: '34600'
      - :internal_id: '1446'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34605'
      - :internal_id: '1447'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34606'
      - :internal_id: '1448'
        :name: Spain
        :minute_price: 0.39
        :prefix: '34607'
      - :internal_id: '1449'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34608'
      - :internal_id: '1450'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34609'
      - :internal_id: '1451'
        :name: Spain
        :minute_price: 0.39
        :prefix: '34610'
      - :internal_id: '1452'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34615'
      - :internal_id: '1453'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34616'
      - :internal_id: '1454'
        :name: Spain
        :minute_price: 0.39
        :prefix: '34617'
      - :internal_id: '1455'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34618'
      - :internal_id: '1456'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34619'
      - :internal_id: '1457'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34620'
      - :internal_id: '1458'
        :name: Spain
        :minute_price: 0.35
        :prefix: '34622'
      - :internal_id: '1459'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34625'
      - :internal_id: '1460'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34626'
      - :internal_id: '1461'
        :name: Spain
        :minute_price: 0.39
        :prefix: '34627'
      - :internal_id: '1462'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34628'
      - :internal_id: '1463'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34629'
      - :internal_id: '1464'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34630'
      - :internal_id: '1465'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34635'
      - :internal_id: '1466'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34636'
      - :internal_id: '1467'
        :name: Spain
        :minute_price: 0.39
        :prefix: '34637'
      - :internal_id: '1468'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34638'
      - :internal_id: '1469'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34639'
      - :internal_id: '1470'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34645'
      - :internal_id: '1471'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34646'
      - :internal_id: '1472'
        :name: Spain
        :minute_price: 0.39
        :prefix: '34647'
      - :internal_id: '1473'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34648'
      - :internal_id: '1474'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34649'
      - :internal_id: '1475'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34650'
      - :internal_id: '1476'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34651'
      - :internal_id: '1477'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34652'
      - :internal_id: '1478'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34653'
      - :internal_id: '1479'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34654'
      - :internal_id: '1480'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34655'
      - :internal_id: '1481'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34656'
      - :internal_id: '1482'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34657'
      - :internal_id: '1483'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34658'
      - :internal_id: '1484'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34659'
      - :internal_id: '1485'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34660'
      - :internal_id: '1486'
        :name: Spain
        :minute_price: 0.39
        :prefix: '34661'
      - :internal_id: '1487'
        :name: Spain
        :minute_price: 0.39
        :prefix: '34662'
      - :internal_id: '1488'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34665'
      - :internal_id: '1489'
        :name: Spain
        :minute_price: 0.39
        :prefix: '34666'
      - :internal_id: '1490'
        :name: Spain
        :minute_price: 0.39
        :prefix: '34667'
      - :internal_id: '1491'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34669'
      - :internal_id: '1492'
        :name: Spain
        :minute_price: 0.39
        :prefix: '34670'
      - :internal_id: '1493'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34675'
      - :internal_id: '1494'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34676'
      - :internal_id: '1495'
        :name: Spain
        :minute_price: 0.39
        :prefix: '34677'
      - :internal_id: '1496'
        :name: Spain
        :minute_price: 0.39
        :prefix: '34678'
      - :internal_id: '1497'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34679'
      - :internal_id: '1498'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34680'
      - :internal_id: '1499'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34685'
      - :internal_id: '1500'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34686'
      - :internal_id: '1501'
        :name: Spain
        :minute_price: 0.39
        :prefix: '34687'
      - :internal_id: '1502'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34689'
      - :internal_id: '1503'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34690'
      - :internal_id: '1504'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34692'
      - :internal_id: '1505'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34695'
      - :internal_id: '1506'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34696'
      - :internal_id: '1507'
        :name: Spain
        :minute_price: 0.39
        :prefix: '34697'
      - :internal_id: '1508'
        :name: Spain
        :minute_price: 0.36
        :prefix: '34699'
      - :internal_id: '2363'
        :name: Sri Lanka (Democrati
        :minute_price: 0.2
        :prefix: '94'
      - :internal_id: '1310'
        :name: Sudan (Republic of t
        :minute_price: 0.27
        :prefix: '249'
      - :internal_id: '2234'
        :name: Suriname (Republic o
        :minute_price: 0.37
        :prefix: '597'
      - :internal_id: '1332'
        :name: Swaziland (Kingdom o
        :minute_price: 0.24
        :prefix: '268'
      - :internal_id: '1333'
        :name: Swaziland (Kingdom o
        :minute_price: 0.36
        :prefix: '2686'
      - :internal_id: '1817'
        :name: Sweden
        :minute_price: 0.03
        :prefix: '46'
      - :internal_id: '1838'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '4670'
      - :internal_id: '1839'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '4673'
      - :internal_id: '1840'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '4674'
      - :internal_id: '1841'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '4676'
      - :internal_id: '1818'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '46102'
      - :internal_id: '1819'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '46103'
      - :internal_id: '1820'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '46104'
      - :internal_id: '1821'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '46105'
      - :internal_id: '1822'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '46106'
      - :internal_id: '1823'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '46107'
      - :internal_id: '1824'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '46124'
      - :internal_id: '1825'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '46126'
      - :internal_id: '1826'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '46127'
      - :internal_id: '1827'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '46129'
      - :internal_id: '1828'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '46252'
      - :internal_id: '1829'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '46308'
      - :internal_id: '1830'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '46376'
      - :internal_id: '1831'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '46518'
      - :internal_id: '1832'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '46519'
      - :internal_id: '1833'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '46665'
      - :internal_id: '1834'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '46673'
      - :internal_id: '1835'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '46674'
      - :internal_id: '1836'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '46675'
      - :internal_id: '1837'
        :name: Sweden
        :minute_price: 0.33
        :prefix: '46676'
      - :internal_id: '1581'
        :name: Switzerland (Confede
        :minute_price: 0.04
        :prefix: '41'
      - :internal_id: '1582'
        :name: Switzerland (Confede
        :minute_price: 0.04
        :prefix: '411'
      - :internal_id: '1583'
        :name: Switzerland (Confede
        :minute_price: 0.04
        :prefix: '4122'
      - :internal_id: '1584'
        :name: Switzerland (Confede
        :minute_price: 0.04
        :prefix: '4143'
      - :internal_id: '1585'
        :name: Switzerland (Confede
        :minute_price: 0.04
        :prefix: '4144'
      - :internal_id: '1586'
        :name: Switzerland (Confede
        :minute_price: 0.43
        :prefix: '4176'
      - :internal_id: '1587'
        :name: Switzerland (Confede
        :minute_price: 0.43
        :prefix: '4177'
      - :internal_id: '1588'
        :name: Switzerland (Confede
        :minute_price: 0.43
        :prefix: '4178'
      - :internal_id: '1589'
        :name: Switzerland (Confede
        :minute_price: 0.43
        :prefix: '4179'
      - :internal_id: '2368'
        :name: Syrian Arab Republic
        :minute_price: 0.46
        :prefix: '963'
      - :internal_id: '2355'
        :name: Taiwan
        :minute_price: 0.03
        :prefix: '886'
      - :internal_id: '2356'
        :name: Taiwan
        :minute_price: 0.03
        :prefix: '8862'
      - :internal_id: '2357'
        :name: Taiwan
        :minute_price: 0.13
        :prefix: '8869'
      - :internal_id: '2393'
        :name: Tajikistan (Republic
        :minute_price: 0.26
        :prefix: '992'
      - :internal_id: '1316'
        :name: Tanzania (United Rep
        :minute_price: 0.34
        :prefix: '255'
      - :internal_id: '2254'
        :name: Thailand
        :minute_price: 0.06
        :prefix: '66'
      - :internal_id: '2255'
        :name: Thailand
        :minute_price: 0.13
        :prefix: '661'
      - :internal_id: '2256'
        :name: Thailand
        :minute_price: 0.04
        :prefix: '662'
      - :internal_id: '2257'
        :name: Thailand
        :minute_price: 0.13
        :prefix: '668'
      - :internal_id: '2258'
        :name: Thailand
        :minute_price: 0.13
        :prefix: '669'
      - :internal_id: '1280'
        :name: Togolese Republic
        :minute_price: 0.26
        :prefix: '228'
      - :internal_id: '2277'
        :name: Tokelau
        :minute_price: 1.22
        :prefix: '690'
      - :internal_id: '2264'
        :name: Tonga (Kingdom of)
        :minute_price: 0.41
        :prefix: '676'
      - :internal_id: '1268'
        :name: Tunisia
        :minute_price: 0.32
        :prefix: '216'
      - :internal_id: '2358'
        :name: Turkey
        :minute_price: 0.27
        :prefix: '90'
      - :internal_id: '2394'
        :name: Turkmenistan
        :minute_price: 0.22
        :prefix: '993'
      - :internal_id: '2275'
        :name: Tuvalu
        :minute_price: 1.16
        :prefix: '688'
      - :internal_id: '1317'
        :name: Uganda (Republic of)
        :minute_price: 0.19
        :prefix: '256'
      - :internal_id: '1567'
        :name: Ukraine
        :minute_price: 0.19
        :prefix: '380'
      - :internal_id: '2375'
        :name: United Arab Emirates
        :minute_price: 0.36
        :prefix: '971'
      - :internal_id: '1652'
        :name: United Kingdom of Gr
        :minute_price: 0.03
        :prefix: '44'
      - :internal_id: '1655'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447'
      - :internal_id: '1814'
        :name: United Kingdom of Gr
        :minute_price: 0.2
        :prefix: '448'
      - :internal_id: '1815'
        :name: United Kingdom of Gr
        :minute_price: 0.2
        :prefix: '449'
      - :internal_id: '1656'
        :name: United Kingdom of Gr
        :minute_price: 0.5
        :prefix: '4470'
      - :internal_id: '1653'
        :name: United Kingdom of Gr
        :minute_price: 0.03
        :prefix: '44207'
      - :internal_id: '1654'
        :name: United Kingdom of Gr
        :minute_price: 0.03
        :prefix: '44208'
      - :internal_id: '1657'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '44770'
      - :internal_id: '1658'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '44771'
      - :internal_id: '1659'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '44772'
      - :internal_id: '1660'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '44773'
      - :internal_id: '1679'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '44776'
      - :internal_id: '1689'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '44778'
      - :internal_id: '1699'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '44780'
      - :internal_id: '1700'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '44781'
      - :internal_id: '1718'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '44784'
      - :internal_id: '1742'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '44788'
      - :internal_id: '1661'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447740'
      - :internal_id: '1662'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447741'
      - :internal_id: '1663'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447742'
      - :internal_id: '1664'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447743'
      - :internal_id: '1665'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447745'
      - :internal_id: '1666'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447746'
      - :internal_id: '1667'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447747'
      - :internal_id: '1668'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447748'
      - :internal_id: '1669'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447749'
      - :internal_id: '1670'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447750'
      - :internal_id: '1671'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447751'
      - :internal_id: '1672'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447752'
      - :internal_id: '1673'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447753'
      - :internal_id: '1674'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447754'
      - :internal_id: '1675'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447756'
      - :internal_id: '1676'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447757'
      - :internal_id: '1677'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447758'
      - :internal_id: '1678'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447759'
      - :internal_id: '1680'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447770'
      - :internal_id: '1681'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447771'
      - :internal_id: '1682'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447772'
      - :internal_id: '1683'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447773'
      - :internal_id: '1684'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447774'
      - :internal_id: '1685'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447775'
      - :internal_id: '1686'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447776'
      - :internal_id: '1687'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447778'
      - :internal_id: '1688'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447779'
      - :internal_id: '1690'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447790'
      - :internal_id: '1691'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447791'
      - :internal_id: '1692'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447792'
      - :internal_id: '1693'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447793'
      - :internal_id: '1694'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447794'
      - :internal_id: '1695'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447795'
      - :internal_id: '1696'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447796'
      - :internal_id: '1697'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447798'
      - :internal_id: '1698'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447799'
      - :internal_id: '1701'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447820'
      - :internal_id: '1702'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447821'
      - :internal_id: '1703'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447823'
      - :internal_id: '1704'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447824'
      - :internal_id: '1705'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447825'
      - :internal_id: '1706'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447826'
      - :internal_id: '1707'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447827'
      - :internal_id: '1708'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447828'
      - :internal_id: '1709'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447830'
      - :internal_id: '1710'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447831'
      - :internal_id: '1711'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447832'
      - :internal_id: '1712'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447833'
      - :internal_id: '1713'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447834'
      - :internal_id: '1714'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447835'
      - :internal_id: '1715'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447836'
      - :internal_id: '1716'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447837'
      - :internal_id: '1717'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447838'
      - :internal_id: '1719'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447850'
      - :internal_id: '1720'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447851'
      - :internal_id: '1721'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447852'
      - :internal_id: '1722'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447853'
      - :internal_id: '1723'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447854'
      - :internal_id: '1724'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447855'
      - :internal_id: '1725'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447859'
      - :internal_id: '1726'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447860'
      - :internal_id: '1727'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447861'
      - :internal_id: '1728'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447862'
      - :internal_id: '1729'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447863'
      - :internal_id: '1730'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447865'
      - :internal_id: '1731'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447866'
      - :internal_id: '1732'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447867'
      - :internal_id: '1733'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447868'
      - :internal_id: '1734'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447869'
      - :internal_id: '1735'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447870'
      - :internal_id: '1736'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447871'
      - :internal_id: '1737'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447875'
      - :internal_id: '1738'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447876'
      - :internal_id: '1739'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447877'
      - :internal_id: '1740'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447878'
      - :internal_id: '1741'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447879'
      - :internal_id: '1743'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447890'
      - :internal_id: '1744'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447891'
      - :internal_id: '1745'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447896'
      - :internal_id: '1746'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447897'
      - :internal_id: '1747'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447898'
      - :internal_id: '1748'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447899'
      - :internal_id: '1749'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447900'
      - :internal_id: '1750'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447901'
      - :internal_id: '1751'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447903'
      - :internal_id: '1752'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447904'
      - :internal_id: '1753'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447905'
      - :internal_id: '1754'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447906'
      - :internal_id: '1755'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447908'
      - :internal_id: '1756'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447909'
      - :internal_id: '1757'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447910'
      - :internal_id: '1758'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447913'
      - :internal_id: '1759'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447914'
      - :internal_id: '1760'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447915'
      - :internal_id: '1761'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447916'
      - :internal_id: '1762'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447917'
      - :internal_id: '1763'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447918'
      - :internal_id: '1764'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447919'
      - :internal_id: '1765'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447920'
      - :internal_id: '1766'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447921'
      - :internal_id: '1767'
        :name: United Kingdom of Gr
        :minute_price: 0.25
        :prefix: '447922'
      - :internal_id: '1768'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447929'
      - :internal_id: '1769'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447930'
      - :internal_id: '1770'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447931'
      - :internal_id: '1771'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447932'
      - :internal_id: '1772'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447933'
      - :internal_id: '1773'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447939'
      - :internal_id: '1774'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447940'
      - :internal_id: '1775'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447941'
      - :internal_id: '1776'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447944'
      - :internal_id: '1777'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447946'
      - :internal_id: '1778'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447947'
      - :internal_id: '1779'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447949'
      - :internal_id: '1780'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447950'
      - :internal_id: '1781'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447951'
      - :internal_id: '1782'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447952'
      - :internal_id: '1783'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447953'
      - :internal_id: '1784'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447955'
      - :internal_id: '1785'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447956'
      - :internal_id: '1786'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447957'
      - :internal_id: '1787'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447958'
      - :internal_id: '1788'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447959'
      - :internal_id: '1789'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447960'
      - :internal_id: '1790'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447961'
      - :internal_id: '1791'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447962'
      - :internal_id: '1792'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447963'
      - :internal_id: '1793'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447966'
      - :internal_id: '1794'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447967'
      - :internal_id: '1795'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447968'
      - :internal_id: '1796'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447969'
      - :internal_id: '1797'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447970'
      - :internal_id: '1798'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447971'
      - :internal_id: '1799'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447973'
      - :internal_id: '1800'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447974'
      - :internal_id: '1801'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447976'
      - :internal_id: '1802'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447977'
      - :internal_id: '1803'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447979'
      - :internal_id: '1804'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447980'
      - :internal_id: '1805'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447981'
      - :internal_id: '1806'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447984'
      - :internal_id: '1807'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447985'
      - :internal_id: '1808'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447986'
      - :internal_id: '1809'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447987'
      - :internal_id: '1810'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447988'
      - :internal_id: '1811'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447989'
      - :internal_id: '1812'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447990'
      - :internal_id: '1813'
        :name: United Kingdom of Gr
        :minute_price: 0.27
        :prefix: '447999'
      - :internal_id: '2235'
        :name: Uruguay (Eastern Rep
        :minute_price: 0.32
        :prefix: '598'
      - :internal_id: '2405'
        :name: Uzbekistan (Republic
        :minute_price: 0.14
        :prefix: '998'
      - :internal_id: '2266'
        :name: Vanuatu (Republic of
        :minute_price: 0.93
        :prefix: '678'
      - :internal_id: '1566'
        :name: Vatican City
        :minute_price: 0.04
        :prefix: '379'
      - :internal_id: '2217'
        :name: Venezuela (Bolivaria
        :minute_price: 0.05
        :prefix: '58'
      - :internal_id: '2218'
        :name: Venezuela (Bolivaria
        :minute_price: 0.04
        :prefix: '58212'
      - :internal_id: '2219'
        :name: Venezuela (Bolivaria
        :minute_price: 0.04
        :prefix: '58241'
      - :internal_id: '2220'
        :name: Venezuela (Bolivaria
        :minute_price: 0.04
        :prefix: '58261'
      - :internal_id: '2221'
        :name: Venezuela (Bolivaria
        :minute_price: 0.26
        :prefix: '58412'
      - :internal_id: '2222'
        :name: Venezuela (Bolivaria
        :minute_price: 0.26
        :prefix: '58414'
      - :internal_id: '2223'
        :name: Venezuela (Bolivaria
        :minute_price: 0.26
        :prefix: '58415'
      - :internal_id: '2224'
        :name: Venezuela (Bolivaria
        :minute_price: 0.22
        :prefix: '58416'
      - :internal_id: '2225'
        :name: Venezuela (Bolivaria
        :minute_price: 0.26
        :prefix: '58417'
      - :internal_id: '2226'
        :name: Venezuela (Bolivaria
        :minute_price: 0.26
        :prefix: '58418'
      - :internal_id: '2340'
        :name: Viet Nam (Socialist
        :minute_price: 0.32
        :prefix: '84'
      - :internal_id: '2269'
        :name: Wallis and Futuna (T
        :minute_price: 1.33
        :prefix: '681'
      - :internal_id: '2372'
        :name: Yemen (Republic of)
        :minute_price: 0.25
        :prefix: '967'
      - :internal_id: '1321'
        :name: Zambia (Republic of)
        :minute_price: 0.11
        :prefix: '260'
      - :internal_id: '1322'
        :name: Zambia (Republic of)
        :minute_price: 0.24
        :prefix: '26095'
      - :internal_id: '1323'
        :name: Zambia (Republic of)
        :minute_price: 0.24
        :prefix: '26096'
      - :internal_id: '1324'
        :name: Zambia (Republic of)
        :minute_price: 0.24
        :prefix: '26097'
      - :internal_id: '1320'
        :name: Zanzibar
        :minute_price: 1.41
        :prefix: '259'
      - :internal_id: '1327'
        :name: Zimbabwe (Republic o
        :minute_price: 0.45
        :prefix: '263'
    1:
      :trunkTypeName: Mexicana
      :currencyId: 5
      :currencyName: MXN
      :rates:
      - :internal_id: '1208'
        :name: Afghanistan (Islamic
        :minute_price: 6.11
        :prefix: '93'
      - :internal_id: '582'
        :name: Albania (Republic of
        :minute_price: 4.16
        :prefix: '355'
      - :internal_id: '329'
        :name: Algeria (People''s De
        :minute_price: 3.25
        :prefix: '213'
      - :internal_id: '193'
        :name: American Samoa
        :minute_price: 1.69
        :prefix: '1684'
      - :internal_id: '617'
        :name: Andorra (Principalit
        :minute_price: 1.04
        :prefix: '376'
      - :internal_id: '618'
        :name: Andorra (Principalit
        :minute_price: 5.46
        :prefix: '3763'
      - :internal_id: '619'
        :name: Andorra (Principalit
        :minute_price: 5.46
        :prefix: '3764'
      - :internal_id: '620'
        :name: Andorra (Principalit
        :minute_price: 5.46
        :prefix: '3766'
      - :internal_id: '367'
        :name: Angola (Republic of)
        :minute_price: 4.81
        :prefix: '244'
      - :internal_id: '38'
        :name: Anguilla
        :minute_price: 6.11
        :prefix: '1264'
      - :internal_id: '40'
        :name: Antigua and Barbuda
        :minute_price: 4.29
        :prefix: '1268'
      - :internal_id: '1004'
        :name: Argentine Republic
        :minute_price: 0.52
        :prefix: '54'
      - :internal_id: '1028'
        :name: Argentine Republic
        :minute_price: 4.03
        :prefix: '549'
      - :internal_id: '1005'
        :name: Argentine Republic
        :minute_price: 0.26
        :prefix: '5411'
      - :internal_id: '1006'
        :name: Argentine Republic
        :minute_price: 0.26
        :prefix: '54221'
      - :internal_id: '1007'
        :name: Argentine Republic
        :minute_price: 0.26
        :prefix: '54223'
      - :internal_id: '1009'
        :name: Argentine Republic
        :minute_price: 0.52
        :prefix: '54230'
      - :internal_id: '1010'
        :name: Argentine Republic
        :minute_price: 0.39
        :prefix: '54232'
      - :internal_id: '1012'
        :name: Argentine Republic
        :minute_price: 0.52
        :prefix: '54237'
      - :internal_id: '1013'
        :name: Argentine Republic
        :minute_price: 0.26
        :prefix: '54261'
      - :internal_id: '1015'
        :name: Argentine Republic
        :minute_price: 0.39
        :prefix: '54291'
      - :internal_id: '1016'
        :name: Argentine Republic
        :minute_price: 0.52
        :prefix: '54299'
      - :internal_id: '1017'
        :name: Argentine Republic
        :minute_price: 0.26
        :prefix: '54341'
      - :internal_id: '1018'
        :name: Argentine Republic
        :minute_price: 0.52
        :prefix: '54342'
      - :internal_id: '1019'
        :name: Argentine Republic
        :minute_price: 0.39
        :prefix: '54348'
      - :internal_id: '1020'
        :name: Argentine Republic
        :minute_price: 0.26
        :prefix: '54351'
      - :internal_id: '1021'
        :name: Argentine Republic
        :minute_price: 0.52
        :prefix: '54353'
      - :internal_id: '1022'
        :name: Argentine Republic
        :minute_price: 0.52
        :prefix: '54354'
      - :internal_id: '1023'
        :name: Argentine Republic
        :minute_price: 0.52
        :prefix: '54358'
      - :internal_id: '1026'
        :name: Argentine Republic
        :minute_price: 0.52
        :prefix: '54381'
      - :internal_id: '1027'
        :name: Argentine Republic
        :minute_price: 0.52
        :prefix: '54387'
      - :internal_id: '1008'
        :name: Argentine Republic
        :minute_price: 0.52
        :prefix: '542293'
      - :internal_id: '1011'
        :name: Argentine Republic
        :minute_price: 0.52
        :prefix: '542362'
      - :internal_id: '1014'
        :name: Argentine Republic
        :minute_price: 0.52
        :prefix: '542652'
      - :internal_id: '1024'
        :name: Argentine Republic
        :minute_price: 0.52
        :prefix: '543722'
      - :internal_id: '1025'
        :name: Argentine Republic
        :minute_price: 0.52
        :prefix: '543752'
      - :internal_id: '613'
        :name: Armenia (Republic of
        :minute_price: 1.95
        :prefix: '374'
      - :internal_id: '614'
        :name: Armenia (Republic of
        :minute_price: 1.17
        :prefix: '3741'
      - :internal_id: '615'
        :name: Armenia (Republic of
        :minute_price: 4.29
        :prefix: '3749'
      - :internal_id: '420'
        :name: Aruba
        :minute_price: 4.42
        :prefix: '297'
      - :internal_id: '370'
        :name: Ascension
        :minute_price: 18.2
        :prefix: '247'
      - :internal_id: '1084'
        :name: Australia
        :minute_price: 0.39
        :prefix: '61'
      - :internal_id: '1094'
        :name: Australia
        :minute_price: 3.51
        :prefix: '614'
      - :internal_id: '1085'
        :name: Australia
        :minute_price: 3.51
        :prefix: '6114'
      - :internal_id: '1086'
        :name: Australia
        :minute_price: 3.51
        :prefix: '6115'
      - :internal_id: '1087'
        :name: Australia
        :minute_price: 3.51
        :prefix: '6117'
      - :internal_id: '1088'
        :name: Australia
        :minute_price: 3.51
        :prefix: '6118'
      - :internal_id: '1089'
        :name: Australia
        :minute_price: 3.51
        :prefix: '6119'
      - :internal_id: '1090'
        :name: Australia
        :minute_price: 0.39
        :prefix: '6128'
      - :internal_id: '1091'
        :name: Australia
        :minute_price: 0.39
        :prefix: '6129'
      - :internal_id: '1092'
        :name: Australia
        :minute_price: 0.39
        :prefix: '6138'
      - :internal_id: '1093'
        :name: Australia
        :minute_price: 0.39
        :prefix: '6139'
      - :internal_id: '1106'
        :name: Australian External
        :minute_price: 13.13
        :prefix: '672'
      - :internal_id: '694'
        :name: Austria
        :minute_price: 0.52
        :prefix: '43'
      - :internal_id: '695'
        :name: Austria
        :minute_price: 0.52
        :prefix: '431'
      - :internal_id: '713'
        :name: Austria
        :minute_price: 3.9
        :prefix: '438'
      - :internal_id: '696'
        :name: Austria
        :minute_price: 4.55
        :prefix: '43650'
      - :internal_id: '697'
        :name: Austria
        :minute_price: 4.55
        :prefix: '43660'
      - :internal_id: '698'
        :name: Austria
        :minute_price: 3.38
        :prefix: '43664'
      - :internal_id: '699'
        :name: Austria
        :minute_price: 4.55
        :prefix: '43676'
      - :internal_id: '700'
        :name: Austria
        :minute_price: 4.55
        :prefix: '43677'
      - :internal_id: '701'
        :name: Austria
        :minute_price: 4.55
        :prefix: '43678'
      - :internal_id: '702'
        :name: Austria
        :minute_price: 4.55
        :prefix: '43680'
      - :internal_id: '703'
        :name: Austria
        :minute_price: 4.55
        :prefix: '43681'
      - :internal_id: '704'
        :name: Austria
        :minute_price: 4.55
        :prefix: '43688'
      - :internal_id: '705'
        :name: Austria
        :minute_price: 4.55
        :prefix: '43699'
      - :internal_id: '708'
        :name: Austria
        :minute_price: 4.55
        :prefix: '43711'
      - :internal_id: '709'
        :name: Austria
        :minute_price: 4.55
        :prefix: '43720'
      - :internal_id: '710'
        :name: Austria
        :minute_price: 4.55
        :prefix: '43730'
      - :internal_id: '711'
        :name: Austria
        :minute_price: 4.55
        :prefix: '43740'
      - :internal_id: '712'
        :name: Austria
        :minute_price: 4.55
        :prefix: '43780'
      - :internal_id: '706'
        :name: Austria
        :minute_price: 4.55
        :prefix: '4369988'
      - :internal_id: '707'
        :name: Austria
        :minute_price: 4.55
        :prefix: '4369989'
      - :internal_id: '1241'
        :name: Azerbaijani Republic
        :minute_price: 3.51
        :prefix: '994'
      - :internal_id: '27'
        :name: Bahamas (Commonwealt
        :minute_price: 1.17
        :prefix: '1242'
      - :internal_id: '1233'
        :name: Bahrain (State of)
        :minute_price: 2.99
        :prefix: '973'
      - :internal_id: '1198'
        :name: Bangladesh (People''s
        :minute_price: 1.56
        :prefix: '880'
      - :internal_id: '28'
        :name: Barbados
        :minute_price: 5.2
        :prefix: '1246'
      - :internal_id: '616'
        :name: Belarus (Republic of
        :minute_price: 4.94
        :prefix: '375'
      - :internal_id: '468'
        :name: Belgium
        :minute_price: 0.52
        :prefix: '32'
      - :internal_id: '469'
        :name: Belgium
        :minute_price: 4.81
        :prefix: '3247'
      - :internal_id: '470'
        :name: Belgium
        :minute_price: 5.46
        :prefix: '3248'
      - :internal_id: '471'
        :name: Belgium
        :minute_price: 5.72
        :prefix: '3249'
      - :internal_id: '924'
        :name: Belize
        :minute_price: 5.2
        :prefix: '501'
      - :internal_id: '343'
        :name: Benin (Republic of)
        :minute_price: 1.82
        :prefix: '229'
      - :internal_id: '107'
        :name: Bermuda
        :minute_price: 2.08
        :prefix: '1441'
      - :internal_id: '1235'
        :name: Bhutan (Kingdom of)
        :minute_price: 3.77
        :prefix: '975'
      - :internal_id: '1074'
        :name: Bolivia (Republic of
        :minute_price: 2.21
        :prefix: '591'
      - :internal_id: '633'
        :name: Bosnia and Herzegovi
        :minute_price: 6.11
        :prefix: '387'
      - :internal_id: '393'
        :name: Botswana (Republic o
        :minute_price: 4.29
        :prefix: '267'
      - :internal_id: '1029'
        :name: Brazil (Federative R
        :minute_price: 1.05
        :prefix: '55'
      - :internal_id: '1033'
        :name: Brazil (Federative R
        :minute_price: 2.6
        :prefix: '5501'
      - :internal_id: '1035'
        :name: Brazil (Federative R
        :minute_price: 0.39
        :prefix: '5511'
      - :internal_id: '1036'
        :name: Brazil (Federative R
        :minute_price: 0.65
        :prefix: '5519'
      - :internal_id: '1037'
        :name: Brazil (Federative R
        :minute_price: 0.39
        :prefix: '5521'
      - :internal_id: '1041'
        :name: Brazil (Federative R
        :minute_price: 0.52
        :prefix: '5527'
      - :internal_id: '1042'
        :name: Brazil (Federative R
        :minute_price: 0.52
        :prefix: '5531'
      - :internal_id: '1043'
        :name: Brazil (Federative R
        :minute_price: 0.65
        :prefix: '5533'
      - :internal_id: '1044'
        :name: Brazil (Federative R
        :minute_price: 0.52
        :prefix: '5541'
      - :internal_id: '1045'
        :name: Brazil (Federative R
        :minute_price: 0.65
        :prefix: '5543'
      - :internal_id: '1046'
        :name: Brazil (Federative R
        :minute_price: 0.65
        :prefix: '5544'
      - :internal_id: '1047'
        :name: Brazil (Federative R
        :minute_price: 0.65
        :prefix: '5548'
      - :internal_id: '1048'
        :name: Brazil (Federative R
        :minute_price: 0.52
        :prefix: '5551'
      - :internal_id: '1049'
        :name: Brazil (Federative R
        :minute_price: 0.52
        :prefix: '5561'
      - :internal_id: '1050'
        :name: Brazil (Federative R
        :minute_price: 0.65
        :prefix: '5562'
      - :internal_id: '1051'
        :name: Brazil (Federative R
        :minute_price: 0.78
        :prefix: '5567'
      - :internal_id: '1052'
        :name: Brazil (Federative R
        :minute_price: 0.52
        :prefix: '5571'
      - :internal_id: '1053'
        :name: Brazil (Federative R
        :minute_price: 0.52
        :prefix: '5581'
      - :internal_id: '1054'
        :name: Brazil (Federative R
        :minute_price: 0.52
        :prefix: '5585'
      - :internal_id: '1055'
        :name: Brazil (Federative R
        :minute_price: 0.65
        :prefix: '5591'
      - :internal_id: '1030'
        :name: Brazil (Federative R
        :minute_price: 2.6
        :prefix: '55007'
      - :internal_id: '1031'
        :name: Brazil (Federative R
        :minute_price: 2.6
        :prefix: '55008'
      - :internal_id: '1032'
        :name: Brazil (Federative R
        :minute_price: 2.6
        :prefix: '55009'
      - :internal_id: '1034'
        :name: Brazil (Federative R
        :minute_price: 2.6
        :prefix: '55017'
      - :internal_id: '1038'
        :name: Brazil (Federative R
        :minute_price: 2.21
        :prefix: '55217'
      - :internal_id: '1039'
        :name: Brazil (Federative R
        :minute_price: 2.21
        :prefix: '55218'
      - :internal_id: '1040'
        :name: Brazil (Federative R
        :minute_price: 2.21
        :prefix: '55219'
      - :internal_id: '45'
        :name: British Virgin Islan
        :minute_price: 3.64
        :prefix: '1284'
      - :internal_id: '1107'
        :name: Brunei Darussalam
        :minute_price: 0.91
        :prefix: '673'
      - :internal_id: '586'
        :name: Bulgaria (Republic o
        :minute_price: 5.98
        :prefix: '359'
      - :internal_id: '340'
        :name: Burkina Faso
        :minute_price: 4.55
        :prefix: '226'
      - :internal_id: '380'
        :name: Burundi (Republic of
        :minute_price: 1.82
        :prefix: '257'
      - :internal_id: '1190'
        :name: Cambodia (Kingdom of
        :minute_price: 3.38
        :prefix: '855'
      - :internal_id: '360'
        :name: Cameroon (Republic o
        :minute_price: 3.9
        :prefix: '237'
      - :internal_id: '231'
        :name: Canada - Alberta
        :minute_price: 0.84
        :prefix: '1780'
      - :internal_id: '84'
        :name: Canada - Alberta (so
        :minute_price: 0.84
        :prefix: '1403'
      - :internal_id: '30'
        :name: Canada - British Col
        :minute_price: 0.84
        :prefix: '1250'
      - :internal_id: '158'
        :name: Canada - British Col
        :minute_price: 0.84
        :prefix: '1604'
      - :internal_id: '230'
        :name: Canada - British Col
        :minute_price: 0.84
        :prefix: '1778'
      - :internal_id: '4'
        :name: Canada - Manitoba
        :minute_price: 0.84
        :prefix: '1204'
      - :internal_id: '130'
        :name: Canada - Montreal
        :minute_price: 0.84
        :prefix: '1514'
      - :internal_id: '123'
        :name: Canada - New Brunswi
        :minute_price: 0.84
        :prefix: '1506'
      - :internal_id: '203'
        :name: Canada - Newfoundlan
        :minute_price: 0.84
        :prefix: '1709'
      - :internal_id: '281'
        :name: Canada - Nova Scotia
        :minute_price: 0.84
        :prefix: '1902'
      - :internal_id: '135'
        :name: Canada - Ontario
        :minute_price: 0.84
        :prefix: '1519'
      - :internal_id: '166'
        :name: Canada - Ontario
        :minute_price: 0.84
        :prefix: '1613'
      - :internal_id: '199'
        :name: Canada - Ontario
        :minute_price: 0.84
        :prefix: '1705'
      - :internal_id: '243'
        :name: Canada - Ontario
        :minute_price: 0.84
        :prefix: '1807'
      - :internal_id: '96'
        :name: Canada - Ontario (To
        :minute_price: 0.84
        :prefix: '1416'
      - :internal_id: '110'
        :name: Canada - Quebec
        :minute_price: 0.84
        :prefix: '1450'
      - :internal_id: '254'
        :name: Canada - Quebec
        :minute_price: 0.84
        :prefix: '1819'
      - :internal_id: '98'
        :name: Canada - Quebec (Que
        :minute_price: 0.84
        :prefix: '1418'
      - :internal_id: '52'
        :name: Canada - Saskatchewa
        :minute_price: 0.84
        :prefix: '1306'
      - :internal_id: '46'
        :name: Canada - Toronto (On
        :minute_price: 0.84
        :prefix: '1289'
      - :internal_id: '181'
        :name: Canada - Toronto (On
        :minute_price: 0.84
        :prefix: '1647'
      - :internal_id: '284'
        :name: Canada - Toronto (On
        :minute_price: 0.84
        :prefix: '1905'
      - :internal_id: '274'
        :name: Canada - Yukon & NW
        :minute_price: 0.84
        :prefix: '1867'
      - :internal_id: '361'
        :name: Cape Verde (Republic
        :minute_price: 6.11
        :prefix: '238'
      - :internal_id: '359'
        :name: Central African Repu
        :minute_price: 2.6
        :prefix: '236'
      - :internal_id: '358'
        :name: Chad (Republic of)
        :minute_price: 6.63
        :prefix: '235'
      - :internal_id: '1056'
        :name: Chile
        :minute_price: 0.91
        :prefix: '56'
      - :internal_id: '1057'
        :name: Chile
        :minute_price: 0.39
        :prefix: '562'
      - :internal_id: '1058'
        :name: Chile
        :minute_price: 0.52
        :prefix: '56321'
      - :internal_id: '1059'
        :name: Chile
        :minute_price: 3.51
        :prefix: '565697'
      - :internal_id: '1060'
        :name: Chile
        :minute_price: 3.51
        :prefix: '565698'
      - :internal_id: '1061'
        :name: Chile
        :minute_price: 3.51
        :prefix: '565699'
      - :internal_id: '1192'
        :name: China (People''s Repu
        :minute_price: 0.39
        :prefix: '86'
      - :internal_id: '1062'
        :name: Colombia (Republic o
        :minute_price: 1.95
        :prefix: '57'
      - :internal_id: '396'
        :name: Comoros (Islamic Fed
        :minute_price: 8.84
        :prefix: '269'
      - :internal_id: '365'
        :name: Congo-Brazzaville (R
        :minute_price: 2.86
        :prefix: '242'
      - :internal_id: '366'
        :name: Congo-Kinshasa (Demo
        :minute_price: 6.37
        :prefix: '243'
      - :internal_id: '1116'
        :name: Cook Islands
        :minute_price: 19.5
        :prefix: '682'
      - :internal_id: '929'
        :name: Costa Rica
        :minute_price: 1.56
        :prefix: '506'
      - :internal_id: '339'
        :name: Cote d''Ivoire (Repub
        :minute_price: 3.51
        :prefix: '225'
      - :internal_id: '631'
        :name: Croatia (Republic of
        :minute_price: 4.29
        :prefix: '385'
      - :internal_id: '971'
        :name: Cuba
        :minute_price: 16.9
        :prefix: '53'
      - :internal_id: '1002'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '538'
      - :internal_id: '993'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '5375'
      - :internal_id: '1003'
        :name: Cuba
        :minute_price: 16.12
        :prefix: '5399'
      - :internal_id: '972'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '53213'
      - :internal_id: '973'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '53226'
      - :internal_id: '974'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '53234'
      - :internal_id: '975'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '53244'
      - :internal_id: '976'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '53246'
      - :internal_id: '977'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '53314'
      - :internal_id: '978'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '53322'
      - :internal_id: '979'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '53333'
      - :internal_id: '980'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '53412'
      - :internal_id: '981'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '53419'
      - :internal_id: '982'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '53422'
      - :internal_id: '983'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '53423'
      - :internal_id: '984'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '53522'
      - :internal_id: '985'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '53561'
      - :internal_id: '986'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '53567'
      - :internal_id: '987'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '53613'
      - :internal_id: '992'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '53728'
      - :internal_id: '994'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '53751'
      - :internal_id: '995'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '53756'
      - :internal_id: '988'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '537263'
      - :internal_id: '989'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '537264'
      - :internal_id: '990'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '537268'
      - :internal_id: '991'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '537270'
      - :internal_id: '996'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '537880'
      - :internal_id: '997'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '537885'
      - :internal_id: '998'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '537886'
      - :internal_id: '999'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '537890'
      - :internal_id: '1000'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '537891'
      - :internal_id: '1001'
        :name: Cuba
        :minute_price: 18.85
        :prefix: '537892'
      - :internal_id: '584'
        :name: Cyprus (Republic of)
        :minute_price: 1.17
        :prefix: '357'
      - :internal_id: '652'
        :name: Czech Republic
        :minute_price: 0.52
        :prefix: '420'
      - :internal_id: '653'
        :name: Czech Republic
        :minute_price: 0.52
        :prefix: '4202'
      - :internal_id: '662'
        :name: Czech Republic
        :minute_price: 3.77
        :prefix: '42072'
      - :internal_id: '663'
        :name: Czech Republic
        :minute_price: 3.77
        :prefix: '42073'
      - :internal_id: '664'
        :name: Czech Republic
        :minute_price: 3.77
        :prefix: '42077'
      - :internal_id: '665'
        :name: Czech Republic
        :minute_price: 3.77
        :prefix: '42093'
      - :internal_id: '654'
        :name: Czech Republic
        :minute_price: 3.77
        :prefix: '420601'
      - :internal_id: '655'
        :name: Czech Republic
        :minute_price: 3.77
        :prefix: '420602'
      - :internal_id: '656'
        :name: Czech Republic
        :minute_price: 3.77
        :prefix: '420603'
      - :internal_id: '657'
        :name: Czech Republic
        :minute_price: 3.77
        :prefix: '420604'
      - :internal_id: '658'
        :name: Czech Republic
        :minute_price: 3.77
        :prefix: '420605'
      - :internal_id: '659'
        :name: Czech Republic
        :minute_price: 3.77
        :prefix: '420606'
      - :internal_id: '660'
        :name: Czech Republic
        :minute_price: 3.77
        :prefix: '420607'
      - :internal_id: '661'
        :name: Czech Republic
        :minute_price: 3.77
        :prefix: '420608'
      - :internal_id: '666'
        :name: Czech Republic
        :minute_price: 3.77
        :prefix: '420961'
      - :internal_id: '667'
        :name: Czech Republic
        :minute_price: 3.77
        :prefix: '420962'
      - :internal_id: '668'
        :name: Czech Republic
        :minute_price: 3.77
        :prefix: '420963'
      - :internal_id: '669'
        :name: Czech Republic
        :minute_price: 3.77
        :prefix: '420964'
      - :internal_id: '670'
        :name: Czech Republic
        :minute_price: 3.77
        :prefix: '420965'
      - :internal_id: '671'
        :name: Czech Republic
        :minute_price: 3.77
        :prefix: '420966'
      - :internal_id: '878'
        :name: Denmark
        :minute_price: 4.03
        :prefix: '45'
      - :internal_id: '369'
        :name: Diego Garcia
        :minute_price: 28.99
        :prefix: '246'
      - :internal_id: '376'
        :name: Djibouti (Republic o
        :minute_price: 9.23
        :prefix: '253'
      - :internal_id: '224'
        :name: Dominica (Commonweal
        :minute_price: 6.37
        :prefix: '1767'
      - :internal_id: '245'
        :name: Dominican Republic
        :minute_price: 2.86
        :prefix: '1809'
      - :internal_id: '1105'
        :name: East Timor
        :minute_price: 14.3
        :prefix: '670'
      - :internal_id: '1076'
        :name: Ecuador
        :minute_price: 4.55
        :prefix: '593'
      - :internal_id: '327'
        :name: Egypt (Arab Republic
        :minute_price: 3.51
        :prefix: '20'
      - :internal_id: '926'
        :name: El Salvador (Republi
        :minute_price: 2.34
        :prefix: '503'
      - :internal_id: '1206'
        :name: Emergency
        :minute_price: 0
        :prefix: '911'
      - :internal_id: '363'
        :name: Equatorial Guinea (R
        :minute_price: 5.2
        :prefix: '240'
      - :internal_id: '419'
        :name: Eritrea
        :minute_price: 6.5
        :prefix: '291'
      - :internal_id: '604'
        :name: Estonia (Republic of
        :minute_price: 0.78
        :prefix: '372'
      - :internal_id: '374'
        :name: Ethiopia (Federal De
        :minute_price: 5.98
        :prefix: '251'
      - :internal_id: '923'
        :name: Falkland Islands (Ma
        :minute_price: 14.04
        :prefix: '500'
      - :internal_id: '421'
        :name: Faroe Islands
        :minute_price: 3.38
        :prefix: '298'
      - :internal_id: '1113'
        :name: Fiji (Republic of)
        :minute_price: 5.33
        :prefix: '679'
      - :internal_id: '585'
        :name: Finland
        :minute_price: 3.77
        :prefix: '358'
      - :internal_id: '472'
        :name: France
        :minute_price: 0.39
        :prefix: '33'
      - :internal_id: '473'
        :name: France
        :minute_price: 0.39
        :prefix: '331'
      - :internal_id: '474'
        :name: France
        :minute_price: 3.38
        :prefix: '336'
      - :internal_id: '485'
        :name: France
        :minute_price: 3.38
        :prefix: '3361'
      - :internal_id: '486'
        :name: France
        :minute_price: 3.38
        :prefix: '3362'
      - :internal_id: '501'
        :name: France
        :minute_price: 3.12
        :prefix: '3367'
      - :internal_id: '502'
        :name: France
        :minute_price: 3.12
        :prefix: '3368'
      - :internal_id: '481'
        :name: France
        :minute_price: 3.38
        :prefix: '33603'
      - :internal_id: '482'
        :name: France
        :minute_price: 3.12
        :prefix: '33607'
      - :internal_id: '483'
        :name: France
        :minute_price: 3.12
        :prefix: '33608'
      - :internal_id: '484'
        :name: France
        :minute_price: 3.38
        :prefix: '33609'
      - :internal_id: '487'
        :name: France
        :minute_price: 3.12
        :prefix: '33630'
      - :internal_id: '488'
        :name: France
        :minute_price: 3.12
        :prefix: '33631'
      - :internal_id: '489'
        :name: France
        :minute_price: 3.12
        :prefix: '33632'
      - :internal_id: '490'
        :name: France
        :minute_price: 3.12
        :prefix: '33633'
      - :internal_id: '491'
        :name: France
        :minute_price: 3.38
        :prefix: '33650'
      - :internal_id: '492'
        :name: France
        :minute_price: 3.38
        :prefix: '33660'
      - :internal_id: '493'
        :name: France
        :minute_price: 3.38
        :prefix: '33661'
      - :internal_id: '494'
        :name: France
        :minute_price: 3.38
        :prefix: '33662'
      - :internal_id: '495'
        :name: France
        :minute_price: 3.38
        :prefix: '33663'
      - :internal_id: '496'
        :name: France
        :minute_price: 3.38
        :prefix: '33664'
      - :internal_id: '497'
        :name: France
        :minute_price: 3.38
        :prefix: '33665'
      - :internal_id: '498'
        :name: France
        :minute_price: 3.38
        :prefix: '33666'
      - :internal_id: '499'
        :name: France
        :minute_price: 3.38
        :prefix: '33667'
      - :internal_id: '500'
        :name: France
        :minute_price: 3.38
        :prefix: '33668'
      - :internal_id: '503'
        :name: France
        :minute_price: 3.38
        :prefix: '33698'
      - :internal_id: '504'
        :name: France
        :minute_price: 3.38
        :prefix: '33699'
      - :internal_id: '475'
        :name: France
        :minute_price: 3.38
        :prefix: '336001'
      - :internal_id: '476'
        :name: France
        :minute_price: 3.38
        :prefix: '336002'
      - :internal_id: '477'
        :name: France
        :minute_price: 3.38
        :prefix: '336003'
      - :internal_id: '478'
        :name: France
        :minute_price: 3.38
        :prefix: '336007'
      - :internal_id: '479'
        :name: France
        :minute_price: 3.38
        :prefix: '336008'
      - :internal_id: '480'
        :name: France
        :minute_price: 3.38
        :prefix: '336009'
      - :internal_id: '1077'
        :name: French Guiana (Frenc
        :minute_price: 4.55
        :prefix: '594'
      - :internal_id: '1122'
        :name: French Polynesia (Te
        :minute_price: 4.42
        :prefix: '689'
      - :internal_id: '364'
        :name: Gabonese Republic
        :minute_price: 1.95
        :prefix: '241'
      - :internal_id: '332'
        :name: Gambia (Republic of
        :minute_price: 5.85
        :prefix: '220'
      - :internal_id: '1242'
        :name: Georgia
        :minute_price: 1.43
        :prefix: '995'
      - :internal_id: '1243'
        :name: Georgia
        :minute_price: 1.3
        :prefix: '99532'
      - :internal_id: '1244'
        :name: Georgia
        :minute_price: 2.99
        :prefix: '99577'
      - :internal_id: '1245'
        :name: Georgia
        :minute_price: 2.99
        :prefix: '99593'
      - :internal_id: '1246'
        :name: Georgia
        :minute_price: 2.99
        :prefix: '99595'
      - :internal_id: '1247'
        :name: Georgia
        :minute_price: 2.99
        :prefix: '99597'
      - :internal_id: '1248'
        :name: Georgia
        :minute_price: 2.99
        :prefix: '99598'
      - :internal_id: '1249'
        :name: Georgia
        :minute_price: 2.99
        :prefix: '99599'
      - :internal_id: '916'
        :name: Germany (Federal Rep
        :minute_price: 0.39
        :prefix: '49'
      - :internal_id: '917'
        :name: Germany (Federal Rep
        :minute_price: 4.94
        :prefix: '4915'
      - :internal_id: '918'
        :name: Germany (Federal Rep
        :minute_price: 4.94
        :prefix: '4916'
      - :internal_id: '919'
        :name: Germany (Federal Rep
        :minute_price: 4.94
        :prefix: '4917'
      - :internal_id: '920'
        :name: Germany (Federal Rep
        :minute_price: 4.94
        :prefix: '4918'
      - :internal_id: '921'
        :name: Germany (Federal Rep
        :minute_price: 0.39
        :prefix: '4930'
      - :internal_id: '922'
        :name: Germany (Federal Rep
        :minute_price: 0.39
        :prefix: '4969'
      - :internal_id: '347'
        :name: Ghana
        :minute_price: 3.51
        :prefix: '233'
      - :internal_id: '571'
        :name: Gibraltar
        :minute_price: 6.5
        :prefix: '350'
      - :internal_id: '1199'
        :name: Global Mobile Satell
        :minute_price: 65.65
        :prefix: '881'
      - :internal_id: '423'
        :name: Greece
        :minute_price: 0.52
        :prefix: '30'
      - :internal_id: '424'
        :name: Greece
        :minute_price: 0.39
        :prefix: '3021'
      - :internal_id: '425'
        :name: Greece
        :minute_price: 0.52
        :prefix: '30231'
      - :internal_id: '426'
        :name: Greece
        :minute_price: 3.64
        :prefix: '30693'
      - :internal_id: '427'
        :name: Greece
        :minute_price: 3.64
        :prefix: '30694'
      - :internal_id: '428'
        :name: Greece
        :minute_price: 3.9
        :prefix: '30697'
      - :internal_id: '429'
        :name: Greece
        :minute_price: 3.9
        :prefix: '30699'
      - :internal_id: '422'
        :name: Greenland (Denmark)
        :minute_price: 9.88
        :prefix: '299'
      - :internal_id: '113'
        :name: Grenada and Carriaco
        :minute_price: 4.94
        :prefix: '1473'
      - :internal_id: '1073'
        :name: Guadeloupe (French D
        :minute_price: 5.72
        :prefix: '590'
      - :internal_id: '190'
        :name: Guam
        :minute_price: 0.52
        :prefix: '1671'
      - :internal_id: '925'
        :name: Guatemala (Republic
        :minute_price: 2.6
        :prefix: '502'
      - :internal_id: '338'
        :name: Guinea (Republic of)
        :minute_price: 2.73
        :prefix: '224'
      - :internal_id: '368'
        :name: Guinea-Bissau (Repub
        :minute_price: 16.9
        :prefix: '245'
      - :internal_id: '1075'
        :name: Guyana
        :minute_price: 5.85
        :prefix: '592'
      - :internal_id: '934'
        :name: Haiti (Republic of)
        :minute_price: 3.9
        :prefix: '509'
      - :internal_id: '936'
        :name: Haiti (Republic of)
        :minute_price: 4.68
        :prefix: '5093'
      - :internal_id: '937'
        :name: Haiti (Republic of)
        :minute_price: 5.07
        :prefix: '5094'
      - :internal_id: '938'
        :name: Haiti (Republic of)
        :minute_price: 5.33
        :prefix: '5095'
      - :internal_id: '939'
        :name: Haiti (Republic of)
        :minute_price: 4.94
        :prefix: '5097'
      - :internal_id: '935'
        :name: Haiti (Republic of)
        :minute_price: 3.9
        :prefix: '50921'
      - :internal_id: '927'
        :name: Honduras (Republic o
        :minute_price: 5.72
        :prefix: '504'
      - :internal_id: '1188'
        :name: Hong Kong (Special a
        :minute_price: 0.52
        :prefix: '852'
      - :internal_id: '587'
        :name: Hungary (Republic of
        :minute_price: 0.52
        :prefix: '36'
      - :internal_id: '588'
        :name: Hungary (Republic of
        :minute_price: 0.52
        :prefix: '361'
      - :internal_id: '589'
        :name: Hungary (Republic of
        :minute_price: 4.68
        :prefix: '3620'
      - :internal_id: '590'
        :name: Hungary (Republic of
        :minute_price: 4.68
        :prefix: '3630'
      - :internal_id: '591'
        :name: Hungary (Republic of
        :minute_price: 4.68
        :prefix: '3670'
      - :internal_id: '581'
        :name: Iceland
        :minute_price: 4.42
        :prefix: '354'
      - :internal_id: '1205'
        :name: India (Republic of)
        :minute_price: 2.6
        :prefix: '91'
      - :internal_id: '1095'
        :name: Indonesia (Republic
        :minute_price: 1.56
        :prefix: '62'
      - :internal_id: '1194'
        :name: Inmarsat Atlantic Oc
        :minute_price: 59.15
        :prefix: '871'
      - :internal_id: '1197'
        :name: Inmarsat Atlantic Oc
        :minute_price: 59.15
        :prefix: '874'
      - :internal_id: '1196'
        :name: Inmarsat Indian Ocea
        :minute_price: 72.8
        :prefix: '873'
      - :internal_id: '1195'
        :name: Inmarsat Pacific Oce
        :minute_price: 88.4
        :prefix: '872'
      - :internal_id: '1193'
        :name: Inmarsat Single Numb
        :minute_price: 52.52
        :prefix: '870'
      - :internal_id: '1200'
        :name: International Networ
        :minute_price: 52
        :prefix: '882'
      - :internal_id: '1238'
        :name: Iran (Islamic Republ
        :minute_price: 3.25
        :prefix: '98'
      - :internal_id: '1215'
        :name: Iraq (Republic of)
        :minute_price: 3.64
        :prefix: '964'
      - :internal_id: '574'
        :name: Ireland
        :minute_price: 0.39
        :prefix: '353'
      - :internal_id: '575'
        :name: Ireland
        :minute_price: 0.39
        :prefix: '3531'
      - :internal_id: '576'
        :name: Ireland
        :minute_price: 4.03
        :prefix: '35383'
      - :internal_id: '577'
        :name: Ireland
        :minute_price: 4.03
        :prefix: '35385'
      - :internal_id: '578'
        :name: Ireland
        :minute_price: 4.03
        :prefix: '35386'
      - :internal_id: '579'
        :name: Ireland
        :minute_price: 4.03
        :prefix: '35387'
      - :internal_id: '580'
        :name: Ireland
        :minute_price: 4.03
        :prefix: '35388'
      - :internal_id: '1222'
        :name: Israel (State of)
        :minute_price: 0.52
        :prefix: '972'
      - :internal_id: '1223'
        :name: Israel (State of)
        :minute_price: 0.52
        :prefix: '9722'
      - :internal_id: '1224'
        :name: Israel (State of)
        :minute_price: 4.42
        :prefix: '97222'
      - :internal_id: '1225'
        :name: Israel (State of)
        :minute_price: 4.42
        :prefix: '97242'
      - :internal_id: '1226'
        :name: Israel (State of)
        :minute_price: 1.69
        :prefix: '97250'
      - :internal_id: '1227'
        :name: Israel (State of)
        :minute_price: 1.69
        :prefix: '97252'
      - :internal_id: '1228'
        :name: Israel (State of)
        :minute_price: 1.69
        :prefix: '97254'
      - :internal_id: '1229'
        :name: Israel (State of)
        :minute_price: 1.69
        :prefix: '97257'
      - :internal_id: '1230'
        :name: Israel (State of)
        :minute_price: 4.42
        :prefix: '97259'
      - :internal_id: '1231'
        :name: Israel (State of)
        :minute_price: 4.42
        :prefix: '97282'
      - :internal_id: '1232'
        :name: Israel (State of)
        :minute_price: 4.42
        :prefix: '97292'
      - :internal_id: '635'
        :name: Italy
        :minute_price: 0.39
        :prefix: '39'
      - :internal_id: '636'
        :name: Italy
        :minute_price: 5.07
        :prefix: '393'
      - :internal_id: '278'
        :name: Jamaica
        :minute_price: 4.81
        :prefix: '1876'
      - :internal_id: '1180'
        :name: Japan
        :minute_price: 0.65
        :prefix: '81'
      - :internal_id: '1181'
        :name: Japan
        :minute_price: 0.65
        :prefix: '813'
      - :internal_id: '1182'
        :name: Japan
        :minute_price: 2.86
        :prefix: '8170'
      - :internal_id: '1183'
        :name: Japan
        :minute_price: 2.86
        :prefix: '8180'
      - :internal_id: '1184'
        :name: Japan
        :minute_price: 2.86
        :prefix: '8190'
      - :internal_id: '1213'
        :name: Jordan (Hashemite Ki
        :minute_price: 2.99
        :prefix: '962'
      - :internal_id: '377'
        :name: Kenya (Republic of)
        :minute_price: 5.07
        :prefix: '254'
      - :internal_id: '1119'
        :name: Kiribati (Republic o
        :minute_price: 12.61
        :prefix: '686'
      - :internal_id: '1187'
        :name: Korea (Democratic Pe
        :minute_price: 10.92
        :prefix: '850'
      - :internal_id: '1185'
        :name: Korea (Republic of)
        :minute_price: 1.17
        :prefix: '82'
      - :internal_id: '1216'
        :name: Kuwait (State of)
        :minute_price: 1.95
        :prefix: '965'
      - :internal_id: '1250'
        :name: Kyrgyz Republic
        :minute_price: 2.08
        :prefix: '996'
      - :internal_id: '1191'
        :name: Lao People''s Democra
        :minute_price: 1.56
        :prefix: '856'
      - :internal_id: '595'
        :name: Latvia (Republic of)
        :minute_price: 3.12
        :prefix: '371'
      - :internal_id: '596'
        :name: Latvia (Republic of)
        :minute_price: 1.56
        :prefix: '3712'
      - :internal_id: '600'
        :name: Latvia (Republic of)
        :minute_price: 4.29
        :prefix: '3716'
      - :internal_id: '601'
        :name: Latvia (Republic of)
        :minute_price: 1.56
        :prefix: '3717'
      - :internal_id: '602'
        :name: Latvia (Republic of)
        :minute_price: 4.29
        :prefix: '3718'
      - :internal_id: '603'
        :name: Latvia (Republic of)
        :minute_price: 4.29
        :prefix: '3719'
      - :internal_id: '597'
        :name: Latvia (Republic of)
        :minute_price: 4.29
        :prefix: '37155'
      - :internal_id: '598'
        :name: Latvia (Republic of)
        :minute_price: 4.29
        :prefix: '37158'
      - :internal_id: '599'
        :name: Latvia (Republic of)
        :minute_price: 4.29
        :prefix: '37159'
      - :internal_id: '1212'
        :name: Lebanon
        :minute_price: 4.81
        :prefix: '961'
      - :internal_id: '392'
        :name: Lesotho (Kingdom of)
        :minute_price: 6.24
        :prefix: '266'
      - :internal_id: '345'
        :name: Liberia (Republic of
        :minute_price: 5.2
        :prefix: '231'
      - :internal_id: '331'
        :name: Libya (Socialist Peo
        :minute_price: 5.46
        :prefix: '218'
      - :internal_id: '690'
        :name: Liechtenstein (Princ
        :minute_price: 1.04
        :prefix: '423'
      - :internal_id: '691'
        :name: Liechtenstein (Princ
        :minute_price: 6.11
        :prefix: '4235'
      - :internal_id: '692'
        :name: Liechtenstein (Princ
        :minute_price: 6.11
        :prefix: '4236'
      - :internal_id: '693'
        :name: Liechtenstein (Princ
        :minute_price: 6.11
        :prefix: '4237'
      - :internal_id: '592'
        :name: Lithuania (Republic
        :minute_price: 1.56
        :prefix: '370'
      - :internal_id: '593'
        :name: Lithuania (Republic
        :minute_price: 3.9
        :prefix: '3706'
      - :internal_id: '594'
        :name: Lithuania (Republic
        :minute_price: 3.9
        :prefix: '3709'
      - :internal_id: '573'
        :name: Luxembourg
        :minute_price: 4.68
        :prefix: '352'
      - :internal_id: '1189'
        :name: Macao (Special admin
        :minute_price: 1.69
        :prefix: '853'
      - :internal_id: '634'
        :name: Macedonia (The Forme
        :minute_price: 2.34
        :prefix: '389'
      - :internal_id: '387'
        :name: Madagascar (Republic
        :minute_price: 4.68
        :prefix: '261'
      - :internal_id: '391'
        :name: Malawi
        :minute_price: 1.17
        :prefix: '265'
      - :internal_id: '1083'
        :name: Malaysia
        :minute_price: 1.04
        :prefix: '60'
      - :internal_id: '1211'
        :name: Maldives (Republic o
        :minute_price: 4.81
        :prefix: '960'
      - :internal_id: '337'
        :name: Mali (Republic of)
        :minute_price: 5.07
        :prefix: '223'
      - :internal_id: '583'
        :name: Malta
        :minute_price: 6.89
        :prefix: '356'
      - :internal_id: '1125'
        :name: Marshall Islands (Re
        :minute_price: 5.98
        :prefix: '692'
      - :internal_id: '1079'
        :name: Martinique (French D
        :minute_price: 6.63
        :prefix: '596'
      - :internal_id: '334'
        :name: Mauritania (Islamic
        :minute_price: 3.64
        :prefix: '222'
      - :internal_id: '335'
        :name: Mauritania (Islamic
        :minute_price: 7.93
        :prefix: '22263'
      - :internal_id: '336'
        :name: Mauritania (Islamic
        :minute_price: 7.93
        :prefix: '22264'
      - :internal_id: '344'
        :name: Mauritius (Republic
        :minute_price: 3.64
        :prefix: '230'
      - :internal_id: '1124'
        :name: Micronesia (Federate
        :minute_price: 6.37
        :prefix: '691'
      - :internal_id: '605'
        :name: Moldova (Republic of
        :minute_price: 2.47
        :prefix: '373'
      - :internal_id: '610'
        :name: Moldova (Republic of
        :minute_price: 2.99
        :prefix: '3735'
      - :internal_id: '611'
        :name: Moldova (Republic of
        :minute_price: 4.16
        :prefix: '37369'
      - :internal_id: '612'
        :name: Moldova (Republic of
        :minute_price: 4.16
        :prefix: '37379'
      - :internal_id: '606'
        :name: Moldova (Republic of
        :minute_price: 2.99
        :prefix: '373210'
      - :internal_id: '607'
        :name: Moldova (Republic of
        :minute_price: 2.99
        :prefix: '373215'
      - :internal_id: '608'
        :name: Moldova (Republic of
        :minute_price: 2.99
        :prefix: '373216'
      - :internal_id: '609'
        :name: Moldova (Republic of
        :minute_price: 2.99
        :prefix: '373219'
      - :internal_id: '621'
        :name: Monaco (Principality
        :minute_price: 1.04
        :prefix: '377'
      - :internal_id: '622'
        :name: Monaco (Principality
        :minute_price: 1.69
        :prefix: '3774'
      - :internal_id: '626'
        :name: Monaco (Principality
        :minute_price: 1.69
        :prefix: '3776'
      - :internal_id: '623'
        :name: Monaco (Principality
        :minute_price: 5.33
        :prefix: '37744'
      - :internal_id: '624'
        :name: Monaco (Principality
        :minute_price: 5.33
        :prefix: '37745'
      - :internal_id: '625'
        :name: Monaco (Principality
        :minute_price: 5.33
        :prefix: '37747'
      - :internal_id: '1236'
        :name: Mongolia
        :minute_price: 2.21
        :prefix: '976'
      - :internal_id: '188'
        :name: Montserrat
        :minute_price: 7.28
        :prefix: '1664'
      - :internal_id: '328'
        :name: Morocco (Kingdom of)
        :minute_price: 5.72
        :prefix: '212'
      - :internal_id: '381'
        :name: Mozambique (Republic
        :minute_price: 4.16
        :prefix: '258'
      - :internal_id: '1210'
        :name: Myanmar (Union of)
        :minute_price: 6.5
        :prefix: '95'
      - :internal_id: '390'
        :name: Namibia (Republic of
        :minute_price: 4.81
        :prefix: '264'
      - :internal_id: '1108'
        :name: Nauru (Republic of)
        :minute_price: 18.33
        :prefix: '674'
      - :internal_id: '1237'
        :name: Nepal
        :minute_price: 5.59
        :prefix: '977'
      - :internal_id: '430'
        :name: Netherlands (Kingdom
        :minute_price: 0.39
        :prefix: '31'
      - :internal_id: '466'
        :name: Netherlands (Kingdom
        :minute_price: 5.2
        :prefix: '3165'
      - :internal_id: '431'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31610'
      - :internal_id: '432'
        :name: Netherlands (Kingdom
        :minute_price: 5.2
        :prefix: '31611'
      - :internal_id: '433'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31612'
      - :internal_id: '434'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31613'
      - :internal_id: '435'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31614'
      - :internal_id: '436'
        :name: Netherlands (Kingdom
        :minute_price: 5.2
        :prefix: '31615'
      - :internal_id: '437'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31616'
      - :internal_id: '438'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31617'
      - :internal_id: '439'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31618'
      - :internal_id: '440'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31619'
      - :internal_id: '441'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31620'
      - :internal_id: '442'
        :name: Netherlands (Kingdom
        :minute_price: 5.2
        :prefix: '31621'
      - :internal_id: '443'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31622'
      - :internal_id: '444'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31623'
      - :internal_id: '445'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31624'
      - :internal_id: '446'
        :name: Netherlands (Kingdom
        :minute_price: 5.2
        :prefix: '31625'
      - :internal_id: '447'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31626'
      - :internal_id: '448'
        :name: Netherlands (Kingdom
        :minute_price: 5.2
        :prefix: '31627'
      - :internal_id: '449'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31628'
      - :internal_id: '450'
        :name: Netherlands (Kingdom
        :minute_price: 5.2
        :prefix: '31629'
      - :internal_id: '451'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31630'
      - :internal_id: '452'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31632'
      - :internal_id: '453'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31633'
      - :internal_id: '454'
        :name: Netherlands (Kingdom
        :minute_price: 5.2
        :prefix: '31636'
      - :internal_id: '455'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31638'
      - :internal_id: '456'
        :name: Netherlands (Kingdom
        :minute_price: 5.2
        :prefix: '31640'
      - :internal_id: '457'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31641'
      - :internal_id: '458'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31642'
      - :internal_id: '459'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31643'
      - :internal_id: '460'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31644'
      - :internal_id: '461'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31645'
      - :internal_id: '462'
        :name: Netherlands (Kingdom
        :minute_price: 5.2
        :prefix: '31646'
      - :internal_id: '463'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31647'
      - :internal_id: '464'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31648'
      - :internal_id: '465'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31649'
      - :internal_id: '467'
        :name: Netherlands (Kingdom
        :minute_price: 4.94
        :prefix: '31665'
      - :internal_id: '1082'
        :name: Netherlands Antilles
        :minute_price: 3.12
        :prefix: '599'
      - :internal_id: '1120'
        :name: New Caledonia (Terri
        :minute_price: 6.11
        :prefix: '687'
      - :internal_id: '1097'
        :name: New Zealand
        :minute_price: 0.52
        :prefix: '64'
      - :internal_id: '1098'
        :name: New Zealand
        :minute_price: 5.85
        :prefix: '642'
      - :internal_id: '928'
        :name: Nicaragua
        :minute_price: 4.68
        :prefix: '505'
      - :internal_id: '341'
        :name: Niger (Republic of t
        :minute_price: 3.12
        :prefix: '227'
      - :internal_id: '348'
        :name: Nigeria (Federal Rep
        :minute_price: 2.08
        :prefix: '234'
      - :internal_id: '349'
        :name: Nigeria (Federal Rep
        :minute_price: 1.04
        :prefix: '2341'
      - :internal_id: '357'
        :name: Nigeria (Federal Rep
        :minute_price: 3.9
        :prefix: '23490'
      - :internal_id: '350'
        :name: Nigeria (Federal Rep
        :minute_price: 3.25
        :prefix: '234802'
      - :internal_id: '351'
        :name: Nigeria (Federal Rep
        :minute_price: 3.64
        :prefix: '234803'
      - :internal_id: '352'
        :name: Nigeria (Federal Rep
        :minute_price: 3.77
        :prefix: '234804'
      - :internal_id: '353'
        :name: Nigeria (Federal Rep
        :minute_price: 3.9
        :prefix: '234805'
      - :internal_id: '354'
        :name: Nigeria (Federal Rep
        :minute_price: 3.64
        :prefix: '234806'
      - :internal_id: '355'
        :name: Nigeria (Federal Rep
        :minute_price: 3.9
        :prefix: '234807'
      - :internal_id: '356'
        :name: Nigeria (Federal Rep
        :minute_price: 3.25
        :prefix: '234808'
      - :internal_id: '1117'
        :name: Niue
        :minute_price: 18.72
        :prefix: '683'
      - :internal_id: '189'
        :name: Northern Mariana Isl
        :minute_price: 3.9
        :prefix: '1670'
      - :internal_id: '904'
        :name: Norway
        :minute_price: 4.03
        :prefix: '47'
      - :internal_id: '1219'
        :name: Oman (Sultanate of)
        :minute_price: 3.9
        :prefix: '968'
      - :internal_id: '1207'
        :name: Pakistan (Islamic Re
        :minute_price: 2.86
        :prefix: '92'
      - :internal_id: '1114'
        :name: Palau (Republic of)
        :minute_price: 7.93
        :prefix: '680'
      - :internal_id: '1220'
        :name: Palestine (Occupied
        :minute_price: 5.72
        :prefix: '970'
      - :internal_id: '930'
        :name: Panama (Republic of)
        :minute_price: 1.04
        :prefix: '507'
      - :internal_id: '931'
        :name: Panama (Republic of)
        :minute_price: 0.52
        :prefix: '5072'
      - :internal_id: '932'
        :name: Panama (Republic of)
        :minute_price: 2.86
        :prefix: '5076'
      - :internal_id: '1109'
        :name: Papua New Guinea
        :minute_price: 16.38
        :prefix: '675'
      - :internal_id: '1078'
        :name: Paraguay (Republic o
        :minute_price: 2.73
        :prefix: '595'
      - :internal_id: '940'
        :name: Peru
        :minute_price: 0.91
        :prefix: '51'
      - :internal_id: '941'
        :name: Peru
        :minute_price: 0.52
        :prefix: '5112'
      - :internal_id: '942'
        :name: Peru
        :minute_price: 0.52
        :prefix: '5113'
      - :internal_id: '943'
        :name: Peru
        :minute_price: 0.52
        :prefix: '5114'
      - :internal_id: '944'
        :name: Peru
        :minute_price: 0.52
        :prefix: '5115'
      - :internal_id: '945'
        :name: Peru
        :minute_price: 0.52
        :prefix: '5116'
      - :internal_id: '946'
        :name: Peru
        :minute_price: 0.52
        :prefix: '5117'
      - :internal_id: '947'
        :name: Peru
        :minute_price: 4.94
        :prefix: '5119'
      - :internal_id: '948'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51419'
      - :internal_id: '949'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51429'
      - :internal_id: '950'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51439'
      - :internal_id: '951'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51449'
      - :internal_id: '952'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51519'
      - :internal_id: '953'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51529'
      - :internal_id: '954'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51539'
      - :internal_id: '955'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51549'
      - :internal_id: '956'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51569'
      - :internal_id: '957'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51619'
      - :internal_id: '958'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51629'
      - :internal_id: '959'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51639'
      - :internal_id: '960'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51649'
      - :internal_id: '961'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51659'
      - :internal_id: '962'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51669'
      - :internal_id: '963'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51679'
      - :internal_id: '964'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51729'
      - :internal_id: '965'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51739'
      - :internal_id: '966'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51749'
      - :internal_id: '967'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51769'
      - :internal_id: '968'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51829'
      - :internal_id: '969'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51839'
      - :internal_id: '970'
        :name: Peru
        :minute_price: 4.94
        :prefix: '51849'
      - :internal_id: '1096'
        :name: Philippines (Republi
        :minute_price: 3.38
        :prefix: '63'
      - :internal_id: '905'
        :name: Poland (Republic of)
        :minute_price: 0.52
        :prefix: '48'
      - :internal_id: '906'
        :name: Poland (Republic of)
        :minute_price: 4.81
        :prefix: '4822'
      - :internal_id: '907'
        :name: Poland (Republic of)
        :minute_price: 4.81
        :prefix: '4850'
      - :internal_id: '908'
        :name: Poland (Republic of)
        :minute_price: 4.81
        :prefix: '4851'
      - :internal_id: '909'
        :name: Poland (Republic of)
        :minute_price: 4.81
        :prefix: '4860'
      - :internal_id: '910'
        :name: Poland (Republic of)
        :minute_price: 4.81
        :prefix: '4866'
      - :internal_id: '911'
        :name: Poland (Republic of)
        :minute_price: 4.81
        :prefix: '4869'
      - :internal_id: '914'
        :name: Poland (Republic of)
        :minute_price: 4.81
        :prefix: '4888'
      - :internal_id: '915'
        :name: Poland (Republic of)
        :minute_price: 4.81
        :prefix: '4890'
      - :internal_id: '912'
        :name: Poland (Republic of)
        :minute_price: 4.81
        :prefix: '48787'
      - :internal_id: '913'
        :name: Poland (Republic of)
        :minute_price: 4.81
        :prefix: '48789'
      - :internal_id: '572'
        :name: Portugal
        :minute_price: 4.81
        :prefix: '351'
      - :internal_id: '236'
        :name: Puerto Rico
        :minute_price: 0.65
        :prefix: '1787'
      - :internal_id: '304'
        :name: Puerto Rico
        :minute_price: 0.65
        :prefix: '1939'
      - :internal_id: '1234'
        :name: Qatar (State of)
        :minute_price: 6.5
        :prefix: '974'
      - :internal_id: '388'
        :name: Reunion (French Depa
        :minute_price: 5.46
        :prefix: '262'
      - :internal_id: '637'
        :name: Romania
        :minute_price: 2.08
        :prefix: '40'
      - :internal_id: '638'
        :name: Romania
        :minute_price: 1.69
        :prefix: '4021'
      - :internal_id: '639'
        :name: Romania
        :minute_price: 3.64
        :prefix: '4072'
      - :internal_id: '640'
        :name: Romania
        :minute_price: 3.64
        :prefix: '4074'
      - :internal_id: '641'
        :name: Romania
        :minute_price: 3.64
        :prefix: '4076'
      - :internal_id: '642'
        :name: Romania
        :minute_price: 3.64
        :prefix: '4078'
      - :internal_id: '1126'
        :name: Russian Federation
        :minute_price: 0.91
        :prefix: '7'
      - :internal_id: '1175'
        :name: Russian Federation
        :minute_price: 1.3
        :prefix: '790'
      - :internal_id: '1176'
        :name: Russian Federation
        :minute_price: 1.3
        :prefix: '791'
      - :internal_id: '1177'
        :name: Russian Federation
        :minute_price: 1.3
        :prefix: '792'
      - :internal_id: '1178'
        :name: Russian Federation
        :minute_price: 1.3
        :prefix: '795'
      - :internal_id: '1179'
        :name: Russian Federation
        :minute_price: 1.3
        :prefix: '796'
      - :internal_id: '1129'
        :name: Russian Federation
        :minute_price: 3.12
        :prefix: '7300'
      - :internal_id: '1130'
        :name: Russian Federation
        :minute_price: 2.47
        :prefix: '7310'
      - :internal_id: '1131'
        :name: Russian Federation
        :minute_price: 2.47
        :prefix: '7311'
      - :internal_id: '1132'
        :name: Russian Federation
        :minute_price: 2.47
        :prefix: '7312'
      - :internal_id: '1133'
        :name: Russian Federation
        :minute_price: 2.47
        :prefix: '7313'
      - :internal_id: '1134'
        :name: Russian Federation
        :minute_price: 2.47
        :prefix: '7314'
      - :internal_id: '1135'
        :name: Russian Federation
        :minute_price: 2.47
        :prefix: '7315'
      - :internal_id: '1136'
        :name: Russian Federation
        :minute_price: 2.47
        :prefix: '7316'
      - :internal_id: '1137'
        :name: Russian Federation
        :minute_price: 2.47
        :prefix: '7317'
      - :internal_id: '1138'
        :name: Russian Federation
        :minute_price: 2.47
        :prefix: '7318'
      - :internal_id: '1139'
        :name: Russian Federation
        :minute_price: 2.47
        :prefix: '7321'
      - :internal_id: '1140'
        :name: Russian Federation
        :minute_price: 2.47
        :prefix: '7322'
      - :internal_id: '1141'
        :name: Russian Federation
        :minute_price: 2.47
        :prefix: '7323'
      - :internal_id: '1142'
        :name: Russian Federation
        :minute_price: 2.47
        :prefix: '7324'
      - :internal_id: '1143'
        :name: Russian Federation
        :minute_price: 2.47
        :prefix: '7325'
      - :internal_id: '1144'
        :name: Russian Federation
        :minute_price: 2.47
        :prefix: '7326'
      - :internal_id: '1145'
        :name: Russian Federation
        :minute_price: 2.47
        :prefix: '7327'
      - :internal_id: '1147'
        :name: Russian Federation
        :minute_price: 2.47
        :prefix: '7328'
      - :internal_id: '1148'
        :name: Russian Federation
        :minute_price: 2.47
        :prefix: '7329'
      - :internal_id: '1149'
        :name: Russian Federation
        :minute_price: 3.12
        :prefix: '7333'
      - :internal_id: '1150'
        :name: Russian Federation
        :minute_price: 0.91
        :prefix: '7477'
      - :internal_id: '1151'
        :name: Russian Federation
        :minute_price: 0.91
        :prefix: '7478'
      - :internal_id: '1152'
        :name: Russian Federation
        :minute_price: 0.26
        :prefix: '7495'
      - :internal_id: '1153'
        :name: Russian Federation
        :minute_price: 0.65
        :prefix: '7496'
      - :internal_id: '1154'
        :name: Russian Federation
        :minute_price: 0.65
        :prefix: '7498'
      - :internal_id: '1155'
        :name: Russian Federation
        :minute_price: 0.26
        :prefix: '7499'
      - :internal_id: '1156'
        :name: Russian Federation
        :minute_price: 0.91
        :prefix: '7501'
      - :internal_id: '1157'
        :name: Russian Federation
        :minute_price: 0.91
        :prefix: '7502'
      - :internal_id: '1158'
        :name: Russian Federation
        :minute_price: 0.91
        :prefix: '7503'
      - :internal_id: '1159'
        :name: Russian Federation
        :minute_price: 0.91
        :prefix: '7504'
      - :internal_id: '1160'
        :name: Russian Federation
        :minute_price: 0.91
        :prefix: '7505'
      - :internal_id: '1161'
        :name: Russian Federation
        :minute_price: 0.91
        :prefix: '7509'
      - :internal_id: '1162'
        :name: Russian Federation
        :minute_price: 0.91
        :prefix: '7510'
      - :internal_id: '1163'
        :name: Russian Federation
        :minute_price: 0.91
        :prefix: '7511'
      - :internal_id: '1164'
        :name: Russian Federation
        :minute_price: 0.91
        :prefix: '7512'
      - :internal_id: '1165'
        :name: Russian Federation
        :minute_price: 0.91
        :prefix: '7513'
      - :internal_id: '1166'
        :name: Russian Federation
        :minute_price: 0.91
        :prefix: '7517'
      - :internal_id: '1167'
        :name: Russian Federation
        :minute_price: 0.91
        :prefix: '7543'
      - :internal_id: '1168'
        :name: Russian Federation
        :minute_price: 3.12
        :prefix: '7676'
      - :internal_id: '1169'
        :name: Russian Federation
        :minute_price: 3.12
        :prefix: '7700'
      - :internal_id: '1170'
        :name: Russian Federation
        :minute_price: 3.12
        :prefix: '7701'
      - :internal_id: '1171'
        :name: Russian Federation
        :minute_price: 3.12
        :prefix: '7702'
      - :internal_id: '1172'
        :name: Russian Federation
        :minute_price: 3.12
        :prefix: '7705'
      - :internal_id: '1173'
        :name: Russian Federation
        :minute_price: 0.26
        :prefix: '7812'
      - :internal_id: '1174'
        :name: Russian Federation
        :minute_price: 0.39
        :prefix: '7813'
      - :internal_id: '1127'
        :name: Russian Federation
        :minute_price: 0.91
        :prefix: '70971'
      - :internal_id: '1128'
        :name: Russian Federation
        :minute_price: 0.91
        :prefix: '70976'
      - :internal_id: '1146'
        :name: Russian Federation
        :minute_price: 0.91
        :prefix: '73272'
      - :internal_id: '373'
        :name: Rwandese Republic
        :minute_price: 2.86
        :prefix: '250'
      - :internal_id: '418'
        :name: Saint Helena
        :minute_price: 26
        :prefix: '290'
      - :internal_id: '276'
        :name: Saint Kitts and Nevi
        :minute_price: 6.5
        :prefix: '1869'
      - :internal_id: '933'
        :name: Saint Pierre and Miq
        :minute_price: 4.03
        :prefix: '508'
      - :internal_id: '233'
        :name: Saint Vincent and th
        :minute_price: 3.51
        :prefix: '1784'
      - :internal_id: '1118'
        :name: Samoa (Independent S
        :minute_price: 8.32
        :prefix: '685'
      - :internal_id: '627'
        :name: San Marino (Republic
        :minute_price: 0.78
        :prefix: '378'
      - :internal_id: '362'
        :name: Sao Tome and Princip
        :minute_price: 26
        :prefix: '239'
      - :internal_id: '1217'
        :name: Saudi Arabia (Kingdo
        :minute_price: 4.42
        :prefix: '966'
      - :internal_id: '333'
        :name: Senegal (Republic of
        :minute_price: 4.55
        :prefix: '221'
      - :internal_id: '630'
        :name: Serbia and Montenegr
        :minute_price: 5.07
        :prefix: '381'
      - :internal_id: '371'
        :name: Seychelles (Republic
        :minute_price: 6.5
        :prefix: '248'
      - :internal_id: '346'
        :name: Sierra Leone
        :minute_price: 4.03
        :prefix: '232'
      - :internal_id: '1099'
        :name: Singapore (Republic
        :minute_price: 0.26
        :prefix: '65'
      - :internal_id: '672'
        :name: Slovak Republic
        :minute_price: 1.56
        :prefix: '421'
      - :internal_id: '673'
        :name: Slovak Republic
        :minute_price: 4.42
        :prefix: '421901'
      - :internal_id: '674'
        :name: Slovak Republic
        :minute_price: 4.42
        :prefix: '421902'
      - :internal_id: '675'
        :name: Slovak Republic
        :minute_price: 4.42
        :prefix: '421903'
      - :internal_id: '676'
        :name: Slovak Republic
        :minute_price: 4.42
        :prefix: '421904'
      - :internal_id: '677'
        :name: Slovak Republic
        :minute_price: 4.42
        :prefix: '421905'
      - :internal_id: '678'
        :name: Slovak Republic
        :minute_price: 4.42
        :prefix: '421906'
      - :internal_id: '679'
        :name: Slovak Republic
        :minute_price: 4.42
        :prefix: '421907'
      - :internal_id: '680'
        :name: Slovak Republic
        :minute_price: 4.42
        :prefix: '421908'
      - :internal_id: '681'
        :name: Slovak Republic
        :minute_price: 4.42
        :prefix: '421909'
      - :internal_id: '682'
        :name: Slovak Republic
        :minute_price: 4.42
        :prefix: '421910'
      - :internal_id: '683'
        :name: Slovak Republic
        :minute_price: 4.42
        :prefix: '421911'
      - :internal_id: '684'
        :name: Slovak Republic
        :minute_price: 4.42
        :prefix: '421912'
      - :internal_id: '685'
        :name: Slovak Republic
        :minute_price: 4.42
        :prefix: '421914'
      - :internal_id: '686'
        :name: Slovak Republic
        :minute_price: 4.42
        :prefix: '421915'
      - :internal_id: '687'
        :name: Slovak Republic
        :minute_price: 4.42
        :prefix: '421916'
      - :internal_id: '688'
        :name: Slovak Republic
        :minute_price: 4.42
        :prefix: '421918'
      - :internal_id: '689'
        :name: Slovak Republic
        :minute_price: 4.42
        :prefix: '421919'
      - :internal_id: '632'
        :name: Slovenia (Republic o
        :minute_price: 5.72
        :prefix: '386'
      - :internal_id: '1111'
        :name: Solomon Islands
        :minute_price: 17.94
        :prefix: '677'
      - :internal_id: '375'
        :name: Somali Democratic Re
        :minute_price: 10.4
        :prefix: '252'
      - :internal_id: '397'
        :name: South Africa (Republ
        :minute_price: 1.3
        :prefix: '27'
      - :internal_id: '398'
        :name: South Africa (Republ
        :minute_price: 1.3
        :prefix: '2711'
      - :internal_id: '399'
        :name: South Africa (Republ
        :minute_price: 1.3
        :prefix: '2721'
      - :internal_id: '400'
        :name: South Africa (Republ
        :minute_price: 3.9
        :prefix: '2772'
      - :internal_id: '401'
        :name: South Africa (Republ
        :minute_price: 3.9
        :prefix: '2773'
      - :internal_id: '404'
        :name: South Africa (Republ
        :minute_price: 3.9
        :prefix: '2776'
      - :internal_id: '411'
        :name: South Africa (Republ
        :minute_price: 3.9
        :prefix: '2782'
      - :internal_id: '412'
        :name: South Africa (Republ
        :minute_price: 3.9
        :prefix: '2783'
      - :internal_id: '413'
        :name: South Africa (Republ
        :minute_price: 3.9
        :prefix: '2784'
      - :internal_id: '402'
        :name: South Africa (Republ
        :minute_price: 3.9
        :prefix: '27741'
      - :internal_id: '403'
        :name: South Africa (Republ
        :minute_price: 3.9
        :prefix: '27742'
      - :internal_id: '405'
        :name: South Africa (Republ
        :minute_price: 3.9
        :prefix: '27781'
      - :internal_id: '406'
        :name: South Africa (Republ
        :minute_price: 3.9
        :prefix: '27782'
      - :internal_id: '407'
        :name: South Africa (Republ
        :minute_price: 3.9
        :prefix: '27783'
      - :internal_id: '408'
        :name: South Africa (Republ
        :minute_price: 3.9
        :prefix: '27784'
      - :internal_id: '409'
        :name: South Africa (Republ
        :minute_price: 3.9
        :prefix: '27791'
      - :internal_id: '410'
        :name: South Africa (Republ
        :minute_price: 3.9
        :prefix: '27792'
      - :internal_id: '414'
        :name: South Africa (Republ
        :minute_price: 3.9
        :prefix: '27850'
      - :internal_id: '415'
        :name: South Africa (Republ
        :minute_price: 3.9
        :prefix: '27851'
      - :internal_id: '416'
        :name: South Africa (Republ
        :minute_price: 3.9
        :prefix: '27852'
      - :internal_id: '417'
        :name: South Africa (Republ
        :minute_price: 3.9
        :prefix: '27853'
      - :internal_id: '505'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34'
      - :internal_id: '506'
        :name: Spain
        :minute_price: 4.68
        :prefix: '346'
      - :internal_id: '507'
        :name: Spain
        :minute_price: 5.07
        :prefix: '34600'
      - :internal_id: '508'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34605'
      - :internal_id: '509'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34606'
      - :internal_id: '510'
        :name: Spain
        :minute_price: 5.07
        :prefix: '34607'
      - :internal_id: '511'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34608'
      - :internal_id: '512'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34609'
      - :internal_id: '513'
        :name: Spain
        :minute_price: 5.07
        :prefix: '34610'
      - :internal_id: '514'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34615'
      - :internal_id: '515'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34616'
      - :internal_id: '516'
        :name: Spain
        :minute_price: 5.07
        :prefix: '34617'
      - :internal_id: '517'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34618'
      - :internal_id: '518'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34619'
      - :internal_id: '519'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34620'
      - :internal_id: '520'
        :name: Spain
        :minute_price: 4.55
        :prefix: '34622'
      - :internal_id: '521'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34625'
      - :internal_id: '522'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34626'
      - :internal_id: '523'
        :name: Spain
        :minute_price: 5.07
        :prefix: '34627'
      - :internal_id: '524'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34628'
      - :internal_id: '525'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34629'
      - :internal_id: '526'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34630'
      - :internal_id: '527'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34635'
      - :internal_id: '528'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34636'
      - :internal_id: '529'
        :name: Spain
        :minute_price: 5.07
        :prefix: '34637'
      - :internal_id: '530'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34638'
      - :internal_id: '531'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34639'
      - :internal_id: '532'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34645'
      - :internal_id: '533'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34646'
      - :internal_id: '534'
        :name: Spain
        :minute_price: 5.07
        :prefix: '34647'
      - :internal_id: '535'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34648'
      - :internal_id: '536'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34649'
      - :internal_id: '537'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34650'
      - :internal_id: '538'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34651'
      - :internal_id: '539'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34652'
      - :internal_id: '540'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34653'
      - :internal_id: '541'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34654'
      - :internal_id: '542'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34655'
      - :internal_id: '543'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34656'
      - :internal_id: '544'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34657'
      - :internal_id: '545'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34658'
      - :internal_id: '546'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34659'
      - :internal_id: '547'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34660'
      - :internal_id: '548'
        :name: Spain
        :minute_price: 5.07
        :prefix: '34661'
      - :internal_id: '549'
        :name: Spain
        :minute_price: 5.07
        :prefix: '34662'
      - :internal_id: '550'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34665'
      - :internal_id: '551'
        :name: Spain
        :minute_price: 5.07
        :prefix: '34666'
      - :internal_id: '552'
        :name: Spain
        :minute_price: 5.07
        :prefix: '34667'
      - :internal_id: '553'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34669'
      - :internal_id: '554'
        :name: Spain
        :minute_price: 5.07
        :prefix: '34670'
      - :internal_id: '555'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34675'
      - :internal_id: '556'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34676'
      - :internal_id: '557'
        :name: Spain
        :minute_price: 5.07
        :prefix: '34677'
      - :internal_id: '558'
        :name: Spain
        :minute_price: 5.07
        :prefix: '34678'
      - :internal_id: '559'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34679'
      - :internal_id: '560'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34680'
      - :internal_id: '561'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34685'
      - :internal_id: '562'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34686'
      - :internal_id: '563'
        :name: Spain
        :minute_price: 5.07
        :prefix: '34687'
      - :internal_id: '564'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34689'
      - :internal_id: '565'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34690'
      - :internal_id: '566'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34692'
      - :internal_id: '567'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34695'
      - :internal_id: '568'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34696'
      - :internal_id: '569'
        :name: Spain
        :minute_price: 5.07
        :prefix: '34697'
      - :internal_id: '570'
        :name: Spain
        :minute_price: 4.68
        :prefix: '34699'
      - :internal_id: '1209'
        :name: Sri Lanka (Democrati
        :minute_price: 2.6
        :prefix: '94'
      - :internal_id: '372'
        :name: Sudan (Republic of t
        :minute_price: 3.51
        :prefix: '249'
      - :internal_id: '1080'
        :name: Suriname (Republic o
        :minute_price: 4.81
        :prefix: '597'
      - :internal_id: '394'
        :name: Swaziland (Kingdom o
        :minute_price: 3.12
        :prefix: '268'
      - :internal_id: '395'
        :name: Swaziland (Kingdom o
        :minute_price: 4.68
        :prefix: '2686'
      - :internal_id: '879'
        :name: Sweden
        :minute_price: 0.39
        :prefix: '46'
      - :internal_id: '900'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '4670'
      - :internal_id: '901'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '4673'
      - :internal_id: '902'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '4674'
      - :internal_id: '903'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '4676'
      - :internal_id: '880'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '46102'
      - :internal_id: '881'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '46103'
      - :internal_id: '882'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '46104'
      - :internal_id: '883'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '46105'
      - :internal_id: '884'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '46106'
      - :internal_id: '885'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '46107'
      - :internal_id: '886'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '46124'
      - :internal_id: '887'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '46126'
      - :internal_id: '888'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '46127'
      - :internal_id: '889'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '46129'
      - :internal_id: '890'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '46252'
      - :internal_id: '891'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '46308'
      - :internal_id: '892'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '46376'
      - :internal_id: '893'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '46518'
      - :internal_id: '894'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '46519'
      - :internal_id: '895'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '46665'
      - :internal_id: '896'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '46673'
      - :internal_id: '897'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '46674'
      - :internal_id: '898'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '46675'
      - :internal_id: '899'
        :name: Sweden
        :minute_price: 4.29
        :prefix: '46676'
      - :internal_id: '643'
        :name: Switzerland (Confede
        :minute_price: 0.52
        :prefix: '41'
      - :internal_id: '644'
        :name: Switzerland (Confede
        :minute_price: 0.52
        :prefix: '411'
      - :internal_id: '645'
        :name: Switzerland (Confede
        :minute_price: 0.52
        :prefix: '4122'
      - :internal_id: '646'
        :name: Switzerland (Confede
        :minute_price: 0.52
        :prefix: '4143'
      - :internal_id: '647'
        :name: Switzerland (Confede
        :minute_price: 0.52
        :prefix: '4144'
      - :internal_id: '648'
        :name: Switzerland (Confede
        :minute_price: 5.59
        :prefix: '4176'
      - :internal_id: '649'
        :name: Switzerland (Confede
        :minute_price: 5.59
        :prefix: '4177'
      - :internal_id: '650'
        :name: Switzerland (Confede
        :minute_price: 5.59
        :prefix: '4178'
      - :internal_id: '651'
        :name: Switzerland (Confede
        :minute_price: 5.59
        :prefix: '4179'
      - :internal_id: '1214'
        :name: Syrian Arab Republic
        :minute_price: 5.98
        :prefix: '963'
      - :internal_id: '1201'
        :name: Taiwan
        :minute_price: 0.39
        :prefix: '886'
      - :internal_id: '1202'
        :name: Taiwan
        :minute_price: 0.39
        :prefix: '8862'
      - :internal_id: '1203'
        :name: Taiwan
        :minute_price: 1.69
        :prefix: '8869'
      - :internal_id: '1239'
        :name: Tajikistan (Republic
        :minute_price: 3.38
        :prefix: '992'
      - :internal_id: '378'
        :name: Tanzania (United Rep
        :minute_price: 4.42
        :prefix: '255'
      - :internal_id: '1100'
        :name: Thailand
        :minute_price: 0.78
        :prefix: '66'
      - :internal_id: '1101'
        :name: Thailand
        :minute_price: 1.69
        :prefix: '661'
      - :internal_id: '1102'
        :name: Thailand
        :minute_price: 0.52
        :prefix: '662'
      - :internal_id: '1103'
        :name: Thailand
        :minute_price: 1.69
        :prefix: '668'
      - :internal_id: '1104'
        :name: Thailand
        :minute_price: 1.69
        :prefix: '669'
      - :internal_id: '342'
        :name: Togolese Republic
        :minute_price: 3.38
        :prefix: '228'
      - :internal_id: '1123'
        :name: Tokelau
        :minute_price: 15.86
        :prefix: '690'
      - :internal_id: '1110'
        :name: Tonga (Kingdom of)
        :minute_price: 5.33
        :prefix: '676'
      - :internal_id: '275'
        :name: Trinidad and Tobago
        :minute_price: 2.73
        :prefix: '1868'
      - :internal_id: '330'
        :name: Tunisia
        :minute_price: 4.16
        :prefix: '216'
      - :internal_id: '1204'
        :name: Turkey
        :minute_price: 3.51
        :prefix: '90'
      - :internal_id: '1240'
        :name: Turkmenistan
        :minute_price: 2.86
        :prefix: '993'
      - :internal_id: '182'
        :name: Turks and Caicos Isl
        :minute_price: 3.25
        :prefix: '1649'
      - :internal_id: '1121'
        :name: Tuvalu
        :minute_price: 15.08
        :prefix: '688'
      - :internal_id: '379'
        :name: Uganda (Republic of)
        :minute_price: 2.47
        :prefix: '256'
      - :internal_id: '629'
        :name: Ukraine
        :minute_price: 2.47
        :prefix: '380'
      - :internal_id: '1221'
        :name: United Arab Emirates
        :minute_price: 4.68
        :prefix: '971'
      - :internal_id: '714'
        :name: United Kingdom of Gr
        :minute_price: 0.39
        :prefix: '44'
      - :internal_id: '717'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447'
      - :internal_id: '876'
        :name: United Kingdom of Gr
        :minute_price: 2.6
        :prefix: '448'
      - :internal_id: '877'
        :name: United Kingdom of Gr
        :minute_price: 2.6
        :prefix: '449'
      - :internal_id: '718'
        :name: United Kingdom of Gr
        :minute_price: 6.5
        :prefix: '4470'
      - :internal_id: '715'
        :name: United Kingdom of Gr
        :minute_price: 0.39
        :prefix: '44207'
      - :internal_id: '716'
        :name: United Kingdom of Gr
        :minute_price: 0.39
        :prefix: '44208'
      - :internal_id: '719'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '44770'
      - :internal_id: '720'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '44771'
      - :internal_id: '721'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '44772'
      - :internal_id: '722'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '44773'
      - :internal_id: '741'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '44776'
      - :internal_id: '751'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '44778'
      - :internal_id: '761'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '44780'
      - :internal_id: '762'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '44781'
      - :internal_id: '780'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '44784'
      - :internal_id: '804'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '44788'
      - :internal_id: '723'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447740'
      - :internal_id: '724'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447741'
      - :internal_id: '725'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447742'
      - :internal_id: '726'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447743'
      - :internal_id: '727'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447745'
      - :internal_id: '728'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447746'
      - :internal_id: '729'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447747'
      - :internal_id: '730'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447748'
      - :internal_id: '731'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447749'
      - :internal_id: '732'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447750'
      - :internal_id: '733'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447751'
      - :internal_id: '734'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447752'
      - :internal_id: '735'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447753'
      - :internal_id: '736'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447754'
      - :internal_id: '737'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447756'
      - :internal_id: '738'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447757'
      - :internal_id: '739'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447758'
      - :internal_id: '740'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447759'
      - :internal_id: '742'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447770'
      - :internal_id: '743'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447771'
      - :internal_id: '744'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447772'
      - :internal_id: '745'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447773'
      - :internal_id: '746'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447774'
      - :internal_id: '747'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447775'
      - :internal_id: '748'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447776'
      - :internal_id: '749'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447778'
      - :internal_id: '750'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447779'
      - :internal_id: '752'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447790'
      - :internal_id: '753'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447791'
      - :internal_id: '754'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447792'
      - :internal_id: '755'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447793'
      - :internal_id: '756'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447794'
      - :internal_id: '757'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447795'
      - :internal_id: '758'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447796'
      - :internal_id: '759'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447798'
      - :internal_id: '760'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447799'
      - :internal_id: '763'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447820'
      - :internal_id: '764'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447821'
      - :internal_id: '765'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447823'
      - :internal_id: '766'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447824'
      - :internal_id: '767'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447825'
      - :internal_id: '768'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447826'
      - :internal_id: '769'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447827'
      - :internal_id: '770'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447828'
      - :internal_id: '771'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447830'
      - :internal_id: '772'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447831'
      - :internal_id: '773'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447832'
      - :internal_id: '774'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447833'
      - :internal_id: '775'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447834'
      - :internal_id: '776'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447835'
      - :internal_id: '777'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447836'
      - :internal_id: '778'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447837'
      - :internal_id: '779'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447838'
      - :internal_id: '781'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447850'
      - :internal_id: '782'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447851'
      - :internal_id: '783'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447852'
      - :internal_id: '784'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447853'
      - :internal_id: '785'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447854'
      - :internal_id: '786'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447855'
      - :internal_id: '787'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447859'
      - :internal_id: '788'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447860'
      - :internal_id: '789'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447861'
      - :internal_id: '790'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447862'
      - :internal_id: '791'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447863'
      - :internal_id: '792'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447865'
      - :internal_id: '793'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447866'
      - :internal_id: '794'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447867'
      - :internal_id: '795'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447868'
      - :internal_id: '796'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447869'
      - :internal_id: '797'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447870'
      - :internal_id: '798'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447871'
      - :internal_id: '799'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447875'
      - :internal_id: '800'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447876'
      - :internal_id: '801'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447877'
      - :internal_id: '802'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447878'
      - :internal_id: '803'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447879'
      - :internal_id: '805'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447890'
      - :internal_id: '806'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447891'
      - :internal_id: '807'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447896'
      - :internal_id: '808'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447897'
      - :internal_id: '809'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447898'
      - :internal_id: '810'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447899'
      - :internal_id: '811'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447900'
      - :internal_id: '812'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447901'
      - :internal_id: '813'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447903'
      - :internal_id: '814'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447904'
      - :internal_id: '815'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447905'
      - :internal_id: '816'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447906'
      - :internal_id: '817'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447908'
      - :internal_id: '818'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447909'
      - :internal_id: '819'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447910'
      - :internal_id: '820'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447913'
      - :internal_id: '821'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447914'
      - :internal_id: '822'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447915'
      - :internal_id: '823'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447916'
      - :internal_id: '824'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447917'
      - :internal_id: '825'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447918'
      - :internal_id: '826'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447919'
      - :internal_id: '827'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447920'
      - :internal_id: '828'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447921'
      - :internal_id: '829'
        :name: United Kingdom of Gr
        :minute_price: 3.25
        :prefix: '447922'
      - :internal_id: '830'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447929'
      - :internal_id: '831'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447930'
      - :internal_id: '832'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447931'
      - :internal_id: '833'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447932'
      - :internal_id: '834'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447933'
      - :internal_id: '835'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447939'
      - :internal_id: '836'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447940'
      - :internal_id: '837'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447941'
      - :internal_id: '838'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447944'
      - :internal_id: '839'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447946'
      - :internal_id: '840'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447947'
      - :internal_id: '841'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447949'
      - :internal_id: '842'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447950'
      - :internal_id: '843'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447951'
      - :internal_id: '844'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447952'
      - :internal_id: '845'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447953'
      - :internal_id: '846'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447955'
      - :internal_id: '847'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447956'
      - :internal_id: '848'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447957'
      - :internal_id: '849'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447958'
      - :internal_id: '850'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447959'
      - :internal_id: '851'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447960'
      - :internal_id: '852'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447961'
      - :internal_id: '853'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447962'
      - :internal_id: '854'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447963'
      - :internal_id: '855'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447966'
      - :internal_id: '856'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447967'
      - :internal_id: '857'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447968'
      - :internal_id: '858'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447969'
      - :internal_id: '859'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447970'
      - :internal_id: '860'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447971'
      - :internal_id: '861'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447973'
      - :internal_id: '862'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447974'
      - :internal_id: '863'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447976'
      - :internal_id: '864'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447977'
      - :internal_id: '865'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447979'
      - :internal_id: '866'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447980'
      - :internal_id: '867'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447981'
      - :internal_id: '868'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447984'
      - :internal_id: '869'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447985'
      - :internal_id: '870'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447986'
      - :internal_id: '871'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447987'
      - :internal_id: '872'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447988'
      - :internal_id: '873'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447989'
      - :internal_id: '874'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447990'
      - :internal_id: '875'
        :name: United Kingdom of Gr
        :minute_price: 3.51
        :prefix: '447999'
      - :internal_id: '74'
        :name: United States Virgin
        :minute_price: 0.91
        :prefix: '1340'
      - :internal_id: '1081'
        :name: Uruguay (Eastern Rep
        :minute_price: 4.16
        :prefix: '598'
      - :internal_id: '5'
        :name: US - Alabama
        :minute_price: 0.84
        :prefix: '1205'
      - :internal_id: '31'
        :name: US - Alabama
        :minute_price: 0.84
        :prefix: '1251'
      - :internal_id: '35'
        :name: US - Alabama
        :minute_price: 0.84
        :prefix: '1256'
      - :internal_id: '70'
        :name: US - Alabama
        :minute_price: 0.84
        :prefix: '1334'
      - :internal_id: '286'
        :name: US - Alaska
        :minute_price: 0.84
        :prefix: '1907'
      - :internal_id: '116'
        :name: US - Arizona
        :minute_price: 0.84
        :prefix: '1480'
      - :internal_id: '136'
        :name: US - Arizona
        :minute_price: 0.84
        :prefix: '1520'
      - :internal_id: '156'
        :name: US - Arizona
        :minute_price: 0.84
        :prefix: '1602'
      - :internal_id: '174'
        :name: US - Arizona
        :minute_price: 0.84
        :prefix: '1623'
      - :internal_id: '300'
        :name: US - Arizona
        :minute_price: 0.84
        :prefix: '1928'
      - :internal_id: '115'
        :name: US - Arkansas
        :minute_price: 0.84
        :prefix: '1479'
      - :internal_id: '118'
        :name: US - Arkansas
        :minute_price: 0.84
        :prefix: '1501'
      - :internal_id: '277'
        :name: US - Arkansas
        :minute_price: 0.84
        :prefix: '1870'
      - :internal_id: '9'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1209'
      - :internal_id: '12'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1213'
      - :internal_id: '56'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1310'
      - :internal_id: '67'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1323'
      - :internal_id: '89'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1408'
      - :internal_id: '95'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1415'
      - :internal_id: '127'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1510'
      - :internal_id: '137'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1530'
      - :internal_id: '142'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1559'
      - :internal_id: '144'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1562'
      - :internal_id: '172'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1619'
      - :internal_id: '175'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1626'
      - :internal_id: '183'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1650'
      - :internal_id: '186'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1661'
      - :internal_id: '201'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1707'
      - :internal_id: '206'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1714'
      - :internal_id: '221'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1760'
      - :internal_id: '241'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1805'
      - :internal_id: '253'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1818'
      - :internal_id: '257'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1831'
      - :internal_id: '267'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1858'
      - :internal_id: '288'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1909'
      - :internal_id: '294'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1916'
      - :internal_id: '299'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1925'
      - :internal_id: '308'
        :name: US - California
        :minute_price: 0.84
        :prefix: '1949'
      - :internal_id: '49'
        :name: US - Colorado
        :minute_price: 0.84
        :prefix: '1303'
      - :internal_id: '211'
        :name: US - Colorado
        :minute_price: 0.84
        :prefix: '1719'
      - :internal_id: '212'
        :name: US - Colorado
        :minute_price: 0.84
        :prefix: '1720'
      - :internal_id: '313'
        :name: US - Colorado
        :minute_price: 0.84
        :prefix: '1970'
      - :internal_id: '3'
        :name: US - Connecticut
        :minute_price: 0.84
        :prefix: '1203'
      - :internal_id: '269'
        :name: US - Connecticut
        :minute_price: 0.84
        :prefix: '1860'
      - :internal_id: '312'
        :name: US - Connecticut
        :minute_price: 0.84
        :prefix: '1959'
      - :internal_id: '48'
        :name: US - Delaware
        :minute_price: 0.84
        :prefix: '1302'
      - :internal_id: '25'
        :name: US - Florida
        :minute_price: 0.84
        :prefix: '1239'
      - :internal_id: '51'
        :name: US - Florida
        :minute_price: 0.84
        :prefix: '1305'
      - :internal_id: '66'
        :name: US - Florida
        :minute_price: 0.84
        :prefix: '1321'
      - :internal_id: '77'
        :name: US - Florida
        :minute_price: 0.84
        :prefix: '1352'
      - :internal_id: '81'
        :name: US - Florida
        :minute_price: 0.84
        :prefix: '1386'
      - :internal_id: '88'
        :name: US - Florida
        :minute_price: 0.84
        :prefix: '1407'
      - :internal_id: '143'
        :name: US - Florida
        :minute_price: 0.84
        :prefix: '1561'
      - :internal_id: '194'
        :name: US - Florida
        :minute_price: 0.84
        :prefix: '1689'
      - :internal_id: '214'
        :name: US - Florida
        :minute_price: 0.84
        :prefix: '1727'
      - :internal_id: '219'
        :name: US - Florida
        :minute_price: 0.84
        :prefix: '1754'
      - :internal_id: '226'
        :name: US - Florida
        :minute_price: 0.84
        :prefix: '1772'
      - :internal_id: '235'
        :name: US - Florida
        :minute_price: 0.84
        :prefix: '1786'
      - :internal_id: '248'
        :name: US - Florida
        :minute_price: 0.84
        :prefix: '1813'
      - :internal_id: '264'
        :name: US - Florida
        :minute_price: 0.84
        :prefix: '1850'
      - :internal_id: '271'
        :name: US - Florida
        :minute_price: 0.84
        :prefix: '1863'
      - :internal_id: '283'
        :name: US - Florida
        :minute_price: 0.84
        :prefix: '1904'
      - :internal_id: '306'
        :name: US - Florida
        :minute_price: 0.84
        :prefix: '1941'
      - :internal_id: '310'
        :name: US - Florida
        :minute_price: 0.84
        :prefix: '1954'
      - :internal_id: '22'
        :name: US - Georgia
        :minute_price: 0.84
        :prefix: '1229'
      - :internal_id: '85'
        :name: US - Georgia
        :minute_price: 0.84
        :prefix: '1404'
      - :internal_id: '112'
        :name: US - Georgia
        :minute_price: 0.84
        :prefix: '1470'
      - :internal_id: '114'
        :name: US - Georgia
        :minute_price: 0.84
        :prefix: '1478'
      - :internal_id: '191'
        :name: US - Georgia
        :minute_price: 0.84
        :prefix: '1678'
      - :internal_id: '200'
        :name: US - Georgia
        :minute_price: 0.84
        :prefix: '1706'
      - :internal_id: '225'
        :name: US - Georgia
        :minute_price: 0.84
        :prefix: '1770'
      - :internal_id: '290'
        :name: US - Georgia
        :minute_price: 0.84
        :prefix: '1912'
      - :internal_id: '244'
        :name: US - Hawaii
        :minute_price: 0.84
        :prefix: '1808'
      - :internal_id: '8'
        :name: US - Idaho
        :minute_price: 0.84
        :prefix: '1208'
      - :internal_id: '16'
        :name: US - Illinois
        :minute_price: 0.84
        :prefix: '1217'
      - :internal_id: '19'
        :name: US - Illinois
        :minute_price: 0.84
        :prefix: '1224'
      - :internal_id: '55'
        :name: US - Illinois
        :minute_price: 0.84
        :prefix: '1309'
      - :internal_id: '57'
        :name: US - Illinois
        :minute_price: 0.84
        :prefix: '1312'
      - :internal_id: '171'
        :name: US - Illinois
        :minute_price: 0.84
        :prefix: '1618'
      - :internal_id: '176'
        :name: US - Illinois
        :minute_price: 0.84
        :prefix: '1630'
      - :internal_id: '202'
        :name: US - Illinois
        :minute_price: 0.84
        :prefix: '1708'
      - :internal_id: '227'
        :name: US - Illinois
        :minute_price: 0.84
        :prefix: '1773'
      - :internal_id: '250'
        :name: US - Illinois
        :minute_price: 0.84
        :prefix: '1815'
      - :internal_id: '262'
        :name: US - Illinois
        :minute_price: 0.84
        :prefix: '1847'
      - :internal_id: '18'
        :name: US - Indiana
        :minute_price: 0.84
        :prefix: '1219'
      - :internal_id: '36'
        :name: US - Indiana
        :minute_price: 0.84
        :prefix: '1260'
      - :internal_id: '62'
        :name: US - Indiana
        :minute_price: 0.84
        :prefix: '1317'
      - :internal_id: '151'
        :name: US - Indiana
        :minute_price: 0.84
        :prefix: '1574'
      - :internal_id: '223'
        :name: US - Indiana
        :minute_price: 0.84
        :prefix: '1765'
      - :internal_id: '247'
        :name: US - Indiana
        :minute_price: 0.84
        :prefix: '1812'
      - :internal_id: '64'
        :name: US - Iowa
        :minute_price: 0.84
        :prefix: '1319'
      - :internal_id: '131'
        :name: US - Iowa
        :minute_price: 0.84
        :prefix: '1515'
      - :internal_id: '145'
        :name: US - Iowa
        :minute_price: 0.84
        :prefix: '1563'
      - :internal_id: '179'
        :name: US - Iowa
        :minute_price: 0.84
        :prefix: '1641'
      - :internal_id: '204'
        :name: US - Iowa
        :minute_price: 0.84
        :prefix: '1712'
      - :internal_id: '61'
        :name: US - Kansas
        :minute_price: 0.84
        :prefix: '1316'
      - :internal_id: '173'
        :name: US - Kansas
        :minute_price: 0.84
        :prefix: '1620'
      - :internal_id: '234'
        :name: US - Kansas
        :minute_price: 0.84
        :prefix: '1785'
      - :internal_id: '291'
        :name: US - Kansas
        :minute_price: 0.84
        :prefix: '1913'
      - :internal_id: '42'
        :name: US - Kentucky
        :minute_price: 0.84
        :prefix: '1270'
      - :internal_id: '119'
        :name: US - Kentucky
        :minute_price: 0.84
        :prefix: '1502'
      - :internal_id: '160'
        :name: US - Kentucky
        :minute_price: 0.84
        :prefix: '1606'
      - :internal_id: '268'
        :name: US - Kentucky
        :minute_price: 0.84
        :prefix: '1859'
      - :internal_id: '20'
        :name: US - Louisiana
        :minute_price: 0.84
        :prefix: '1225'
      - :internal_id: '63'
        :name: US - Louisiana
        :minute_price: 0.84
        :prefix: '1318'
      - :internal_id: '72'
        :name: US - Louisiana
        :minute_price: 0.84
        :prefix: '1337'
      - :internal_id: '121'
        :name: US - Louisiana
        :minute_price: 0.84
        :prefix: '1504'
      - :internal_id: '325'
        :name: US - Louisiana
        :minute_price: 0.84
        :prefix: '1985'
      - :internal_id: '7'
        :name: US - Maine
        :minute_price: 0.84
        :prefix: '1207'
      - :internal_id: '26'
        :name: US - Maryland
        :minute_price: 0.84
        :prefix: '1240'
      - :internal_id: '47'
        :name: US - Maryland
        :minute_price: 0.84
        :prefix: '1301'
      - :internal_id: '91'
        :name: US - Maryland
        :minute_price: 0.84
        :prefix: '1410'
      - :internal_id: '108'
        :name: US - Maryland
        :minute_price: 0.84
        :prefix: '1443'
      - :internal_id: '73'
        :name: US - Massachusetts
        :minute_price: 0.84
        :prefix: '1339'
      - :internal_id: '76'
        :name: US - Massachusetts
        :minute_price: 0.84
        :prefix: '1351'
      - :internal_id: '93'
        :name: US - Massachusetts
        :minute_price: 0.84
        :prefix: '1413'
      - :internal_id: '125'
        :name: US - Massachusetts
        :minute_price: 0.84
        :prefix: '1508'
      - :internal_id: '170'
        :name: US - Massachusetts
        :minute_price: 0.84
        :prefix: '1617'
      - :internal_id: '228'
        :name: US - Massachusetts
        :minute_price: 0.84
        :prefix: '1774'
      - :internal_id: '232'
        :name: US - Massachusetts
        :minute_price: 0.84
        :prefix: '1781'
      - :internal_id: '266'
        :name: US - Massachusetts
        :minute_price: 0.84
        :prefix: '1857'
      - :internal_id: '321'
        :name: US - Massachusetts
        :minute_price: 0.84
        :prefix: '1978'
      - :internal_id: '23'
        :name: US - Michigan
        :minute_price: 0.84
        :prefix: '1231'
      - :internal_id: '29'
        :name: US - Michigan
        :minute_price: 0.84
        :prefix: '1248'
      - :internal_id: '41'
        :name: US - Michigan
        :minute_price: 0.84
        :prefix: '1269'
      - :internal_id: '58'
        :name: US - Michigan
        :minute_price: 0.84
        :prefix: '1313'
      - :internal_id: '133'
        :name: US - Michigan
        :minute_price: 0.84
        :prefix: '1517'
      - :internal_id: '154'
        :name: US - Michigan
        :minute_price: 0.84
        :prefix: '1586'
      - :internal_id: '169'
        :name: US - Michigan
        :minute_price: 0.84
        :prefix: '1616'
      - :internal_id: '217'
        :name: US - Michigan
        :minute_price: 0.84
        :prefix: '1734'
      - :internal_id: '246'
        :name: US - Michigan
        :minute_price: 0.84
        :prefix: '1810'
      - :internal_id: '285'
        :name: US - Michigan
        :minute_price: 0.84
        :prefix: '1906'
      - :internal_id: '307'
        :name: US - Michigan
        :minute_price: 0.84
        :prefix: '1947'
      - :internal_id: '326'
        :name: US - Michigan
        :minute_price: 0.84
        :prefix: '1989'
      - :internal_id: '17'
        :name: US - Minnesota
        :minute_price: 0.84
        :prefix: '1218'
      - :internal_id: '65'
        :name: US - Minnesota
        :minute_price: 0.84
        :prefix: '1320'
      - :internal_id: '124'
        :name: US - Minnesota
        :minute_price: 0.84
        :prefix: '1507'
      - :internal_id: '165'
        :name: US - Minnesota
        :minute_price: 0.84
        :prefix: '1612'
      - :internal_id: '184'
        :name: US - Minnesota
        :minute_price: 0.84
        :prefix: '1651'
      - :internal_id: '222'
        :name: US - Minnesota
        :minute_price: 0.84
        :prefix: '1763'
      - :internal_id: '309'
        :name: US - Minnesota
        :minute_price: 0.84
        :prefix: '1952'
      - :internal_id: '21'
        :name: US - Mississippi
        :minute_price: 0.84
        :prefix: '1228'
      - :internal_id: '155'
        :name: US - Mississippi
        :minute_price: 0.84
        :prefix: '1601'
      - :internal_id: '187'
        :name: US - Mississippi
        :minute_price: 0.84
        :prefix: '1662'
      - :internal_id: '59'
        :name: US - Missouri
        :minute_price: 0.84
        :prefix: '1314'
      - :internal_id: '97'
        :name: US - Missouri
        :minute_price: 0.84
        :prefix: '1417'
      - :internal_id: '141'
        :name: US - Missouri
        :minute_price: 0.84
        :prefix: '1557'
      - :internal_id: '150'
        :name: US - Missouri
        :minute_price: 0.84
        :prefix: '1573'
      - :internal_id: '178'
        :name: US - Missouri
        :minute_price: 0.84
        :prefix: '1636'
      - :internal_id: '185'
        :name: US - Missouri
        :minute_price: 0.84
        :prefix: '1660'
      - :internal_id: '251'
        :name: US - Missouri
        :minute_price: 0.84
        :prefix: '1816'
      - :internal_id: '87'
        :name: US - Montana
        :minute_price: 0.84
        :prefix: '1406'
      - :internal_id: '54'
        :name: US - Nebraska
        :minute_price: 0.84
        :prefix: '1308'
      - :internal_id: '83'
        :name: US - Nebraska
        :minute_price: 0.84
        :prefix: '1402'
      - :internal_id: '196'
        :name: US - Nevada
        :minute_price: 0.84
        :prefix: '1702'
      - :internal_id: '229'
        :name: US - Nevada
        :minute_price: 0.84
        :prefix: '1775'
      - :internal_id: '157'
        :name: US - New Hampshire
        :minute_price: 0.84
        :prefix: '1603'
      - :internal_id: '140'
        :name: US - New Jersey
        :minute_price: 0.84
        :prefix: '1551'
      - :internal_id: '163'
        :name: US - New Jersey
        :minute_price: 0.84
        :prefix: '1609'
      - :internal_id: '216'
        :name: US - New Jersey
        :minute_price: 0.84
        :prefix: '1732'
      - :internal_id: '263'
        :name: US - New Jersey
        :minute_price: 0.84
        :prefix: '1848'
      - :internal_id: '265'
        :name: US - New Jersey
        :minute_price: 0.84
        :prefix: '1856'
      - :internal_id: '270'
        :name: US - New Jersey
        :minute_price: 0.84
        :prefix: '1862'
      - :internal_id: '287'
        :name: US - New Jersey
        :minute_price: 0.84
        :prefix: '1908'
      - :internal_id: '320'
        :name: US - New Jersey
        :minute_price: 0.84
        :prefix: '1973'
      - :internal_id: '122'
        :name: US - New Mexico
        :minute_price: 0.84
        :prefix: '1505'
      - :internal_id: '1252'
        :name: US - New Mexico
        :minute_price: 0.84
        :prefix: '1575'
      - :internal_id: '11'
        :name: US - New York
        :minute_price: 0.84
        :prefix: '1212'
      - :internal_id: '60'
        :name: US - New York
        :minute_price: 0.84
        :prefix: '1315'
      - :internal_id: '75'
        :name: US - New York
        :minute_price: 0.84
        :prefix: '1347'
      - :internal_id: '132'
        :name: US - New York
        :minute_price: 0.84
        :prefix: '1516'
      - :internal_id: '134'
        :name: US - New York
        :minute_price: 0.84
        :prefix: '1518'
      - :internal_id: '153'
        :name: US - New York
        :minute_price: 0.84
        :prefix: '1585'
      - :internal_id: '161'
        :name: US - New York
        :minute_price: 0.84
        :prefix: '1607'
      - :internal_id: '177'
        :name: US - New York
        :minute_price: 0.84
        :prefix: '1631'
      - :internal_id: '180'
        :name: US - New York
        :minute_price: 0.84
        :prefix: '1646'
      - :internal_id: '208'
        :name: US - New York
        :minute_price: 0.84
        :prefix: '1716'
      - :internal_id: '210'
        :name: US - New York
        :minute_price: 0.84
        :prefix: '1718'
      - :internal_id: '261'
        :name: US - New York
        :minute_price: 0.84
        :prefix: '1845'
      - :internal_id: '292'
        :name: US - New York
        :minute_price: 0.84
        :prefix: '1914'
      - :internal_id: '295'
        :name: US - New York
        :minute_price: 0.84
        :prefix: '1917'
      - :internal_id: '32'
        :name: US - North Carolina
        :minute_price: 0.84
        :prefix: '1252'
      - :internal_id: '71'
        :name: US - North Carolina
        :minute_price: 0.84
        :prefix: '1336'
      - :internal_id: '198'
        :name: US - North Carolina
        :minute_price: 0.84
        :prefix: '1704'
      - :internal_id: '255'
        :name: US - North Carolina
        :minute_price: 0.84
        :prefix: '1828'
      - :internal_id: '289'
        :name: US - North Carolina
        :minute_price: 0.84
        :prefix: '1910'
      - :internal_id: '297'
        :name: US - North Carolina
        :minute_price: 0.84
        :prefix: '1919'
      - :internal_id: '323'
        :name: US - North Carolina
        :minute_price: 0.84
        :prefix: '1980'
      - :internal_id: '324'
        :name: US - North Carolina
        :minute_price: 0.84
        :prefix: '1984'
      - :internal_id: '195'
        :name: US - North Dakota
        :minute_price: 0.84
        :prefix: '1701'
      - :internal_id: '15'
        :name: US - Ohio
        :minute_price: 0.84
        :prefix: '1216'
      - :internal_id: '24'
        :name: US - Ohio
        :minute_price: 0.84
        :prefix: '1234'
      - :internal_id: '69'
        :name: US - Ohio
        :minute_price: 0.84
        :prefix: '1330'
      - :internal_id: '80'
        :name: US - Ohio
        :minute_price: 0.84
        :prefix: '1380'
      - :internal_id: '99'
        :name: US - Ohio
        :minute_price: 0.84
        :prefix: '1419'
      - :internal_id: '106'
        :name: US - Ohio
        :minute_price: 0.84
        :prefix: '1440'
      - :internal_id: '129'
        :name: US - Ohio
        :minute_price: 0.84
        :prefix: '1513'
      - :internal_id: '147'
        :name: US - Ohio
        :minute_price: 0.84
        :prefix: '1567'
      - :internal_id: '167'
        :name: US - Ohio
        :minute_price: 0.84
        :prefix: '1614'
      - :internal_id: '218'
        :name: US - Ohio
        :minute_price: 0.84
        :prefix: '1740'
      - :internal_id: '303'
        :name: US - Ohio
        :minute_price: 0.84
        :prefix: '1937'
      - :internal_id: '86'
        :name: US - Oklahoma
        :minute_price: 0.84
        :prefix: '1405'
      - :internal_id: '152'
        :name: US - Oklahoma
        :minute_price: 0.84
        :prefix: '1580'
      - :internal_id: '296'
        :name: US - Oklahoma
        :minute_price: 0.84
        :prefix: '1918'
      - :internal_id: '120'
        :name: US - Oregon
        :minute_price: 0.84
        :prefix: '1503'
      - :internal_id: '139'
        :name: US - Oregon
        :minute_price: 0.84
        :prefix: '1541'
      - :internal_id: '314'
        :name: US - Oregon
        :minute_price: 0.84
        :prefix: '1971'
      - :internal_id: '14'
        :name: US - Pennsylvania
        :minute_price: 0.84
        :prefix: '1215'
      - :internal_id: '39'
        :name: US - Pennsylvania
        :minute_price: 0.84
        :prefix: '1267'
      - :internal_id: '92'
        :name: US - Pennsylvania
        :minute_price: 0.84
        :prefix: '1412'
      - :internal_id: '109'
        :name: US - Pennsylvania
        :minute_price: 0.84
        :prefix: '1445'
      - :internal_id: '117'
        :name: US - Pennsylvania
        :minute_price: 0.84
        :prefix: '1484'
      - :internal_id: '148'
        :name: US - Pennsylvania
        :minute_price: 0.84
        :prefix: '1570'
      - :internal_id: '164'
        :name: US - Pennsylvania
        :minute_price: 0.84
        :prefix: '1610'
      - :internal_id: '209'
        :name: US - Pennsylvania
        :minute_price: 0.84
        :prefix: '1717'
      - :internal_id: '213'
        :name: US - Pennsylvania
        :minute_price: 0.84
        :prefix: '1724'
      - :internal_id: '249'
        :name: US - Pennsylvania
        :minute_price: 0.84
        :prefix: '1814'
      - :internal_id: '259'
        :name: US - Pennsylvania
        :minute_price: 0.84
        :prefix: '1835'
      - :internal_id: '279'
        :name: US - Pennsylvania
        :minute_price: 0.84
        :prefix: '1878'
      - :internal_id: '82'
        :name: US - Rhode Island
        :minute_price: 0.84
        :prefix: '1401'
      - :internal_id: '239'
        :name: US - South Carolina
        :minute_price: 0.84
        :prefix: '1803'
      - :internal_id: '260'
        :name: US - South Carolina
        :minute_price: 0.84
        :prefix: '1843'
      - :internal_id: '272'
        :name: US - South Carolina
        :minute_price: 0.84
        :prefix: '1864'
      - :internal_id: '159'
        :name: US - South Dakota
        :minute_price: 0.84
        :prefix: '1605'
      - :internal_id: '100'
        :name: US - Tennessee
        :minute_price: 0.84
        :prefix: '1423'
      - :internal_id: '168'
        :name: US - Tennessee
        :minute_price: 0.84
        :prefix: '1615'
      - :internal_id: '215'
        :name: US - Tennessee
        :minute_price: 0.84
        :prefix: '1731'
      - :internal_id: '273'
        :name: US - Tennessee
        :minute_price: 0.84
        :prefix: '1865'
      - :internal_id: '280'
        :name: US - Tennessee
        :minute_price: 0.84
        :prefix: '1901'
      - :internal_id: '301'
        :name: US - Tennessee
        :minute_price: 0.84
        :prefix: '1931'
      - :internal_id: '10'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1210'
      - :internal_id: '13'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1214'
      - :internal_id: '34'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1254'
      - :internal_id: '44'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1281'
      - :internal_id: '68'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1325'
      - :internal_id: '79'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1361'
      - :internal_id: '90'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1409'
      - :internal_id: '102'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1430'
      - :internal_id: '103'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1432'
      - :internal_id: '111'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1469'
      - :internal_id: '128'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1512'
      - :internal_id: '192'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1682'
      - :internal_id: '205'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1713'
      - :internal_id: '242'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1806'
      - :internal_id: '252'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1817'
      - :internal_id: '256'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1830'
      - :internal_id: '258'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1832'
      - :internal_id: '282'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1903'
      - :internal_id: '293'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1915'
      - :internal_id: '302'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1936'
      - :internal_id: '305'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1940'
      - :internal_id: '311'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1956'
      - :internal_id: '319'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1972'
      - :internal_id: '322'
        :name: US - Texas
        :minute_price: 0.84
        :prefix: '1979'
      - :internal_id: '315'
        :name: US - Toll Free
        :minute_price: 2.4
        :prefix: '1800'
      - :internal_id: '1253'
        :name: US - Toll Free
        :minute_price: 2.4
        :prefix: '1822'
      - :internal_id: '1254'
        :name: US - Toll Free
        :minute_price: 2.4
        :prefix: '1833'
      - :internal_id: '1255'
        :name: US - Toll Free
        :minute_price: 2.4
        :prefix: '1844'
      - :internal_id: '1256'
        :name: US - Toll Free
        :minute_price: 2.4
        :prefix: '1855'
      - :internal_id: '317'
        :name: US - Toll Free
        :minute_price: 2.4
        :prefix: '1866'
      - :internal_id: '318'
        :name: US - Toll Free
        :minute_price: 2.4
        :prefix: '1877'
      - :internal_id: '1257'
        :name: US - Toll Free
        :minute_price: 2.4
        :prefix: '1880'
      - :internal_id: '1258'
        :name: US - Toll Free
        :minute_price: 2.4
        :prefix: '1881'
      - :internal_id: '1259'
        :name: US - Toll Free
        :minute_price: 2.4
        :prefix: '1882'
      - :internal_id: '1260'
        :name: US - Toll Free
        :minute_price: 2.4
        :prefix: '1883'
      - :internal_id: '1261'
        :name: US - Toll Free
        :minute_price: 2.4
        :prefix: '1884'
      - :internal_id: '1262'
        :name: US - Toll Free
        :minute_price: 2.4
        :prefix: '1885'
      - :internal_id: '1263'
        :name: US - Toll Free
        :minute_price: 2.4
        :prefix: '1886'
      - :internal_id: '1264'
        :name: US - Toll Free
        :minute_price: 2.4
        :prefix: '1887'
      - :internal_id: '316'
        :name: US - Toll Free
        :minute_price: 2.4
        :prefix: '1888'
      - :internal_id: '1265'
        :name: US - Toll Free
        :minute_price: 2.4
        :prefix: '1889'
      - :internal_id: '105'
        :name: US - Utah
        :minute_price: 0.84
        :prefix: '1435'
      - :internal_id: '237'
        :name: US - Utah
        :minute_price: 0.84
        :prefix: '1801'
      - :internal_id: '238'
        :name: US - Vermont
        :minute_price: 0.84
        :prefix: '1802'
      - :internal_id: '43'
        :name: US - Virginia
        :minute_price: 0.84
        :prefix: '1276'
      - :internal_id: '104'
        :name: US - Virginia
        :minute_price: 0.84
        :prefix: '1434'
      - :internal_id: '138'
        :name: US - Virginia
        :minute_price: 0.84
        :prefix: '1540'
      - :internal_id: '149'
        :name: US - Virginia
        :minute_price: 0.84
        :prefix: '1571'
      - :internal_id: '197'
        :name: US - Virginia
        :minute_price: 0.84
        :prefix: '1703'
      - :internal_id: '220'
        :name: US - Virginia
        :minute_price: 0.84
        :prefix: '1757'
      - :internal_id: '240'
        :name: US - Virginia
        :minute_price: 0.84
        :prefix: '1804'
      - :internal_id: '6'
        :name: US - Washington
        :minute_price: 0.84
        :prefix: '1206'
      - :internal_id: '33'
        :name: US - Washington
        :minute_price: 0.84
        :prefix: '1253'
      - :internal_id: '78'
        :name: US - Washington
        :minute_price: 0.84
        :prefix: '1360'
      - :internal_id: '101'
        :name: US - Washington
        :minute_price: 0.84
        :prefix: '1425'
      - :internal_id: '126'
        :name: US - Washington
        :minute_price: 0.84
        :prefix: '1509'
      - :internal_id: '146'
        :name: US - Washington
        :minute_price: 0.84
        :prefix: '1564'
      - :internal_id: '2'
        :name: US - Washington DC
        :minute_price: 0.84
        :prefix: '1202'
      - :internal_id: '50'
        :name: US - West Virginia
        :minute_price: 0.84
        :prefix: '1304'
      - :internal_id: '37'
        :name: US - Wisconsin
        :minute_price: 0.84
        :prefix: '1262'
      - :internal_id: '94'
        :name: US - Wisconsin
        :minute_price: 0.84
        :prefix: '1414'
      - :internal_id: '162'
        :name: US - Wisconsin
        :minute_price: 0.84
        :prefix: '1608'
      - :internal_id: '207'
        :name: US - Wisconsin
        :minute_price: 0.84
        :prefix: '1715'
      - :internal_id: '298'
        :name: US - Wisconsin
        :minute_price: 0.84
        :prefix: '1920'
      - :internal_id: '53'
        :name: US - Wyoming
        :minute_price: 0.84
        :prefix: '1307'
      - :internal_id: '1251'
        :name: Uzbekistan (Republic
        :minute_price: 1.82
        :prefix: '998'
      - :internal_id: '1112'
        :name: Vanuatu (Republic of
        :minute_price: 12.09
        :prefix: '678'
      - :internal_id: '628'
        :name: Vatican City
        :minute_price: 0.52
        :prefix: '379'
      - :internal_id: '1063'
        :name: Venezuela (Bolivaria
        :minute_price: 0.65
        :prefix: '58'
      - :internal_id: '1064'
        :name: Venezuela (Bolivaria
        :minute_price: 0.52
        :prefix: '58212'
      - :internal_id: '1065'
        :name: Venezuela (Bolivaria
        :minute_price: 0.52
        :prefix: '58241'
      - :internal_id: '1066'
        :name: Venezuela (Bolivaria
        :minute_price: 0.52
        :prefix: '58261'
      - :internal_id: '1067'
        :name: Venezuela (Bolivaria
        :minute_price: 3.38
        :prefix: '58412'
      - :internal_id: '1068'
        :name: Venezuela (Bolivaria
        :minute_price: 3.38
        :prefix: '58414'
      - :internal_id: '1069'
        :name: Venezuela (Bolivaria
        :minute_price: 3.38
        :prefix: '58415'
      - :internal_id: '1070'
        :name: Venezuela (Bolivaria
        :minute_price: 2.86
        :prefix: '58416'
      - :internal_id: '1071'
        :name: Venezuela (Bolivaria
        :minute_price: 3.38
        :prefix: '58417'
      - :internal_id: '1072'
        :name: Venezuela (Bolivaria
        :minute_price: 3.38
        :prefix: '58418'
      - :internal_id: '1186'
        :name: Viet Nam (Socialist
        :minute_price: 4.16
        :prefix: '84'
      - :internal_id: '1115'
        :name: Wallis and Futuna (T
        :minute_price: 17.29
        :prefix: '681'
      - :internal_id: '1218'
        :name: Yemen (Republic of)
        :minute_price: 3.25
        :prefix: '967'
      - :internal_id: '383'
        :name: Zambia (Republic of)
        :minute_price: 1.43
        :prefix: '260'
      - :internal_id: '384'
        :name: Zambia (Republic of)
        :minute_price: 3.12
        :prefix: '26095'
      - :internal_id: '385'
        :name: Zambia (Republic of)
        :minute_price: 3.12
        :prefix: '26096'
      - :internal_id: '386'
        :name: Zambia (Republic of)
        :minute_price: 3.12
        :prefix: '26097'
      - :internal_id: '382'
        :name: Zanzibar
        :minute_price: 18.33
        :prefix: '259'
      - :internal_id: '389'
        :name: Zimbabwe (Republic o
        :minute_price: 5.85
        :prefix: '263'
