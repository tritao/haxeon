package compiler.hl;

import haxe.Exception;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * The loader's link of an HLB 9 module of sections (`hl_code_link`, vendor/hashlink/src/link.c), done ahead of time: the HLB 8
 * module whose tables are the ones the VM builds when it loads the sections, numbered as it numbers them, with the same load
 * errors. Tools that read dense modules read a module of sections through it (`HlModuleReader`, `haxeon dev hl-link`, the
 * debugger), and `code_link --compare` checks that the VM's link of a file equals this one.
 *
 * The dense module also has the debug sections tools read: the function identities (each function's name from its key, its
 * index as its stable id, as the loader gives them), the opcode source spans of every section by function index, and the
 * source snapshots the sections carry.
 *
 * Only `haxe` is imported, so the debugger, which runs on JavaScript, links with the same code.
 */
class HlStaticLink {
	public static inline final VERSION = 9;
	static inline final FILE_DEBUG = 1;
	static inline final SECTION_CODE = 1;
	static inline final SECTION_CODE_VERSION = 1;
	static inline final SECTION_LZ4 = 1;
	static inline final ROLE_STRUCTURAL = 0;
	static inline final ROLE_OWNED = 1;
	static inline final ROLE_SHARED = 2;

	static inline final KEY_FUNCTION = 0;
	static inline final KEY_GLOBAL = 1;
	static inline final KEY_TYPE = 2;
	static inline final KEY_NATIVE = 3;
	static inline final KEY_SECTION = 4;
	static final KEY_NAMES = ["function", "global", "type", "native", "section"];

	// Type kinds (hl_type_kind).
	static inline final HFUN = 10;
	static inline final HOBJ = 11;
	static inline final HREF = 14;
	static inline final HVIRTUAL = 15;
	static inline final HABSTRACT = 17;
	static inline final HENUM = 18;
	static inline final HNULL = 19;
	static inline final HMETHOD = 20;
	static inline final HSTRUCT = 21;
	static inline final HPACKED = 22;
	static inline final HENUMTAG = 24;
	static inline final HLAST = 25;
	static inline final HI32 = 3;
	static inline final HF64 = 6;
	static inline final HBOOL = 7;
	static inline final HBYTES = 8;
	static inline final HTYPE = 13;

	/** Operand counts by opcode, as `link_op_nargs` reads them from opcodes.h: -1 is a call's or a switch's list. */
	static final NARGS = [
		2, 2, 2, 2, 2, 2, 1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 2, 2, 1, 1, 2, 3, 4, 5, 6, -1, -1, -1, -1, 2, 3, 3,
		2, 2, 3, 3, 2,
		2, 3, 3, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 2, 2, 2, 2, 2, 2, 2, 0, 1, 1, 1, -1, 1, 2, 1, 3, 3, 3, 3,
		3, 3, 3, 3, 1,
		2, 2, 2, 2, 2, 2, 2, -1, 2, 2, 4, 3, 0, 2, 3, 0, 3, 3, 1, 2, 1, 0
	];

	static inline final OINT = 1;
	static inline final OFLOAT = 2;
	static inline final OBYTES = 4;
	static inline final OSTRING = 5;
	static inline final OCALL0 = 24;
	static inline final OCALL4 = 28;
	static inline final OCALLN = 29;
	static inline final OCALLMETHOD = 30;
	static inline final OCALLTHIS = 31;
	static inline final OCALLCLOSURE = 32;
	static inline final OSTATICCLOSURE = 33;
	static inline final OINSTANCECLOSURE = 34;
	static inline final OGETGLOBAL = 36;
	static inline final OSETGLOBAL = 37;
	static inline final ODYNGET = 42;
	static inline final ODYNSET = 43;
	static inline final OSWITCH = 70;
	static inline final OTYPE = 84;
	static inline final OMAKEENUM = 90;
	static inline final OCATCH = 101;

	static inline final OPCODE_SOURCE_SPANS = 2;
	static inline final SOURCE_SNAPSHOTS = 3;

	/** The HLB 8 module the loader's link of `file` holds. Throws the loader's error for a file it would not load. */
	public static function link(file:Bytes):Bytes
		return new HlStaticLink(file).run();

	/** Whether `file` is a module of sections. */
	public static function isSectioned(file:Bytes):Bool
		return file.length >= 4 && file.get(0) == "H".code && file.get(1) == "L".code && file.get(2) == "B".code
			&& file.get(3) == VERSION;

	/**
	 * `link`, with the bytes each part of the sections takes, summed over the sections: a compressed section's parts count
	 * decoded, and the last part is what compression took off (negative), so the parts add up to the file's size.
	 */
	public static function linkWithParts(file:Bytes):{module:Bytes, parts:Array<{name:String, bytes:Int}>} {
		var link = new HlStaticLink(file), module = link.run(), total = 0;
		var parts = [for (index in 0...PART_NAMES.length) {name: PART_NAMES[index], bytes: link.parts[index]}];
		for (part in parts)
			total += part.bytes;
		parts.push({name: "taken off by compression", bytes: file.length - 4 - total});
		return {module: module, parts: parts};
	}

	static final PART_NAMES = [
		"header, directory and program record", "section headers", "section names", "imports and heads",
		"ints, floats, strings and bytes", "debug files", "types", "constants", "function instructions",
		"function debug lines and assignments", "debug sub-sections"
	];

	final file:Bytes;
	final parts:Array<Int> = [for (_ in 0...11) 0];

	// What is being read: one section's bytes, or the file.
	var data:Bytes;
	var pos = 0;
	var end = 0;
	var current = -1;
	var sections:Array<Section> = [];

	// The keys: an entry per function, global, nominal type, native and section.
	final entries:Array<Entry> = [];
	final keys:Map<String, Int> = [];

