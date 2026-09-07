import * as vscode from "vscode";
import {LanguageClient} from "vscode-languageclient/node";
import {execFile} from "child_process";
import {promisify} from "util";
import {readFile} from "fs/promises";

type Message = {type: string; [key: string]: unknown};
const runFile = promisify(execFile);

export class ProfilerPanel {
  private static current: ProfilerPanel | undefined;
  private readonly panel: vscode.WebviewPanel;
  private readonly disposables: vscode.Disposable[] = [];
  private reconnectTimer: NodeJS.Timeout | undefined;
  private reconnectDelay = 500;
  private desiredConnected = false;
  private desiredRunning = false;
  private sampleRate = 250;
  private recording = false;

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
    if (message.type === "capture") {
      if (!this.recording) {
        const uri = await vscode.window.showSaveDialog({filters: {"HashLink profile": ["hlpc"]}, defaultUri: vscode.Uri.file("profile.hlpc")});
        if (!uri) return;
        this.recording = await this.execute("captureStart", {type: "command", path: uri.fsPath});
      } else { await this.execute("captureStop"); this.recording = false; }
      this.panel.webview.postMessage({type: "recording", active: this.recording});
      return;
    }
    if (message.type === "openCapture" || message.type === "compareCapture") {
      const count = message.type === "compareCapture" ? 2 : 1;
      const uris = await vscode.window.showOpenDialog({canSelectMany: count === 2, filters: {"HashLink profile": ["hlpc"]}});
      if (!uris || uris.length !== count) return;
      const start = Number(message.startMs ?? 0), end = Number(message.endMs ?? Number.MAX_SAFE_INTEGER);
      const captures = await Promise.all(uris.map(uri => this.readCapture(uri.fsPath, start, end)));
      this.panel.webview.postMessage({type: count === 2 ? "comparison" : "offline", captures});
      return;
    }
    if (message.type === "exportCapture") {
      const source = await vscode.window.showOpenDialog({canSelectMany: false, filters: {"HashLink profile": ["hlpc"]}});
      if (!source?.[0]) return;
      const format = String(message.format), extension = format === "perfetto" ? "json" : "folded";
      const target = await vscode.window.showSaveDialog({filters: {[format]: [extension]}});
      if (!target) return;
      const args = ["export", "--format", format];
      if (format === "perfetto") args.push("--output", target.fsPath);
      args.push(source[0].fsPath);
      const result = await runFile(this.hlprof(), args);
      if (format === "folded") await vscode.workspace.fs.writeFile(target, Buffer.from(result.stdout));
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
    if (command === "captureStart") Object.assign(options, {path: String(message.path)});
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

  private hlprof(): string { return vscode.workspace.getConfiguration("haxeon.profiler").get("hlprofPath", "hlprof-live"); }

  private async readCapture(path: string, startMs: number, endMs: number): Promise<unknown> {
    const args = ["export", "--format", "folded", "--start-ms", String(Math.max(0, startMs)), "--end-ms", String(Math.max(startMs, endMs)), path];
    const {stdout} = await runFile(this.hlprof(), args);
    const stacks = stdout.trim().split(/\r?\n/).filter(Boolean).map(line => { const split = line.lastIndexOf(" "); return {frames: line.slice(0, split).split(";"), samples: Number(line.slice(split + 1))}; });
    const bytes = await readFile(path), timeline: unknown[] = [];
    for (let at = 24; at + 16 <= bytes.length;) { const type = bytes.readUInt32LE(at), size = bytes.readUInt32LE(at + 4), ns = Number(bytes.readBigUInt64LE(at + 8)); at += 16; if (at + size > bytes.length) break; if (type === 1) timeline.push({type: "metadata", ms: ns / 1e6}); if (type === 2 && size >= 24) timeline.push({type: "samples", ms: ns / 1e6, dropped: Number(bytes.readBigUInt64LE(at + 16))}); at += size; }
    return {path, stacks, timeline};
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
  body{font-family:var(--vscode-font-family);color:var(--vscode-foreground);padding:12px}button,input,select{margin-right:6px}.toolbar,.health{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:12px}.health span{padding:3px 7px;background:var(--vscode-badge-background);color:var(--vscode-badge-foreground);border-radius:3px}.timeline{margin:8px 0 14px}.timeline canvas{width:100%;height:230px;border:1px solid var(--vscode-panel-border);cursor:crosshair}.timeline-head{display:flex;gap:8px;align-items:center}.layout{display:grid;grid-template-columns:1fr 1fr;gap:16px}.pane{min-width:0}.tree-row,.flame{cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.tree-row:hover,.flame:hover{outline:1px solid var(--vscode-focusBorder)}.regression{color:var(--vscode-testing-iconFailed)}.improvement{color:var(--vscode-testing-iconPassed)}.flame-row{display:flex;height:25px;gap:1px;margin-bottom:1px}.flame{box-sizing:border-box;padding:4px;background:var(--vscode-charts-blue);color:var(--vscode-editor-background);min-width:2px}.marker{color:var(--vscode-descriptionForeground)}#error{color:var(--vscode-errorForeground)}</style></head><body>
  <div class="toolbar"><button data-command="connect">Connect</button><button data-command="start">Start</button><button data-command="pause">Pause</button><button data-command="reset">Reset</button><button id="capture">Record</button><button id="openCapture">Open</button><button id="compareCapture">Compare</button><button data-export="folded">Export folded</button><button data-export="perfetto">Export Perfetto</button><input id="rate" type="number" min="1" max="100000" value="250"><label>range ms <input id="startMs" type="number" min="0" value="0"></label><label>to <input id="endMs" type="number" min="0" value="9007199254740991"></label><select id="thread"><option value="all">All threads</option></select><select id="revision"><option value="all">All revisions</option></select></div>
  <div id="connection" class="marker">Disconnected</div><div id="health" class="health"></div><div id="markers"></div><div id="error"></div><section class="timeline"><div class="timeline-head"><h3>Runtime timeline</h3><span id="selection" class="marker">Drag to select a time range</span><button id="clearRange">Clear range</button></div><canvas id="timeline"></canvas></section><div class="layout"><section><h3>Call tree</h3><div id="tree"></div></section><section><h3>Flame graph</h3><div id="flame"></div></section></div>
  <script nonce="${nonce}">${script()}</script></body></html>`;
}

function script(): string {
  return `const vscode=acquireVsCodeApi(),nodes=new Map(),filteredNodes=new Map(),markers=[],stackDefinitions=new Map();let samples=0,timelineSamples=[],gcTimeline=[],selectedRange=null,dragStart=null;
document.querySelectorAll('[data-command]').forEach(b=>b.onclick=()=>vscode.postMessage({type:'command',command:b.dataset.command,sampleRate:Number(document.getElementById('rate').value)}));
const range=()=>({startMs:Number(document.getElementById('startMs').value),endMs:Number(document.getElementById('endMs').value)});document.getElementById('capture').onclick=()=>vscode.postMessage({type:'capture'});document.getElementById('openCapture').onclick=()=>vscode.postMessage({type:'openCapture',...range()});document.getElementById('compareCapture').onclick=()=>vscode.postMessage({type:'compareCapture',...range()});document.querySelectorAll('[data-export]').forEach(b=>b.onclick=()=>vscode.postMessage({type:'exportCapture',format:b.dataset.export}));
document.getElementById('revision').onchange=render;
document.getElementById('thread').onchange=()=>{if(selectedRange)rebuildRange();render()};
window.addEventListener('message',({data})=>{if(data.type==='error'){document.getElementById('error').textContent=data.value;return}if(data.type==='recording'){document.getElementById('capture').textContent=data.active?'Stop recording':'Record';return}if(data.type==='offline'||data.type==='comparison'){loadCaptures(data.captures);return}if(data.type==='connection'){document.getElementById('connection').textContent=data.state+(data.delay?' in '+data.delay+'ms':'')+(data.gap?' — sample gap after reconnect':'');return}if(data.type==='revision')markers.push(data.value);if(data.type==='snapshot'){const v=data.value||{},stream=v.timeline;if((v.samples||0)<samples){nodes.clear();stackDefinitions.clear();markers.length=0;selectedRange=null}samples=v.samples||0;if(nodes.size===0&&v.view?.flameGraph){v.view.flameGraph.forEach(n=>nodes.set(n.id,n));markers.splice(0,markers.length,...(v.view.revisionMarkers||[]))}else if(v.viewDelta?.nodes)v.viewDelta.nodes.forEach(n=>nodes.set(n.id,n));if(stream){if(stream.reset){timelineSamples=[];gcTimeline=[];stackDefinitions.clear();if(stream.gap)document.getElementById('selection').textContent='Timeline gap — retained window restarted'}(stream.stacks||[]).forEach(s=>stackDefinitions.set(s.key,s.frameDetails));timelineSamples.push(...(stream.samples||[]));gcTimeline.push(...(stream.counters||[]));if(timelineSamples.length>50000)timelineSamples.splice(0,timelineSamples.length-50000);if(gcTimeline.length>512)gcTimeline.splice(0,gcTimeline.length-512)}if(selectedRange)rebuildRange();updateHealth(v.viewDelta?.health||v.view?.health);}(data.value?.view?.revisionMarkers||[]).forEach(addRevision);if(data.value)addRevision(data.value);render()});
function loadCaptures(captures){nodes.clear();samples=0;const totals=new Map();captures.forEach((c,index)=>c.stacks.forEach(s=>{samples+=index?0:s.samples;const key=s.frames.join('>'),v=totals.get(key)||{a:0,b:0,frames:s.frames};index?v.b+=s.samples:v.a+=s.samples;totals.set(key,v)}));totals.forEach((v,key)=>{let parent='',depth=0;v.frames.forEach(name=>{const id=parent?parent+'>'+name:name,n=nodes.get(id)||{id,parentId:parent||null,name,depth,selfSamples:0,totalSamples:0,delta:0,revisions:[]};n.totalSamples+=v.a;n.delta+=(v.b||0)-v.a;n.confidence=Math.abs(n.delta)/Math.sqrt(Math.max(1,v.a+(v.b||0)));nodes.set(id,n);parent=id;depth++});nodes.get(parent).selfSamples+=v.a});markers.splice(0,markers.length,...captures[0].timeline.filter(e=>e.type==='metadata').map((e,i)=>({moduleId:'capture',oldRevision:i,newRevision:i+1,timestamp:e.ms})));document.getElementById('connection').textContent=captures.length===2?'Offline comparison (|z| ≥ 1.96 is statistically notable)':'Offline capture';render()}
function addRevision(m){if(!m||m.newRevision==null)return;const s=document.getElementById('revision');if(![...s.options].some(o=>o.value==String(m.newRevision)))s.add(new Option('Revision '+m.newRevision,String(m.newRevision)))}
function visible(n){const r=document.getElementById('revision').value,t=document.getElementById('thread').value;return (r==='all'||(n.revisions||[]).includes(Number(r)))&&(t==='all'||(n.threadSamples||[]).some(x=>x.threadId===Number(t)))}
function open(n){if(n.file)vscode.postMessage({type:'openSource',file:n.file,line:n.line})}
function render(){const started=performance.now(),source=selectedRange?filteredNodes:nodes,values=[...source.values()].filter(visible),shownSamples=selectedRange?[...filteredNodes.values()].filter(n=>n.depth===0).reduce((n,v)=>n+v.totalSamples,0):samples,tree=document.getElementById('tree');tree.textContent='';values.forEach(n=>{const d=document.createElement('div');d.className='tree-row '+(n.delta>0?'regression':n.delta<0?'improvement':'');d.style.paddingLeft=(n.depth*16)+'px';d.textContent=n.name+'  '+n.selfSamples+'/'+n.totalSamples+(n.delta?' Δ'+n.delta:'');d.title=((n.file||'')+(n.line?':'+n.line:''))+(n.delta?' comparison delta '+n.delta:'');d.onclick=()=>open(n);tree.appendChild(d)});const flame=document.getElementById('flame');flame.textContent='';const depths=Math.max(0,...values.map(n=>n.depth));for(let depth=0;depth<=depths;depth++){const row=document.createElement('div');row.className='flame-row';values.filter(n=>n.depth===depth).forEach(n=>{const d=document.createElement('div');d.className='flame';d.style.width=Math.max(1,n.totalSamples*100/Math.max(1,shownSamples))+'%';d.textContent=n.name+' '+n.totalSamples+(n.delta?' Δ'+n.delta:'');d.onclick=()=>open(n);row.appendChild(d)});flame.appendChild(row)}document.getElementById('markers').innerHTML=markers.map(m=>'<div class="marker">↻ module '+m.moduleId+' revision '+m.oldRevision+' → '+m.newRevision+'</div>').join('');renderTimeline();const latency=document.getElementById('uiLatency');if(latency)latency.textContent='UI '+(performance.now()-started).toFixed(1)+' ms'}

function rebuildRange(){filteredNodes.clear();if(!selectedRange)return;const thread=document.getElementById('thread').value;timelineSamples.filter(s=>s.timestamp>=selectedRange[0]&&s.timestamp<=selectedRange[1]&&(thread==='all'||s.threadId===Number(thread))).forEach(s=>{const frames=stackDefinitions.get(s.stackKey)||[];let parent='',depth=0;frames.forEach(frame=>{const id=parent?parent+'>'+frame.stableKey:frame.stableKey,n=filteredNodes.get(id)||{...frame,id,parentId:parent||null,depth,selfSamples:0,totalSamples:0,revisions:[frame.revision],threadSamples:[{threadId:s.threadId,samples:0}]};n.totalSamples++;filteredNodes.set(id,n);parent=id;depth++});if(parent)filteredNodes.get(parent).selfSamples++})}

const canvas=document.getElementById('timeline');document.getElementById('clearRange').onclick=()=>{selectedRange=null;filteredNodes.clear();document.getElementById('selection').textContent='Drag to select a time range';render()};canvas.onpointerdown=e=>{dragStart=e.offsetX;canvas.setPointerCapture(e.pointerId)};canvas.onpointerup=e=>{if(dragStart==null||timelineSamples.length<2)return;const bounds=timeBounds(),a=timeAt(Math.min(dragStart,e.offsetX),bounds),b=timeAt(Math.max(dragStart,e.offsetX),bounds);dragStart=null;if(b>a){selectedRange=[a,b];document.getElementById('selection').textContent=((a-bounds[0])*1000).toFixed(0)+'–'+((b-bounds[0])*1000).toFixed(0)+' ms ('+((b-a)*1000).toFixed(0)+' ms)';rebuildRange();render()}};window.addEventListener('resize',renderTimeline);
function timeBounds(){const times=timelineSamples.map(s=>s.timestamp).concat(gcTimeline.map(g=>g.timestamp));return times.length?[Math.min(...times),Math.max(...times)]:[0,1]}
function timeAt(x,b){return b[0]+Math.max(0,Math.min(1,(x-58)/Math.max(1,canvas.clientWidth-68)))*(b[1]-b[0])}
function renderTimeline(){const dpr=devicePixelRatio||1,w=canvas.clientWidth||800,h=230;if(canvas.width!==w*dpr||canvas.height!==h*dpr){canvas.width=w*dpr;canvas.height=h*dpr}const c=canvas.getContext('2d');c.setTransform(dpr,0,0,dpr,0,0);c.clearRect(0,0,w,h);if(!timelineSamples.length&&!gcTimeline.length){c.fillStyle=getComputedStyle(document.body).color;c.fillText('Waiting for telemetry…',12,24);return}const b=timeBounds(),x=t=>58+(t-b[0])/Math.max(.000001,b[1]-b[0])*(w-68),tracks=[{name:'heap',field:'heap',color:'#4ea1ff'},{name:'alloc/s',field:'allocated',rate:true,color:'#f0a33b'},{name:'collections',field:'collections',rate:true,color:'#55c271'},{name:'GC µs/s',field:'markMicros',rate:true,color:'#d66efd'}];tracks.forEach((track,i)=>{const top=6+i*52,bottom=top+39,values=gcTimeline.map((g,j)=>track.rate&&j?Math.max(0,(Number(g[track.field])-Number(gcTimeline[j-1][track.field]))/Math.max(.001,g.timestamp-gcTimeline[j-1].timestamp)):Number(g[track.field]));const max=Math.max(1,...values);c.fillStyle=getComputedStyle(document.body).color;c.fillText(track.name,4,top+12);c.strokeStyle=track.color;c.beginPath();gcTimeline.forEach((g,j)=>{const px=x(g.timestamp),py=bottom-values[j]/max*31;j?c.lineTo(px,py):c.moveTo(px,py)});c.stroke()});if(selectedRange){c.fillStyle='rgba(100,150,255,.18)';c.fillRect(x(selectedRange[0]),0,x(selectedRange[1])-x(selectedRange[0]),h)}c.fillStyle=getComputedStyle(document.body).color;c.fillText('0 ms',58,h-4);c.fillText(Math.round((b[1]-b[0])*1000)+' ms',Math.max(60,w-65),h-4)}
function updateHealth(h){if(!h)return;const gc=(h.gcStats||[]).at(-1),memory=gc?'<span>heap '+formatBytes(gc.heap)+'</span><span>allocated '+formatBytes(gc.allocated)+'</span><span>collections '+gc.collections+'</span>':'';document.getElementById('health').innerHTML='<span>buffer '+Math.round((h.bufferUtilization||0)*100)+'%</span><span>rate '+h.effectiveSampleRate+'/'+h.requestedSampleRate+' Hz</span><span>dropped '+h.dropped+'</span><span>GC samples '+(h.gcSamples||0)+'</span>'+memory+'<span>native symbols '+(h.nativeSymbolCount||0)+'</span><span>overhead '+Number(h.overheadMicrosPerSample||0).toFixed(1)+' µs/sample</span><span>generated '+(h.generatedBytes||0)+' B</span><span>metadata '+Number(h.metadataRefreshMs||0).toFixed(1)+' ms</span><span id="uiLatency">UI — ms</span>';const s=document.getElementById('thread'),selected=s.value;(h.threads||[]).forEach(t=>{if(![...s.options].some(o=>o.value==String(t.id)))s.add(new Option(t.name,String(t.id)))});s.value=[...s.options].some(o=>o.value===selected)?selected:'all'}
function formatBytes(value){const n=Number(value||0);if(n<1024)return n+' B';if(n<1048576)return(n/1024).toFixed(1)+' KiB';return(n/1048576).toFixed(1)+' MiB'}
render();`;
}
