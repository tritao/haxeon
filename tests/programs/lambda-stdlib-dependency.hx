// StringTools is loaded on demand. It is referenced only inside local and
// anonymous functions here, which must still count as dependencies.
function main():Int {
	function prefixed(text:String):Bool {
		return StringTools.startsWith(text, "ab");
	}
	var suffixed = function(text:String):Bool return StringTools.endsWith(text, "yz");
	return prefixed("abc") && suffixed("xyz") ? 42 : 1;
}
