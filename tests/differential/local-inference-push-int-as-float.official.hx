// What a later use expects of an empty array does not type what is pushed into it: the first push fixes the element, so
// returning the array as Array<Float> after pushing an Int is an error, in both compilers (Int should be Float).
class Main {
	static function numbers():Array<Float> {
		var values = [];
		values.push(1);
		return values;
	}

	static function main():Void
		Sys.println(numbers()[0]);
}
