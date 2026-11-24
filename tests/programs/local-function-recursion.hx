// A local function's name is bound in its own body, whether or not it declares its result type: it may call itself,
// capture locals, be captured by a lambda, be passed as a value and return itself. A lambda a `var` holds is not.
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
	if (names.join(",") != "root,branch,leaf")
		return 2;

	// No declared result: the result is inferred from the body.
	function fibonacci(n:Int)
		return n < 2 ? n : fibonacci(n - 1) + fibonacci(n - 2);
	if (fibonacci(10) != 55)
		return 3;
	function countDown(n)
		return n == 0 ? 0 : 1 + countDown(n - 1);
	if (countDown(3) != 3)
		return 8;
	// A lambda a `var` holds is not in scope in its own initializer: `step` there is the one before it.
	var step = () -> 1;
	var step = function() return step() + 1;
	if (step() != 2)
		return 9;

	// A Void function without a declared result that captures outer locals, as a depth-first visit does.
	var edges:Map<String, Array<String>> = ["app" => ["ui", "core"], "ui" => ["core"], "core" => []];
	var order:Array<String> = [], seen:Map<String, Bool> = [];
	function visit(node:String) {
		if (seen.exists(node))
			return;
		seen.set(node, true);
		for (next in edges.get(node))
			visit(next);
		order.push(node);
	}
	visit("app");
	if (order.join(",") != "core,ui,app")
		return 4;

	// Used as a value, inside its own body and outside it.
	var total = 0;
	function sumTo(n:Int) {
		if (n == 0)
			return;
		total += n;
		var self = sumTo;
		self(n - 1);
	}
	var call = sumTo;
	call(4);
	if (total != 10)
		return 5;
	var counts = [3, 2].map(function(n) {
		function count(k:Int):Int
			return k == 0 ? 0 : 1 + count(k - 1);
		return count(n);
	});
	if (counts.join(",") != "3,2")
		return 6;

	// A local function that returns itself.
	var calls = 0;
	function chain(step:Int):Dynamic {
		calls += step;
		return chain;
	}
	var next:Int->Dynamic = chain(1);
	next = next(2);
	next(3);
	if (calls != 6)
		return 7;
	return 42;
}
