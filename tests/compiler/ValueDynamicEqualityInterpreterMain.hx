import compiler.Frontend;
import compiler.ir.IrInterpreter;

class ValueDynamicEqualityInterpreterMain {
	static function main():Void run();
	public static function run():Void {
		var source = 'interface Equatable {} struct Item implements Equatable { public var value:Int; '
			+ 'public function new(value:Int) this.value=value; '
			+ 'public function equals(other:Item):Bool return value % 10 == other.value % 10; } '
			+ 'struct MaybeItem implements Equatable { public var item:Null<Item>; '
			+ 'public function new(item:Null<Item>) this.item=item; } '
			+ 'class RefItem { public var value:Int; public function new(value:Int) this.value=value; } '
			+ 'function main():Int { var a:Dynamic=new Item(2); var b:Dynamic=new Item(12); '
			+ 'var ma:Dynamic=new MaybeItem(new Item(3)); var mb:Dynamic=new MaybeItem(new Item(13)); '
			+ 'var view:Equatable=new Item(3); var erased:Dynamic=view; var concrete:Dynamic=new Item(13); '
			+ 'return a == b && ma == mb && erased == concrete && concrete == erased '
			+ '&& new RefItem(1) != new RefItem(1) ? 42 : 1; }';
		var result = new IrInterpreter(Frontend.compile(source)).run("main");
		if (result != 42) throw 'interpreter Dynamic value equality returned $result';
		var ownedSource = 'interface Equatable {} struct OwnedItem implements Equatable { public var value:Int; public var label:String; '
			+ 'public function new(value:Int) { this.value=value; label="owned"; } '
			+ 'public function equals(other:OwnedItem):Bool { var same=value%10==other.value%10; '
			+ 'value=100; label="left"; other.value=200; other.label="right"; return same; } } '
			+ 'function main():Int { var a:Dynamic=new OwnedItem(1); var b:Dynamic=new OwnedItem(11); '
			+ 'if (!(a==b)) return 1; var x:OwnedItem=cast a; var y:OwnedItem=cast b; '
			+ 'return x.value==1 && y.value==11 && x.label=="owned" && y.label=="owned" ? 42 : 2; }';
		if (new IrInterpreter(Frontend.compile(ownedSource)).run("main") != 42)
			throw "a mutating equality method changed its borrowed Dynamic boxes";
		var compiler = new compiler.Compiler();
		compiler.update("Equatable.hx", "interface Equatable {}");
		compiler.update("Item.hx", "struct Item implements Equatable { public var value:Int; public function new(value:Int) this.value=value%10; }");
		compiler.update("Main.hx", "function main():Int { var a:Dynamic=new Item(2); var b:Dynamic=new Item(12); return a == b ? 42 : 1; }");
		if (new IrInterpreter(compiler.compile("Main").ir).run("main") != 42)
			throw "initial Dynamic equality did not use the declared fields";
		compiler.update("Item.hx", "struct Item implements Equatable { public var value:Int; public var other:Int; "
			+ "public function new(value:Int) { this.value=value%10; other=value; } }");
		if (new IrInterpreter(compiler.compile("Main").ir).run("main") != 1)
			throw "Dynamic equality retained a stale field list after an incremental layout edit";
		compiler.update("Item.hx", "struct Item { public var value:Int; public function new(value:Int) this.value=value; }");
		var rejected = false;
		try new IrInterpreter(compiler.compile("Main").ir).run("main") catch (error:Dynamic) {
			if (Std.string(error) != "Struct value does not conform to Equatable") throw error;
			rejected = true;
		}
		if (!rejected) throw "Dynamic equality retained conformance after its removal";
		compiler.update("Item.hx", "struct Item implements Equatable { public var value:Int; public function new(value:Int) this.value=value; "
			+ "public function equals(other:Item):Bool return value%10==other.value%10; }");
		if (new IrInterpreter(compiler.compile("Main").ir).run("main") != 42)
			throw "Dynamic equality did not restore a new declared conformance";
		Sys.println("PASS: interpreter uses struct equality through Dynamic, including incremental layout and conformance edits");
	}
}
