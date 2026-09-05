function main():Int {
	return switch 1 {
		case 1: 42;
		default: throw "unexpected branch";
	};
}
