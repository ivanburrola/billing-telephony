{
	"$or"=>
		[
			{
				"$or"=>
					[
						{:destination=>/^188012300[0-9][0-9]$/},
						{:destination=>/^18001240001$/},
						{:destination=>/^18001112222$/}
					]
			},
			{
				"$or"=>
					[
						{
							"$and"=>
								[
									{:host=>/^10.10.2.15$/},
									{:identifier=>/^9154000300$/}
								]
						},
						{
							"$and"=>
								[
									{
										"$or"=>
											[
												{:host=>/^10.10.10.1$/},
												{:host=>/^10.10.10.2$/}
											]
									},
									{
										"$or"=>
											[
												{:gateway=>/^Alfa$/},
												{:gateway=>/^Beta$/}
											]
									}
								]
						}
					]
			}
		]
}