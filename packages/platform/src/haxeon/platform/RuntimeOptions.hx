package haxeon.platform;

import nativekit.ffi.NativeKitTypes.InitOptions;

/** Application identity and event-queue options used to start a runtime. */
class RuntimeOptions {
	public var eventQueueCapacity:Int = 0;
	public var applicationId:Null<String> = null;
	public var applicationName:Null<String> = null;

	public function new() {
	}

	public function nativeValue():InitOptions {
		var value = new InitOptions();
		value.set_struct_size(InitOptions.size());
		value.set_event_queue_capacity(eventQueueCapacity);
		value.set_application_id(applicationId);
		value.set_application_name(applicationName);
		value.set_api_version(nativekit.ffi.NativeKit.nk_api_version());
		return value;
	}
}
