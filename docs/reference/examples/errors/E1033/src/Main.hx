enum SaveError {
	Full;
}

class Main {
	static function save(text:String):Result<Int, SaveError>
		return text.length > 8 ? Err(Full) : Ok(text.length);

	static function main():Void {
		save("notes"); // the Result of save is dropped
	}
}
