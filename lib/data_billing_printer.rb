# encoding: utf-8

require 'axlsx'
require 'pry'
require 'pp'

require './lib/utils'

class DataBillingPrinter
	def initialize(options)
		@customer_id = options[:customer_id]
		@customer_name = options[:customer_name]
		@year = options[:year]
		@month = options[:month]
		@graph_def = options[:graph_def]
		@pricing_def = options[:pricing_def]
		@graph_id = options[:graph_id]
		@records = options[:records]
		@title = options[:title]
		@headers = options[:headers]
		@inbound_columns = options[:inbound_columns]
		@outbound_columns = options[:outbound_columns]
		@results = options[:results]
		@generation_time = Time.now
		@filename = "data"+
		            "::"+
		            @customer_name.downcase.gsub(/[^a-z0-9]+/, '_')+
		            "::"+
		            @customer_id.to_s+
		            "::"+
		            @graph_id.to_s+
		            "::"+
		            @year+@month+
		            "::"+
		            @generation_time.strftime("%Y%m%d%H%M%S%z")+
		            ".xlsx"
		@filedir = File.join(
			File.dirname(__FILE__),
			"..",
			"invoices"
		)
		@filepath = File.join(@filedir, @filename)
		FileUtils.touch(@filepath)
		@fullfilepath = File.realpath(@filepath)
		@p = Axlsx::Package.new
		@wb = @p.workbook
	end

	def print
		@ws_totals = @wb.add_worksheet(name: "Totals")
		@ws_summarized = @wb.add_worksheet(name: "Summarized")
		@ws_detail = @wb.add_worksheet(name: "Detail")
		print_detail(@ws_detail)
		print_summarized(@ws_summarized)
		print_totals(@ws_totals)
		@p.serialize(@fullfilepath)
		@fullfilepath
	end

	private

	def print_detail(ws)
		@wb.styles do |s|
			style_title = s.add_style bg_color: "000033", fg_color: "ffffff", sz: 18, alignment: { :horizontal=> :center }, border: Axlsx::STYLE_THIN_BORDER
			style_header = s.add_style bg_color: "333399", fg_color: "ffffff", sz: 14, alignment: { :horizontal=> :center }, border: Axlsx::STYLE_THIN_BORDER
			style_date = s.add_style format_code: "YYYY/MM/DD HH:MM:SS", sz: 12
			style_regular = s.add_style format_code: "YYYY/MM/DD HH:MM:SS", sz: 12, format_code: "#,##0.00000"
			ws.add_row(["Graph Details"], style: [ style_title ])
			ws.add_row(0.upto(@headers.size-1).map{ |i| @headers[i][:label] }, style: style_header)
			ws.merge_cells("A1:I1")
			@records.find.sort("col_0_date" => Mongo::ASCENDING).each do |row|
				ws.add_row(
					0.upto(@headers.size-1).map{ |i| @headers[i][:id] }.map{ |field| row[field] },
					style: [ style_date, style_regular, style_regular, style_regular, style_regular, style_regular, style_regular, style_regular, style_regular ]
				)
			end
			ws.column_widths 25, 35, 35, 35, 35, 35, 35, 35, 35
		end
	end

	def print_summarized(ws)
		@wb.styles do |s|
			style_title = s.add_style bg_color: "000033", fg_color: "ffffff", sz: 18, alignment: { :horizontal=> :center }, border: Axlsx::STYLE_THIN_BORDER
			style_header = s.add_style bg_color: "333399", fg_color: "ffffff", sz: 14, alignment: { :horizontal=> :center }, border: Axlsx::STYLE_THIN_BORDER
			style_date = s.add_style format_code: "YYYY/MM/DD HH:MM:SS", sz: 12
			style_regular = s.add_style format_code: "YYYY/MM/DD HH:MM:SS", sz: 12, format_code: "#,##0.00000"
			ws.add_row(["Summarized"], style: [ style_title ])
			ws.add_row([ "Date", "Inbound", "Outbound" ], style: style_header)
			ws.merge_cells("A1:C1")
			@records.find.sort("col_0_date" => Mongo::ASCENDING).each do |row|
				ws.add_row(
					[ row["col_0_date"], row["subtotals"]["inbound"], row["subtotals"]["outbound"] ],
					style: [ style_date, style_regular, style_regular ]
				)
			end
			ws.column_widths 25, 35, 35
		end
	end

	def print_totals(ws)
		@wb.styles do |s|
			style_title = s.add_style bg_color: "000033", fg_color: "ffffff", sz: 18, alignment: { :horizontal=> :center }, border: Axlsx::STYLE_THIN_BORDER
			style_header = s.add_style bg_color: "333399", fg_color: "ffffff", sz: 14, alignment: { :horizontal=> :center }, border: Axlsx::STYLE_THIN_BORDER
			style_date = s.add_style format_code: "YYYY/MM/DD HH:MM:SS", sz: 12
			style_regular = s.add_style sz: 12, format_code: "#,##0.00000"
			style_ccy = s.add_style sz: 12, format_code: "$#,##0.00"
			style_right = s.add_style sz: 12, alignment: { :horizontal => :right }
			ws.add_row(["Totals"], style: [ style_title ])
			ws.merge_cells("A1:B1")

			date_limits = @records.aggregate([ "$group" => { "_id" => true, min: { "$min" => "$col_0_date" }, max: { "$max" => "$col_0_date" }, max_samples: { "$max" => "$subtotals.outbound" } } ])

			total_samples = @records.count
			date_min = date_limits.first["min"]
			date_max = date_limits.first["max"]
			max_samples = date_limits.first["max_samples"]
			kth_num = (total_samples.to_f * 0.0500).floor
			kth_largest = @records.find({ row_number: (total_samples - kth_num + 1) }, fields: { "_id" => false, "subtotals.outbound" => true }).first["subtotals"]["outbound"]
			mbs = kth_largest / 1024.0 / 1024.0
			price_per_mb = @results[:price_per_mb]
			total = price_per_mb * mbs

			ws.add_row([ "Customer", "#{@customer_name} (#{@customer_id})" ], style: [ style_header, style_right ])
			ws.add_row([ "Graph Name", @title ], style: [ style_header, style_right ])
			ws.add_row([ "Date Start", date_min ], style: [ style_header, style_date ])
			ws.add_row([ "Date End", date_max ], style: [ style_header, style_date ])
			ws.add_row([ "Total Samples", total_samples ], style: [ style_header, nil ])
			ws.add_row([ "Percentile Used", 95.0 ], style: [ style_header, style_regular ])
			ws.add_row([ "5.0 Percent", kth_num ], style: [ style_header, style_regular ])
			ws.add_row([ "Peak", max_samples ], style: [ style_header, style_regular ])
			ws.add_row([ "Kth Largest", kth_largest ], style: [ style_header, style_regular ])
			ws.add_row([ "95th Percentile", mbs ], style: [ style_header, style_regular ])
			ws.add_row([ "Price per Mbps", @results[:price_per_mb] ], style: [ style_header, style_ccy ])
			ws.add_row([ "Total", total ], style: [ style_header, style_ccy ])
			ws.add_row([ ], style: [ style_header, nil ])
			ws.add_row([ "Generated On", @generation_time ], style: [ style_header, style_date ])

			ws.column_widths 35, 45
		end
	end
end


