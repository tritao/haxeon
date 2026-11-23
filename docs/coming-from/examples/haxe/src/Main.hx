class Main {
	static function main():Void {
		final milliseconds = Duration.toMilliseconds(3);
		#if verbose
		Sys.println("Duration:");
		#end
		Sys.println('$milliseconds ms');
	}
}
