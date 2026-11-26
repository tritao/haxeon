package haxeon.platform;

import nativekit.ffi.NativeKitTypes.InitOptions;

/** Application identity and event-queue options used to start a runtime. */
class RuntimeOptions {
	/** How many events may queue, or zero for the default. */
	public var eventQueueCapacity:Int = 0;

	/** A reverse-DNS identifier for the app, or null. */
	public var applicationId:Null<String> = null;

	/** The app's display name, or null. */
	public var applicationName:Null<String> = null;

	/** The default options. */
	public function new() {}

	/** The generated ABI record for these options, for the `Native` interop entry points. */
	public function nativeValue():InitOptions {
		var value = new InitOptions();
		value.struct_size = InitOptions.byteSize();
		value.event_queue_capacity = eventQueueCapacity;
		value.application_id = applicationId;
		value.application_name = applicationName;
		value.api_version = nativekit.ffi.NativeKit.nk_api_version();
		return value;
	}
}
