import haxe.io.Bytes;
import haxe.io.Eof;
import sys.net.Host;
import sys.net.Socket;

// haxe.io.Input/Output built on readByte/writeByte, and a loopback sys.net.Socket exchange, give Haxe's results.
class MemoryInput extends haxe.io.Input {
	final bytes:Bytes;
	var position = 0;

	public function new(bytes:Bytes)
		this.bytes = bytes;

	override public function readByte():Int {
		if (position >= bytes.length)
			throw new Eof();
		return bytes.get(position++);
	}
}

class MemoryOutput extends haxe.io.Output {
	public final buffer = new haxe.io.BytesBuffer();

	public function new() {}

	override public function writeByte(c:Int):Void
		buffer.addByte(c);
}

function streams():Int {
	var input = new MemoryInput(Bytes.ofString("first\r\nsecond\nlast"));
	if (input.readLine() != "first" || input.readLine() != "second" || input.readLine() != "last")
		return 1;
	try {
		input.readLine();
		return 2;
	} catch (_:Eof) {}
	var output = new MemoryOutput();
	output.writeInt32(-2);
	output.bigEndian = true;
	output.writeUInt16(0x1234);
	output.writeDouble(1.5);
	output.writeString("ok");
	var written = output.buffer.getBytes();
	if (written.length != 4 + 2 + 8 + 2 || written.get(4) != 0x12 || written.get(5) != 0x34)
		return 3;
	var back = new MemoryInput(written);
	if (back.readInt32() != -2)
		return 4;
	back.bigEndian = true;
	if (back.readUInt16() != 0x1234 || back.readDouble() != 1.5 || back.readString(2) != "ok")
		return 5;
	try {
		output.writeInt8(200);
		return 6;
	} catch (error:Dynamic) {
		// Haxeon does not catch by enum type yet, so the value is checked.
		if (Std.string(error) != "Overflow")
			return 7;
	}
	return 0;
}

function sockets():Int {
	var loopback = new Host("127.0.0.1");
	if (loopback.toString() != "127.0.0.1")
		return 10;
	var server = new Socket();
	server.bind(loopback, 0);
	server.listen(1);
	var port = server.host().port;
	if (port <= 0)
		return 11;
	var client = new Socket();
	client.connect(loopback, port);
	var accepted = server.accept();
	client.output.writeString("hello\n");
	client.output.flush();
	if (accepted.input.readLine() != "hello")
		return 12;
	var reply = Bytes.ofString("pong!");
	accepted.output.writeFullBytes(reply, 0, reply.length);
	var received = Bytes.alloc(5);
	client.input.readFullBytes(received, 0, 5);
	if (received.toString() != "pong!")
		return 13;
	if (accepted.peer().host.toString() != "127.0.0.1" || client.peer().port != port)
		return 14;
	accepted.close();
	try {
		client.input.readByte();
		return 15;
	} catch (_:Eof) {}
	client.close();
	server.close();
	return 0;
}

function main():Int {
	var failure = streams();
	if (failure == 0)
		failure = sockets();
	return failure == 0 ? 42 : failure;
}
