enum abstract PayloadKind(String) {
	var first = "first";
	var second = "second";
}

enum PayloadValue {
	Item(kind:PayloadKind, value:Int);
}

function main():Int {
	var item = PayloadValue.Item(PayloadKind.first, 42);
	return switch item {
		case PayloadValue.Item(first, Value): Value;
		case PayloadValue.Item(second, _): 1;
		default: 0;
	};
}
