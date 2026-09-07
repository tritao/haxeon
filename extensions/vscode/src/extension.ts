import * as vscode from "vscode";
import {LanguageClient, LanguageClientOptions, ServerOptions} from "vscode-languageclient/node";
import {ProfilerPanel} from "./profilerPanel";

let client: LanguageClient | undefined;

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  const config = vscode.workspace.getConfiguration("haxeon");
  const serverOptions: ServerOptions = {command: config.get<string>("server.path", "haxeon-lsp")};
  const clientOptions: LanguageClientOptions = {documentSelector: [{scheme: "file", language: "haxe"}]};
  client = new LanguageClient("haxeon", "Haxeon", serverOptions, clientOptions);
  context.subscriptions.push(client, vscode.commands.registerCommand("haxeon.profiler.open", async () => {
    ProfilerPanel.show(context, client!);
  }), vscode.commands.registerCommand("haxeon.profiler.setToken", async () => {
    const token = await vscode.window.showInputBox({title: "Haxeon diagnostics token", password: true, ignoreFocusOut: true});
    if (token) await context.secrets.store("haxeon.profiler.token", token);
  }), vscode.commands.registerCommand("haxeon.profiler.clearToken", () => context.secrets.delete("haxeon.profiler.token")));
  await client.start();
}

export async function deactivate(): Promise<void> {
  await client?.stop();
}
