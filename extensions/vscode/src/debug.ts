import {stat} from "node:fs/promises";
import {join} from "node:path";
import * as vscode from "vscode";

const type = "haxeon";
const launch = {type, name: "Launch Haxeon", request: "launch"};

async function hasProject(directory: string): Promise<boolean> {
  return stat(join(directory, "haxeon.toml")).then(file => file.isFile(), () => false);
}

export function registerDebugger(context: vscode.ExtensionContext): void {
  const provideDebugConfigurations = async (folder: vscode.WorkspaceFolder | undefined) =>
    folder && await hasProject(folder.uri.fsPath) ? [{...launch}] : [];

  context.subscriptions.push(
    vscode.debug.registerDebugConfigurationProvider(type, {
      provideDebugConfigurations,
      async resolveDebugConfiguration(folder, configuration) {
        if (configuration.type) return configuration;
        const document = vscode.window.activeTextEditor?.document;
        const project = folder ?? (document && vscode.workspace.getWorkspaceFolder(document.uri)) ??
          vscode.workspace.workspaceFolders?.[0];
        if (project && await hasProject(project.uri.fsPath)) return {...configuration, ...launch, cwd: project.uri.fsPath};
        return undefined;
      },
      async resolveDebugConfigurationWithSubstitutedVariables(folder, configuration) {
        configuration.cwd ??= folder?.uri.fsPath;
        if (!configuration.cwd || (configuration.request === "launch" && !await hasProject(configuration.cwd))) {
          void vscode.window.showErrorMessage("Open a project folder containing haxeon.toml or set the debug configuration's cwd.");
          return undefined;
        }
        if (process.arch !== "x64" || !["linux", "darwin", "win32"].includes(process.platform)) {
          void vscode.window.showErrorMessage("The bundled HashLink debugger requires x64 Linux, macOS, or Windows.");
          return undefined;
        }
        configuration.cli = vscode.workspace.getConfiguration("haxeon")
          .get<string>("server.path", "haxeon");
        return configuration;
      }
    }),
    vscode.debug.registerDebugConfigurationProvider(type, {provideDebugConfigurations}, vscode.DebugConfigurationProviderTriggerKind.Dynamic),
    vscode.debug.registerDebugAdapterDescriptorFactory(type, {
      createDebugAdapterDescriptor() {
        return new vscode.DebugAdapterExecutable(process.execPath, [context.asAbsolutePath("dist/adapter.js")], {
          env: {...process.env, ELECTRON_RUN_AS_NODE: "1"}
        });
      }
    })
  );
}