	// The linked tables.
	final strings:Array<String> = [];
	final stringIds:Map<String, Int> = [];
	final files:Array<String> = [];
	final fileIds:Map<String, Int> = [];
	final ints:Array<Int> = [];
	final intIds:Map<Int, Int> = [];
	final floats:Array<Bytes> = [];
	final floatIds:Map<String, Int> = [];
	final byteBlobs:Array<Bytes> = [];
	final byteIds:Map<String, Int> = [];

	/** Linked types: each in its HLB 8 encoding with linked indices, its kind, and, for a function type, its arguments' count. */
	var types:Array<Null<Bytes>> = [];

	final typeKinds:Array<Int> = [];
	final structuralIds:Map<String, Int> = [];
	var ownedTypes = 0;
	final globals:Array<Int> = [];
	var nglobals = 0;
	final constantIds:Map<String, Int> = [];
	final constants:Array<{global:Int, fields:Array<Int>}> = [];
	final fieldKinds:Map<Int, Array<Int>> = [];
	final natives:Array<{lib:String, name:String, type:Int}> = [];
	var nfunctions = 0;
	var functionTypes:Array<Int> = [];
	var functionBodies:Array<Bytes> = [];
	var functionNames:Array<String> = [];
	var debug = false;
	final spanFiles:Array<String> = [];
	final spanFileIds:Map<String, Int> = [];
	final spanGroups:Array<{id:Int, body:Bytes}> = [];
	final snapshots:Map<Int, Bytes> = [];

	function new(file:Bytes) {
		this.file = file;
		data = file;
		end = file.length;
	}

	// ---- errors

	function fail(message:String):Dynamic
		throw new Exception(message);

	function malformed(what:String):Dynamic
		return fail(current < 0
			? 'Malformed HLB $VERSION file: $what' : 'Malformed section `${sections[current].path}`: $what');

	static function key(module:String, member:String):String
		return module == "" ? member : module + "." + member;

	// ---- reading

	function byte():Int {
		if (pos >= end)
			malformed("no more data");
		return data.get(pos++);
	}

	function index():Int {
		var b = byte();
		if ((b & 0x80) == 0)
			return b & 0x7F;
		if ((b & 0x40) == 0) {
			var v = byte() | ((b & 31) << 8);
			return (b & 0x20) == 0 ? v : -v;
		}
		var c = byte(), d = byte(), e = byte();
		var v = ((b & 31) << 24) | (c << 16) | (d << 8) | e;
		return (b & 0x20) == 0 ? v : -v;
	}

	function uindex():Int {
		var i = index();
		if (i < 0)
			malformed("negative index");
		return i;
	}

	function count():Int {
		var n = uindex();
		// Every entry takes at least a byte, which bounds what a corrupt count can make us allocate.
		if (n > end)
			malformed("a table count exceeds the data");
		return n;
	}

	function i32():Int {
		if (end - pos < 4)
			malformed("no more data");
		var v = data.getInt32(pos);
		pos += 4;
		return v;
	}

	function raw(size:Int):Int {
		if (size < 0 || end - pos < size)
			malformed("no more data");
		var at = pos;
		pos += size;
		return at;
	}

	function text():String {
		var length = uindex();
		return data.getString(raw(length), length);
	}

	function stringTable(n:Int):Array<String> {
		var size = i32(), base = raw(size), offset = 0, out:Array<String> = [];
		for (_ in 0...n) {
			var length = uindex();
			if (length >= size - offset || data.get(base + offset + length) != 0)
				malformed("invalid string");
			out.push(data.getString(base + offset, length));
			offset += length + 1;
		}
		return out;
	}

	function local(n:Int, what:String):Int {
		var i = uindex();
		if (i >= n)
			malformed(what);
		return i;
	}

	// ---- keys

	function find(kind:Int, module:String, member:String):Int {
		var id = keys.get(kind + "\n" + module + "\n" + member);
		return id == null ? -1 : id;
	}

	function add(kind:Int, module:String, member:String, value:Int, extra:Int):Int {
		var name = kind + "\n" + module + "\n" + member;
		if (keys.exists(name))
			return -1;
		keys.set(name, entries.length);
		entries.push({
			kind: kind,
			module: module,
			member: member,
			value: value,
			section: current,
			extra: extra
		});
		return entries.length - 1;
	}

	// ---- literals

	function internString(value:String):Int {
		var id = stringIds.get(value);
		if (id == null) {
			id = strings.length;
			strings.push(value);
			stringIds.set(value, id);
		}
		return id;
	}

	function internFile(value:String):Int {
		var id = fileIds.get(value);
		if (id == null) {
			id = files.length;
			files.push(value);
			fileIds.set(value, id);
		}
		return id;
	}

	// ---- the file

	function run():Bytes {
		if (!isSectioned(file))
			malformed("invalid header");
		pos = 4;
		var flags = uindex();
		if (flags & ~FILE_DEBUG != 0)
			malformed("unknown flags");
		debug = flags & FILE_DEBUG != 0;
		var n = count();
		for (index in 0...n) {
			var section = new Section(text());
			section.offset = i32();
			section.size = i32();
			raw(8);
			sections.push(section);
			if (section.path == "")
				malformed("a section without a module path");
			if (add(KEY_SECTION, section.path, "", index, 0) < 0)
				fail('Two sections are named `${section.path}`');
		}
		var entryModule = text(), entryMember = text(), area = pos;
		parts[0] += area - 4;
		for (section in sections) {
			if (section.offset < 0 || section.size < 0 || section.offset > file.length - area
				|| section.size > file.length - area - section.offset)
				malformed("a section lies outside the file");
			section.data = file;
			section.start = area + section.offset;
			section.end = section.start + section.size;
		}
		for (index in 0...sections.length)
			readInterface(index);
		current = -1;
		functionTypes = [for (_ in 0...nfunctions) -1];
		functionBodies = [for (_ in 0...nfunctions) null];
		functionNames = [for (_ in 0...nfunctions) ""];
		types = [for (_ in 0...ownedTypes) null];
		for (_ in 0...ownedTypes)
			typeKinds.push(-1);
		for (_ in 0...nglobals)
			globals.push(-1);
		for (entry in entries)
			if (entry.kind == KEY_FUNCTION)
				functionNames[entry.value] = entry.member;
		for (index in 0...sections.length)
			readTypes(index);
		current = -1;
		checkImports();
		for (index in 0...sections.length)
			readCode(index);
		current = -1;
		var entry = find(KEY_FUNCTION, entryModule, entryMember);
		if (entry < 0)
			fail('The entry function `${key(entryModule, entryMember)}` is not defined by any section');
		return dense(entries[entry].value);
	}

