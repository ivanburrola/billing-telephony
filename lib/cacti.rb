#!/usr/local/bin/ruby

require './lib/utils'
require 'yaml'
require 'mechanize'
require 'mongo'
require 'csv'

class CactiExtract
  def initialize(cacti_url, login, password, collection)
    @mechanize, @cacti_url, @login, @password, @collection = Mechanize.new, cacti_url, login, password, collection
  end

  def fetch(ts_from, ts_to, graph_id)
    s = Time.now
    puts "Fetching graph data..."
    login_uri = @cacti_url+'/index.php'
    graph_uri = @cacti_url+'/graph_xport.php'
    graph_params = { :graph_start => (ts_from.to_i-300).to_s.strip, :graph_end => ts_to.to_i.to_s.strip, :local_graph_id => graph_id.to_s.strip, :rra_id => "0" }

    if (ENV["LOCALDEBUG"]||'').strip.downcase =~ /^(yes|on|true|1)$/
      puts "Simulating Cacti data fetch..."
      local_test_data_fname = File.join(File.dirname(__FILE__), '..', 'config', 'test_local_cacti_fetch.yml')
      full = YAML.load(open(local_test_data_fname).read)
      puts "Done."
    else
      puts "Fetching data from Cacti..."
      agent = Mechanize.new
      page = agent.get(login_uri)
      login_form = page.form('login')
      login_form.login_username = @login
      login_form.login_password = @password
      page = agent.submit(login_form)
      page = agent.get(graph_uri, graph_params)
      full = CSV.parse(page.body)
      puts "Done."
    end

    puts ("Fetched in %i seconds." % [ Time.now-s ])

    title = full[0][1]

    c=0; c += 1 until (full[c] == [""])

    # Get CSV's text column headers
    headers = full[c+1]

    # Turn it into a hash like:
    #
    # { 0 => { id: "col_0_date", label: "Date" },
    #   1 => { id: "col_1_something_else", label: "Something Else" } }
    #
    headers = (0..headers.size-1).map do |n|
      {
        n => {
          id: "col_#{n}_"+headers[n].downcase.gsub(/[^0-9a-z_]+/,'_'),
          label: headers[n]
        }
      }
    end.hashes_merge

    detail_ext = full[c+2..-1]

    puts "Inserting fetched data into database..."
    s = Time.now
    t = detail_ext.size
    c = 0
    detail = detail_ext.each do |r|
      c += 1
      print "\x0d\tInserting row #{c} of #{t}      "
      data = [ Time.parse(r[0]), *(r[1..-1].map(&:to_f)) ]
      insert_doc = 0.upto(data.size-1).to_a.map{ |n| { headers[n][:id] => data[n] }}.hashes_merge
      @collection.insert(insert_doc)
    end
    puts
    puts ("Inserted in %i seconds." % [ Time.now-s ])

    [ title, headers ]
  end
end

