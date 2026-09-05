import compiler.abi.PatchPlanner;
import compiler.abi.PatchPlanner.AbiChange;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;

typedef AbiFixture = {
	final name:String;
	final previous:Null<RuntimeAbiDescriptor>;
	final next:RuntimeAbiDescriptor;
	final expected:ExpectedDecision;
}

enum ExpectedDecision {
	Patch;
	Reload(reason:AbiChange);
}

class AbiMatrixMain {
	static function main():Void {
		var empty = abi();
		var fixtures:Array<AbiFixture> = [
			fixture("initial load", null, abi(["main" => "()->I32"]), Patch),
			fixture("unchanged ABI", empty, abi(), Patch),
			fixture("function added", empty, abi(["helper" => "()->I32"]), Reload(FunctionAdded("helper"))),
			fixture("function removed", abi(["helper" => "()->I32"]), empty, Reload(FunctionRemoved("helper"))),
			fixture("function signature changed", abi(["main" => "()->I32"]), abi(["main" => "(I32)->I32"]), Reload(FunctionSignatureChanged("main"))),
			fixture("object added", empty, abi(null, ["Editor" => "fields=value:I32"]), Reload(ObjectAdded("Editor"))),
			fixture("object removed", abi(null, ["Editor" => "fields=value:I32"]), empty, Reload(ObjectRemoved("Editor"))),
			fixture("instance field added", abi(null, ["Editor" => "fields=value:I32"]), abi(null, ["Editor" => "fields=value:I32,generation:I32"]),
				Reload(ObjectLayoutChanged("Editor"))),
			fixture("instance field reordered", abi(null, ["Editor" => "fields=left:I32,right:I32"]), abi(null, ["Editor" => "fields=right:I32,left:I32"]),
				Reload(ObjectLayoutChanged("Editor"))),
			fixture("method table changed", abi(null, ["Editor" => "methods=read:Editor.read"]),
				abi(null, ["Editor" => "methods=read:Editor.read,write:Editor.write"]), Reload(ObjectLayoutChanged("Editor"))),
			fixture("base class changed", abi(null, ["Editor" => "base=Node"]), abi(null, ["Editor" => "base=Widget"]), Reload(ObjectLayoutChanged("Editor"))),
			fixture("closure capture changed", abi(null, ["$lambda-env:main:1" => "fields=value:I32"]),
				abi(null, ["$lambda-env:main:1" => "fields=value:I32,offset:I32"]), Reload(ClosureLayoutChanged("$lambda-env:main:1"))),
			fixture("interface changed", abi(null, null, ["Readable" => "methods=read()->I32"]),
				abi(null, null, ["Readable" => "methods=read()->I32;reset()->Void"]), Reload(InterfaceChanged("Readable"))),
			fixture("enum changed", abi(null, null, null, ["Result" => "Ok(I32);Error(Bytes)"]), abi(null, null, null, ["Result" => "Error(Bytes);Ok(I32)"]),
				Reload(EnumChanged("Result"))),
			fixture("static field type changed", abi(null, null, null, null, ["Editor.count" => "I32"]),
				abi(null, null, null, null, ["Editor.count" => "F64"]), Reload(GlobalLayoutChanged("Editor.count")))
		];
		for (fixture in fixtures)
			assertDecision(fixture);
		Sys.println('PASS: ${fixtures.length} ABI compatibility policy fixtures');
	}

	static function fixture(name:String, previous:Null<RuntimeAbiDescriptor>, next:RuntimeAbiDescriptor, expected:ExpectedDecision):AbiFixture
		return {
			name: name,
			previous: previous,
			next: next,
			expected: expected
		};

	static function abi(?functions:Map<String, String>, ?objects:Map<String, String>, ?interfaces:Map<String, String>, ?enums:Map<String, String>,
			?globals:Map<String, String>):RuntimeAbiDescriptor
		return {
			functions: functions == null ? [] : functions,
			objects: objects == null ? [] : objects,
			interfaces: interfaces == null ? [] : interfaces,
			enums: enums == null ? [] : enums,
			globals: globals == null ? [] : globals
		};

	static function assertDecision(fixture:AbiFixture):Void {
		var actual = PatchPlanner.plan(fixture.previous, fixture.next);
		switch [fixture.expected, actual] {
			case [Patch, Patch]:
			case [Reload(expected), ReloadDomain(reasons)] if (reasons.length == 1 && Type.enumEq(expected, reasons[0])):
			case [_, _]:
				throw '${fixture.name}: expected ${fixture.expected}, got $actual';
		}
	}
}