	// ---- pass 1: interfaces

	function enter(section:Section):Void {
		data = section.data;
		pos = section.start;
		end = section.end;
	}

	function readImports(section:Section, n:Int, kinds:Bool):Array<Import> {
		var out:Array<Import> = [];
		for (_ in 0...n) {
			var module = section.names[local(section.names.length, "invalid name index")],
				member = section.names[local(section.names.length, "invalid name index")],
				expected = kinds ? byte() : local(section.ntimports + section.ntypes, "invalid type index");
			if (kinds && !nominal(expected) && expected != HVIRTUAL)
				malformed("an imported type is not nominal");
			out.push({module: module, member: member, expected: expected, resolved: -1});
		}
		return out;
	}

	static function nominal(kind:Int):Bool
		return kind == HOBJ || kind == HSTRUCT || kind == HENUM || kind == HENUMTAG;

	function readInterface(si:Int):Void {
		var s = sections[si];
		current = si;
		enter(s);
		var kind = uindex(), version = uindex(), flags = uindex();
		if (kind != SECTION_CODE || version != SECTION_CODE_VERSION)
			fail('Malformed section `${s.path}`: unsupported section kind $kind:$version');
		if (flags & ~SECTION_LZ4 != 0)
			malformed("unknown section flags");
		if (flags & SECTION_LZ4 != 0) {
			var size = uindex(), packed = end - pos;
			if (Std.int(size / 255) > packed)
				malformed("invalid compressed data");
			var decoded = try decompress(data, pos, packed,
				size) catch (_:Exception) malformed("invalid compressed data");
			parts[1] += pos - s.start;
			s.data = decoded;
			s.start = 0;
			s.end = size;
		} else {
			parts[1] += pos - s.start;
			s.start = pos;
		}
		enter(s);
		s.nnames = count();
		s.nfimports = count();
		s.ngimports = count();
		s.ntimports = count();
		s.nnatives = count();
		s.ntypes = count();
		s.nglobals = count();
		s.nfunctions = count();
		s.nints = count();
		s.nfloats = count();
		s.nstrings = count();
		s.nbytes = count();
		s.nconstants = count();
		s.ndebugfiles = count();
		if (s.ndebugfiles > 0 && !debug)
			malformed("debug files in a file without debug information");
		var mark = pos;
		s.names = stringTable(s.nnames);
		parts[2] += pos - mark;
		mark = pos;
		s.fimports = readImports(s, s.nfimports, false);
		s.gimports = readImports(s, s.ngimports, false);
		s.timports = readImports(s, s.ntimports, true);
		s.natives = readImports(s, s.nnatives, false);
		s.tmap = [for (_ in 0...s.ntimports + s.ntypes) -1];
		for (i in 0...s.ntypes) {
			var role = byte(), kind = byte();
			s.typeRoles.push(role);
			s.typeKinds.push(kind);
			s.typeKeys.push(-1);
			if (role > ROLE_SHARED || kind >= HLAST)
				malformed("invalid type head");
			if (role == ROLE_STRUCTURAL) {
				if (nominal(kind))
					malformed("a nominal type without a key");
				continue;
			}
			if (!nominal(kind) && kind != HVIRTUAL)
				malformed("a structural type with a key");
			s.typeKeys[i] = local(s.nnames, "invalid name index");
			var member = s.names[s.typeKeys[i]];
			if (role == ROLE_OWNED) {
				if (add(KEY_TYPE, s.path, member, ownedTypes, kind) < 0)
					duplicate(s, KEY_TYPE, member);
				s.tmap[s.ntimports + i] = ownedTypes++;
			} else {
				var id = find(KEY_TYPE, "", member);
				if (id < 0) {
					add(KEY_TYPE, "", member, ownedTypes, kind);
					s.tmap[s.ntimports + i] = ownedTypes++;
				} else if (entries[id].section == si)
					fail('`${s.path}` defines shared type `$member` twice');
				else if (entries[id].extra != kind)
					fail('`${s.path}` defines shared type `$member` differently from `${sections[entries[id].section].path}`');
				else
					s.tmap[s.ntimports + i] = entries[id].value;
			}
		}
		s.firstGlobal = nglobals;
		for (_ in 0...s.nglobals) {
			var member = s.names[local(s.nnames, "invalid name index")];
			s.globalTypes.push(local(s.ntimports + s.ntypes, "invalid type index"));
			if (add(KEY_GLOBAL, s.path, member, nglobals++, 0) < 0)
				duplicate(s, KEY_GLOBAL, member);
		}
		s.firstFunction = nfunctions;
		for (_ in 0...s.nfunctions) {
			var member = s.names[local(s.nnames, "invalid name index")];
			s.functionKeys.push(member);
			s.functionTypes.push(local(s.ntimports + s.ntypes, "invalid type index"));
			if (add(KEY_FUNCTION, s.path, member, nfunctions++, 0) < 0)
				duplicate(s, KEY_FUNCTION, member);
		}
		for (native in s.natives) {
			var id = find(KEY_NATIVE, native.module, native.member);
			if (id < 0) {
				id = add(KEY_NATIVE, native.module, native.member, natives.length, -1);
				natives.push({lib: native.module, name: native.member, type: -1});
			}
			native.resolved = id;
		}
		parts[3] += pos - mark;
		s.typesPos = pos;
	}

