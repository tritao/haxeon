enum Reply {
	Values(values:Array<Int>);
}

function main():Int {
	var result:Reply = Values([40, 2]);
	return switch result {
		case Values([first, second]): first + second;
		default: 0;
	};
}
