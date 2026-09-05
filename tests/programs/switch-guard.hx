enum GuardedValue {
	Number(value:Int);
}

function main():Int {
	var value:GuardedValue = GuardedValue.Number(42);
	return switch value {
		case GuardedValue.Number(number) if (number == 42): number;
		default: 0;
	};
}