	function duplicate(s:Section, kind:Int, member:String):Void
		fail('`${s.path}` exports ${KEY_NAMES[kind]} `${key(s.path, member)}` twice');

	// ---- pass 2: types

	function resolve(s:Section, im:Import, kind:Int):Int {
		var id = find(kind, im.module, im.member);
		if (id < 0)
			fail('`${s.path}` imports ${KEY_NAMES[kind]} `${key(im.module, im.member)}`, which no section defines');
		im.resolved = id;
		return entries[id].value;
	}

	function readTypes(si:Int):Void {
		var s = sections[si];
		current = si;
		enter(s);
		pos = s.typesPos;
		for (im in s.fimports)
			s.fmap.push(resolve(s, im, KEY_FUNCTION));
		for (native in s.natives)
			s.fmap.push(-1 - entries[native.resolved].value);
		for (i in 0...s.nfunctions)
			s.fmap.push(s.firstFunction + i);
		for (im in s.gimports)
			s.gmap.push(resolve(s, im, KEY_GLOBAL));
		for (i in 0...s.nglobals)
			s.gmap.push(s.firstGlobal + i);
		for (_ in 0...s.nconstants)
			s.gmap.push(-1);
		for (i in 0...s.ntimports) {
			var im = s.timports[i];
			s.tmap[i] = resolve(s, im, KEY_TYPE);
			var entry = entries[im.resolved];
			if (entry.extra != im.expected)
				fail('`${s.path}` imports type `${key(im.module, im.member)}` as another kind than `${sections[entry.section].path}` defines');
		}
		var mark = pos;
		for (_ in 0...s.nints) {
			var v = i32(), id = intIds.get(v);
			if (id == null) {
				id = ints.length;
				ints.push(v);
				intIds.set(v, id);
			}
			s.imap.push(id);
		}
		for (_ in 0...s.nfloats) {
			var at = raw(8), bits = data.sub(at, 8), name = bits.toHex(), id = floatIds.get(name);
			if (id == null) {
				id = floats.length;
				floats.push(bits);
				floatIds.set(name, id);
			}
			s.flmap.push(id);
		}
		for (value in stringTable(s.nstrings))
			s.smap.push(internString(value));
		for (_ in 0...s.nbytes) {
			var length = uindex(), blob = data.sub(raw(length), length), name = blob.toHex(), id = byteIds.get(name);
			if (id == null) {
				id = byteBlobs.length;
				byteBlobs.push(blob);
				byteIds.set(name, id);
			}
			s.bmap.push(id);
		}
		parts[4] += pos - mark;
		mark = pos;
		for (value in stringTable(s.ndebugfiles))
			s.dmap.push(internFile(value));
		parts[5] += pos - mark;
		mark = pos;
		var positions:Array<Int> = [];
		for (_ in 0...s.ntypes) {
			positions.push(pos);
			skipType();
		}
		var after = pos;
		for (i in 0...s.ntypes) {
			if (s.typeRoles[i] != ROLE_STRUCTURAL)
				continue;
			pos = positions[i];
			var type = readType(s);
			if (type.kind != s.typeKinds[i])
				malformed("a type differs from its head");
			var name = type.bytes.toHex(), id = structuralIds.get(name);
			if (id == null) {
				id = types.length;
				types.push(type.bytes);
				typeKinds.push(type.kind);
				structuralIds.set(name, id);
			}
			s.tmap[s.ntimports + i] = id;
		}
		for (i in 0...s.ntypes) {
			if (s.typeRoles[i] == ROLE_STRUCTURAL)
				continue;
			var slot = s.tmap[s.ntimports + i], member = s.names[s.typeKeys[i]];
			pos = positions[i];
			var type = readType(s);
			if (type.kind != s.typeKinds[i])
				malformed("a type differs from its head");
			var first = types[slot];
			if (first == null) {
				types[slot] = type.bytes;
				typeKinds[slot] = type.kind;
			} else if (first.compare(type.bytes) != 0) {
				var id = find(KEY_TYPE, "", member);
				fail('`${s.path}` defines shared type `$member` differently from `${sections[entries[id].section].path}`');
			}
		}
		pos = after;
		parts[6] += pos - mark;
		for (i in 0...s.nglobals)
			globals[s.firstGlobal + i] = s.tmap[s.globalTypes[i]];
		for (i in 0...s.nfunctions) {
			var type = s.tmap[s.functionTypes[i]];
			if (typeKinds[type] != HFUN && typeKinds[type] != HMETHOD)
				malformed("a function's type is not a function type");
			functionTypes[s.firstFunction + i] = type;
		}
		for (n in s.natives) {
			var entry = entries[n.resolved], native = natives[entry.value], type = s.tmap[n.expected];
			if (typeKinds[type] != HFUN)
				malformed("a native's type is not a function type");
			if (native.type < 0) {
				native.type = type;
				entry.extra = si;
			} else if (native.type != type)
				fail('`${s.path}` declares native `${n.module}@${n.member}` with another type than `${sections[entry.extra].path}`');
		}
		s.codePos = pos;
	}

	function checkImports():Void
		for (s in sections) {
			for (k in 0...s.nfimports + s.ngimports) {
				var isFunction = k < s.nfimports,
					im = isFunction ? s.fimports[k] : s.gimports[k - s.nfimports],
					entry = entries[im.resolved],
					defined = isFunction ? functionTypes[entry.value] : globals[entry.value];
				if (s.tmap[im.expected] != defined)
					fail('`${s.path}` imports ${isFunction ? "function" : "global"} `${key(im.module, im.member)}` with another type than `${sections[entry.section].path}` defines');
			}
		}

