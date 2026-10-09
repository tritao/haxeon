package haxeon.ui.host;

/** Settings shared by desktop and browser UI hosts. */
class UiHostOptions {
	public var title:String = "NativeKit UI";
	/** Stable application identifier passed to the desktop platform. */
	public var applicationId:Null<String> = null;
	public var width:Int = 1280;
	public var height:Int = 800;
	public var eventQueueCapacity:Int = 256;

	public function new() {}

	public function validate():Void {
		if (title == null || title.length == 0 || width <= 0 || height <= 0 ||
			eventQueueCapacity <= 0)
			throw "UI host options are invalid";
	}
}
