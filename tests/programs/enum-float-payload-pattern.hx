enum FloatPayload {
	Value(amount:Float);
}

function main():Int {
	var value = FloatPayload.Value(0.5);
	var half = switch value {
		case Value(0.5): 40;
		case _: 0;
	};
	var zero = FloatPayload.Value(0.0);
	return half + switch zero {
		case Value(0): 2;
		case _: 0;
	};
}