	function mapType(s:Section):Int {
		var i = index();
		if (i < 0 || i >= s.ntimports + s.ntypes)
			malformed("invalid type index");
		if (s.tmap[i] < 0)
			malformed("a structural type refers to a later one");
		return s.tmap[i];
	}

	function mapString(s:Section):Int
		return s.smap[local(s.nstrings, "invalid string index")];

	function mapFunction(s:Section, i:Int):Int {
		if (i < 0 || i >= s.nfimports + s.nnatives + s.nfunctions)
			malformed("invalid function index");
		var f = s.fmap[i];
		return f < 0 ? nfunctions + (-1 - f) : f;
	}

	function typeGlobal(s:Section):Int
		return s.gmap[local(s.ngimports + s.nglobals, "invalid global index in a type")];

	/** One type of the section's table in HLB 8's encoding with linked indices, as read_type reads it. */
	function readType(s:Section):{kind:Int, bytes:Bytes} {
		var out = new Output(), kind = byte();
		out.byte(kind);
		switch kind {
			case HFUN | HMETHOD:
				var nargs = byte();
				out.byte(nargs);
				for (_ in 0...nargs + 1)
					out.index(mapType(s));
			case HOBJ | HSTRUCT:
				out.index(mapString(s));
				var base = index();
				if (base >= 0) {
					if (base >= s.ntimports + s.ntypes || s.tmap[base] < 0)
						malformed("invalid super type");
					out.index(s.tmap[base]);
				} else
					out.index(-1);
				var global = uindex();
				if (global > 0) {
					if (global - 1 >= s.ngimports + s.nglobals)
						malformed("invalid global index in a type");
					global = s.gmap[global - 1] + 1;
				}
				out.index(global);
				var nfields = count(), nproto = count(), nbindings = count();
				out.index(nfields);
				out.index(nproto);
				out.index(nbindings);
				for (_ in 0...nfields) {
					out.index(mapString(s));
					out.index(mapType(s));
				}
				for (_ in 0...nproto) {
					out.index(mapString(s));
					out.index(mapFunction(s, uindex()));
					out.index(index());
				}
				for (_ in 0...nbindings) {
					out.index(uindex());
					out.index(mapFunction(s, uindex()));
				}
			case HVIRTUAL:
				out.index(mapString(s));
				var nfields = count();
				out.index(nfields);
				for (_ in 0...nfields) {
					out.index(mapString(s));
					out.index(mapType(s));
				}
			case HABSTRACT:
				out.index(mapString(s));
			case HENUM:
				out.index(mapString(s));
				var global = uindex();
				if (global > 0) {
					if (global - 1 >= s.ngimports + s.nglobals)
						malformed("invalid global index in a type");
					global = s.gmap[global - 1] + 1;
				}
				out.index(global);
				var nconstructs = count();
				out.index(nconstructs);
				for (_ in 0...nconstructs) {
					out.index(mapString(s));
					var nparams = count();
					out.index(nparams);
					for (_ in 0...nparams)
						out.index(mapType(s));
				}
			case HENUMTAG:
				out.index(mapType(s));
				var ncases = count();
				out.index(ncases);
				for (_ in 0...ncases)
					out.index(typeGlobal(s));
			case HREF | HNULL | HPACKED:
				out.index(mapType(s));
			default:
				if (kind >= HLAST)
					malformed("invalid type kind");
		}
		return {kind: kind, bytes: out.bytes()};
	}

	function skipType():Void {
		var kind = byte();
		switch kind {
			case HFUN | HMETHOD:
				for (_ in 0...byte() + 1)
					index();
			case HOBJ | HSTRUCT:
				index();
				index();
				index();
				var nfields = count(), nproto = count(), nbindings = count();
				for (_ in 0...nfields * 2 + nproto * 3 + nbindings * 2)
					index();
			case HVIRTUAL:
				index();
				for (_ in 0...count() * 2)
					index();
			case HENUM:
				index();
				index();
				for (_ in 0...count()) {
					index();
					for (_ in 0...count())
						index();
				}
			case HENUMTAG:
				index();
				for (_ in 0...count())
					index();
			case HABSTRACT | HREF | HNULL | HPACKED:
				index();
			default:
				if (kind >= HLAST)
					malformed("invalid type kind");
		}
	}

	// ---- pass 3: code

	function mapLocal(map:Array<Int>, i:Int, what:String):Int {
		if (i < 0 || i >= map.length)
			malformed(what);
		return map[i];
	}

	function readConstants(s:Section):Void
		for (k in 0...s.nconstants) {
			var type = mapType(s), n = count(), kind = typeKinds[type];
			var fieldKinds = kind == HOBJ || kind == HSTRUCT ? objectFieldKinds(type) : null;
			if (fieldKinds == null || n > fieldKinds.length)
				malformed("invalid constant");
			var fields:Array<Int> = [];
			for (j in 0...n) {
				var v = uindex();
				fields.push(switch fieldKinds[j] {
					case HI32: mapLocal(s.imap, v, "invalid int index");
					case HBOOL: v;
					case HF64: mapLocal(s.flmap, v, "invalid float index");
					case HBYTES: mapLocal(s.smap, v, "invalid string index");
					case HTYPE:
						if (v >= s.ntimports + s.ntypes)
							malformed("invalid type index");
						s.tmap[v];
					default:
						var g = mapLocal(s.gmap, v, "invalid global index");
						if (g < 0)
							malformed("a constant refers to a later one");
						g;
				});
			}
			var name = type + ":" + fields.join(","), id = constantIds.get(name);
			if (id == null) {
				id = constants.length;
				constants.push({global: nglobals++, fields: fields});
				globals.push(type);
				constantIds.set(name, id);
			}
			s.gmap[s.ngimports + s.nglobals + k] = constants[id].global;
		}

