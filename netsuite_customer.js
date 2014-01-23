function buildCustomerBillingInfo(customerId) {
    var wrk;
    var res;

    var listOriginIds=[];
    var listRateIds=[];

    var customer = nlapiLoadRecord("customer", customerId);

    res = {
        customer: { id: customer.id, name: customer.fields.entityid },
        origins: {},
        rates: {},
    };

    wrk = nlapiSearchRecord(
        "customrecord_tel_origenes",
        null,
        [
            new nlobjSearchFilter("custrecord_tto_customer", null, "is", customerId),
        ],
        [
    		new nlobjSearchColumn("internalId"),
    		new nlobjSearchColumn("name"),
    		new nlobjSearchColumn("custrecord_tto_customer"),
    		new nlobjSearchColumn("custrecord_tto_tarifa"),
    		new nlobjSearchColumn("custrecord_tto_tipo_troncal"),
    		new nlobjSearchColumn("custrecord_tto_invoice_group"),
    		new nlobjSearchColumn("custrecord_tto_aprovisionado"),
    		new nlobjSearchColumn("custrecord_tto_us_local"),
    		new nlobjSearchColumn("custrecord_tto_us_nationalld"),
    		new nlobjSearchColumn("custrecord_tto_us_mexicold"),
    		new nlobjSearchColumn("custrecord_tto_us_mexicomobilejrz"),
    		new nlobjSearchColumn("custrecord_tto_us_mexicomobile"),
    		new nlobjSearchColumn("custrecord_tto_us_mexicojuarez"),
    		new nlobjSearchColumn("custrecord_tto_us_tollfree"),
    		new nlobjSearchColumn("custrecord_tto_us_mexicotollfree"),
    		new nlobjSearchColumn("custrecord_tto_mx_locales"),
    		new nlobjSearchColumn("custrecord_tto_mx_cellocal"),
    		new nlobjSearchColumn("custrecord_tto_mx_celnacional"),
    		new nlobjSearchColumn("custrecord_tto_mx_ldnacional"),
    		new nlobjSearchColumn("custrecord_tto_mx_uscanada"),
    		new nlobjSearchColumn("custrecord_tto_mx_tollfreemx"),
    		new nlobjSearchColumn("custrecord_tto_mx_tollfreeus"),
    		new nlobjSearchColumn("custrecord_tto_completed_sales"),
        ]
    );

    if(wrk) wrk.forEach(function(v,i,a){
        var rateId = Number(v.getValue("custrecord_tto_tarifa"));
        var originId = Number(v.getValue("internalId"));
        if(listRateIds.indexOf(rateId)<0) listRateIds.push(rateId);
        if(listOriginIds.indexOf(originId)<0) listOriginIds.push(originId);
        res.origins[originId] = ({
            internal_id:     originId,
            name:            v.getValue("name"),
            rate:            { internal_id: rateId, name: v.getText("custrecord_tto_tarifa") },
            trunk_type:      { internal_id: Number(v.getValue("custrecord_tto_tipo_troncal")), name: v.getText("custrecord_tto_tipo_troncal") },
            invoice_group:   v.getValue("custrecord_tto_invoice_group"),
            provisioned:     v.getValue("custrecord_tto_aprovisionado") == "T" ? true : false,
            completed_sales: v.getValue("custrecord_tto_completed_sales") == "T" ? true : false,
            rate_overrides:   {
        		us_local: Number(v.getValue("custrecord_tto_us_local")),
        		us_nationalld: Number(v.getValue("custrecord_tto_us_nationalld")),
        		us_mexicold: Number(v.getValue("custrecord_tto_us_mexicold")),
        		us_mexicomobilejrz: Number(v.getValue("custrecord_tto_us_mexicomobilejrz")),
        		us_mexicomobile: Number(v.getValue("custrecord_tto_us_mexicomobile")),
        		us_mexicojuarez: Number(v.getValue("custrecord_tto_us_mexicojuarez")),
        		us_tollfree: Number(v.getValue("custrecord_tto_us_tollfree")),
        		us_mexicotollfree: Number(v.getValue("custrecord_tto_us_mexicotollfree")),
        		mx_locales: Number(v.getValue("custrecord_tto_mx_locales")),
        		mx_cellocal: Number(v.getValue("custrecord_tto_mx_cellocal")),
        		mx_celnacional: Number(v.getValue("custrecord_tto_mx_celnacional")),
        		mx_ldnacional: Number(v.getValue("custrecord_tto_mx_ldnacional")),
        		mx_uscanada: Number(v.getValue("custrecord_tto_mx_uscanada")),
        		mx_tollfreemx: Number(v.getValue("custrecord_tto_mx_tollfreemx")),
        		mx_tollfreeus: Number(v.getValue("custrecord_tto_mx_tollfreeus")),
            },
            prefix_overrides: {},
            plans: {},
            identifiers: {},
        });
    });

    wrk = nlapiSearchRecord(
        "customrecord_tel_tarifas",
        null,
        [
            new nlobjSearchFilter("internalId", null, "anyOf", listRateIds),
        ],
        [
            new nlobjSearchColumn("internalId"),
            new nlobjSearchColumn("name"),
            new nlobjSearchColumn("custrecord_tt_tipotroncal"),
            new nlobjSearchColumn("custrecord_tt_currency"),
            new nlobjSearchColumn("custrecord_tt_local_prefix"),
            new nlobjSearchColumn("custrecord_tt_us_local"),
            new nlobjSearchColumn("custrecord_tt_us_nationalld"),
            new nlobjSearchColumn("custrecord_tt_us_mexicold"),
            new nlobjSearchColumn("custrecord_tt_us_mexicomobilejrz"),
            new nlobjSearchColumn("custrecord_tt_us_mexicomobile"),
            new nlobjSearchColumn("custrecord_tt_us_mexicojuarez"),
            new nlobjSearchColumn("custrecord_tt_us_tollfree"),
            new nlobjSearchColumn("custrecord_tt_us_mexicotollfree"),
            new nlobjSearchColumn("custrecord_tt_mx_locales"),
            new nlobjSearchColumn("custrecord_tt_mx_cellocal"),
            new nlobjSearchColumn("custrecord_tt_mx_celnacional"),
            new nlobjSearchColumn("custrecord_tt_mx_ldnacional"),
            new nlobjSearchColumn("custrecord_tt_mx_uscanada"),
            new nlobjSearchColumn("custrecord_tt_mx_tollfreemx"),
            new nlobjSearchColumn("custrecord_tt_mx_tollfreeus"),
        ]
    );

    if(wrk) wrk.forEach(function(v,i,a){
        res.rates[i] = {
            internal_id: Number(v.getValue("internalId")),
            name: v.getValue("name"),
            currency: { internal_id: Number(v.getValue("custrecord_tt_currency")), name: v.getText("custrecord_tt_currency") },
            local_prefix: v.getValue("custrecord_tt_local_prefix"),
            trunk_type: { internal_id: v.getValue("custrecord_tt_tipotroncal"), name: v.getText("custrecord_tt_tipotroncal") },
            us_local: Number(v.getValue("custrecord_tt_us_local")),
            us_nationalld: Number(v.getValue("custrecord_tt_us_nationalld")),
            us_mexicold: Number(v.getValue("custrecord_tt_us_mexicold")),
            us_mexicomobilejrz: Number(v.getValue("custrecord_tt_us_mexicomobilejrz")),
            us_mexicomobile: Number(v.getValue("custrecord_tt_us_mexicomobile")),
            us_mexicojuarez: Number(v.getValue("custrecord_tt_us_mexicojuarez")),
            us_tollfree: Number(v.getValue("custrecord_tt_us_tollfree")),
            us_mexicotollfree: Number(v.getValue("custrecord_tt_us_mexicotollfree")),
            mx_locales: Number(v.getValue("custrecord_tt_mx_locales")),
            mx_cellocal: Number(v.getValue("custrecord_tt_mx_cellocal")),
            mx_celnacional: Number(v.getValue("custrecord_tt_mx_celnacional")),
            mx_ldnacional: Number(v.getValue("custrecord_tt_mx_ldnacional")),
            mx_uscanada: Number(v.getValue("custrecord_tt_mx_uscanada")),
            mx_tollfreemx: Number(v.getValue("custrecord_tt_mx_tollfreemx")),
            mx_tollfreeus: Number(v.getValue("custrecord_tt_mx_tollfreeus")),
        };
    });

    for(var i=0; i<listOriginIds.length; i++) {
        var originId = listOriginIds[i];

        wrk = nlapiSearchRecord(
            "customrecord_tel_overrides",
            null,
            [
                new nlobjSearchFilter("custrecord_ttov_origen", null, "is", originId),
            ],
            [
                new nlobjSearchColumn("internalId"),
                new nlobjSearchColumn("custrecord_ttov_prefix"),
                new nlobjSearchColumn("custrecord_ttov_per_call"),
                new nlobjSearchColumn("custrecord_ttov_precio"),
            ]
        );
        if(wrk) wrk.forEach(function(v,i,a){
            res.origins[originId].prefix_overrides[Number(v.getValue("internalId"))] = {
                internal_id: Number(v.getValue("internalId")),
                prefix: v.getValue("custrecord_ttov_prefix"),
                per_call: v.getValue("custrecord_ttov_per_call") == "T" ? true : false,
                price: Number(v.getValue("custrecord_ttov_precio")),
            };
        });

        wrk = nlapiSearchRecord(
            "customrecord_tel_planes",
            null,
            [
                new nlobjSearchFilter("custrecord_ttp_origen", null, "is", originId),
            ],
            [
                new nlobjSearchColumn("internalId"),
                new nlobjSearchColumn("custrecord_ttp_volumen"),
                new nlobjSearchColumn("custrecord_ttp_tipo_llamadas"),
            ]
        );
        if(wrk) wrk.forEach(function(v,i,a){
            res.origins[originId].plans[Number(v.getValue("internalId"))] = {
                internal_id: Number(v.getValue("internalId")),
                volume: Number(v.getValue("custrecord_ttp_volumen")),
                call_type: { internal_id: v.getValue("custrecord_ttp_tipo_llamadas"), name: v.getText("custrecord_ttp_tipo_llamadas") },
            };
        });

        wrk = nlapiSearchRecord(
            "customrecord_tel_identifiers",
            null,
            [
                new nlobjSearchFilter("custrecord_telid_origen", null, "is", originId),
            ],
            [
                new nlobjSearchColumn("internalId"),
                new nlobjSearchColumn("custrecord_telid_rxlist_ipaddr"),
                new nlobjSearchColumn("custrecord_telid_eq_name"),
                new nlobjSearchColumn("custrecord_telid_rxlist_srcnumbers"),
            ]
        );
        if(wrk) wrk.forEach(function(v,i,a){
            res.origins[originId].identifiers[Number(v.getValue("internalId"))] = {
                internal_id: Number(v.getValue("internalId")),
                rxlist_ipaddr: v.getValue("custrecord_telid_rxlist_ipaddr"),
                eq_name: v.getValue("custrecord_telid_eq_name"),
                rxlist_srcnumbers: v.getValue("custrecord_telid_rxlist_srcnumbers"),
            };
        });
    }
    return res;
}

