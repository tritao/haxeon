// Compiles without the native UI libraries. From the Haxeon root:
//   .tools/haxe/haxe -cp src --run compiler.tools.HaxeonCompiler --output=OUT.hl --entry=KeyHashTests \
//     --root=packages/ui/tests/key-hash --root=packages/ui/haxe packages/ui/tests/key-hash/KeyHashTests.hx \
//     packages/ui/haxe/haxeon/ui/core/KeyHash.hx
//   LD_LIBRARY_PATH=out:.tools/hashlink .tools/hashlink/hl OUT.hl
import haxeon.ui.core.KeyHash;

class KeyHashTests {
	static function expect(ok:Bool, message:String):Void {
		if (!ok)
			throw message;
	}

	static function same(x:KeyHash, y:KeyHash):Bool
		return x.a == y.a && x.b == y.b;

	static function main():Void {
		var h = new KeyHash(), g = new KeyHash();
		h.addString("pane").addInt(7).addFloat(320.5).addBool(true);
		g.addString("pane").addInt(7).addFloat(320.5).addBool(true);
		expect(same(h, g), "same inputs give the same key");

		g.reset().addString("pane").addInt(7).addFloat(320.5).addBool(false);
		expect(!same(h, g), "a bool changes the key");
		g.reset().addString("pane").addInt(8).addFloat(320.5).addBool(true);
		expect(!same(h, g), "an int changes the key");
		g.reset().addString("pane").addInt(7).addFloat(320.500000001).addBool(true);
		expect(same(h, g), "float differences below the resolution do not");
		g.reset().addString("pane").addInt(7).addFloat(320.51).addBool(true);
		expect(!same(h, g), "float differences above it do");

		h.reset().addString("ab").addString("c");
		g.reset().addString("a").addString("bc");
		expect(!same(h, g), "string boundaries matter");
		h.reset().addString("");
		g.reset().addString(null);
		expect(!same(h, g), "empty and null differ");
		h.reset();
		g.reset();
		expect(same(h, g), "reset restores the seed");

		// Many near keys, as the dock builds: titles, badge counts, widths. Count lane collisions.
		var seen:Map<String, Bool> = new Map(), collisions = 0, total = 0;
		var k = new KeyHash();
		for (width in 0...400)
			for (badge in 0...20)
				for (title in ["Hierarchy", "Sensors", "Console", "Telemetry", "Inspector"]) {
					k.reset().addString("dock/pane:first").addFloat(width * 0.5).addInt(badge).addString(title);
					var id = k.a + ":" + k.b;
					if (seen.exists(id))
						collisions++;
					seen.set(id, true);
					total++;
				}
		expect(collisions == 0, "no collisions among " + total + " keys: " + collisions);
		Sys.println("PASS: key hash separates " + total + " near keys with no collision");
	}
}
