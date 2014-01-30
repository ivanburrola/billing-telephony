# encoding: utf-8

require 'active_record'

$mvts_db_config={
    host: Configuration.remote.hostname,
    database: Configuration.remote.database,
    username: Configuration.remote.username,
    password: Configuration.remote.password,
    adapter: "mysql2",
    encoding: "utf8",
    pool: "5"
}

ActiveRecord::Base.logger = Logger.new(STDOUT) if $options.debug

class MvtsCdr < ActiveRecord::Base

  establish_connection($mvts_db_config)

  self.table_name = "mvts_cdr_"+( "%04i%02i" % [ $options.year, $options.month ] )

  self.primary_key = "cdr_id"

  default_scope {
    where("in_ani is not null").
        where("out_dnis is not null").
        where("elapsed_time is not null").
        where("length(in_ani) >= 10").
        where("length(out_dnis) >= 10").
        where("elapsed_time > 0").
        where("elapsed_time < 86000000").
        where("(out_dnis regexp '#{ Configuration.toll_free_regexp }' and src_name not regexp '^Genpact (MX|US)') or src_name not in (#{ Configuration.core_gateways.map{|cg| '"'+cg.strip+'"' }.join(', ') })").
        where("out_dnis not regexp '^160117656[0-9]{7}$'").
        where("out_dnis not regexp '^[0-9]{6}656[0-9]{7}$'")
  }

  def clean
    {
        _id: cdr_id.to_i,
        gateway: (src_name||'').strip,
        host: (remote_src_sig_address||'').gsub(/\:.*$/,''),
        identifier: in_ani.strip,
        call_date: cdr_date,
        source: clean_id(in_ani),
        destination: clean_id(out_dnis),
        duration: ((elapsed_time||0.0)/1000.0).ceil
    }
  end

  def to_s
    clean.inspect
  end

  private

  def clean_id(str)
    (str || '').
        strip.
        gsub(/^((656|614)\d{7})$/, '52\1').
        gsub(/^(55\d{8})$/, '52\1').
        gsub(/^(04[45]\d{10})$/, '52\1').
        gsub(/^((915|919|956)\d{7})$/, '1\1').
        gsub(/^001(\d+)$/, '1\1')
  end
end
