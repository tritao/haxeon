package compiler.hl.patch;

import compiler.core.InternalError;
import compiler.hl.HlWriter;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

/** A key of a module of sections: the home section's module path and the member (docs/design/MODULE_SECTIONS.md, section 1). */
typedef HlSectionKey = {
	final module:String;
	final member:String;
}

/**
 * What HLP 12 carries besides the module's identity and revisions: the sections whose bytes changed, in the HLB 9 encoding, the
 * paths of the sections the module no longer has, the functions that take other names, the functions no stored closure may still
 * reach, and the classes whose existing instances run their live initializer, bases first.
 */
typedef HlSectionPatchContent = {
	final replaced:Array<{path:String, bytes:Bytes}>;
	final removed:Array<String>;
	final renames:Array<{module:String, from:String, to:String}>;
	final guards:Array<{key:HlSectionKey, description:String}>;
	final migrations:Array<{type:HlSectionKey, initializer:HlSectionKey}>;
}

/**
 * Encodes HLP 12, a patch made of module sections, which the runtime links against the link state the loader kept for the
 * running module (`hl_module_link_patch`, docs/design/MODULE_SECTIONS.md, "As built in slice 4a"): a key the module has keeps its
 * slot, a new one takes the next, and a function whose linked code is the running one's is not compiled again.
 */
class HlSectionPatch {
	public static inline final MAGIC = "HLP";
	public static inline final VERSION = 12;

	public static function encode(moduleId:Bytes, baseRevision:Int, revision:Int, content:HlSectionPatchContent):Bytes {
		if (moduleId.length != 16)
			throw new InternalError("Module ID must contain 16 bytes");
		if (baseRevision < 0 || revision <= baseRevision)
			throw new InternalError("Invalid patch revision range");
		var out = new BytesOutput();
		out.bigEndian = false;
		out.writeString(MAGIC);
		out.writeByte(VERSION);
		out.write(moduleId);
		count(out, baseRevision);
		count(out, revision);
		count(out, content.replaced.length);
		for (section in content.replaced) {
			text(out, section.path);
			out.writeInt32(section.bytes.length);
			out.write(section.bytes);
		}
		count(out, content.removed.length);
		for (path in content.removed)
			text(out, path);
		count(out, content.renames.length);
		for (rename in content.renames) {
			text(out, rename.module);
			text(out, rename.from);
			text(out, rename.to);
		}
		count(out, content.guards.length);
		for (guard in content.guards) {
			key(out, guard.key);
			text(out, guard.description);
		}
		count(out, content.migrations.length);
		for (migration in content.migrations) {
			key(out, migration.type);
			key(out, migration.initializer);
		}
		return out.getBytes();
	}

	/** Reads HLP 12 back, for tools and tests; malformed bytes are an `InternalError`. */
	public static function decode(bytes:Bytes):{
		moduleId:Bytes,
		baseRevision:Int,
		revision:Int,
		content:HlSectionPatchContent
	} {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != MAGIC || input.readByte() != VERSION)
				throw new InternalError("Not an HLP 12 patch");
			var moduleId = input.read(16), baseRevision = readCount(input), revision = readCount(input);
			var replaced = [for (_ in 0...readCount(input)) {
				var path = readText(input), size = input.readInt32();
				{
					path:path, bytes:input.read(size)
				};
			}];
			var removed = [for (_ in 0...readCount(input)) readText(input)];
			var renames = [for (_ in 0...readCount(input)) {
				var module = readText(input), from = readText(input);
				{
					module:module, from:from, to:readText(input)
				};
			}];
			var guards = [for (_ in 0...readCount(input)) {
				var key = readKey(input);
				{
					key:key, description:readText(input)
				};
			}];
			var migrations = [for (_ in 0...readCount(input)) {
				var type = readKey(input);
				{
					type:type, initializer:readKey(input)
				};
			}];
			if (input.position != bytes.length)
				throw new InternalError("Trailing HLP 12 data");
			return {
				moduleId: moduleId,
				baseRevision: baseRevision,
				revision: revision,
				content: {
					replaced: replaced,
					removed: removed,
					renames: renames,
					guards: guards,
					migrations: migrations
				}
			};
		} catch (_:haxe.io.Eof)
			throw new InternalError("Truncated HLP 12 patch");
	}

	static function readCount(input:BytesInput):Int
		return compiler.hl.HlBytecodeInput.unsigned(input, "HLP");

	static function readText(input:BytesInput):String
		return input.readString(readCount(input));

	static function readKey(input:BytesInput):HlSectionKey {
		var module = readText(input);
		return {module: module, member: readText(input)};
	}

	static function count(out:BytesOutput, value:Int):Void {
		if (value < 0)
			throw new InternalError('Negative patch count $value');
		out.write(HlWriter.encodeIndex(value));
	}

	static function text(out:BytesOutput, value:String):Void {
		var bytes = Bytes.ofString(value);
		count(out, bytes.length);
		out.write(bytes);
	}

	static function key(out:BytesOutput, value:HlSectionKey):Void {
		text(out, value.module);
		text(out, value.member);
	}
}
