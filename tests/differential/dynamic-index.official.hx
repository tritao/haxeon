// Indexing a Dynamic value, as Haxe does on HashLink: the array it holds is read and written, null past its end on a read;
// a null value, a negative index, or a value that holds no array fails.
class Main {
	static function show(read:Void->Dynamic):Void {
		try Sys.println(read()) catch (error:Dynamic) Sys.println("error");
	}

	static function main():Void {
		var a:Dynamic = [1, 2, 3];
		show(() -> a[1]);
		show(() -> a[10]);
		show(() -> a[-1]);
		show(() -> {
			a[0] = 7;
			a[0];
		});
		show(() -> {
			a[3] = 9;
			a.length;
		});
		show(() -> a);
		show(() -> (a[1] = 4));
		show(() -> {
			a[1] += 10;
			a[1];
		});
		show(() -> {
			a[2]++;
			a[2];
		});
		var s:Dynamic = ["x", "y"];
		show(() -> s[1]);
		var f:Dynamic = [1.5, 2.5];
		show(() -> f[1] * 2);
		var o:Dynamic = {a: 1};
		show(() -> o[0]);
		var str:Dynamic = "hello";
		show(() -> str[1]);
		var n:Dynamic = null;
		show(() -> n[0]);
		show(() -> {
			n[0] = 1;
			0;
		});
		var json:Dynamic = haxe.Json.parse('{"items":[10,20],"nested":[[1,2],[3]]}');
		show(() -> json.items[1]);
		show(() -> {
			json.items[0] += 5;
			json.items[0];
		});
		show(() -> json.nested[1][0]);
		var i = 1;
		show(() -> json.items[i - 1]);
	}
}
