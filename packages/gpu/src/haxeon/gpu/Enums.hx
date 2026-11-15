package haxeon.gpu;

/**
 * The GPU enums of the public API: the generated NativeKit enums themselves, so their values come from the ABI and never
 * need converting.
 */
/** Buffer roles, combined with `|`; the native NativeKit flags, so values never need converting. */
typedef BufferUsage = nativekit.ffi.NativeKitGpu.NativeBufferUsage;

typedef ImageFormat = nativekit.ffi.NativeKitGpu.GpuImageFormat;

/** Image roles, combined with `|`; the native NativeKit flags, so values never need converting. */
typedef ImageUsage = nativekit.ffi.NativeKitGpu.NativeImageUsage;

/** Image shape; Auto is 2D, or a 2D array for a layered image. */
typedef ImageType = nativekit.ffi.NativeKitGpu.NativeImageType;

typedef LoadAction = nativekit.ffi.NativeKitGpu.NativeLoadAction;

typedef StoreAction = nativekit.ffi.NativeKitGpu.NativeStoreAction;

typedef ReadbackState = nativekit.ffi.NativeKitGpu.NativeReadbackState;

typedef TimestampState = nativekit.ffi.NativeKitGpu.NativeTimestampState;

typedef BatchPassKind = nativekit.ffi.NativeKitGpu.NativeBatchPassKind;

typedef Filter = nativekit.ffi.NativeKitGpu.NativeFilter;

typedef Wrap = nativekit.ffi.NativeKitGpu.NativeWrap;

typedef IndexType = nativekit.ffi.NativeKitGpu.NativeIndexType;

typedef ShaderStage = nativekit.ffi.NativeKitGpu.NativeShaderStage;

typedef ShaderLanguage = nativekit.ffi.NativeKitGpu.NativeShaderLanguage;

typedef UniformType = nativekit.ffi.NativeKitGpu.NativeUniformType;

/** Vertex attribute formats. */
typedef VertexFormat = nativekit.ffi.NativeKitGpu.NativeVertexFormat;
