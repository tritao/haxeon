import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.semantic.SemanticSignature;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.Typer;

/** Formation checks run before descriptor generation or target lowering. */
class KeyPathTypingMain {
	static function main():Void {
		var node = 'class Node { public var width:Int = 1; public final height:Int = 2; '
			+ 'private var hidden:Int = 0; public static var count:Int = 0; '
			+ 'public function size():Int return width; public var computed(get,never):Int; '
			+ 'function get_computed():Int return width; } ';
		expectType(node, '\\Node.width', 'WritableKeyPath<Node,Int>');
		expectType(node, '\\Node.height', 'KeyPath<Node,Int>');
		expectType('class Base { public var width:Int = 1; } class Child extends Base {} ', '\\Child.width', 'WritableKeyPath<Child,Int>');
		expectType('struct Point { public var x:Int = 1; } struct Rect { public var point:Point; } ',
			'\\Rect.point.x', 'WritableKeyPath<Rect,Int>');
		expectType('class Box<T> { public var item:T; } ', '\\Box<Int>.item', 'WritableKeyPath<Box<Int>,Int>');
		expectError(node, '\\Node.missing', 'has no stored field "missing"');
		expectError(node, '\\Node.hidden', 'Cannot access private field "Node.hidden"');
		expectError(node, '\\Node.count', 'static field "count"');
		expectError(node, '\\Node.size', 'method "size"');
		expectError(node, '\\Node.computed', 'computed property "computed"');
		expectError('struct Point { public var x:Int = 1; } class Model { public var point:Null<Point>; } ',
			'\\Model.point.x', 'nullable intermediate');
		var read = compiler.Frontend.compile(node + 'function main():Int { var n = new Node(); return (\\Node.width).get(n) + 41; }');
		if (new compiler.ir.IrInterpreter(read).run('main') != 42)
			throw 'Known class-root path did not read its stored field';
		var writes = compiler.Frontend.compile(node
			+ 'struct Point { public var x:Int; public function new(x:Int) this.x=x; } '
			+ 'function read(p:KeyPath<Node,Int>, n:Node):Int return p.get(n); '
			+ 'function update(p:WritableKeyPath<Point,Int>, n:Point):Point { p.set(n,21); return n; } '
			+ 'function main():Int { var n=new Node(); (\\Node.width).set(n,21); '
			+ 'var point=update(\\Point.x,new Point(0)); return read(\\Node.width,n)+(\\Point.x).get(point); }');
		if (new compiler.ir.IrInterpreter(writes).run('main') != 42)
			throw 'Escaped class read or escaped struct write did not preserve its root';
		var composition = compiler.Frontend.compile('class Child { public var x:Int=21; } class Root { public var child:Child=new Child(); } '
			+ 'function compose(p:WritableKeyPath<Root,Child>,q:WritableKeyPath<Child,Int>):WritableKeyPath<Root,Int> return p.then(q); '
			+ 'function main():Int { var r=new Root(); var p=compose(\\Root.child,\\Child.x); '
			+ 'p.set(r,42); if(p != \\Root.child.x) return 1; '
			+ 'if(haxeon.Hashing.hash(p) != haxeon.Hashing.hash(\\Root.child.x)) return 2; '
			+ 'if(p.toString() != "\\\\Root.child.x") return 3; return p.get(r); }');
		if (new compiler.ir.IrInterpreter(composition).run('main') != 42) throw 'Escaped composition or identity failed';
		var granted = compiler.Frontend.compile('struct Point { public var x:Int=0; } '
			+ 'class Root { public var point(default,null):Point=new Point(); '
			+ 'public static function run():Int return update(\\Root.point,\\Point.x,new Root()); } '
			+ 'function update<R,V>(p:WritableKeyPath<R,V>,q:WritableKeyPath<V,Int>,r:R):Int { var path=p.then(q); path.set(r,42); return path.get(r); } '
			+ 'function main():Int return Root.run();');
		if (new compiler.ir.IrInterpreter(granted).run('main') != 42) throw 'Composition lost the granted setter capability';
		expectError(node, '(\\Node.height).set(new Node(),3)', 'not writable');
		expectError('struct Point { public var x:Int=0; } ', '(\\Point.x).set(new Point(),3)', 'Cannot mutate temporary struct');
		expectType('struct Point { public var x:Int=0; } class Model { public var point:Null<Point>; } ', '\\Model.point', 'WritableKeyPath<Model,Null<Point>>');
		expectError('class Model { public var next:Null<Model>; public var x:Int; } ', '\\Model.next.x', 'nullable intermediate');
		expectError('struct Point { public var x:Int=0; } class Model { public final point:Point; } ',
			'(\\Model.point.x).set(new Model(),1)', 'not writable');
		expectError('interface Observable {} struct Point { public var x:Int=0; } class Model implements Observable { public var point:Point; } ',
			'(\\Model.point.x).set(new Model(),1)', 'Cannot mutate a struct inside Observable');
		expectError('interface Observable {} struct Point { public var x:Int=0; } class Model implements Observable { public var point:Point; } '
			+ 'function compose(p:WritableKeyPath<Model,Point>):WritableKeyPath<Model,Int> return p.then(\\Point.x); ',
			'\\Point.x', 'Cannot mutate a struct inside Observable');
		expectError(node + 'function write(p:KeyPath<Node,Int>, n:Node):Void p.set(n,1); ', '\\Node.width', 'read-only KeyPath');
		expectError(node, '(\\Node.width).then(\\Node.height)', 'matching intermediate types');
		expectError('interface Diffable {} class Model implements Diffable { public var x:Int=0; } function bit(p:KeyPath<Model,Int>):Int return haxeon.Diff.bit(p); ',
			'\\Model.x', 'requires a known direct-field key path');
		for (inlineEnabled in [false, true]) {
			var c = new compiler.Compiler();
			c.update('model/Box.hx', 'package model; class Box<T> { public var item:T; public function new(item:T) this.item = item; }');
			c.update('Main.hx', 'import model.Box; function main():Int { var box:Box<Int> = new Box(42); var path = \\model.Box<Int>.item; return path.get(box); }');
			c.configure(inlineEnabled ? 'inline-on' : 'inline-off', 'test', ['haxeon-inline=' + (inlineEnabled ? '1' : '0')]);
			if (new compiler.ir.IrInterpreter(c.compile('Main').ir).run('main') != 42)
				throw 'Qualified generic-root path failed with inline=' + inlineEnabled;
		}
		Sys.println('PASS: key path formation resolves fields, capabilities and diagnostics');
	}

	static function typePath(prefix:String, path:String):compiler.types.Type.CompilerType {
		var source = new SourceFile('Main.hx', prefix + 'function main():Int { var path = ' + path + '; path = path; return 42; }'),
			program = Typer.type(new Parser(new Lexer(source).tokenize()).parseProgram());
		for (fn in program.functions)
			if (fn.name == 'main')
				for (statement in fn.statements)
					switch statement {
						case TVar(_, value, _): return value.type;
						default:
					}
		throw 'Missing path binding';
	}

	static function expectType(prefix:String, path:String, expected:String):Void {
		var actual = SemanticSignature.display(typePath(prefix, path));
		if (actual != expected) throw '$path: expected $expected, got $actual';
	}

	static function expectError(prefix:String, path:String, message:String):Void {
		try typePath(prefix, path) catch (error:CompileError) {
			if (error.diagnostic.message.indexOf(message) < 0) throw error;
			return;
		}
		throw '$path did not reject $message';
	}
}
