import * as vscode from "vscode";
import {LanguageClient} from "vscode-languageclient/node";

type Message = {type: string; [key: string]: unknown};

export class ProfilerPanel {
  private static current: ProfilerPanel | undefined;
  private readonly panel: vscode.WebviewPanel;
  private readonly disposables: vscode.Disposable[] = [];
  private reconnectTimer: NodeJS.Timeout | undefined;
  private reconnectDelay = 500;
  private desiredConnected = false;
  private desiredRunning = false;
  private sampleRate = 250;

  static show(context: vscode.ExtensionContext, client: LanguageClient): void {
    if (this.current) {
      this.current.panel.reveal();
      return;
    }
    this.current = new ProfilerPanel(context, client);
  }

  private constructor(private readonly context: vscode.ExtensionContext, private readonly client: LanguageClient) {
    this.panel = vscode.window.createWebviewPanel("haxeonProfiler", "Haxeon Realtime Profiler", vscode.ViewColumn.Beside, {enableScripts: true});
    this.panel.webview.html = html(this.panel.webview);
    this.disposables.push(
      client.onNotification("haxeon/profilerSnapshot", value => this.snapshot(value)),
      client.onNotification("haxeon/profilerMetadataChanged", value => this.panel.webview.postMessage({type: "revision", value})),
      this.panel.webview.onDidReceiveMessage(message => this.receive(message as Message)),
      this.panel.onDidDispose(() => this.dispose())
    );
  }

  private async receive(message: Message): Promise<void> {
    if (message.type === "openSource") {
      const file = String(message.file ?? "");
      const line = Number(message.line ?? 1);
      if (!file) return;
      const root = vscode.workspace.workspaceFolders?.[0]?.uri;
      const uri = root && !file.startsWith("/") ? vscode.Uri.joinPath(root, file) : vscode.Uri.file(file);
      const editor = await vscode.window.showTextDocument(uri, {preview: true});
      const position = new vscode.Position(Math.max(0, line - 1), 0);
      editor.selection = new vscode.Selection(position, position);
      editor.revealRange(new vscode.Range(position, position), vscode.TextEditorRevealType.InCenterIfOutsideViewport);
      return;
    }
    const command = String(message.command ?? "");
    if (!command) return;
	if (command === "connect") this.desiredConnected = true;
	if (command === "start") { this.desiredConnected = true; this.desiredRunning = true; this.sampleRate = Number(message.sampleRate ?? 250); }
	if (command === "pause") this.desiredRunning = false;
	if (command === "disconnect") { this.desiredConnected = false; this.desiredRunning = false; }
	await this.execute(command, message);
  }

  private async execute(command: string, message: Message = {type: "command"}): Promise<boolean> {
    const config = vscode.workspace.getConfiguration("haxeon.profiler");
    const token = await this.context.secrets.get("haxeon.profiler.token");
    const options = command === "connect" ? {host: config.get("host"), port: config.get("port"), token}
      : command === "start" ? {sampleRate: Number(message.sampleRate ?? this.sampleRate ?? config.get("sampleRate")), pollIntervalMs: 100} : {};
    try {
      const value = await this.client.sendRequest("workspace/executeCommand", {command: `haxeon.profiler.${command}`, arguments: [options]});
      this.panel.webview.postMessage({type: "snapshot", value});
      if (command === "connect" || command === "start") this.panel.webview.postMessage({type: "connection", state: "connected"});
      return true;
    } catch (error) {
      this.panel.webview.postMessage({type: "error", value: String(error)});
      if (this.desiredConnected) this.scheduleReconnect();
      return false;
    }
  }

  private snapshot(value: unknown): void {
    this.panel.webview.postMessage({type: "snapshot", value});
    const snapshot = value as {state?: string; error?: string};
    if (snapshot.state === "failed" || snapshot.error) this.scheduleReconnect();
    else if (snapshot.state === "running") { this.reconnectDelay = 500; this.panel.webview.postMessage({type: "connection", state: "connected"}); }
  }

  private scheduleReconnect(): void {
    if (!this.desiredConnected || this.reconnectTimer) return;
    const delay = this.reconnectDelay;
    this.reconnectDelay = Math.min(10000, delay * 2);
    this.panel.webview.postMessage({type: "connection", state: "reconnecting", delay});
    this.reconnectTimer = setTimeout(async () => {
      this.reconnectTimer = undefined;
      if (!this.desiredConnected) return;
      if (await this.execute("connect") && (!this.desiredRunning || await this.execute("start", {type: "command", sampleRate: this.sampleRate}))) {
        this.reconnectDelay = 500;
        this.panel.webview.postMessage({type: "connection", state: "reconnected", gap: true});
      } else this.scheduleReconnect();
    }, delay);
  }

  private dispose(): void {
    ProfilerPanel.current = undefined;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    for (const disposable of this.disposables.splice(0)) disposable.dispose();
  }
}

