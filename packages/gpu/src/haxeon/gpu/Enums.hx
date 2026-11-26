package haxeon.gpu;

/**
 * The GPU enums of the public API: the generated NativeKit enums themselves, so their values come from the ABI and never
 * need converting.
 */
/** Buffer roles, combined with `|`; the native NativeKit flags, so values never need converting. */
typedef BufferUsage = nativekit.ffi.NativeKitGpu.NativeBufferUsage;

/** Pixel formats. */
typedef ImageFormat = nativekit.ffi.NativeKitGpu.GpuImageFormat;

/** Image roles, combined with `|`; the native NativeKit flags, so values never need converting. */
typedef ImageUsage = nativekit.ffi.NativeKitGpu.NativeImageUsage;

/** Image shape; Auto is 2D, or a 2D array for a layered image. */
typedef ImageType = nativekit.ffi.NativeKitGpu.NativeImageType;

/** What a pass starts an attachment with. */
typedef LoadAction = nativekit.ffi.NativeKitGpu.NativeLoadAction;

/** What a pass does with an attachment at its end. */
typedef StoreAction = nativekit.ffi.NativeKitGpu.NativeStoreAction;

/** How far a readback has got. */
typedef ReadbackState = nativekit.ffi.NativeKitGpu.NativeReadbackState;

/** How far a timestamp has got. */
typedef TimestampState = nativekit.ffi.NativeKitGpu.NativeTimestampState;

/** The kinds of pass a batch holds. */
typedef BatchPassKind = nativekit.ffi.NativeKitGpu.NativeBatchPassKind;

/** How sampling filters texels. */
typedef Filter = nativekit.ffi.NativeKitGpu.NativeFilter;

/** How sampling treats coordinates outside the image. */
typedef Wrap = nativekit.ffi.NativeKitGpu.NativeWrap;

/** How indexed draws read indices. */
typedef IndexType = nativekit.ffi.NativeKitGpu.NativeIndexType;

/** The shader stages. */
typedef ShaderStage = nativekit.ffi.NativeKitGpu.NativeShaderStage;

/** The languages hand-written shader sources are in. */
typedef ShaderLanguage = nativekit.ffi.NativeKitGpu.NativeShaderLanguage;

/** The types of uniform block members. */
typedef UniformType = nativekit.ffi.NativeKitGpu.NativeUniformType;

/** Vertex attribute formats. */
typedef VertexFormat = nativekit.ffi.NativeKitGpu.NativeVertexFormat;
