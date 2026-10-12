function main():Int {
	var total = 0;
	for (i in 0...6) {
		var value = switch i {
			case 1: continue;
			case 4: break;
			default: i;
		};
		total += value;
	}
	if (total != 5)
		return 1;

	// An expression in an inner loop must target that loop, not its parent.
	total = 0;
	for (i in 1...4)
		for (j in 0...5) {
			var value = switch j {
				case 1: continue;
				case 3: break;
				default: i + j;
			};
			total += value;
		}
	if (total != 18)
		return 2;

	// Leaving a loop from an expression must close its active try trap.
	total = 0;
	for (i in 0...5) {
		try {
			var value = switch i {
				case 1: continue;
				case 3: break;
				default: i;
			};
			total += value;
		} catch (error:Dynamic) {
			return 3;
		}
	}
	if (total != 2)
		return 4;
	return 0;
}
