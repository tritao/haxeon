import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.Typer;

/** Negative capability and construction cases from the key-path specification. */
class KeyPathSpecMain {
	static function main():Void {
		var node='class Node { public var value:Int=1; public final fixed:Int=2; '
			+'public var writeOnly(never,default):Int; public var computed(default,set):Int=0; '
			+'function set_computed(v:Int):Int return v; } ';
		reject(node,'var p=\\Node;','requires at least one stored field','E1009');
		reject(node,'var p=\\Node.writeOnly;','Cannot read field','E1009');
		reject(node,'var p=\\Node.computed;','computed property','E1009');
		reject(node,'var p:KeyPath<Node,Float>=\\Node.value;','Type mismatch','E1002');
		reject(node,'var p:KeyPath<Node,Int>=\\Node.value; p.set(new Node(),1);','read-only KeyPath','E1009');
		reject(node,'var p:KeyPath<Node,Int>=\\Node.value; p=p; p.set(new Node(),1);','read-only KeyPath','E1009');
		reject(node,'var p:KeyPath<Node,Int>=\\Node.value; var write=function() p.set(new Node(),1);','read-only KeyPath','E1009');
		reject(node,'var p:WritableKeyPath<Node,Int>=\\Node.fixed;','Type mismatch','E1002');
		reject(node,'var p:KeyPath<Node,Int>="value";','Type mismatch','E1002');
		reject(node,'var p:KeyPath<Node,Int>=1;','Type mismatch','E1002');
		reject(node,'var p=new KeyPath<Node,Int>();','',null);
		reject(node,'(\\Node.value).get();','expects 1 argument','E1008');
		reject(node,'(\\Node.value).set(new Node());','expects 2 arguments','E1008');
		reject(node,'(\\Node.value).then();','expects 1 argument','E1008');
		reject(node,'(\\Node.value).then(1);','requires a key path','E1009');
		reject(node,'(\\Node.value).toString(1);','expects no arguments','E1008');
		var inheritance='class Base { public var value:Int=0; } class Child extends Base {} ';
		reject(inheritance,'var p:KeyPath<Base,Int>=\\Child.value;','Type mismatch','E1002');
		var point='struct Point { public var x:Int=0; } ';
		reject(point+'class Store { public static final point:Point=new Point(); } ',
			'(\\Point.x).set(Store.point,1);','cannot be assigned','E1026');
		var holder=point+'class Holder { public var point:Point; public var optional:Null<Point>; } ';
		reject(holder,'var p:KeyPath<Holder,Point>=\\Holder.point; var q=p.then(\\Point.x); q.set(new Holder(),1);',
			'read-only KeyPath','E1009');
		reject(holder,'(\\Holder.optional).then(\\Point.x);','matching intermediate types','E1009');
		reject(node+'class Reference { public final node:Node; } ',
			'var p=(\\Reference.node).then(\\Node.value); p.set(new Reference(),1);','read-only KeyPath','E1009');
		var diffable='interface Diffable {} '+point+'class DiffNode implements Diffable { public var value:Int=0; public var point:Point; } ';
		reject(diffable,'var bit=haxeon.Diff.bit(DiffNode,"value");','expects','E1008');
		reject(diffable,'var bit=haxeon.Diff.bit(\\DiffNode.point.x);','known direct-field key path','E1009');
		var tracked='interface Observable {} '+point+'class Model implements Observable { public var point:Point; } ';
		reject(tracked,'(\\Model.point.x).set(new Model(),1);','Cannot mutate a struct inside Observable','E1027');
		reject(tracked,'(\\Point.x).set(new Model().point,1);','Cannot mutate a struct inside Observable','E1027');
		reject(tracked+'function compose(p:WritableKeyPath<Model,Point>,q:WritableKeyPath<Point,Int>):WritableKeyPath<Model,Int> return p.then(q); ',
			'', 'Cannot mutate a struct inside Observable','E1027');
		Sys.println('PASS: key-path construction, invariant types, operation arity and deferred writes have explicit diagnostics');
	}
	static function reject(prefix:String,body:String,message:String,code:Null<String>):Void {
		var source=new SourceFile('Main.hx',prefix+'function main():Int { '+body+' return 42; }');
		try Typer.type(new Parser(new Lexer(source).tokenize()).parseProgram()) catch(error:CompileError) {
			if(error.diagnostic.message.indexOf(message)<0 || code!=null && error.diagnostic.code!=code) throw error;
			return;
		}
		throw 'Expected rejection: '+body;
	}
}
