import {spawn, ChildProcess} from "node:child_process";
import {mkdtempSync, rmSync} from "node:fs";
import {readFile} from "node:fs/promises";
import {createServer} from "node:net";
import {tmpdir} from "node:os";
import {join, resolve} from "node:path";
import {DebugSession, OutputEvent, TerminatedEvent} from "vscode-debugadapter";
import {DebugProtocol} from "vscode-debugprotocol";

const {HLAdapter} = require("./hashlink") as {HLAdapter: typeof DebugSession};

interface LaunchPlan {
  command: string;
  arguments: string[];
  cwd: string;
  program: string;
  classPaths: string[];
  environment: NodeJS.ProcessEnv;
}

async function availablePort(): Promise<number> {
  const server = createServer();
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close(() => reject(new Error("Could not allocate a local debug port.")));
        return;
      }
      server.close(error => error ? reject(error) : resolve(address.port));
    });
  });
}

class ProjectAdapter extends HLAdapter {
  private building?: ChildProcess;
  private disconnected = false;
  private temporary?: string;
  declare protected proc: ChildProcess | null;

  protected override async launchRequest(response: DebugProtocol.LaunchResponse, args: DebugProtocol.LaunchRequestArguments & {
    cwd: string;
    cli?: string;
    args?: string[];
  }): Promise<void> {
    try {
      const port = args.noDebug ? undefined : await availablePort();
      if (this.disconnected) return;
      this.temporary = mkdtempSync(join(tmpdir(), "debug-launch-"));
      const planFile = join(this.temporary, "launch.json");
      const command = ["run", "--color=never", "--launch-plan", planFile];
      if (port !== undefined) command.push("--debug-port", String(port));
      command.push("--", ...(args.args ?? []));
      const cli = args.cli || "haxeon";
      await new Promise<void>((resolve, reject) => {
        const child = this.building = spawn(cli, command, {cwd: args.cwd, stdio: ["ignore", "pipe", "pipe"]});
        child.stdout.setEncoding("utf8").on("data", output => this.sendEvent(new OutputEvent(output, "stdout")));
        child.stderr.setEncoding("utf8").on("data", output => this.sendEvent(new OutputEvent(output, "stderr")));
        child.once("error", reject);
        child.once("close", (code, signal) => {
          this.building = undefined;
          if (code === 0) resolve();
          else reject(new Error(`Project build failed (${signal ?? `exit code ${code}`}). See the Debug Console.`));
        });
      });
      const plan: LaunchPlan = JSON.parse(await readFile(planFile, "utf8"));
      if (this.disconnected) return;
      super.launchRequest(response, {
        noDebug: args.noDebug,
        cwd: plan.cwd,
        hl: plan.command,
        commandArguments: plan.arguments,
        program: plan.program,
        classPaths: plan.classPaths,
        env: {...process.env, ...plan.environment},
        port
      } as DebugProtocol.LaunchRequestArguments);
    } catch (error) {
      if (!this.disconnected) {
        this.sendErrorResponse(response, 3000, (error as Error).message);
        this.sendEvent(new TerminatedEvent());
      }
    } finally {
      if (this.temporary) rmSync(this.temporary, {recursive: true, force: true});
      this.temporary = undefined;
    }
  }

  protected override attachRequest(response: DebugProtocol.AttachResponse, args: DebugProtocol.AttachRequestArguments & {
    cwd: string;
    port?: number;
    program?: string;
    sourceRoots?: string[];
  }): void {
    const cwd = resolve(args.cwd);
    const program = resolve(cwd, args.program ?? "build/host/main.hl");
    const port = args.port ?? 6112;
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      this.sendErrorResponse(response, 3000, "Specify a debug port from 1 to 65535.");
      return;
    }
    try {
      const classPaths = (args.sourceRoots ?? ["src"]).map(root => resolve(cwd, root));
      super.attachRequest(response, {cwd, program, port, classPaths} as DebugProtocol.AttachRequestArguments);
    } catch (error) {
      this.sendErrorResponse(response, 3000, `Could not load debug bytecode at ${program}: ${(error as Error).message}`);
    }
  }

  protected override disconnectRequest(response: DebugProtocol.DisconnectResponse, args: DebugProtocol.DisconnectArguments): void {
    this.disconnected = true;
    super.disconnectRequest(response, args);
    this.shutdown();
  }

  override shutdown(): void {
    this.disconnected = true;
    this.building?.kill();
    this.proc?.kill();
    if (this.temporary) rmSync(this.temporary, {recursive: true, force: true});
    this.temporary = undefined;
    super.shutdown();
  }
}

DebugSession.run(ProjectAdapter);
