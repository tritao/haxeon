const assert = require("node:assert/strict");
const {execFile, spawn} = require("node:child_process");
const {once} = require("node:events");
const {appendFile, cp, mkdtemp, readFile, rename, rm} = require("node:fs/promises");
const {createServer} = require("node:net");
const {tmpdir} = require("node:os");
const {join, resolve} = require("node:path");
const {promisify} = require("node:util");

const root = resolve(__dirname, "../..");
const cli = join(root, "scripts/haxeon");
const adapter = join(root, "extensions/vscode/dist/adapter.js");

// The probe built by the compiler itself as module sections (HLB 9), run in place of the plan's dense module: the debugger
// reads the file through its static link, the VM links it when it loads it. `haxeon run` writes dense modules until sections
// are the default, so only the attached target can run one.
async function buildSections(project, output) {
  const run = promisify(execFile);
  const compiler = process.env.HAXEON_COMPILER_HL
    || (await run(cli, ["dev", "tool-path", "compiler.tools.HaxeonCompiler"], {cwd: root})).stdout.trim();
  const hashlink = (await run(join(root, "scripts/hashlink-path.sh"))).stdout.trim();
  const libraries = [join(root, "out"), hashlink, process.env.LD_LIBRARY_PATH].filter(Boolean).join(":");
  await run(join(hashlink, "hl"), [compiler, "--module-sections", "--entry=Probe", `--root=${join(project, "src")}`,
    `--root=${join(root, "stdlib")}`, join(project, "src/Probe.hx"), `--output=${output}`],
  {cwd: root, env: {...process.env, LD_LIBRARY_PATH: libraries}});
  const head = await readFile(output);
  assert.equal(head.toString("latin1", 0, 3) + head[3], "HLB9", `${output} is not a module of sections`);
}

