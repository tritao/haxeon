// A `return` inside a block that is a value, such as a try expression's catch, returns from the lambda it is in, also when the
// lambda's result is inferred from its returns.
function apply<U>(f:Int->U):U
	return f(1);

function main():Int {
	var parsed = apply(x -> {
		var y = try (x > 0 ? x : throw "negative") catch (e:String) {
			return 7;
		};
		return y + 41;
	});
	var fallback = apply(x -> {
		var y = try (x < 0 ? x : throw "positive") catch (e:String) {
			return 42;
		};
		return y;
	});
	return parsed == 42 && fallback == 42 ? 42 : 1;
}
