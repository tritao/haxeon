package compiler.ir;

import compiler.ir.Ir.IrType;

/** Opaque carrier for a traced lane slot. It is not a Haxe Dynamic value and must never box its input. */
class IrValueLaneReference {
	public static inline final TYPE_NAME = "value_lane_reference";
	public static inline final PACK = "$lane:reference-pack";
	public static inline final UNPACK = "$lane:reference-unpack";
	public static inline final READ = "__value_array_read_ref";
	public static inline final WRITE = "__value_array_write_ref";

	public static function type():IrType return Abstract(TYPE_NAME);
	public static function isCarrier(type:IrType):Bool return switch type {
		case Abstract(TYPE_NAME): true;
		default: false;
	};

	/** Target lowering checks that the chosen lane actually stores this type as a reference. */
	public static function canCarry(type:IrType):Bool return switch type {
		case Dyn, Bytes, ManagedBytes, Obj(_), Enum(_), Array(_), Iterator(_), Function(_, _), Virtual(_): true;
		case Abstract(name): name != TYPE_NAME && IrHlScalarRef.element(type) == null;
		case Nullable(inner): canCarry(inner) || switch inner { case I32, I64, F32, F64, Bool: true; default: false; };
		default: false;
	};
}
