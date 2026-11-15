class A {
	function f() {
		var explicit:Map<String, String> = ["Own" => "explicit.Own"],
			shared:Map<String, String> = ["Own" => "shared.Own", "Wide" => "shared.Wide"],
			later:Map<String, String> = ["Wide" => "later.Wide", "Late" => "later.Late"];
	}
}
