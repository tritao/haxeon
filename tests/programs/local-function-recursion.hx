// Local functions may call themselves, including when they capture locals or are captured by a lambda.
function main():Int {
	function factorial(n:Int):Int
		return n <= 1 ? 1 : n * factorial(n - 1);
	var parents:Map<String, Null<String>> = ["leaf" => "branch", "branch" => "root", "root" => null];
	function depth(name:String):Int {
		var parent = parents.get(name);
		return parent == null ? 0 : depth(parent) + 1;
	}
	var names = ["root", "leaf", "branch"];
	names.sort((left, right) -> depth(left) - depth(right));
	if (factorial(5) != 120 || depth("leaf") != 2)
		return 1;
	return names.join(",") == "root,branch,leaf" ? 42 : 2;
}
