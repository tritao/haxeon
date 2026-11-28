package std.fs;

import haxe.io.Bytes;
import std.fs.FileNatives;
import std.fs.FileNatives.WriteMode;
import std.fs.Operations;

/*
 * Files and directories by path, resolved as the operating system resolves them: absolute, or against the working
 * directory, following `..` and symbolic links. Each operation returns a `Result` whose `Err` says why it failed
 * (`FileError`); none throws. Called as `Files.read(path)` after `import std.fs.Files;`. On Wasm the files are the
 * session's in-memory filesystem. `Root` has the same operations confined to one directory.
 */

/** The bytes of the file `path`. */
function read(path:Path):Result<Bytes, FileError>
	return Operations.read(null, path);

/** The text of the file `path`, read as UTF-8. */
function readText(path:Path):Result<String, FileError>
	return Operations.readText(null, path);

/** Writes `content` to the file `path`, creating it or replacing what it held. */
function write(path:Path, content:Bytes):Result<Void, FileError>
	return Operations.write(null, path, content, Replace);

/** Writes `text` as UTF-8 to the file `path`, creating it or replacing what it held. */
function writeText(path:Path, text:String):Result<Void, FileError>
	return Operations.write(null, path, Bytes.ofString(text), Replace);

/** Adds `content` to the end of the file `path`, creating it when it is missing. */
function append(path:Path, content:Bytes):Result<Void, FileError>
	return Operations.write(null, path, content, Append);

/** Adds `text` as UTF-8 to the end of the file `path`, creating it when it is missing. */
function appendText(path:Path, text:String):Result<Void, FileError>
	return Operations.write(null, path, Bytes.ofString(text), Append);

/** Creates the file `path` holding `content`; `AlreadyExists` when anything is there, which is left as it was. */
function create(path:Path, content:Bytes):Result<Void, FileError>
	return Operations.write(null, path, content, Create);

/**
 * Replaces the file `path` with `content` in one step: a reader, or a crash, sees the old file or the new one, never
 * part of either. The content goes to a temporary file beside `path`, reaches the disk, and is moved into place.
 */
function writeAtomic(path:Path, content:Bytes):Result<Void, FileError>
	return Operations.writeAtomic(null, path, content);

/** What is at `path`, following a symbolic link to what it points to. */
function metadata(path:Path):Result<Metadata, FileError>
	return Operations.metadata(null, path, true);

/** What is at `path`; a symbolic link is described itself (`SymbolicLink`), not what it points to. */
function linkMetadata(path:Path):Result<Metadata, FileError>
	return Operations.metadata(null, path, false);

/**
 * What `path` names, as one absolute path with every symbolic link on the way resolved: two paths to one entry answer
 * the same, so it keys what is cached by file. `NotFound` when nothing is there.
 */
function canonical(path:Path):Result<Path, FileError> {
	var found = #if wasm FileNatives.canonical(path.toString()) #else nativeCanonical(path.toString()) #end;
	return found == null ? Err(FileNatives.lastError()) : Ok(Path.of(found));
}

#if !wasm
// Bound here rather than in FileNatives, which every program reading files through sys.FileSystem loads.
@:hlNative("haxeon_runtime", "__fs_canonical")
internal extern function nativeCanonical(path:String):Null<String>;
#end

/** The working directory: what a relative path is resolved against, and where a child process starts by default. */
function workingDirectory():Path
	return Path.of(#if wasm FileNatives.workingDirectory() #else nativeWorkingDirectory() #end);

/**
 * Makes the directory `path` the working directory, for every thread of the process. `NotFound`, `NotADirectory`, or
 * `PermissionDenied` when it cannot be entered.
 */
function setWorkingDirectory(path:Path):Result<Void, FileError> {
	#if wasm
	var entered = FileNatives.setWorkingDirectory(path.toString());
	#else
	var entered = nativeSetWorkingDirectory(path.toString());
	#end
	return entered ? Ok() : Err(FileNatives.lastError());
}

#if !wasm
@:hlNative("haxeon_runtime", "__sys_get_cwd")
internal extern function nativeWorkingDirectory():String;

@:hlNative("haxeon_runtime", "__fs_set_working_directory")
internal extern function nativeSetWorkingDirectory(path:String):Bool;
#end

/** The entries of the directory `path`, in no particular order, without `.` and `..`. */
function list(path:Path):Result<Array<Entry>, FileError>
	return Operations.list(null, path);

/**
 * Makes sure the directory `path` exists: creates it and any missing parents, and succeeds when it is already there.
 * `AlreadyExists` when something other than a directory is at `path`, `NotADirectory` when one is on the way to it.
 */
function createDirectory(path:Path):Result<Void, FileError>
	return Operations.createDirectory(null, path);

/**
 * Makes sure nothing is at `path`: deletes a file, a symbolic link (not what it points to) or an empty directory, and
 * succeeds when nothing was there. `NotEmpty` for a directory with entries; `removeTree` removes those too.
 */
function remove(path:Path):Result<Void, FileError>
	return Operations.remove(null, path);

/** Deletes the file, symbolic link or empty directory `path`, as `remove` does, but `NotFound` when nothing is there. */
function delete(path:Path):Result<Void, FileError>
	return Operations.delete(null, path);

/**
 * Makes sure nothing is at `path`, a directory's entries included: removes the tree beneath it first, depth first, and
 * succeeds when nothing was there. A symbolic link is removed itself; what it points to is left alone.
 */
function removeTree(path:Path):Result<Void, FileError>
	return Operations.removeTree(null, path);

/** Moves the file or directory `path` to `target`, replacing a file there; both must be on the same volume. */
function rename(path:Path, target:Path):Result<Void, FileError>
	return Operations.rename(null, path, target);

/** Copies the bytes of the file `path` to the file `target`, creating it or replacing what it held. */
function copy(path:Path, target:Path):Result<Void, FileError>
	return Operations.copy(null, path, target);
