class BaseError {}
class ParseError extends BaseError {}

function main():Int {
	try {
		throw new ParseError();
	} catch (error:BaseError) {
		return 42;
	}
}