	/** The linked encoding of type `type`. */
	function definition(type:Int):Bytes {
		var bytes = types[type];
		if (bytes == null)
			throw new Exception('Type $type has no definition');
		return bytes;
	}

	/** The kinds of the own fields of object type `type`, from its linked encoding. */
	function objectFieldKinds(type:Int):Array<Int> {
		var known = fieldKinds.get(type);
		if (known != null)
			return known;
		var reader = new HlStaticLink(definition(type));
		reader.byte();
		reader.index();
		reader.index();
		reader.index();
		var n = reader.uindex();
		reader.uindex();
		reader.uindex();
		known = [for (_ in 0...n) {
			reader.index();
			typeKinds[reader.index()];
		}];
		fieldKinds.set(type, known);
		return known;
	}

	function readCode(si:Int):Void {
		var s = sections[si];
		current = si;
		enter(s);
		pos = s.codePos;
		var mark = pos;
		readConstants(s);
		parts[7] += pos - mark;
		for (i in 0...s.nfunctions)
			readFunction(s, i);
		mark = pos;
		readDebugSections(s);
		parts[10] += pos - mark;
		if (pos != end)
			malformed("trailing data");
	}

	function readFunction(s:Section, i:Int):Void {
		var findex = s.firstFunction + i, out = new Output();
		var mark = pos;
		out.index(functionTypes[findex]);
		out.index(findex);
		var nregs = count(), nops = count();
		out.index(nregs);
		out.index(nops);
		for (_ in 0...nregs)
			out.index(mapType(s));
		for (_ in 0...nops)
			readOpcode(s, out);
		parts[8] += pos - mark;
		mark = pos;
		if (debug) {
			readLines(s, nops, out);
			var nassigns = count();
			out.index(nassigns);
			for (_ in 0...nassigns) {
				out.index(s.smap[local(s.nstrings, "invalid string index")]);
				out.index(index());
				out.index(index());
			}
		}
		parts[9] += pos - mark;
		functionBodies[findex] = out.bytes();
	}

	function readOpcode(s:Section, out:Output):Void {
		var op = byte();
		if (op >= NARGS.length)
			malformed("invalid opcode");
		out.byte(op);
		var p:Array<Int> = [];
		switch NARGS[op] {
			case -1:
				if (op == OSWITCH) {
					p.push(uindex());
					var n = count();
					p.push(n);
					for (_ in 0...n)
						p.push(uindex());
					p.push(uindex());
				} else if (op == OCALLN || op == OCALLCLOSURE || op == OCALLMETHOD || op == OCALLTHIS
					|| op == OMAKEENUM) {
					p.push(index());
					p.push(index());
					var n = byte();
					p.push(n);
					for (_ in 0...n)
						p.push(index());
				} else
					malformed("an opcode of unknown shape");
			case n:
				for (_ in 0...n)
					p.push(index());
		}
		switch op {
			case OINT: p[1] = mapLocal(s.imap, p[1], "invalid int index");
			case OFLOAT: p[1] = mapLocal(s.flmap, p[1], "invalid float index");
			case OBYTES: p[1] = mapLocal(s.bmap, p[1], "invalid bytes index");
			case OSTRING: p[1] = mapLocal(s.smap, p[1], "invalid string index");
			case OTYPE:
				if (p[1] < 0 || p[1] >= s.ntimports + s.ntypes)
					malformed("invalid type index");
				p[1] = s.tmap[p[1]];
			case OGETGLOBAL: p[1] = mapLocal(s.gmap, p[1], "invalid global index");
			case OSETGLOBAL | OCATCH: p[0] = mapLocal(s.gmap, p[0], "invalid global index");
			case ODYNGET: p[2] = mapLocal(s.smap, p[2], "invalid string index");
			case ODYNSET: p[1] = mapLocal(s.smap, p[1], "invalid string index");
			case op if (op >= OCALL0 && op <= OCALL4 || op == OCALLN || op == OSTATICCLOSURE || op == OINSTANCECLOSURE):
				p[1] = mapFunction(s, p[1]);
			default:
		}
		if (op == OSWITCH) {
			for (v in p)
				out.index(v);
		} else if (NARGS[op] == -1) {
			out.index(p[0]);
			out.index(p[1]);
			out.byte(p[2]);
			for (k in 3...p.length)
				out.index(p[k]);
		} else
			for (v in p)
				out.index(v);
	}

	/** The function's lines as HLB 8 encodes them, the files mapped: read as `read_debug` does, written as the compiler does. */
	function readLines(s:Section, nops:Int, out:Output):Void {
		var lineFiles:Array<Int> = [], lines:Array<Int> = [], file = -1, line = 0;
		while (lineFiles.length < nops) {
			var b = byte();
			if (b & 1 != 0) {
				var f = ((b >> 1) << 8) | byte();
				if (f >= s.ndebugfiles)
					malformed("invalid debug file");
				file = s.dmap[f];
			} else if (b & 2 != 0) {
				var delta = b >> 6, run = (b >> 2) & 15;
				if (lineFiles.length + run > nops)
					malformed("debug lines past the function's end");
				for (_ in 0...run) {
					lineFiles.push(file);
					lines.push(line);
				}
				line += delta;
			} else {
				if (b & 4 != 0)
					line += b >> 3;
				else {
					var b2 = byte(), b3 = byte();
					line = (b >> 3) | (b2 << 5) | (b3 << 13);
				}
				lineFiles.push(file);
				lines.push(line);
			}
		}
		var currentFile = -1, currentLine = 0, i = 0;
		while (i < nops) {
			var f = lineFiles[i], l = lines[i];
			if (f != currentFile) {
				out.byte(((f >> 8) << 1) | 1);
				out.byte(f & 0xFF);
				currentFile = f;
			}
			if (l == currentLine) {
				var run = 1;
				while (run < 15 && i + run < nops && lineFiles[i + run] == f && lines[i + run] == currentLine)
					run++;
				out.byte((run << 2) | 2);
				i += run;
			} else {
				var delta = l - currentLine;
				if (delta > 0 && delta <= 31)
					out.byte((delta << 3) | 4);
				else {
					out.byte((l & 0x1F) << 3);
					out.byte((l >> 5) & 0xFF);
					out.byte((l >> 13) & 0xFF);
				}
				currentLine = l;
				i++;
			}
		}
	}

