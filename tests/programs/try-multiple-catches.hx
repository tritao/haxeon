class BaseError {}
class ParseError extends BaseError {}
class OtherError {}

function main():Int {
	try {
		throw new ParseError();
	} catch (error:OtherError) {
		return 0;
	} catch (error:ParseError) {
		return 42;
	} catch (error:BaseError) {
		return 1;
	} catch (error:Dynamic) {
		return 2;
	}
}
