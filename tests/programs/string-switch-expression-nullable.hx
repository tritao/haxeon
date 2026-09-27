function fromSpec(spec:Null<String>):String
	return switch (spec) {
		case null: "painted";
		case "aluminium 6061": "aluminium";
		case "birch plywood": "plywood-birch";
		case "bearing steel": "bearing-steel";
		case "cast iron": "cast-iron";
		case "bronze": "bronze";
		case "spring steel": "spring-steel";
		case "steel 12.9": "steel-12-9";
		case "steel C45": "steel-c45";
		case "steel 8": "steel-8";
		case "steel 8.8": "steel-8-8";
		case "steel": "machined-steel";
		default: "unknown";
	};

function main():Int {
	var decoded = "steel 12.9".split("").join("");
	return fromSpec(null) == "painted"
		&& fromSpec(decoded) == "steel-12-9"
		&& fromSpec("steel 12.9") == "steel-12-9"
		&& fromSpec("steel 8.8") == "steel-8-8"
		&& fromSpec("steel") == "machined-steel" ? 42 : 0;
}
