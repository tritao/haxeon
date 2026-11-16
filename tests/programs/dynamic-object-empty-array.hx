// A field of an object literal passed as Dynamic is typed in a Dynamic context, as in Haxe: an empty array there is an
// Array<Dynamic>, and values with a type of their own keep it.
function describe(params:Dynamic):String
	return haxe.Json.stringify(params);

function main():Int {
	var text = describe({uri: "a", diagnostics: [], nested: {more: []}, count: 2, flags: [true]});
	var back:Dynamic = haxe.Json.parse(text);
	var diagnostics:Array<Dynamic> = back.diagnostics;
	var flags:Array<Dynamic> = back.flags;
	return diagnostics.length == 0 && back.count == 2 && flags.length == 1 && back.nested.more.length == 0 ? 42 : 1;
}
