// An object literal that fills an empty array or a `null` local is typed in the context of the local's later uses, as
// in Haxe: once a typed use fixes the structure, its optional fields are the local's too.
typedef Argument = {name:String, ?optional:Bool};
typedef ToolRequest = {main:String, classPaths:Array<String>, defines:Array<String>};

class Main {
	static function describe(arguments:Array<Argument>):String
		return [for (argument in arguments) argument.name + (argument.optional == true ? "?" : "")].join(",");

	static function toolRequest(arguments:Array<String>):Null<ToolRequest> {
		var classPaths = [], defines = [];
		while (arguments.length > 0) {
			var argument = arguments.shift();
			switch argument {
				case "--cp" | "--define":
					(argument == "--cp" ? classPaths : defines).push(arguments.shift());
				case _:
					return {main: argument, classPaths: classPaths, defines: defines};
			}
		}
		return null;
	}

	static function main():Void {
		var arguments = [];
		arguments.push({name: "a"});
		Sys.println(describe(arguments));
		arguments.push({name: "b", optional: true});
		Sys.println(describe(arguments));

		var request = toolRequest(["--cp", "src", "--define", "x", "--cp", "lib", "Main"]);
		Sys.println(request == null ? "none" : request.main + " " + request.classPaths.join(":") + " "
			+ request.defines.join(":"));
		Sys.println(arguments[0].optional == null);
	}
}
