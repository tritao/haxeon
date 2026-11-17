// Std.string of an anonymous structure prints its fields as Haxe does: `{a : 1, b : x}`, each value as Std.string converts it,
// nested structures and arrays included, on every backend.
function main():Int {
	var point = {x: 1, y: 2};
	if (Std.string(point) != "{x : 1, y : 2}")
		return 1;
	var mixed:Dynamic = {name: "pad", tags: [3, 4], inner: {flag: true}, missing: null};
	if (Std.string(mixed) != "{name : pad, tags : [3,4], inner : {flag : true}, missing : null}")
		return 2;
	if (Std.string({}) != "{}")
		return 3;
	if (Std.string([{k: 1}, {k: 2}]) != "[{k : 1},{k : 2}]")
		return 4;
	if ('${{v: 1.5}}' != "{v : 1.5}")
		return 5;
	return 42;
}
