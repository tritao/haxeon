package haxe.wire;

import haxe.wire.MessagePackReader;
import haxe.wire.MessagePackWriter;

/**
	Compiler-owned entry point for typed MessagePack codecs.

	The static encode/decode calls are recognized by the Haxeon typer and lowered
	to generated, type-specific functions. The imports keep the reader/writer
	implementation reachable from a source-level MessagePack import.
 */
class MessagePack {}