function html(webview: vscode.Webview): string {
  const nonce = String(Date.now());
  return `<!doctype html><html><head><meta charset="UTF-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src ${webview.cspSource} 'unsafe-inline'; script-src 'nonce-${nonce}'"><style>
  body{font-family:var(--vscode-font-family);color:var(--vscode-foreground);padding:12px}button,input,select{margin-right:6px}.toolbar,.health{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:12px}.health span{padding:3px 7px;background:var(--vscode-badge-background);color:var(--vscode-badge-foreground);border-radius:3px}.layout{display:grid;grid-template-columns:1fr 1fr;gap:16px}.pane{min-width:0}.tree-row,.flame{cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.tree-row:hover,.flame:hover{outline:1px solid var(--vscode-focusBorder)}.flame-row{display:flex;height:25px;gap:1px;margin-bottom:1px}.flame{box-sizing:border-box;padding:4px;background:var(--vscode-charts-blue);color:var(--vscode-editor-background);min-width:2px}.marker{color:var(--vscode-descriptionForeground)}#error{color:var(--vscode-errorForeground)}</style></head><body>
  <div class="toolbar"><button data-command="connect">Connect</button><button data-command="start">Start</button><button data-command="pause">Pause</button><button data-command="reset">Reset</button><input id="rate" type="number" min="1" max="100000" value="250"><select id="revision"><option value="all">All revisions</option></select></div>
  <div id="connection" class="marker">Disconnected</div><div id="health" class="health"></div><div id="markers"></div><div id="error"></div><div class="layout"><section><h3>Call tree</h3><div id="tree"></div></section><section><h3>Flame graph</h3><div id="flame"></div></section></div>
  <script nonce="${nonce}">${script()}</script></body></html>`;
}

function script(): string {
  return `const vscode=acquireVsCodeApi(),nodes=new Map(),markers=[];let samples=0;
document.querySelectorAll('[data-command]').forEach(b=>b.onclick=()=>vscode.postMessage({type:'command',command:b.dataset.command,sampleRate:Number(document.getElementById('rate').value)}));
document.getElementById('revision').onchange=render;
window.addEventListener('message',({data})=>{if(data.type==='error'){document.getElementById('error').textContent=data.value;return}if(data.type==='connection'){document.getElementById('connection').textContent=data.state+(data.delay?' in '+data.delay+'ms':'')+(data.gap?' — sample gap after reconnect':'');return}if(data.type==='revision')markers.push(data.value);if(data.type==='snapshot'){const v=data.value||{};if((v.samples||0)<samples){nodes.clear();markers.length=0}samples=v.samples||0;if(nodes.size===0&&v.view?.flameGraph){v.view.flameGraph.forEach(n=>nodes.set(n.id,n));markers.splice(0,markers.length,...(v.view.revisionMarkers||[]))}else if(v.viewDelta?.nodes)v.viewDelta.nodes.forEach(n=>nodes.set(n.id,n));updateHealth(v.viewDelta?.health||v.view?.health);}(data.value?.view?.revisionMarkers||[]).forEach(addRevision);if(data.value)addRevision(data.value);render()});
function addRevision(m){if(!m||m.newRevision==null)return;const s=document.getElementById('revision');if(![...s.options].some(o=>o.value==String(m.newRevision)))s.add(new Option('Revision '+m.newRevision,String(m.newRevision)))}
function visible(n){const r=document.getElementById('revision').value;return r==='all'||(n.revisions||[]).includes(Number(r))}
function open(n){if(n.file)vscode.postMessage({type:'openSource',file:n.file,line:n.line})}
function render(){const values=[...nodes.values()].filter(visible),tree=document.getElementById('tree');tree.textContent='';values.forEach(n=>{const d=document.createElement('div');d.className='tree-row';d.style.paddingLeft=(n.depth*16)+'px';d.textContent=n.name+'  '+n.selfSamples+'/'+n.totalSamples;d.title=(n.file||'')+(n.line?':'+n.line:'');d.onclick=()=>open(n);tree.appendChild(d)});const flame=document.getElementById('flame');flame.textContent='';const depths=Math.max(0,...values.map(n=>n.depth));for(let depth=0;depth<=depths;depth++){const row=document.createElement('div');row.className='flame-row';values.filter(n=>n.depth===depth).forEach(n=>{const d=document.createElement('div');d.className='flame';d.style.width=Math.max(1,n.totalSamples*100/Math.max(1,samples))+'%';d.textContent=n.name+' '+n.totalSamples;d.onclick=()=>open(n);row.appendChild(d)});flame.appendChild(row)}document.getElementById('markers').innerHTML=markers.map(m=>'<div class="marker">↻ module '+m.moduleId+' revision '+m.oldRevision+' → '+m.newRevision+'</div>').join('')}
function updateHealth(h){if(!h)return;document.getElementById('health').innerHTML='<span>buffer '+Math.round((h.bufferUtilization||0)*100)+'%</span><span>rate '+h.effectiveSampleRate+'/'+h.requestedSampleRate+' Hz</span><span>dropped '+h.dropped+'</span><span>metadata '+Number(h.metadataRefreshMs||0).toFixed(1)+' ms</span>'}
render();`;
}
