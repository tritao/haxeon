package compiler.hl.incremental;

/**
 * The answers one build's tables and function layout give the requests (`HlRequestKeys`), each worked out the first time a
 * function being linked asks it. Asking an interning request adds what it names to the tables, as lowering does, so the requests
 * of the functions, asked in program order, make the tables lowering them would.
 */
class HlRequestAnswers {
	/** The answer of a field without a slot, or of a native field with no narrow storage. */
	public static inline final NONE = -1;

	/** The answer of a function the layout does not have. */
	public static inline final GONE = -2;

	public final keys:HlRequestKeys;

	final symbols:HlSymbolTable;
	final functions:Map<String, Int>;
	final answered:Array<Bool>;
	final values:Array<Int>;

	/**
	 * With `continued`, the answers of a build whose tables `symbols` extends, with the same function layout: what it answered
	 * stays the answer (`HlLoweredTables`).
	 */
	public function new(keys:HlRequestKeys, symbols:HlSymbolTable, functions:Map<String, Int>,
			?continued:HlRequestAnswers) {
		this.keys = keys;
		this.symbols = symbols;
		this.functions = functions;
		answered = continued == null ? [] : continued.answered.copy();
		values = continued == null ? [] : continued.values.copy();
	}

	public function answer(key:Int):Int {
		if (key < answered.length && answered[key])
			return values[key];
		var value = ask(keys.request(key));
		if (key >= answered.length) {
			answered.resize(keys.count);
			values.resize(keys.count);
		}
		answered[key] = true;
		values[key] = value;
		return value;
	}

	function ask(request:HlSymbolRequest):Int
		return switch request {
			case ConstInt(value, _): symbols.internInt(value);
			case ConstFloat(value, _): symbols.internFloat(value);
			case ConstString(value, _): symbols.internString(value);
			case TypeOf(type, _): symbols.internTypeId(type, keys.typeKey(type));
			case RefTo(type, _): symbols.internReferenceId(type, keys.typeKey(type));
			case RuntimeHeader(kind, _): symbols.internRuntimeHeader(kind);
			case NativeStorage(type, layout, _):
				var index = symbols.internNativeFieldStorageType(type, layout);
				index == null ? NONE : index;
			case GlobalSlot(name, type, _): symbols.internGlobal(name, type);
			case GlobalByName(name, _): symbols.requireGlobalIndex(name);
			case StringLiteral(value, _): symbols.internStringConstant(value);
			case EnumValue(enumName, constructor, _): symbols.internEnumConstant(enumName, constructor);
			case FunctionRef(name, _):
				var index = functions.get(name);
				index == null ? GONE : index;
			case FieldSlot(owner, name, _):
				var index = symbols.objectFieldIndex(owner, name);
				index == null ? NONE : index;
			case MethodSlot(typeName, name, _): symbols.requireObjectMethodIndex(typeName, name);
			case InterfaceSlot(interfaceName, name, _): symbols.requireInterfaceMethodIndex(interfaceName, name);
			case MethodSlotKnown(typeName, name, _): HlSymbolRequest.HlRemap.methodSlotAnswer(symbols, typeName, name);
		};
}
