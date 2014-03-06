require 'axlsx'

class TelephonyCustomerBillerPrinter
    attr_reader :totals
    def initialize(customer, origin, year, month, cdrs)
      @customer, @origin, @year, @month, @cdrs = customer, origin, year, month, cdrs
      @generation_time = Time.now
      @p = Axlsx::Package.new
      @wb = @p.workbook
      @filename = "telephony"+
                  "::"+
                  @customer[:name].gsub(/[^A-Z0-9_-]+/i, '_')+
                  "::"+
                  @customer[:id]+
                  "::"+
                  @origin[:name].gsub(/[^A-Z0-9_-]+/i, '_')+
                  "::"+
                  @origin[:internal_id].to_s+
                  "::"+
                  ("%04i%02i" % [@year.to_i, @month.to_i])+
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
      @totals = nil
    end

    def print
      add_totals_page
      add_details_page
      @p.serialize(@fullfilepath)
      @fullfilepath
    end

    def add_totals_page
      @p.use_autowidth = true
      ws_totals = @wb.add_worksheet(name: "Totals") do |sheet|
        @totals = @cdrs.group(
                    key: "pricing.final_pricing.call_type",
                    cond: {
                      "billing.customer_id" => @customer[:id].to_i,
                      "billing.origin_id" => @origin[:internal_id]
                    },
                    initial: {
                      minutes: 0,
                      calls: 0,
                      amount: 0,
                      currency: ""
                    },
                    reduce:  "function(cur, result){
                                result.currency = cur.pricing.final_pricing.currency;
                                result.minutes += cur.pricing.final_pricing.minutes;
                                result.calls += 1;
                                result.amount += cur.pricing.final_pricing.total;
                              }")
        @wb.styles do |s|
          black_cell_left = s.add_style :bg_color => "000033", :fg_color => "ffffff", :sz => 14
          black_cell = s.add_style :bg_color => "000033", :fg_color => "ffffff", :sz => 14, :alignment => { :horizontal=> :center }
          black_cell_title = s.add_style :bg_color => "000033", :fg_color => "ffffff", :sz => 22, :alignment => { :horizontal=> :center }
          black_cell_sub = s.add_style :bg_color => "000033", :fg_color => "ffffff", :sz => 8, :alignment => { :horizontal=> :center }
          money = s.add_style :format_code => '[$$-409]#,##0.00;[RED]-[$$-409]#,##0.00', border: Axlsx::STYLE_THIN_BORDER
          money_black = s.add_style :format_code => '[$$-409]#,##0.00;[RED]-[$$-409]#,##0.00', border: Axlsx::STYLE_THIN_BORDER, :bg_color => "000033", :fg_color => "ffffff", :sz => 14

          (1..4).each do |row_num|
            sheet.merge_cells "A#{row_num}:E#{row_num}"
          end

          sheet.add_row [ @customer[:name] ], style: black_cell_title
          sheet.add_row [ @origin[:name] ], style: black_cell
          sheet.add_row [ "Invoice for %04i/%02i" % [ @year, @month ] ], style: black_cell
          sheet.add_row [ "Generated on %s" % [ @generation_time.strftime("%Y-%m-%d %H:%M:%S %:z") ] ], style: black_cell_sub

          sheet.add_row [ nil ]

          sheet.add_row [ "Call Type", "Minutes", "Calls", "Subtotal", "Currency" ], :style => black_cell
          final_total = 0.00
          ccy_name = nil
          @totals.each do |row|
            ccy_name = row["currency"]
            sheet.add_row [
              Configuration.call_type_names[row["pricing.final_pricing.call_type"].to_sym],
              row["minutes"].to_i,
              row["calls"].to_i,
              row["amount"].to_f,
              ccy_name
            ], style: [ Axlsx::STYLE_THIN_BORDER, Axlsx::STYLE_THIN_BORDER, Axlsx::STYLE_THIN_BORDER, money, Axlsx::STYLE_THIN_BORDER ]
            final_total += row["amount"].to_f
          end
          sheet.add_row [ nil, nil, "Total", final_total, ccy_name ], style: [ nil, nil, black_cell, money_black, black_cell_left ]
        end
        sheet.column_widths 50, 20, 20, 20, 20
      end
    end

    def add_details_page
      ws_details = @wb.add_worksheet(name: "Details") do |sheet|
        @wb.styles do |styles|
          headers = styles.add_style bg_color: "000033", fg_color: "ffffff", sz: 14, border: Axlsx::STYLE_THIN_BORDER, alignment: { horizontal: :center }
          details = styles.add_style sz: 10, border: Axlsx::STYLE_THIN_BORDER
          call_date = styles.add_style format_code: 'YYYY-MM-DD HH:MM:SS', sz: 10, border: Axlsx::STYLE_THIN_BORDER
          totals = styles.add_style format_code: '[$$-409]#,##0.00;[RED]-[$$-409]#,##0.00', sz: 10, border: Axlsx::STYLE_THIN_BORDER
          sheet.add_row [
            "ID",
            "Call Date",
            "Gateway",
            "Host Address",
            "Caller Identifier",
            "Source",
            "Destination",
            "Duration in Seconds",
            "Pricing Method",
            "Call Type",
            "Trunk Type",
            "Duration in Minutes",
            "Currency",
            "Call Total"
          ], style: headers
          @cdrs.find({ "billing.customer_id" => @customer[:id].to_i, "billing.origin_id" => @origin[:internal_id] }).each do |row|
            sheet.add_row [
              "ID"+row["_id"].to_s,
              row["call_date"],
              row["gateway"],
              row["host"],
              row["identifier"],
              row["source"],
              row["destination"],
              row["duration"],
              row["pricing"]["final_pricing"]["method"],
              Configuration.call_type_names[row["pricing"]["final_pricing"]["call_type"]],
              row["pricing"]["final_pricing"]["trunk_type"],
              row["pricing"]["final_pricing"]["minutes"],
              row["pricing"]["final_pricing"]["currency"],
              row["pricing"]["final_pricing"]["total"],
            ], style: [
              details,
              call_date,
              details,
              details,
              details,
              details,
              details,
              details,
              details,
              details,
              details,
              details,
              details,
              totals,
            ]
          end
        end
        sheet.column_widths 20,
                            20,
                            32,
                            20,
                            20,
                            20,
                            20,
                            28,
                            20,
                            26,
                            20,
                            28,
                            20,
                            20
      end
    end
end
