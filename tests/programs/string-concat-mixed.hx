class Box {}

class Main {
	static function main():Int {
		var number = 42;
		var flag = true;
		var fraction = 3.5;
		var nothing:Dynamic = null;
		var object:Dynamic = new Box();
		var value = "value=" + number + ",flag=" + flag + ",fraction=" + fraction;
		return value == "value=42,flag=true,fraction=3.5" && ("" + nothing) == "null" && ("" + object).length > 0 ? 42 : 1;
	}
}
