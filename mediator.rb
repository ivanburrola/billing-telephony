#!/usr/bin/env ruby

require './lib/mediator_options'
require './lib/configuration'

# Load configuration before building MySQL ActiveRecord classes
# BAD PRACTICE! : Made it this way to avoid unnecessary complication
#                 with class generators to generate MvtsCdr class
#                 post-requires phase.
$options = MediatorOptions.parse(ARGV)

require './lib/mediator_fetcher'

MediatorFetcher::fetch


