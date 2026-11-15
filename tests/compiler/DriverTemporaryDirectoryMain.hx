import driver.TestDriver;
import sys.FileSystem;
import sys.io.File;

@:access(driver.TestDriver)
class DriverTemporaryDirectoryMain {
	static function main():Void {
		var first = TestDriver.createTemporaryDirectory();
		var second = TestDriver.createTemporaryDirectory();
		if (first == second)
			throw "Concurrent driver runs share a temporary directory";
		if (Sys.systemName() != "Windows") {
			File.saveContent(second + "/keep", "intact");
			if (Sys.command("ln", ["-s", second, first + "/link"]) != 0)
				throw "Cannot create temporary directory symlink";
		}
		TestDriver.removeTemporaryDirectory(first);
		if (FileSystem.exists(first))
			throw "Driver temporary directory was not removed";
		if (Sys.systemName() != "Windows" && File.getContent(second + "/keep") != "intact")
			throw "Cleanup followed a symlink outside the temporary directory";
		TestDriver.removeTemporaryDirectory(second);
	}
}