async function debug(cwd, attach = false, overrideModule = false, sections = false) {
  const session = spawn(process.execPath, [adapter], {stdio: ["pipe", "pipe", "inherit"]});
  const exited = once(session, "exit");
  const messages = [];
  let target;
  let targetExited;
  let sequence = 0;
  let buffer = Buffer.alloc(0);
  session.stdout.on("data", chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    let separator;
    while ((separator = buffer.indexOf("\r\n\r\n")) >= 0) {
      const size = Number(/^Content-Length: (\d+)/i.exec(buffer.subarray(0, separator).toString())[1]);
      const end = separator + 4 + size;
      if (buffer.length < end) break;
      messages.push(JSON.parse(buffer.subarray(separator + 4, end).toString()));
      buffer = buffer.subarray(end);
      session.emit("message");
    }
  });

  async function take(match) {
    const signal = AbortSignal.timeout(120_000);
    for (;;) {
      const index = messages.findIndex(match);
      if (index >= 0) return messages.splice(index, 1)[0];
      assert.ok(session.exitCode === null && session.signalCode === null, JSON.stringify(messages));
      try {
        await Promise.race([once(session, "message", {signal}), exited]);
      } catch (error) {
        throw new Error(JSON.stringify(messages), {cause: error});
      }
    }
  }

  async function request(command, args = {}) {
    const seq = ++sequence;
    const body = JSON.stringify({seq, type: "request", command, arguments: args});
    session.stdin.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
    const answer = await take(message => message.request_seq === seq);
    assert.equal(answer.success, true, JSON.stringify([answer, ...messages]));
    return answer.body;
  }
  const event = name => take(message => message.event === name);
  const source = join(cwd, "src/Probe.hx");

  try {
    await request("initialize", {adapterID: "haxeon", linesStartAt1: true, columnsStartAt1: true, pathFormat: "path"});
    if (attach) {
      const listener = createServer().listen(0, "127.0.0.1");
      await once(listener, "listening");
      const {port} = listener.address();
      await promisify(listener.close.bind(listener))();
      const planFile = join(cwd, "attach-plan.json");
      await promisify(execFile)(cli, ["run", "--launch-plan", planFile, "--debug-port", String(port), "--", "41"], {cwd});
      const plan = JSON.parse(await readFile(planFile, "utf8"));
      let program;
      if (sections) {
        program = join(cwd, "sections.hl");
        await buildSections(cwd, program);
        const at = plan.arguments.indexOf(plan.program);
        assert.ok(at >= 0, JSON.stringify(plan));
        plan.arguments[at] = program;
      }
      if (overrideModule) {
        program = join(cwd, "override.hl");
        await rename(plan.command + ".hl", program);
        plan.arguments.splice(1, 0, `--haxeon-module=${program}`);
      }
      target = spawn("python3", ["-c", `
import ctypes, os, sys
PR_SET_PTRACER = 0x59616d61
if ctypes.CDLL(None).prctl(PR_SET_PTRACER, int(sys.argv[1]), 0, 0, 0):
    sys.exit("Could not permit the test adapter to trace the target")
os.execv(sys.argv[2], sys.argv[2:])
`, String(session.pid), plan.command, ...plan.arguments], {
        cwd: plan.cwd, env: {...process.env, ...plan.environment}, stdio: ["ignore", "ignore", "inherit"]
      });
      targetExited = once(target, "exit");
      await request("attach", {cwd, port, program});
    } else {
      await request("launch", {cwd, cli, args: ["41"]});
    }
    await event("initialized");
    const {breakpoints} = await request("setBreakpoints", {source: {path: source}, breakpoints: [{line: 5}]});
    assert.equal(breakpoints[0].verified, true, JSON.stringify(breakpoints));
    await request("configurationDone");
    const stopped = await event("stopped");
    assert.equal(stopped.body.reason, "breakpoint");
    const {threadId} = stopped.body;
    async function frameAt(line) {
      const {stackFrames} = await request("stackTrace", {threadId});
      assert.equal(stackFrames[0].source.path, source, JSON.stringify(stackFrames));
      assert.equal(stackFrames[0].line, line, JSON.stringify(stackFrames));
      return stackFrames[0];
    }
    const frame = await frameAt(5);
    const {scopes} = await request("scopes", {frameId: frame.id});
    const locals = scopes.find(scope => scope.name === "Locals");
    assert.ok(locals, JSON.stringify(scopes));
    const {variables} = await request("variables", {variablesReference: locals.variablesReference});
    assert.equal(variables.find(variable => variable.name === "count")?.value, "41", JSON.stringify(variables));
    await request("next", {threadId});
    await event("stopped");
    await frameAt(6);
    await request("continue", {threadId});
    await event("terminated");
    if (targetExited) assert.deepEqual(await targetExited, [0, null]);
    else assert.equal((await event("exited")).body.exitCode, 0);
    await request("disconnect");
  } catch (error) {
    console.error(messages);
    throw error;
  } finally {
    session.stdin.end();
    target?.kill();
    await Promise.all([exited, targetExited]);
  }
}

async function main() {
  const project = await mkdtemp(join(tmpdir(), "debug-project-"));
  try {
    await cp(join(root, "tests/fixtures/debug-project"), project, {recursive: true});
    await debug(project);
    console.log("PASS: console project launch, breakpoint, variables, step and termination");
    await debug(project, true);
    console.log("PASS: attach by port, breakpoint, variables, step and termination");
    await debug(project, true, false, true);
    console.log("PASS: attach to a build of module sections, breakpoint, variables, step and termination");
    await appendFile(join(project, "haxeon.toml"), '\n[app]\nname = "debug-probe"\nid = "org.example.debugprobe"\nversion = "1.0.0"\nplatforms = ["linux"]\n');
    await debug(project);
    console.log("PASS: embedded desktop runner launch, breakpoint, variables, step and termination");
    await debug(project, true, true);
    console.log("PASS: embedded desktop runner attaches with both the debug port and explicit module");
  } finally {
    await rm(project, {recursive: true, force: true});
  }
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
