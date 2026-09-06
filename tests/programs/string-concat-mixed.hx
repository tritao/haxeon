class Main {
	static function main():Int {
		var number = 42;
		var flag = true;
		var value = "value=" + number + ",flag=" + flag;
		return value == "value=42,flag=true" ? 42 : 1;
	}
}
