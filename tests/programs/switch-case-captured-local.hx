// A switch arm with several patterns is typed once per pattern; a closure in it must capture that copy's locals.
function find(values:Array<String>, wanted:String):Bool {
	for (value in values)
		if (value == wanted)
			return true;
	return false;
}

function collect(arguments:Array<String>):Int {
	var folders:Array<String> = [];
	var index = 0;
	while (index < arguments.length) {
		switch arguments[index] {
			case "--folder" | "--scratch":
				var folder = arguments[index] + "!";
				if (!find(folders, folder))
					folders.push(folder);
				var same = function(existing:String) return existing == folder;
				if (!same(folder))
					return -1;
			default:
		}
		index++;
	}
	return folders.length;
}

function counted(value:Int):Int {
	switch value {
		case 1 | 2:
			var count = 0;
			var increment = function() {
				count = count + 1;
			};
			increment();
			increment();
			return count;
		case 3, 4:
			var base = value * 2;
			var outer = function() {
				var inner = function() return base;
				return inner();
			};
			return outer();
		default:
			return 0;
	}
}

function selected(value:Int):Int {
	return switch value {
		case 1 | 2:
			{
				var local = value + 1;
				var read = function() return local;
				read();
			}
		default: 0;
	};
}

function main():Int {
	var total = collect(["--folder", "a", "--scratch", "--folder"]);
	// total is 2: "--folder!" and "--scratch!"
	return total + counted(1) + counted(2) + counted(3) + counted(4) + selected(1) + selected(2) + 17;
}
