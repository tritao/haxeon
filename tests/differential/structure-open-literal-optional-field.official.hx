// A field an object literal has turns optional where its open structure meets a structure that declares it optional, as
// Haxe converts a required field to an optional one: Parser.hx's `arguments.push({name, ..., optional, defaultValue})`
// returned as an array of a typedef with final, optional fields (docs/design/STRUCTURE_VALUES.md, slice 6).
typedef Argument = {
	final name:String;
	final ?optional:Bool;
	final ?defaultValue:String;
}

class Main {
	static function parse(names:Array<String>):Array<Argument> {
		var arguments = [];
		for (name in names) {
			var optional = StringTools.startsWith(name, "?"),
				equals = name.indexOf("="),
				defaultValue:Null<String> = equals > 0 ? name.substr(equals + 1) : null;
			arguments.push({name: name, optional: optional, defaultValue: defaultValue});
		}
		return arguments;
	}

	static function main():Void {
		for (argument in parse(["a", "?b", "c=1"]))
			Sys.println(argument.name + " " + argument.optional + " " + argument.defaultValue);
		var flag = {on: true, label: "x"};
		var view:{?on:Bool, label:String} = flag;
		Sys.println(view.on + " " + view.label);
	}
}
