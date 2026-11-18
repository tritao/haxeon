// An object literal typed without an expected structure stays open while its unit is typed: it gains the optional fields of
// the structures it meets, in place, so every alias of it sees them (docs/design/STRUCTURE_VALUES.md, slice 5). Here through a
// local, an argument used twice, an array element (Parser.hx's `arguments.push({...})`), a nested literal, a nullable, a
// function type's result and argument, a generic class's and a map's type parameter.
typedef Argument = {name:String, ?optional:Bool, ?defaultValue:String};
typedef Options = {verbose:Bool, ?level:Int, ?tag:String};

class Box<T> {
	public var value:T;

	public function new(value:T)
		this.value = value;
}

class Main {
	static function describe(arguments:Array<Argument>):String
		return [
			for (argument in arguments)
				argument.name + (argument.optional == true ? "?" : "")
				+ (argument.defaultValue == null ? "" : "=" + argument.defaultValue)
		].join(",");

	static function configure(options:Options):String
		return Std.string(options.verbose) + ":" + Std.string(options.level) + ":" + Std.string(options.tag);

	static function sortedFields(value:Dynamic):String {
		var fields = Reflect.fields(value);
		fields.sort(Reflect.compare);
		return fields.join(",");
	}

	static function main():Void {
		var c = {name: "y"};
		var d:{name:String, ?optional:Bool} = c;
		Sys.println(d.name + " " + d.optional);
		d.optional = true;
		Sys.println(Std.string(c.optional) + " " + (c == d) + " " + sortedFields(c));

		var options = {verbose: true};
		Sys.println(configure(options));
		Sys.println(configure(options));
		options.level = 3;
		Sys.println(configure(options));

		var arguments = [];
		for (name in ["a", "b", "c"])
			arguments.push({name: name, optional: name != "a"});
		Sys.println(describe(arguments));
		arguments[2].defaultValue = "1";
		Sys.println(describe(arguments));

		var nested = {inner: {a: 1}};
		var wide:{inner:{a:Int, ?b:Int}} = nested;
		wide.inner.b = 2;
		Sys.println(nested.inner.a + " " + nested.inner.b);

		var maybe:Null<{name:String, ?w:Int}> = null;
		var q = {name: "q"};
		maybe = q;
		Sys.println(maybe.name + " " + maybe.w);

		var lit = {k: 1};
		var f = () -> lit;
		var g:() -> {k:Int, ?z:String} = f;
		Sys.println(g().k + " " + g().z);

		var arg = {k: 2};
		var h = function(v:{k:Int, ?t:Int}):Int return v.k + (v.t == null ? 0 : v.t);
		Sys.println(h(arg));
		arg.t = 5;
		Sys.println(h(arg));

		var boxed = {k: 3};
		var box = new Box(boxed);
		var wideBox:Box<{k:Int, ?s:String}> = box;
		boxed.s = "s";
		Sys.println(wideBox.value.k + " " + wideBox.value.s);

		var entry = {k: 4};
		var map = new Map<String, {k:Int, ?r:Int}>();
		map.set("e", entry);
		entry.r = 5;
		Sys.println(map.get("e").r);
	}
}
