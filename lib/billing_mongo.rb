# encoding: utf-8

require 'mongo'

class BillingMongo
  def initialize(options)
    @mongo_client = Mongo::MongoClient.new("localhost", 27017, pool_size: 10, pool_timeout: 5)
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
  end

  def cdrs
    @mongo_cdrs
  end

  def last_cdr_id
    last_id_res = @mongo_cdrs.find().sort(_id: -1).first
    last_cdr_id = nil
    last_cdr_id = last_id_res["_id"] if last_id_res
    last_cdr_id
  end
end

