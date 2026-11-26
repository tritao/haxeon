const {execFileSync} = require("node:child_process");
const {copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, renameSync, rmSync} = require("node:fs");
const path = require("node:path");

const extension = path.resolve(__dirname, "..");
const root = path.resolve(extension, "../..");
const vendor = path.join(root, "vendor/hashlink-debugger");
const cache = path.join(extension, ".adapter-build");
const dist = path.join(extension, "dist");
mkdirSync(cache, {recursive: true});
mkdirSync(dist, {recursive: true});

function dependency(repo, revision) {
  const target = path.join(cache, revision);
  if (!existsSync(target)) {
    const checkout = mkdtempSync(path.join(cache, "checkout-"));
    try {
      execFileSync("git", ["init", "--quiet", checkout]);
      execFileSync("git", ["-C", checkout, "fetch", "--quiet", "--depth=1", `https://github.com/${repo}.git`, revision], {stdio: "inherit"});
      execFileSync("git", ["-C", checkout, "checkout", "--quiet", "--detach", "FETCH_HEAD"]);
      renameSync(checkout, target);
    } finally {
      rmSync(checkout, {recursive: true, force: true});
    }
  }
  return target;
}

const externs = dependency("vshaxe/vscode-debugadapter-extern", "384cf87c9b696075ffe1887acc262145823c5e33");
const node = dependency("HaxeFoundation/hxnodejs", "f88685a70b2e4f03dbe0a824ce90ea8b56b27753");
const script = dependency("HaxeFoundation/hscript", "80e3610e15e97dd5e2223c93fa72e49e41c376d7");
const checkout = mkdtempSync(path.join(cache, "adapter-"));
try {
  for (const folder of ["src", "hld"]) cpSync(path.join(vendor, folder), path.join(checkout, folder), {recursive: true});
  cpSync(path.join(root, "vendor/format/format"), path.join(checkout, "format"), {recursive: true});
  const compiler = path.join(root, ".tools/haxe", process.platform === "win32" ? "haxe.exe" : "haxe");
  execFileSync(existsSync(compiler) ? compiler : "haxe", [
    // hld links a module of sections with the compiler's static link (compiler.hl.HlStaticLink), which imports only haxe.
    "-cp", "src", "-cp", ".", "-cp", path.join(root, "src"),
    "-cp", path.join(externs, "src"), "-cp", path.join(node, "src"), "-cp", script,
    path.join(node, "extraParams.hxml"), "-D", "hxnodejs", "-D", "js-es=6", "-D", "project-adapter",
    "-main", "HLAdapter", "-js", path.join(dist, "hashlink.js")
  ], {cwd: checkout, stdio: "inherit"});
  rmSync(path.join(dist, "hashlink.js.map"), {force: true});
  cpSync(path.join(vendor, "hldebug-wrapper/lib"), path.join(dist, "native"), {recursive: true});
  for (const [directory, file, name] of [
    [vendor, "LICENSE.md", "HashLink"],
    [path.join(root, "vendor/format"), "LICENSE", "format"],
    [externs, "LICENSE.md", "debugadapter-extern"],
    [node, "LICENSE.md", "hxnodejs"],
    [script, "LICENSE", "hscript"]
  ]) {
    copyFileSync(path.join(directory, file), path.join(dist, `${name}-LICENSE.md`));
  }
} finally {
  rmSync(checkout, {recursive: true, force: true});
}
