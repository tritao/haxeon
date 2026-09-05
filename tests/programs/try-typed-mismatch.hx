class ExpectedError {}
class ActualError {}

function main():Int {
	try {
		try {
			throw new ActualError();
		} catch (expected:ExpectedError) {
			return 0;
		}
	} catch (actual:Dynamic) {
		return 42;
	}
}
