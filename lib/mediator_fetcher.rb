# encoding: utf-8

require './lib/mvts_cdr'
require './lib/billing_mongo'

module MediatorFetcher
  def self.fetch
    puts
    puts "Mediating for:"
    puts "\tYear: #{$options.year}"
    puts "\tMonth: #{$options.month}"
    puts

    query = MvtsCdr

    billing_mongo = BillingMongo.new(year: $options.year, month: $options.month)

    if billing_mongo.last_cdr_id
      puts "Current last CDR Id found in Mongo : [#{billing_mongo.last_cdr_id}]"
      query = query.where("cdr_id > ?", billing_mongo.last_cdr_id)
    else
      puts "No last CDR Id was found in Mongo, bringing everything."
      query = query.all
    end

    puts

    cdrs_total = query.count
    puts "Records to fetch from MVTS Pro:[#{cdrs_total}]"
    puts

    batch_number = 0
    cdr_number = 0

    query.find_in_batches(batch_size: 10000) do |batch|
      batch_number += 1
      puts "BATCH ##{batch_number}"
      batch.each do |cdr|
        cdr_number += 1
        print "\x0d%7i/%7i (%6.2f%%)          " % [ cdr_number, cdrs_total, 100.0*cdr_number/cdrs_total, cdr ]
        billing_mongo.cdrs.insert(cdr.clean)
      end
      puts
    end

    puts "Done."
  end
end
