// A static property's accessor must be declared ("Method get_limit required by property limit is missing").
class Settings {
	public static var limit(get, never):Int;
}

class Main {
	static function main() {
		Sys.println(Settings.limit);
	}
}
