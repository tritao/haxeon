import compiler.ir.Ir.IrType;
import compiler.ir.IrTypeIdentity;

/** An IR type's identity text is fixed by the compiler, not by how the runtime that built it prints enums and arrays. */
class IrTypeIdentityMain {
	static function main():Void {
		var cases:Array<{type:IrType, text:String}> = [
			{type: I32, text: "I32"},
			{type: Nullable(Bool), text: "Nullable(Bool)"},
			{type: Array(Array(F64)), text: "Array(Array(F64))"},
			{type: Obj("pkg.Name"), text: "Obj(pkg.Name)"},
			{type: Iterator(EnumTag("pkg.Color")), text: "Iterator(EnumTag(pkg.Color))"},
			{type: Function([], Void), text: "Function([],Void)"},
			{
				type: Function([I32, Obj("pkg.Name"), Function([Dyn, Virtual("pkg.Shape")], Abstract("hl_x"))], Nullable(Function([F32], Bytes))),
				text: "Function([I32,Obj(pkg.Name),Function([Dyn,Virtual(pkg.Shape)],Abstract(hl_x))],Nullable(Function([F32],Bytes)))"
			},
			{type: Array(Function([RawPtr, ManagedBytes, TypeRef, I64], Enum("pkg.E"))), text: "Array(Function([RawPtr,ManagedBytes,TypeRef,I64],Enum(pkg.E)))"}
		];
		for (entry in cases) {
			var text = IrTypeIdentity.text(entry.type);
			if (text != entry.text)
				throw 'identity text of ${entry.text} is $text';
			#if !haxeon
			// The pinned form is stock Haxe's Std.string, which the outputs of the stock-built compiler already carry.
			if (Std.string(entry.type) != entry.text)
				throw 'stock Std.string of ${entry.text} is ${Std.string(entry.type)}';
			#end
		}
		if (IrTypeIdentity.listText([I32, Array(Bool)]) != "[I32,Array(Bool)]")
			throw 'list text is ${IrTypeIdentity.listText([I32, Array(Bool)])}';
		if (IrTypeIdentity.id(Obj("pkg.A")) == IrTypeIdentity.id(Obj("pkg.B")))
			throw "distinct types share an identity number";
	}
}
