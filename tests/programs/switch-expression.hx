enum Choice {
	First;
	Second;
}

function main():Int {
	var number = switch (2) {
		case 1: 1;
		case 2: 40;
		default: 0;
	};
	var text = switch "yes" {
		case "yes": 1;
		default: 0;
	};
	var choice = switch Choice.Second {
		case Choice.First: 0;
		case Choice.Second: 1;
	};
	return number + text + choice;
}
