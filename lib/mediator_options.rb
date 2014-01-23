# encoding: utf-8

require 'optparse'
require 'optparse/time'

# This script is supposed to be run every 20 minutes.

$minutes_between_runs = 20

class MediatorOptions
  Version = [ 0, 0, 1 ]

  def self.parse(args)

    options = OpenStruct.new

    default_time = ->(t){ tt=t-(($minutes_between_runs * 1.5).ceil * 60); OpenStruct.new(year: tt.year, month: tt.month) }.call(Time.now)

    options.year = default_time.year
    options.month = default_time.month

    options.from_id = nil

    options.debug = false

    parser = OptionParser.new do |opts|
      opts.banner = "Usage: mediator.rb [options]"
      opts.separator ""
      opts.separator "Specific options:"

      opts.on("-y", "--year YEAR", "Specify year to fetch CDRs from") do |v|
        raise ArgumentError.new("invalid year value") unless v =~ /^\d+$/
        options.year = v.strip.to_i
      end

      opts.on("-m", "--month MONTH", "Specify month to fetch CDRs from") do |v|
        options.month = v.strip.to_i
      end

      opts.on("-f", "--from-id CDR_ID", "Will perform a fetch of CDRS with cdr_id > CDR_ID") do |v|
        options.from_id = v.strip.to_i
      end

      opts.on("-d", "--debug", "Will output database debug information") do |v|
        options.debug = true if v
      end

      opts.separator ""

      opts.separator "Common options:"

      opts.on_tail("-h", "--help", "Show this message") do
        puts opts
        exit
      end

      opts.on_tail("--version", "Show version") do
        puts "Transtelco MVTS Pro Mediator v"+MediatorOptions::Version.join('.')
        exit
      end
    end

    parser.parse!(args)
    options

  end
end
