// Array.pop and Array.shift return abstract elements such as maps and byte buffers intact.
function main():Int {
	var scopes:Array<Map<String, Bool>> = [];
	scopes.push(["first" => true]);
	scopes.push(["second" => true]);
	var last = scopes.pop();
	var first = scopes.shift();
	// pop and shift return Null<T>; a reference is read only once checked.
	if (last == null || first == null)
		return 3;
	if (!last.exists("second") || !first.exists("first") || scopes.length != 0)
		return 1;
	var buffers = [haxe.io.Bytes.alloc(3), haxe.io.Bytes.alloc(5)];
	var buffer = buffers.pop();
	if (buffer == null)
		return 3;
	return buffer.length == 5 && buffers.length == 1 ? 42 : 2;
}
