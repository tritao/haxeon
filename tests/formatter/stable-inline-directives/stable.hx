class A {
	static function run(home:String):Int {
		if (ProcessRunner.environmentValue("HAXEON_COMPILER_SERVER") == "0"
			|| (Sys.systemName() != "Linux") #if eval || Sys.systemName() == "Windows" #end)
			return fallback();
		p = #if haxe3 i.readInt32() #else i.readInt31() #end;
		var ints:Array<#if haxe3 Int #else haxe.Int32 #end> = [];
		#if hl
		trace(1);
		#end
		return 0;
	}
}
