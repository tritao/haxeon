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
    await client!.start();
    ProfilerPanel.show(context.extensionUri, client!);
  }));
}

export async function deactivate(): Promise<void> {
  await client?.stop();
}