	/** The section's debug sub-sections: its opcode spans join the module's, by linked function index; its snapshots too. */
	function readDebugSections(s:Section):Void
		for (_ in 0...count()) {
			var kind = uindex(), version = uindex(), flags = uindex(), size = uindex();
			if (kind <= 0 || version <= 0)
				malformed("invalid debug section header");
			if (flags != 0)
				malformed("a compressed debug section");
			var at = raw(size);
			if (kind == OPCODE_SOURCE_SPANS && version == 2)
				readSpans(s, at, at + size);
			else if (kind == SOURCE_SNAPSHOTS && version == 1)
				readSnapshots(at, at + size);
		}

	function readSpans(s:Section, from:Int, to:Int):Void {
		var outer = end;
		pos = from;
		end = to;
		var sectionFiles = [for (_ in 0...uindex()) text()];
		for (_ in 0...uindex()) {
			var fn = uindex();
			if (fn >= s.nfunctions)
				malformed("invalid opcode source-span function");
			var body = new Output(), n = uindex();
			body.index(s.firstFunction + fn);
			body.index(n);
			for (_ in 0...n) {
				body.index(uindex());
				var f = uindex();
				if (f >= sectionFiles.length)
					malformed("invalid opcode source-span file");
				var id = spanFileIds.get(sectionFiles[f]);
				if (id == null) {
					id = spanFiles.length;
					spanFiles.push(sectionFiles[f]);
					spanFileIds.set(sectionFiles[f], id);
				}
				body.index(id);
				body.index(index());
				body.index(index());
				for (_ in 0...4)
					body.index(uindex());
				body.raw(data, raw(4), 4);
				body.index(uindex());
			}
			spanGroups.push({id: s.firstFunction + fn, body: body.bytes()});
		}
		if (pos != to)
			malformed("trailing opcode source spans");
		end = outer;
	}

	function readSnapshots(from:Int, to:Int):Void {
		var outer = end;
		pos = from;
		end = to;
		for (_ in 0...uindex()) {
			var hash = i32(), length = uindex(), content = data.sub(raw(length), length), known = snapshots.get(hash);
			if (known != null && known.compare(content) != 0)
				malformed('two source snapshots of hash $hash differ');
			snapshots.set(hash, content);
		}
		if (pos != to)
			malformed("trailing source snapshots");
		end = outer;
	}

	// ---- the dense module

	function dense(entry:Int):Bytes {
		// The natives' names follow the strings, as a dense file needs them there.
		var nativeNames = [for (native in natives)[internString(native.lib), internString(native.name)]];
		var out = new Output();
		out.raw(Bytes.ofString("HLB"), 0, 3);
		out.byte(8);
		out.index(debug ? 1 : 0);
		for (n in [
			ints.length, floats.length, strings.length, byteBlobs.length, types.length, nglobals, natives.length,
			nfunctions,
			constants.length, entry
		])
			out.index(n);
		for (v in ints)
			out.int32(v);
		for (bits in floats)
			out.raw(bits, 0, 8);
		out.strings(strings);
		var blobSize = 0;
		for (blob in byteBlobs)
			blobSize += blob.length;
		out.int32(blobSize);
		for (blob in byteBlobs)
			out.raw(blob, 0, blob.length);
		var at = 0;
		for (blob in byteBlobs) {
			out.index(at);
			at += blob.length;
		}
		if (debug) {
			out.index(files.length);
			out.strings(files);
		}
		for (type in 0...types.length) {
			var bytes = definition(type);
			out.raw(bytes, 0, bytes.length);
		}
		for (type in globals)
			out.index(type);
		for (index in 0...natives.length) {
			out.index(nativeNames[index][0]);
			out.index(nativeNames[index][1]);
			out.index(natives[index].type);
			out.index(nfunctions + index);
		}
		for (body in functionBodies)
			out.raw(body, 0, body.length);
		for (constant in constants) {
			out.index(constant.global);
			out.index(constant.fields.length);
			for (field in constant.fields)
				out.index(field);
		}
		var debugSections:Array<{kind:Int, version:Int, payload:Bytes}> = [];
		var identities = new Output();
		identities.index(nfunctions);
		for (findex in 0...nfunctions) {
			var name = functionNames[findex], dot = name.lastIndexOf(".");
			identities.index(findex);
			identities.index(findex);
			identities.text(name);
			identities.text(dot < 0 ? name : name.substr(dot + 1));
			identities.text("");
			identities.index(0);
			identities.index(0);
			identities.index(0);
			identities.index(StringTools.startsWith(name, "__") ? 1 : 0);
		}
		debugSections.push({kind: 1, version: 1, payload: identities.bytes()});
		if (spanGroups.length > 0) {
			var spans = new Output();
			spans.index(spanFiles.length);
			for (path in spanFiles)
				spans.text(path);
			spanGroups.sort((a, b) -> a.id - b.id);
			spans.index(spanGroups.length);
			for (group in spanGroups)
				spans.raw(group.body, 0, group.body.length);
			debugSections.push({kind: OPCODE_SOURCE_SPANS, version: 2, payload: spans.bytes()});
		}
		var hashes = [for (hash in snapshots.keys()) hash];
		if (hashes.length > 0) {
			hashes.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
			var payload = new Output();
			payload.index(hashes.length);
			for (hash in hashes) {
				var content = snapshots.get(hash);
				payload.int32(hash);
				payload.index(content.length);
				payload.raw(content, 0, content.length);
			}
			debugSections.push({kind: SOURCE_SNAPSHOTS, version: 1, payload: payload.bytes()});
		}
		out.index(debugSections.length);
		for (section in debugSections) {
			out.index(section.kind);
			out.index(section.version);
			out.index(0);
			out.index(section.payload.length);
			out.raw(section.payload, 0, section.payload.length);
		}
		return out.bytes();
	}

