package compiler.ir.model;

import compiler.ir.model.Ir.IrType;

/**
 * The text and number that identify an IR type wherever a type becomes a name, a key or a hash. The text is spelled out here
 * rather than taken from `Std.string`, whose output depends on the runtime: stock Haxe prints an array as `[a,b]` and Haxeon as
 * `[a, b]`, so a compiler built by each would name and hash the same types differently. The form is the one stock Haxe prints
 * (`Function([I32,Obj(pkg.Name)],Void)`), the form the compiler's outputs already carry.
 */
@:nullSafety(Strict)
class IrTypeIdentity {
	public static function text(type:IrType):String {
		var out = new StringBuf();
		write(out, type);
		return out.toString();
	}

	/** The text of a list of types, as `[a,b]`. */
	public static function listText(types:Array<IrType>):String {
		var out = new StringBuf();
		writeList(out, types);
		return out.toString();
	}

	/** Whether two types have the same identity (the same `text`), compared without building either text. */
	public static function same(a:IrType, b:IrType):Bool
		return switch [a, b] {
			case [Void, Void], [I32, I32], [I64, I64], [Bool, Bool], [F32, F32], [F64, F64], [Bytes, Bytes], [
				RawPtr,
				RawPtr
			], [
				ManagedBytes,
				ManagedBytes
			],
				[
					Dyn,
					Dyn
				], [
					TypeRef,
					TypeRef
				]:
				true;
			case [Nullable(x), Nullable(y)], [Array(x), Array(y)], [Iterator(x), Iterator(y)]:
				same(x, y);
			case [Enum(x), Enum(y)], [EnumTag(x), EnumTag(y)], [Obj(x), Obj(y)], [Abstract(x), Abstract(y)], [
				Virtual(x),
				Virtual(y)
			]:
				x == y;
			case [Function(xs, x), Function(ys, y)]: sameList(xs, ys) && same(x, y);
			default:
				false;
		};

	public static function sameList(a:Array<IrType>, b:Array<IrType>):Bool {
		if (a.length != b.length)
			return false;
		for (index in 0...a.length)
			if (!same(a[index], b[index]))
				return false;
		return true;
	}

	/** Stable runtime discriminator for an IR type. Exact type checks resolve collisions. */
	public static function id(type:IrType):Int {
		var text = text(type), hash:Int = -2128831035;
		for (index in 0...text.length) {
			hash = Std.int(hash ^ StringTools.fastCodeAt(text, index));
			hash = Std.int(hash * 16777619);
		}
		return hash;
	}

	/** Appends the type's text to `out`, for callers that build a larger text around it. */
	public static function write(out:StringBuf, type:IrType):Void
		switch type {
			case Void:
				out.add("Void");
			case I32:
				out.add("I32");
			case I64:
				out.add("I64");
			case Bool:
				out.add("Bool");
			case F32:
				out.add("F32");
			case F64:
				out.add("F64");
			case Bytes:
				out.add("Bytes");
			case RawPtr:
				out.add("RawPtr");
			case ManagedBytes:
				out.add("ManagedBytes");
			case Dyn:
				out.add("Dyn");
			case TypeRef:
				out.add("TypeRef");
			case Nullable(element):
				wrapped(out, "Nullable(", element);
			case Array(element):
				wrapped(out, "Array(", element);
			case Iterator(element):
				wrapped(out, "Iterator(", element);
			case Enum(name):
				named(out, "Enum(", name);
			case EnumTag(name):
				named(out, "EnumTag(", name);
			case Obj(name):
				named(out, "Obj(", name);
			case Abstract(name):
				named(out, "Abstract(", name);
			case Virtual(name):
				named(out, "Virtual(", name);
			case Function(arguments, result):
				out.add("Function(");
				writeList(out, arguments);
				out.add(",");
				write(out, result);
				out.add(")");
		}

	static inline function wrapped(out:StringBuf, prefix:String, element:IrType):Void {
		out.add(prefix);
		write(out, element);
		out.add(")");
	}

	static inline function named(out:StringBuf, prefix:String, name:String):Void {
		out.add(prefix);
		out.add(name);
		out.add(")");
	}

	static function writeList(out:StringBuf, types:Array<IrType>):Void {
		out.add("[");
		for (index in 0...types.length) {
			if (index > 0)
				out.add(",");
			write(out, types[index]);
		}
		out.add("]");
	}
}
