# encoding: utf-8

require 'pry'
require 'logger'
require 'mongo'

class BillingMongo
  def initialize(options)
    @mongo_logger = Logger.new(STDERR)
    @mongo_logger.level = Logger::WARN
    @mongo_client = Mongo::MongoClient.new("localhost", 27017, pool_size: 15, pool_timeout: 10, logger: @mongo_logger)
    @mongo_db = @mongo_client.db("billing")

    @mongo_cdrs = @mongo_db.collection("call_detail_records_"+( "%04i%02i" % [ options[:year], options[:month] ] ))
    @mongo_cdrs.ensure_index(gateway: Mongo::ASCENDING)
    @mongo_cdrs.ensure_index(host: Mongo::ASCENDING)
    @mongo_cdrs.ensure_index(identifier: Mongo::ASCENDING)
    @mongo_cdrs.ensure_index(gateway: Mongo::ASCENDING, host: Mongo::ASCENDING)
    @mongo_cdrs.ensure_index(gateway: Mongo::ASCENDING, identifier: Mongo::ASCENDING)
    @mongo_cdrs.ensure_index(host: Mongo::ASCENDING, identifier: Mongo::ASCENDING)
    @mongo_cdrs.ensure_index(gateway: Mongo::ASCENDING, host: Mongo::ASCENDING, identifier: Mongo::ASCENDING)
    @mongo_cdrs.ensure_index(call_date: Mongo::ASCENDING)
    @mongo_cdrs.ensure_index(destination: Mongo::ASCENDING)
    @mongo_cdrs.ensure_index(duration: Mongo::ASCENDING)

    @mongo_invoices = @mongo_db.collection("invoices_repository")
  end

  def logger
    @mongo_logger
  end

  def db
    @mongo_db
  end

  def cdrs
    @mongo_cdrs
  end

  def invoices
    @mongo_invoices
  end

  def last_cdr_id
    last_id_res = @mongo_cdrs.find().sort(_id: -1).first
    last_cdr_id = nil
    last_cdr_id = last_id_res["_id"] if last_id_res
    last_cdr_id
  end
end

