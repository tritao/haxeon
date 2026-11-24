package haxeon.ui.host;

import haxeon.platform.AppLaunch;
import haxeon.platform.BindingError;
import haxeon.platform.Runtime;
import haxeon.platform.RuntimeOptions;

/** Runs a UI application on the current platform. */
class UiHost {
	public static function run(create:UiHostContext->UiApplication, options:UiHostOptions):Void {
		var runtimeOptions = configure(create, options);
		Runtime.launch(runtime -> new HostedUiApp(runtime, options, create), runtimeOptions);
	}

	/** Opens a UI application for a desktop runner that supplies ticks, such as live mode. */
	public static function open(create:UiHostContext->UiApplication, options:UiHostOptions):AppLaunch {
		var runtimeOptions = configure(create, options);
		return Runtime.openApp(runtime -> new HostedUiApp(runtime, options, create), runtimeOptions);
	}

	static function configure(create:UiHostContext->UiApplication, options:UiHostOptions):RuntimeOptions {
		if (options == null || create == null)
			throw BindingError.invalidArgument("UiHost.run", "UI options and an application factory are required");
		options.validate();
		var runtimeOptions = new RuntimeOptions();
		runtimeOptions.applicationId = options.applicationId;
		runtimeOptions.applicationName = options.title;
		runtimeOptions.eventQueueCapacity = options.eventQueueCapacity;
		return runtimeOptions;
	}
}
