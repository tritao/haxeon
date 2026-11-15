import compiler.core.Diagnostic.CompileError;
import compiler.Frontend;

class ReadOnlyPropertyMain {
	static function main():Void {
		var classes = 'class Item { public var value(default, null):Int; public function new() value = 0; '
			+ 'public function update(other:Item) other.value = 1; } ';
		for (operation in ['item.value = 1;', 'item.value += 1;', '++item.value;', 'item.value++;'])
			expectError(classes + 'function main():Void { var item = new Item(); ' + operation + ' }');
		var getter = 'class Item { public var value(get, null):Int; var stored:Int; '
			+ 'public function new() stored = 0; function get_value():Int return stored; } ';
		for (operation in ['item.value = 1;', 'item.value += 1;', '++item.value;', 'item.value++;'])
			expectError(getter + 'function main():Void { var item = new Item(); ' + operation + ' }',
				operation == 'item.value++;' ? 'E1018' : 'E1024');
		var staticProperty = 'class Item { public static var value(default, null):Int = 0; } ';
		for (operation in ['Item.value = 1;', 'Item.value += 1;', '++Item.value;', 'Item.value++;'])
			expectError(staticProperty + 'function main():Void { ' + operation + ' }');
		Frontend.compile(classes
			+ 'class Child extends Item { public function new() { super(); value = 3; } } '
			+ 'function main():Void { var item = new Item(); item.update(item); new Child(); }');
		Frontend.compile('@:allow(Friend) class Item { public var value(default, null):Int; public function new() value = 0; } '
			+ 'class Friend { public static function update(item:Item) item.value = 1; } '
			+ 'function main():Void { Friend.update(new Item()); }');
		var methodGrant =
			'class Item { @:allow(Friend.update) public var value(default, null):Int; public function new() value = 0; } ';
		Frontend.compile(methodGrant
			+ 'class Friend { public static function update(item:Item) item.value = 1; } '
			+ 'function main():Void { Friend.update(new Item()); }');
		expectError(methodGrant
			+ 'class Friend { public static function denied(item:Item) item.value = 1; } '
			+ 'function main():Void { Friend.denied(new Item()); }');
		Frontend.compile(classes
			+ '@:access(Item) class Friend { public static function update(item:Item) item.value = 1; } '
			+ 'function main():Void { Friend.update(new Item()); }');
		Frontend.compile(classes
			+ 'class Friend { @:access(Item) public static function update(item:Item) item.value = 1; } '
			+ 'function main():Void { Friend.update(new Item()); }');
		Frontend.compile(classes
			+ 'class Friend { @:access(Item) public static function update(item:Item):Void { '
			+ 'var f = function():Void { item.value = 1; }; f(); } } '
			+ 'function main():Void { Friend.update(new Item()); }');
		var twoFields = 'class Item { public var value(default, null):Int; public var other(default, null):Int; '
			+ 'public function new() { value = 0; other = 0; } } ';
		Frontend.compile(twoFields
			+ '@:access(Item.value) class Friend { public static function update(item:Item) item.value = 1; } '
			+ 'function main():Void { Friend.update(new Item()); }');
		expectError(twoFields
			+ '@:access(Item.value) class Friend { public static function update(item:Item) item.other = 1; } '
			+ 'function main():Void { Friend.update(new Item()); }');
		Frontend.compile(classes + 'function main():Void { var item:Dynamic = new Item(); item.value = 1; }');
		Frontend.compile(classes
			+ 'function main():Void { var item = new Item(); @:privateAccess item.value = 1; '
			+ 'var old = @:privateAccess item.value++; }');
		Frontend.compile(classes
			+ 'function main():Void { var item = new Item(); @:privateAccess var old = item.value++; }');
		expectError(classes
			+ 'function main():Void { var item = new Item(); @:privateAccess var old = item.value++; item.value = 1; }');
		for (operation in ['item.value = 1;', 'item.value += 1;', '++item.value;', 'item.value++;'])
			Frontend.compile(classes + 'function main():Void { var item = new Item(); @:privateAccess ' + operation
				+ ' }');
		Frontend.compile('class Item { public var value = @:privateAccess 42; } '
			+ 'function inferred() return @:privateAccess 42; '
			+ 'function main():Int return new Item().value + inferred() - 42;');
		Frontend.compile('function consume(value:{values:Array<Int>}):Int return value.values.length; '
			+ 'function main():Int { var first = {values: []}; @:privateAccess consume(first); '
			+ 'var second = {values: []}; var count = @:privateAccess consume(second); return count; }');
		Frontend.compile(classes
			+ 'function main():Void { var item = new Item(); @:privateAccess { item.value = 1; } }');
		Frontend.compile(classes
			+ 'function main():Void { var item = new Item(); '
			+ '@:privateAccess { var f = function():Void { item.value = 1; }; f(); } }');
		expectError(classes
			+ 'function main():Void { var item = new Item(); @:privateAccess item.value = 1; item.value = 2; }');
		expectError(classes
			+ 'function main():Void { var item = new Item(); @:privateAccess { item.value = 1; } item.value = 2; }');
		var compiler = new compiler.Compiler();
		compiler.update('Main.hx',
			classes + 'function main():Void { var item = new Item(); @:privateAccess item.value = 1; }');
		compiler.compile('Main');
		compiler.update('Main.hx', classes + 'function main():Void { var item = new Item(); item.value = 1; }');
		try {
			compiler.compile('Main');
			throw 'warm rebuild retained private access';
		} catch (error:CompileError) {
			if (error.diagnostic.code != 'E1024')
				throw error;
		}
		qualifiedAccess();
		deepHierarchy();
		Sys.println('PASS: null setters reject outside writes');
	}

	static function deepHierarchy():Void {
		var source = 'class Base { public var value(default,null):Int; public function new() value = 0; } ';
		for (index in 0...70) {
			var parent = index == 0 ? 'Base' : 'Level' + (index - 1);
			source += 'class Level$index extends $parent { public function new() super(); } ';
		}
		source +=
			'class Leaf extends Level69 { public function new() super(); public function update(other:Leaf) other.value = 1; } ';
		Frontend.compile(source + 'function main():Void { var leaf = new Leaf(); leaf.update(leaf); }');
		expectError(source + 'function main():Void { var leaf = new Leaf(); leaf.value = 1; }');
	}

	static function qualifiedAccess():Void {
		var compiler = new compiler.Compiler();
		compiler.update('model/Item.hx',
			'package model; class Item { public var value(default,null):Int; public function new() value=0; }');
		compiler.update('Main.hx',
			'import model.Item; import client.Friend; function main():Void Friend.update(new Item());');
		var friend =
			'package client; import model.Item; class Friend { @:access(GRANT) public static function update(item:Item) item.value=1; }';
		compiler.update('client/Friend.hx', StringTools.replace(friend, 'GRANT', 'Item'));
		try {
			compiler.compile('Main');
			throw 'unqualified access grant unexpectedly compiled';
		} catch (error:CompileError) {
			if (error.diagnostic.code != 'E1024')
				throw error;
		}
		compiler.update('client/Friend.hx', StringTools.replace(friend, 'GRANT', 'model.Item'));
		compiler.compile('Main');
	}

	static function expectError(source:String, expected:String = 'E1024'):Void {
		try {
			Frontend.compile(source);
		} catch (error:CompileError) {
			if (error.diagnostic.code == expected)
				return;
			throw error;
		}
		throw 'external write unexpectedly compiled';
	}
}
