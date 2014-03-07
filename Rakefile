# encoding: utf-8

require 'resque/tasks'
require 'resque'
require 'pp'
require 'pry'

require './lib/customer_bill_job.rb'
require './lib/data_billing_job.rb'

Resque.logger = Logger.new(STDOUT)
Resque.logger.level = Logger::INFO
Resque.logger.level = Logger::DEBUG if (ENV["DEBUG"]||'').strip.downcase =~ /(1|yes|on)/

def pp_prefix(obj, prefix="")
	output=""
	PP.pp(obj, output)
	output = output.split(/\n/).map{ |line| prefix + line }.join("\n")
	return output
end


namespace :app do
	namespace :resque do
		desc "List failed Resque jobs"
		task :list do
			puts "List of failed retry jobs:"
			failures = Resque::Failure.all(0, Resque::Failure.count)
			failures = [ failures ] unless failures.class == Array
			failures.each do |failure|
				puts "-"*80
				puts failure["failed_at"]
				puts "-"*80
				puts pp_prefix(failure, "\t")
				puts
			end
		end

		desc "Brief list of failed Resque jobs"
		task :brief do
			puts "Brief list of failed retry jobs:"
			failures = Resque::Failure.all(0, Resque::Failure.count)
			failures = [ failures ] unless failures.class == Array
			failures.each do |failure|
				failure.delete("backtrace")
				puts "-"*80
				puts failure["failed_at"]
				puts "-"*80
				puts pp_prefix(failure, "\t")
				puts
			end
		end

		desc "Only IDs list of failed Resque jobs"
		task :ids do
			puts "Very short list of failed retry jobs showing their IDs:"
			i = 0
			failures = Resque::Failure.all(0, Resque::Failure.count)
			failures = [ failures ] unless failures.class == Array
			failures.each do |failure|
				i += 1
				failure.delete("backtrace")
				puts "-"*80
				puts ("[ %12s ] - %20s - %s\n\n%s\n\n" % [ "JOB_ID=#{i}", failure["failed_at"], failure["exception"], pp_prefix(failure["payload"], "\t") ])
			end
			puts "Done."
		end

		desc "Retry specific (JOB_ID=n) failed Resque jobs"
		task :retry do
			cnt = Resque::Failure.count

			raise Exception.new("No jobs to be retried.") if cnt == 0
			job_id_str = (ENV['JOB_ID']||'').strip
			raise Exception.new("Invalid JOB_ID #{job_id_str}") unless job_id_str =~ /^\d+$/
			job_id = job_id_str.to_i
			raise Exception.new("JOB_ID is out of range (#{job_id}, must be between 1 and #{cnt})") unless (1..cnt).include?(job_id)

			i = job_id - 1

			puts "Retrying failed job with Id JOB_ID=#{job_id}."
			Resque::Failure.requeue(i)
			puts "Done."
			puts
		end

		desc "Retry All failed Resque jobs"
		task :retry_all do
			cnt = Resque::Failure.count
			raise Exception.new("No jobs to be retried.") if cnt == 0
			puts "Retrying #{cnt} failed jobs."
			Resque::Failure.count.times do |i|
				Resque::Failure.requeue(i)
			end
			puts "Done."
			puts
		end

		desc "Retry Oldest failed Resque jobs"
		task :retry_oldest do
			cnt = Resque::Failure.count
			raise Exception.new("No jobs to be retried.") if cnt == 0
			if cnt > 0
				puts "Retrying oldest failed job."
				i=0
				Resque::Failure.requeue(i)
			else
				puts "No failed jobs to retry."
			end
			puts "Done."
			puts
		end

		desc "Retry Newest failed Resque jobs"
		task :retry_newest do
			cnt = Resque::Failure.count
			raise Exception.new("No jobs to be retried.") if cnt == 0
			if cnt > 0
				puts "Retrying newest failed job."
				i=cnt-1
				Resque::Failure.requeue(i)
			else
				puts "No failed jobs to retry."
			end
			puts "Done."
			puts
		end

		desc "Clear failed Resque jobs"
		task :clear do
			cnt = Resque::Failure.count
			puts "Clearing #{cnt} failed jobs."
			Resque::Failure.clear
			puts "Done."
			puts
		end
	end
end