	/** The `size` bytes the LZ4 block at `bytes[position, position + length)` decodes to (`HlLz4.decompress`). */
	static function decompress(bytes:Bytes, position:Int, length:Int, size:Int):Bytes {
		var output = Bytes.alloc(size), at = position, last = position + length, written = 0;
		function next():Int {
			if (at >= last)
				throw new Exception("Truncated LZ4 block");
			return bytes.get(at++);
		}
		function extended(n:Int):Int {
			if (n == 15) {
				var more = 255;
				while (more == 255) {
					more = next();
					n += more;
				}
			}
			return n;
		}
		while (true) {
			var token = next(), literals = extended(token >>> 4);
			if (literals > last - at || literals > size - written)
				throw new Exception("Invalid LZ4 literals");
			output.blit(written, bytes, at, literals);
			at += literals;
			written += literals;
			if (at == last)
				break;
			var offset = next() | (next() << 8), match = extended(token & 15) + 4;
			if (offset == 0 || offset > written || match > size - written)
				throw new Exception("Invalid LZ4 match");
			if (offset >= match)
				output.blit(written, output, written - offset, match);
			else
				for (k in 0...match)
					output.set(written + k, output.get(written - offset + k));
			written += match;
		}
		if (written != size)
			throw new Exception("LZ4 block does not decode to its size");
		return output;
	}
}

private typedef Entry = {
	final kind:Int;
	final module:String;
	final member:String;
	final value:Int;

	/** The section that entered the key: the owner, or for a shared definition the one whose definition is kept. */
	final section:Int;

	/** A type's kind; for a native, the section whose declared type the others must match. */
	var extra:Int;
}

private typedef Import = {
	final module:String;
	final member:String;
	final expected:Int;
	var resolved:Int;
}

private class Section {
	public final path:String;
	public var offset = 0;
	public var size = 0;
	public var data:Bytes;
	public var start = 0;
	public var end = 0;
	public var typesPos = 0;
	public var codePos = 0;
	public var nnames = 0;
	public var nfimports = 0;
	public var ngimports = 0;
	public var ntimports = 0;
	public var nnatives = 0;
	public var ntypes = 0;
	public var nglobals = 0;
	public var nfunctions = 0;
	public var nints = 0;
	public var nfloats = 0;
	public var nstrings = 0;
	public var nbytes = 0;
	public var nconstants = 0;
	public var ndebugfiles = 0;
	public var names:Array<String> = [];
	public var fimports:Array<Import> = [];
	public var gimports:Array<Import> = [];
	public var timports:Array<Import> = [];
	public var natives:Array<Import> = [];
	public final typeRoles:Array<Int> = [];
	public final typeKinds:Array<Int> = [];
	public final typeKeys:Array<Int> = [];
	public final globalTypes:Array<Int> = [];
	public final functionKeys:Array<String> = [];
	public final functionTypes:Array<Int> = [];
	public var firstGlobal = 0;
	public var firstFunction = 0;

	/** Local index to linked index, per table. A native's function index is -1 - its native index until the functions are counted. */
	public final fmap:Array<Int> = [];

	public final gmap:Array<Int> = [];
	public var tmap:Array<Int> = [];
	public final imap:Array<Int> = [];
	public final flmap:Array<Int> = [];
	public final smap:Array<Int> = [];
	public final bmap:Array<Int> = [];
	public final dmap:Array<Int> = [];

	public function new(path:String) {
		this.path = path;
		this.data = Bytes.alloc(0);
	}
}

/** HLB's encodings, written. */
private class Output {
	final buffer = new BytesBuffer();

	public function new() {}

	public inline function byte(v:Int):Void
		buffer.addByte(v & 0xFF);

	public function index(v:Int):Void {
		var negative = v < 0, m = negative ? -v : v;
		if (m < 0x80 && !negative)
			byte(m);
		else if (m < 0x2000) {
			byte(0x80 | (negative ? 0x20 : 0) | (m >> 8));
			byte(m & 0xFF);
		} else {
			byte(0xC0 | (negative ? 0x20 : 0) | (m >> 24));
			byte((m >> 16) & 0xFF);
			byte((m >> 8) & 0xFF);
			byte(m & 0xFF);
		}
	}

	public function int32(v:Int):Void {
		byte(v);
		byte(v >> 8);
		byte(v >> 16);
		byte(v >>> 24);
	}

	public function raw(source:Bytes, position:Int, length:Int):Void
		buffer.addBytes(source, position, length);

	public function text(value:String):Void {
		var bytes = Bytes.ofString(value);
		index(bytes.length);
		raw(bytes, 0, bytes.length);
	}

	/** A string table: its byte size, the NUL-terminated strings, then each length. */
	public function strings(values:Array<String>):Void {
		var encoded = [for (value in values) Bytes.ofString(value)], size = 0;
		for (bytes in encoded)
			size += bytes.length + 1;
		int32(size);
		for (bytes in encoded) {
			raw(bytes, 0, bytes.length);
			byte(0);
		}
		for (bytes in encoded)
			index(bytes.length);
	}

	public function bytes():Bytes
		return buffer.getBytes();
}
