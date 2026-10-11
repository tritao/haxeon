package runtime.memory;

/**
	Non-owning pointer to fixed-layout unmanaged memory. For a Flat value pointee,
	`pointer.ref.field` reads a field and assignment to a direct or nested field
	projects the write to its selected native layout offset. It carries no owner
	or lifetime check.
 */
abstract RawPtr<T>(hl.Bytes) from hl.Bytes to hl.Bytes {
	/** Construct a null raw pointer when the result type is known from context. */
	public static inline function nullPtr():RawPtr<Dynamic>
		return cast null;

	/** Reports whether this pointer is null. It does not validate the address. */
	public inline function isNull():Bool
		return (this : hl.Bytes) == null;

	/**
		Read one unmanaged scalar or Flat value through the pointer's selected native field layout.
		Managed references and address-only native value records are rejected by the typer.
	 */
	public inline function load():T
		return cast null;

	/**
		Write one unmanaged scalar or Flat value through the pointer's selected native field layout.
		Managed references and address-only native value records are rejected by the typer.
	 */
	public inline function store(value:T):Void {}

	/** Move by a number of elements of T. */
	public inline function offset(elements:Int):RawPtr<T>
		return cast this;

	/** Move by a number of bytes. */
	public inline function byteOffset(bytes:Int):RawPtr<T>
		return cast this;

	/** Change only the pointee type; no runtime conversion or ownership change occurs. */
	public inline function castTo<U>():RawPtr<U>
		return cast this;
}
