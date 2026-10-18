/// The page a browser gets from the developer API's root URL: the Mentos
/// Console. Self-contained (no CDN) so it works on a LAN without internet.
/// Every request carries the access code the person types in; images are
/// fetched with it and shown from blob URLs.
const devDashboardHtml = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Mentos Console</title>
<style>
:root{
  --bg:#F4F5F4;--surface:#FFFFFF;--raised:#ECEEED;--sunken:#E6E9E7;--line:#E0E3E1;--ink:#0D1110;--soft:#2C3330;--muted:#69726E;--faint:#A3AAA6;
  --accent:#0E9F6E;--accentSoft:#DFF3EA;--accentInk:#FFFFFF;--danger:#D1453B;--dangerSoft:#FBE7E5;--warn:#B7791F;--warnSoft:#FDF1DC;
  --blue:#2563EB;--blueSoft:#E3ECFD;--violet:#7C3AED;--violetSoft:#EEE7FD;
  --mono:ui-monospace,SFMono-Regular,"Cascadia Code",Menlo,Consolas,monospace;
  --shadow:0 1px 2px rgba(16,24,20,.04),0 8px 24px rgba(16,24,20,.06);
  --r:18px;
}
:root[data-theme="dark"]{
  --bg:#08090A;--surface:#111413;--raised:#181C1A;--sunken:#0C0E0D;--line:#222826;--ink:#ECEFED;--soft:#C9CFCC;--muted:#8A938F;--faint:#545C58;
  --accent:#34D399;--accentSoft:#0F2A1F;--accentInk:#04140D;--danger:#F2675C;--dangerSoft:#2E1513;--warn:#F5B94A;--warnSoft:#2A2110;
  --blue:#60A5FA;--blueSoft:#122033;--violet:#A78BFA;--violetSoft:#1E1733;--shadow:0 1px 2px rgba(0,0,0,.3),0 10px 30px rgba(0,0,0,.35);
}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
  --bg:#08090A;--surface:#111413;--raised:#181C1A;--sunken:#0C0E0D;--line:#222826;--ink:#ECEFED;--soft:#C9CFCC;--muted:#8A938F;--faint:#545C58;
  --accent:#34D399;--accentSoft:#0F2A1F;--accentInk:#04140D;--danger:#F2675C;--dangerSoft:#2E1513;--warn:#F5B94A;--warnSoft:#2A2110;
  --blue:#60A5FA;--blueSoft:#122033;--violet:#A78BFA;--violetSoft:#1E1733;--shadow:0 1px 2px rgba(0,0,0,.3),0 10px 30px rgba(0,0,0,.35);
}}
*{box-sizing:border-box}
html,body{margin:0;min-height:100%;background:var(--bg);color:var(--ink);font:15px/1.5 Inter,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;-webkit-font-smoothing:antialiased}
button,input,textarea,select{font:inherit;color:inherit}
button{cursor:pointer}
a{color:var(--accent)}
svg{width:18px;height:18px;flex:none;stroke:currentColor;fill:none;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}
.hidden{display:none!important}
.mono{font-family:var(--mono);font-size:12.5px}
.mut{color:var(--muted)}.faint{color:var(--faint)}
.sm{font-size:13px}.xs{font-size:11.5px}
.ell{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.row{display:flex;align-items:center;gap:10px}
.col{display:flex;flex-direction:column;gap:10px}
.grow{flex:1;min-width:0}
.wrap{flex-wrap:wrap}

/* ---------- shell ---------- */
.shell{display:grid;grid-template-columns:248px 1fr;min-height:100vh}
.side{position:sticky;top:0;height:100vh;padding:18px 14px;border-right:1px solid var(--line);background:var(--surface);display:flex;flex-direction:column;gap:2px;overflow-y:auto}
.brand{display:flex;align-items:center;gap:10px;padding:6px 8px 14px}
.mark{width:34px;height:34px;border-radius:11px;background:var(--ink);color:var(--bg);display:grid;place-items:center;font-weight:800;letter-spacing:-.04em}
.brand b{display:block;font-size:15px;letter-spacing:-.01em}
.nav{display:flex;align-items:center;gap:11px;padding:9px 10px;border-radius:12px;color:var(--soft);border:0;background:none;text-align:left;width:100%;font-weight:500}
.nav:hover{background:var(--raised)}
.nav.sel{background:var(--ink);color:var(--bg)}
.nav .badge{margin-left:auto}
.side .sec{font-size:11px;letter-spacing:.09em;text-transform:uppercase;color:var(--faint);padding:14px 10px 6px;font-weight:600}
.side .foot{margin-top:auto;padding:12px 8px 0;border-top:1px solid var(--line)}
.main{min-width:0;display:flex;flex-direction:column}
.top{position:sticky;top:0;z-index:20;display:flex;align-items:center;gap:10px;padding:14px 28px;background:color-mix(in srgb,var(--bg) 86%,transparent);backdrop-filter:blur(12px);border-bottom:1px solid var(--line)}
.top h1{margin:0;font-size:20px;letter-spacing:-.02em}
.page{padding:24px 28px 80px;max-width:1240px;width:100%}
.mtabs{display:none}
@media (max-width:900px){
  .shell{grid-template-columns:1fr}
  .side{display:none}
  .top{padding:12px 16px}
  .page{padding:16px 16px 100px}
  .mtabs{display:flex;position:fixed;bottom:0;left:0;right:0;z-index:30;background:var(--surface);border-top:1px solid var(--line);overflow-x:auto;padding:6px 6px calc(6px + env(safe-area-inset-bottom));gap:2px;scrollbar-width:none}
  .mtabs button{flex:none;display:flex;flex-direction:column;align-items:center;gap:2px;font-size:10.5px;border:0;background:none;color:var(--muted);padding:6px 10px;border-radius:10px;min-width:62px}
  .mtabs button.sel{color:var(--ink);background:var(--raised)}
  #nodeBtn span{display:none}
}

/* ---------- parts ---------- */
.card{background:var(--surface);border:1px solid var(--line);border-radius:var(--r);padding:18px;box-shadow:var(--shadow)}
.card.flat{box-shadow:none}
.card h3{margin:0 0 12px;font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);font-weight:650;display:flex;align-items:center;gap:8px}
.grid{display:grid;gap:14px}
.g2{grid-template-columns:repeat(2,minmax(0,1fr))}
.g3{grid-template-columns:repeat(3,minmax(0,1fr))}
.g4{grid-template-columns:repeat(4,minmax(0,1fr))}
.g6{grid-template-columns:repeat(6,minmax(0,1fr))}
@media (max-width:1100px){.g6{grid-template-columns:repeat(3,minmax(0,1fr))}.g4{grid-template-columns:repeat(2,minmax(0,1fr))}.g3{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media (max-width:900px){.g2,.g3{grid-template-columns:1fr}}
@media (max-width:520px){.g6,.g4{grid-template-columns:repeat(2,minmax(0,1fr))}}
.stat{padding:16px}
.ic{width:34px;height:34px;border-radius:11px;display:grid;place-items:center;flex:none}
.stat .ic{margin-bottom:12px}
.stat .v{font-size:26px;font-weight:700;letter-spacing:-.03em;font-variant-numeric:tabular-nums;line-height:1.1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.stat .l{color:var(--muted);font-size:13px}
.t-green{background:var(--accentSoft);color:var(--accent)}.t-blue{background:var(--blueSoft);color:var(--blue)}.t-violet{background:var(--violetSoft);color:var(--violet)}.t-warn{background:var(--warnSoft);color:var(--warn)}.t-red{background:var(--dangerSoft);color:var(--danger)}.t-gray{background:var(--raised);color:var(--soft)}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:7px;border:1px solid var(--line);background:var(--surface);padding:8px 14px;border-radius:12px;font-weight:550;white-space:nowrap;transition:.12s}
.btn:hover{border-color:var(--faint)}
.btn.pri{background:var(--ink);border-color:var(--ink);color:var(--bg)}
.btn.acc{background:var(--accent);border-color:var(--accent);color:var(--accentInk)}
.btn.dan{color:var(--danger)}
.btn.ghost{border-color:transparent;background:transparent}
.btn.ghost:hover{background:var(--raised)}
.btn.sm{padding:5px 10px;font-size:13px;border-radius:10px}
.btn.icon{padding:7px;border-radius:10px}
.btn:disabled{opacity:.45;cursor:default}
input,textarea,select{width:100%;background:var(--raised);border:1px solid transparent;border-radius:12px;padding:10px 12px;outline:none;transition:.12s}
input:focus,textarea:focus,select:focus{border-color:var(--accent);background:var(--surface)}
textarea{resize:vertical}
.search{position:relative}
.search svg{position:absolute;left:12px;top:50%;transform:translateY(-50%);color:var(--faint)}
.search input{padding-left:38px}
.pill{display:inline-flex;align-items:center;gap:5px;padding:2px 9px;border-radius:999px;font-size:12px;font-weight:550;background:var(--raised);color:var(--muted);white-space:nowrap}
.pill svg{width:13px;height:13px}
.pill.ok{background:var(--accentSoft);color:var(--accent)}.pill.err{background:var(--dangerSoft);color:var(--danger)}.pill.warn{background:var(--warnSoft);color:var(--warn)}.pill.blue{background:var(--blueSoft);color:var(--blue)}
.badge{min-width:20px;height:20px;padding:0 6px;border-radius:10px;background:var(--accent);color:var(--accentInk);font-size:11.5px;font-weight:700;display:inline-grid;place-items:center}
.dot{width:8px;height:8px;border-radius:50%;background:var(--faint);display:inline-block;flex:none}
.dot.on{background:var(--accent);box-shadow:0 0 0 4px var(--accentSoft)}
.av{border-radius:32%;flex:none;display:grid;place-items:center;font-weight:700;color:#fff;overflow:hidden;background-size:cover;background-position:center}
.chips{display:flex;gap:6px;overflow-x:auto;scrollbar-width:none;padding-bottom:2px}
.chip{border:1px solid var(--line);background:var(--surface);padding:6px 12px;border-radius:999px;font-size:13px;font-weight:550;white-space:nowrap;color:var(--soft)}
.chip.sel{background:var(--ink);border-color:var(--ink);color:var(--bg)}
.empty{padding:36px 16px;text-align:center;color:var(--muted)}
.empty .ic{width:52px;height:52px;border-radius:16px;margin:0 auto 12px;background:var(--raised);color:var(--muted)}
.list>.it{display:flex;gap:12px;align-items:center;padding:11px 4px;border-top:1px solid var(--line)}
.list>.it:first-child{border-top:0}
table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:10px 8px;border-top:1px solid var(--line);font-size:13.5px;vertical-align:middle}
th{color:var(--muted);font-weight:600;font-size:11.5px;text-transform:uppercase;letter-spacing:.07em;border-top:0}
td .mono{word-break:break-all}
tr.click{cursor:pointer}
tr.click:hover td{background:var(--raised)}
.num{text-align:right;font-variant-numeric:tabular-nums}
.switch{position:relative;width:40px;height:24px;flex:none;display:inline-block}
.switch input{opacity:0;width:0;height:0;position:absolute}
.switch span{position:absolute;inset:0;background:var(--line);border-radius:999px;cursor:pointer;transition:.15s}
.switch span:before{content:"";position:absolute;width:18px;height:18px;left:3px;top:3px;background:#fff;border-radius:50%;transition:.15s;box-shadow:0 1px 2px rgba(0,0,0,.2)}
.switch input:checked+span{background:var(--accent)}
.switch input:checked+span:before{transform:translateX(16px)}
.skel{background:linear-gradient(90deg,var(--raised),var(--sunken),var(--raised));background-size:200% 100%;animation:sk 1.2s infinite;border-radius:10px;height:14px}
@keyframes sk{to{background-position:-200% 0}}
.bar{height:5px;border-radius:3px;background:var(--raised);overflow:hidden}
.bar div{height:100%;border-radius:3px;background:var(--accent)}

/* ---------- overview ---------- */
.hero{display:flex;gap:18px;align-items:center;padding:22px;border-radius:24px;background:radial-gradient(120% 140% at 0% 0%,color-mix(in srgb,var(--accent) 20%,var(--surface)) 0%,var(--surface) 55%);border:1px solid var(--line);box-shadow:var(--shadow)}
.hero h2{margin:0;font-size:24px;letter-spacing:-.02em}
.feedline{display:flex;gap:10px;align-items:baseline;padding:9px 0;border-top:1px solid var(--line);font-size:13.5px}
.feedline:first-child{border-top:0}
.feedline .when{color:var(--faint);font-family:var(--mono);font-size:11.5px;white-space:nowrap}
@media (max-width:600px){.hero{flex-wrap:wrap}.hero .side-info{text-align:left!important}}

/* ---------- chats ---------- */
.chat{display:grid;grid-template-columns:330px 1fr;height:calc(100vh - 150px);min-height:480px;border:1px solid var(--line);border-radius:22px;overflow:hidden;background:var(--surface);box-shadow:var(--shadow)}
.chat .left{border-right:1px solid var(--line);display:flex;flex-direction:column;min-height:0}
.chat .left .head{padding:14px;border-bottom:1px solid var(--line)}
.chatlist{overflow-y:auto;flex:1;padding:6px}
.ci{display:flex;gap:11px;align-items:center;padding:10px;border-radius:14px;cursor:pointer}
.ci:hover{background:var(--raised)}
.ci.sel{background:var(--accentSoft)}
.thread{display:flex;flex-direction:column;min-height:0}
.thread .head{display:flex;align-items:center;gap:12px;padding:12px 16px;border-bottom:1px solid var(--line);min-height:65px}
.msgs{flex:1;overflow-y:auto;padding:18px;display:flex;flex-direction:column;gap:4px;background:var(--bg)}
.day{align-self:center;font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--faint);margin:12px 0 6px;font-weight:600}
.bub{max-width:min(72%,560px);padding:8px 12px 6px;border-radius:18px 18px 18px 6px;background:var(--surface);border:1px solid var(--line);align-self:flex-start;white-space:pre-wrap;word-break:break-word}
.bub.me{align-self:flex-end;background:var(--ink);color:var(--bg);border-color:var(--ink);border-radius:18px 18px 6px 18px}
.bub.me a{color:inherit}
.bub .who{font-size:12px;font-weight:650;color:var(--accent);margin-bottom:2px}
.bub .meta{font-size:11px;opacity:.6;text-align:right;margin-top:2px;white-space:nowrap}
.reacts{display:flex;gap:4px;flex-wrap:wrap;margin-top:4px}
.reacts span{background:var(--raised);color:var(--ink);border-radius:999px;padding:0 7px;font-size:12px}
.bub.me .reacts span{background:rgba(255,255,255,.14);color:inherit}
.composer{display:flex;gap:8px;align-items:flex-end;padding:12px;border-top:1px solid var(--line);background:var(--surface)}
.composer textarea{border-radius:22px;min-height:44px;max-height:180px;resize:none;padding:11px 16px}
.chat .back{display:none}
@media (max-width:900px){.chat{grid-template-columns:1fr;height:calc(100vh - 175px)}.chat.open .left{display:none}.chat:not(.open) .thread{display:none}.chat .back{display:inline-flex}}

/* ---------- feed ---------- */
.feed{max-width:640px;margin:0 auto;display:flex;flex-direction:column;gap:14px}
.post .ph{display:flex;align-items:center;gap:11px;margin-bottom:10px}
.post .txt{white-space:pre-wrap;word-break:break-word}
.post .imgs{display:grid;gap:3px;margin-top:12px;border-radius:14px;overflow:hidden;aspect-ratio:1/1}
.post .imgs.n2{grid-template-columns:1fr 1fr}
.post .imgs.n3,.post .imgs.n4{grid-template-columns:1fr 1fr;grid-template-rows:1fr 1fr}
.post .imgs.n3 div:first-child{grid-row:span 2}
.post .imgs div{background:var(--raised) center/cover no-repeat}
.post .acts{display:flex;gap:4px;margin-top:10px}
.post .acts button{display:inline-flex;align-items:center;gap:6px;border:0;background:none;padding:6px 10px;border-radius:10px;color:var(--muted);font-size:13.5px}
.post .acts button:hover:not(:disabled){background:var(--raised)}
.post .acts button:disabled{cursor:default}
.post .acts button.on{color:var(--danger)}
.post .acts button.on svg{fill:currentColor}

/* ---------- logs ---------- */
.log{height:calc(100vh - 230px);min-height:360px;overflow:auto;background:var(--sunken);border:1px solid var(--line);border-radius:16px;padding:10px 12px;font-family:var(--mono);font-size:12px}
.log>div{padding:3px 0;white-space:pre-wrap;word-break:break-word;display:flex;gap:10px;border-bottom:1px dashed color-mix(in srgb,var(--line) 60%,transparent)}
.log .t{color:var(--faint);flex:none}
.log .k{flex:none;width:62px;font-weight:700;overflow:hidden;text-overflow:ellipsis}
.log .api .k{color:var(--blue)}.log .ev .k{color:var(--accent)}.log .pl .k{color:var(--violet)}.log .e,.log .e .k{color:var(--danger)}
pre.code{margin:0;background:var(--sunken);border:1px solid var(--line);border-radius:14px;padding:12px;overflow:auto;font-family:var(--mono);font-size:12.5px;max-height:460px;white-space:pre-wrap;word-break:break-word}

/* ---------- overlays ---------- */
#toasts{position:fixed;right:20px;bottom:20px;z-index:100;display:flex;flex-direction:column;gap:8px;align-items:flex-end}
.toast{background:var(--ink);color:var(--bg);padding:10px 16px;border-radius:14px;box-shadow:var(--shadow);font-size:14px;max-width:min(420px,90vw);animation:tin .18s ease-out;transition:opacity .3s}
.toast.err{background:var(--danger);color:#fff}
@keyframes tin{from{transform:translateY(8px);opacity:0}}
@media (max-width:900px){#toasts{left:16px;right:16px;bottom:84px;align-items:stretch}}
.modal{position:fixed;inset:0;z-index:90;background:rgba(0,0,0,.45);display:grid;place-items:center;padding:16px;animation:fade .15s}
.modal .box{background:var(--surface);border:1px solid var(--line);border-radius:22px;width:min(520px,100%);max-height:88vh;overflow:auto;padding:22px;box-shadow:0 30px 80px rgba(0,0,0,.35)}
.modal h2{margin:0 0 6px;font-size:19px}
@keyframes fade{from{opacity:0}}

/* ---------- login ---------- */
.login{min-height:100vh;display:grid;place-items:center;padding:24px;background:radial-gradient(90% 70% at 50% 0%,color-mix(in srgb,var(--accent) 16%,var(--bg)) 0%,var(--bg) 70%)}
.login .box{width:min(420px,100%);text-align:center}
.login .mark{width:64px;height:64px;border-radius:20px;margin:0 auto 18px;font-size:26px}
.code{font-family:var(--mono);font-size:20px;letter-spacing:.08em;text-align:center;padding:14px}
.feat{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-top:22px}
.feat div{background:var(--surface);border:1px solid var(--line);border-radius:14px;padding:12px 8px;font-size:12px;color:var(--muted)}
.feat svg{display:block;margin:0 auto 6px;color:var(--accent)}
</style>
</head>
<body>

<div id="login" class="login">
  <div class="box">
    <div class="mark">m</div>
    <h1 style="margin:0 0 6px;font-size:28px;letter-spacing:-.03em">Mentos Console</h1>
    <p class="mut" style="margin:0 0 22px">Use your node from this browser. Enter the access code from <b>Settings › Developer</b> in the app.</p>
    <form id="loginForm" class="card" style="text-align:left">
      <input id="code" class="code" placeholder="xxxx-xxxx-xxxx-xxxx" autocomplete="off" autocapitalize="off" spellcheck="false" maxlength="19">
      <button class="btn acc" style="width:100%;margin-top:12px;padding:12px">Connect</button>
      <p id="loginErr" class="sm" style="color:var(--danger);margin:10px 0 0;min-height:1.2em;text-align:center"></p>
    </form>
    <div class="feat">
      <div><svg viewBox="0 0 24 24"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>Chats and feed</div>
      <div><svg viewBox="0 0 24 24"><path d="M20 12V8H6a2 2 0 0 1 0-4h12v4"/><path d="M4 6v12a2 2 0 0 0 2 2h14v-4"/><path d="M18 12a2 2 0 0 0 0 4h4v-4z"/></svg>Wallet</div>
      <div><svg viewBox="0 0 24 24"><path d="M13 2 3 14h9l-1 8 10-12h-9z"/></svg>Live logs</div>
    </div>
    <p class="xs faint" style="margin-top:18px">The code stays in this tab and is sent only to this device.</p>
  </div>
</div>

<div id="app" class="shell hidden">
  <aside class="side" id="side"></aside>
  <div class="main">
    <header class="top">
      <div class="grow">
        <h1 id="pageTitle">Overview</h1>
        <div class="xs mut row" style="gap:6px"><span class="dot" id="liveDot"></span><span id="liveText">connecting…</span></div>
      </div>
      <button class="btn sm" id="nodeBtn" title="Connect or disconnect the node">…</button>
      <button class="btn icon ghost" id="themeBtn" title="Theme"></button>
      <button class="btn icon ghost" id="logoutBtn" title="Sign out"><svg viewBox="0 0 24 24"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/></svg></button>
    </header>
    <main class="page" id="page"></main>
  </div>
  <nav class="mtabs" id="mtabs"></nav>
</div>
<div id="toasts"></div>

<script>
(function(){
"use strict";
var $=function(id){return document.getElementById(id)};
function each(root,sel,fn){Array.prototype.forEach.call(root.querySelectorAll(sel),fn)}
function store(k,v){try{if(v===undefined)return sessionStorage.getItem(k);if(v===null)sessionStorage.removeItem(k);else sessionStorage.setItem(k,v)}catch(e){}return null}
function pref(k,v){try{if(v===undefined)return localStorage.getItem(k);localStorage.setItem(k,v)}catch(e){}return null}

/* ---------------- icons ---------------- */
var I={
 home:'<path d="M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z"/>',
 chat:'<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>',
 feed:'<rect x="3" y="3" width="18" height="18" rx="3"/><path d="M3 9h18M9 21V9"/>',
 people:'<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/>',
 net:'<circle cx="12" cy="12" r="3"/><circle cx="4" cy="6" r="2"/><circle cx="20" cy="6" r="2"/><circle cx="4" cy="18" r="2"/><circle cx="20" cy="18" r="2"/><path d="m6 7 4 3M18 7l-4 3M6 17l4-3M18 17l-4-3"/>',
 wallet:'<path d="M20 12V8H6a2 2 0 0 1 0-4h12v4"/><path d="M4 6v12a2 2 0 0 0 2 2h14v-4"/><path d="M18 12a2 2 0 0 0 0 4h4v-4z"/>',
 market:'<path d="M3 9 4.5 4h15L21 9"/><path d="M3 9h18v2a3 3 0 0 1-6 0 3 3 0 0 1-6 0 3 3 0 0 1-6 0z"/><path d="M5 13v7h14v-7"/>',
 plug:'<path d="M14 7V3M10 7V3M7 7h10v4a5 5 0 0 1-10 0z"/><path d="M12 16v5"/>',
 bell:'<path d="M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.7 21a2 2 0 0 1-3.4 0"/>',
 xfer:'<path d="M7 17 3 13l4-4M3 13h13M17 7l4 4-4 4M21 11H8"/>',
 log:'<path d="M4 6h16M4 12h16M4 18h10"/>',
 code:'<path d="m16 18 6-6-6-6M8 6l-6 6 6 6"/>',
 sun:'<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
 moon:'<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/>',
 auto:'<circle cx="12" cy="12" r="9"/><path d="M12 3a9 9 0 0 1 0 18z" fill="currentColor"/>',
 heart:'<path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1-1.1a5.5 5.5 0 0 0-7.8 7.8l1 1.1L12 21l7.8-7.5 1-1.1a5.5 5.5 0 0 0 0-7.8z"/>',
 comment:'<path d="M21 11.5a8.4 8.4 0 0 1-9 8.4 8.6 8.6 0 0 1-4-1L3 20l1.1-4A8.4 8.4 0 1 1 21 11.5z"/>',
 eye:'<path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8S1 12 1 12z"/><circle cx="12" cy="12" r="3"/>',
 eyeoff:'<path d="M17.9 17.9A10 10 0 0 1 12 20c-7 0-11-8-11-8a18 18 0 0 1 5.1-5.9M9.9 4.2A9 9 0 0 1 12 4c7 0 11 8 11 8a18 18 0 0 1-2.2 3.2M1 1l22 22"/>',
 send:'<path d="m22 2-7 20-4-9-9-4z"/><path d="M22 2 11 13"/>',
 search:'<circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/>',
 back:'<path d="m15 18-6-6 6-6"/>',
 copy:'<rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
 refresh:'<path d="M21 12a9 9 0 1 1-2.6-6.4L21 8"/><path d="M21 3v5h-5"/>',
 plus:'<path d="M12 5v14M5 12h14"/>',
 power:'<path d="M18.4 6.6a9 9 0 1 1-12.8 0M12 2v10"/>',
 bolt:'<path d="M13 2 3 14h9l-1 8 10-12h-9z"/>',
 globe:'<circle cx="12" cy="12" r="10"/><path d="M2 12h20M12 2a15 15 0 0 1 0 20 15 15 0 0 1 0-20"/>',
 coin:'<circle cx="12" cy="12" r="9"/><path d="M14.8 9A3 3 0 0 0 12 7.5c-1.7 0-3 .9-3 2.25S10.3 12 12 12s3 .9 3 2.25-1.3 2.25-3 2.25A3 3 0 0 1 9.2 15M12 6v1.5M12 16.5V18"/>',
 down:'<path d="M12 5v14M19 12l-7 7-7-7"/>',
 up:'<path d="M12 19V5M5 12l7-7 7 7"/>',
 lock:'<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
 trash:'<path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6"/>',
 pause:'<path d="M8 5v14M16 5v14"/>',
 play:'<path d="m7 4 13 8-13 8z"/>',
 dl:'<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M7 10l5 5 5-5M12 15V3"/>',
 check:'<path d="M20 6 9 17l-5-5"/>',
 star:'<path d="m12 3 2.6 6 6.4.6-4.8 4.3 1.4 6.3L12 17l-5.6 3.2 1.4-6.3L3 9.6 9.4 9z"/>'
};
function ic(n){return '<svg viewBox="0 0 24 24">'+(I[n]||'')+'</svg>'}

/* ---------------- utils ---------------- */
function esc(s){return String(s==null?"":s).replace(/[&<>"']/g,function(c){return{"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]})}
function hue(s){var h=0;s=String(s||"");for(var i=0;i<s.length;i++)h=(h*31+s.charCodeAt(i))%360;return h}
function ago(ts){if(!ts)return"";var s=(Date.now()-ts)/1000;if(s<45)return"now";if(s<3600)return Math.floor(s/60)+"m";if(s<86400)return Math.floor(s/3600)+"h";if(s<604800)return Math.floor(s/86400)+"d";return new Date(ts).toLocaleDateString()}
function hm(ts){return new Date(ts).toLocaleTimeString([],{hour:"2-digit",minute:"2-digit"})}
function hms(ts){return new Date(ts).toLocaleTimeString([],{hour:"2-digit",minute:"2-digit",second:"2-digit"})}
function dayLabel(ts){var d=new Date(ts),n=new Date();if(d.toDateString()===n.toDateString())return"Today";n.setDate(n.getDate()-1);if(d.toDateString()===n.toDateString())return"Yesterday";return d.toLocaleDateString([],{weekday:"long",month:"short",day:"numeric"})}
function bytes(n){n=n||0;if(n<1024)return n+" B";if(n<1048576)return(n/1024).toFixed(1)+" KB";if(n<1073741824)return(n/1048576).toFixed(1)+" MB";return(n/1073741824).toFixed(2)+" GB"}
function short(id){return id?id.slice(0,8)+"…"+id.slice(-4):""}
function host(u){try{return new URL(u).host}catch(e){return u}}
function linkify(t){return esc(t).replace(/(https?:\/\/[^\s<]+)/g,'<a href="$1" target="_blank" rel="noopener noreferrer">$1</a>').replace(/(^|\s)#([\w-]{1,40})/g,'$1<span style="color:var(--accent)">#$2</span>')}
function copy(t,what){(navigator.clipboard?navigator.clipboard.writeText(t):Promise.reject()).then(function(){toast((what||"Text")+" copied")},function(){toast("Copy failed","err")})}
function toast(t,kind){var el=document.createElement("div");el.className="toast"+(kind==="err"?" err":"");el.textContent=t;$("toasts").appendChild(el);setTimeout(function(){el.style.opacity="0";setTimeout(function(){el.remove()},300)},kind==="err"?4200:2400)}
function empty(icon,title,body){return'<div class="empty"><div class="ic">'+ic(icon)+'</div><div style="font-weight:650;color:var(--ink)">'+esc(title)+'</div>'+(body?'<div class="sm" style="margin-top:4px">'+esc(body)+'</div>':'')+'</div>'}
function skel(n){var s="";for(var i=0;i<(n||4);i++)s+='<div class="skel" style="margin:12px 0;width:'+(60+(i*17)%35)+'%"></div>';return s}
function tile(icon,tint,size){size=size||34;return'<div class="ic '+tint+'" style="width:'+size+'px;height:'+size+'px">'+ic(icon)+'</div>'}
function modal(html,onMount){var m=document.createElement("div");m.className="modal";m.innerHTML='<div class="box">'+html+'</div>';m.addEventListener("click",function(e){if(e.target===m)m.remove()});document.body.appendChild(m);var close=function(){m.remove()};each(m,"[data-close]",function(b){b.onclick=close});if(onMount)onMount(m,close);return close}
function confirmBox(title,body,action,danger){return new Promise(function(res){modal('<h2>'+esc(title)+'</h2><p class="mut">'+esc(body)+'</p><div class="row" style="justify-content:flex-end;margin-top:18px"><button class="btn" data-no>Cancel</button><button class="btn '+(danger?"dan":"pri")+'" data-yes>'+esc(action)+'</button></div>',function(m,close){m.querySelector("[data-yes]").onclick=function(){close();res(true)};m.querySelector("[data-no]").onclick=function(){close();res(false)}})})}

/* ---------------- api ---------------- */
var token=store("mentosCode")||"";
function api(method,path,body){
  var opt={method:method,headers:{"Authorization":"Bearer "+token}};
  if(body!==undefined){opt.body=typeof body==="string"?body:JSON.stringify(body);opt.headers["Content-Type"]=typeof body==="string"?"text/plain":"application/json"}
  return fetch(path,opt).then(function(r){return r.json().catch(function(){return{}}).then(function(j){if(r.status===401){signOut("That code didn't work");throw new Error("unauthorized")}if(!r.ok)throw new Error(j.error||("HTTP "+r.status));return j})});
}
var imgCache={};
function img(path){if(!imgCache[path])imgCache[path]=fetch(path,{headers:{"Authorization":"Bearer "+token}}).then(function(r){if(!r.ok)throw 0;return r.blob()}).then(function(b){return URL.createObjectURL(b)}).catch(function(){delete imgCache[path];return null});return imgCache[path]}
function hydrate(root){each(root||document,"[data-img]",function(el){var p=el.getAttribute("data-img");el.removeAttribute("data-img");img(p).then(function(u){if(u){el.style.backgroundImage='url("'+u+'")';el.textContent=""}})})}
function av(name,id,size,hasPic){size=size||40;var n=(name||"?").trim();return'<div class="av" style="width:'+size+'px;height:'+size+'px;font-size:'+Math.round(size*.42)+'px;background-color:hsl('+hue(id||n)+',42%,46%)"'+(hasPic&&id?' data-img="/v1/media/avatar/'+esc(id)+'"':'')+'>'+esc(n.charAt(0).toUpperCase())+'</div>'}

/* ---------------- theme ---------------- */
var THEMES=["auto","light","dark"];
function applyTheme(){var t=pref("mentosTheme")||"auto";if(t==="auto")document.documentElement.removeAttribute("data-theme");else document.documentElement.setAttribute("data-theme",t);$("themeBtn").innerHTML=ic(t==="dark"?"moon":t==="light"?"sun":"auto");$("themeBtn").title="Theme: "+t}
$("themeBtn").onclick=function(){var t=pref("mentosTheme")||"auto";pref("mentosTheme",THEMES[(THEMES.indexOf(t)+1)%3]);applyTheme()};
applyTheme();

/* ---------------- login ---------------- */
$("code").addEventListener("input",function(){var v=this.value.toLowerCase().replace(/[^a-z0-9]/g,"").slice(0,16);this.value=v.replace(/(.{4})(?=.)/g,"$1-")});
$("loginForm").addEventListener("submit",function(ev){ev.preventDefault();token=$("code").value.trim().toLowerCase();$("loginErr").textContent="";
  api("GET","/v1/info").then(function(){store("mentosCode",token);start()}).catch(function(e){if(e.message!=="unauthorized")$("loginErr").textContent=e.message})});
function signOut(msg){token="";store("mentosCode",null);stopLive();timers.forEach(clearInterval);timers=[];$("app").classList.add("hidden");$("login").classList.remove("hidden");$("loginErr").textContent=msg||"";$("code").value="";$("code").focus()}
$("logoutBtn").onclick=function(){signOut("")};

/* ---------------- navigation ---------------- */
var PAGES=[
 {id:"overview",t:"Overview",i:"home",s:"Node"},
 {id:"network",t:"Network",i:"net",s:"Node"},
 {id:"transfers",t:"Transfers",i:"xfer",s:"Node"},
 {id:"chats",t:"Chats",i:"chat",s:"Social"},
 {id:"feed",t:"Feed",i:"feed",s:"Social"},
 {id:"people",t:"People",i:"people",s:"Social"},
 {id:"activity",t:"Activity",i:"bell",s:"Social"},
 {id:"wallet",t:"Wallet",i:"wallet",s:"Money"},
 {id:"market",t:"Market",i:"market",s:"Money"},
 {id:"plugins",t:"Plugins",i:"plug",s:"Build"},
 {id:"logs",t:"Logs",i:"log",s:"Build"},
 {id:"api",t:"API",i:"code",s:"Build"}
];
var cur="overview",info=null,timers=[];
function buildNav(){
  var html='<div class="brand"><div class="mark">m</div><div class="grow"><b>Mentos Console</b><span class="xs mut ell" style="display:block" id="sideName">—</span></div></div>',last="";
  PAGES.forEach(function(p){if(p.s!==last){html+='<div class="sec">'+p.s+'</div>';last=p.s}html+='<button class="nav" data-p="'+p.id+'">'+ic(p.i)+'<span>'+p.t+'</span><span class="badge hidden" data-b="'+p.id+'"></span></button>'});
  html+='<div class="foot"><div class="row xs mut"><span class="dot" id="sideDot"></span><span id="sideStatus">—</span></div><div class="xs faint" id="sideApi" style="margin-top:6px"></div></div>';
  $("side").innerHTML=html;
  $("mtabs").innerHTML=PAGES.map(function(p){return'<button data-p="'+p.id+'">'+ic(p.i)+'<span>'+p.t+'</span></button>'}).join("");
  each(document,"[data-p]",function(b){b.onclick=function(){go(b.getAttribute("data-p"))}});
}
function setBadge(id,n){each(document,'[data-b="'+id+'"]',function(el){el.textContent=n>99?"99+":n;el.classList.toggle("hidden",!n)})}
function go(id){if(!PAGES.some(function(p){return p.id===id}))id="overview";cur=id;if(location.hash!=="#"+id)history.replaceState(null,"","#"+id);var p=PAGES.filter(function(x){return x.id===id})[0];$("pageTitle").textContent=p.t;document.title=p.t+" · Mentos Console";
  each(document,"[data-p]",function(b){b.classList.toggle("sel",b.getAttribute("data-p")===id)});
  window.scrollTo(0,0);$("page").innerHTML="";if(R[cur])R[cur]($("page"))}
window.addEventListener("hashchange",function(){var h=location.hash.replace("#","");if(h&&h!==cur)go(h)});

/* ---------------- live stream ---------------- */
var live=null,liveTimer=null,lastRefresh={},feedLines=[];
function stopLive(){if(live){try{live.abort()}catch(e){}live=null}clearTimeout(liveTimer)}
function startLive(){
  stopLive();var ctrl=new AbortController();live=ctrl;
  fetch("/v1/stream",{headers:{"Authorization":"Bearer "+token},signal:ctrl.signal}).then(function(r){
    if(!r.ok||!r.body)throw new Error("stream");setLive(true);
    var reader=r.body.getReader(),dec=new TextDecoder(),buf="";
    function pump(){return reader.read().then(function(x){if(x.done)throw new Error("closed");buf+=dec.decode(x.value,{stream:true});var parts=buf.split("\n\n");buf=parts.pop();parts.forEach(onEvent);return pump()})}
    return pump();
  }).catch(function(){if(live!==ctrl)return;setLive(false);liveTimer=setTimeout(startLive,3000)});
}
function setLive(on){$("liveDot").className="dot"+(on?" on":"");$("liveText").textContent=on?"live":"reconnecting…"}
function onEvent(chunk){var ev="message",data="";chunk.split("\n").forEach(function(l){if(l.indexOf("event:")===0)ev=l.slice(6).trim();else if(l.indexOf("data:")===0)data+=l.slice(5).trim()});if(!data)return;var j;try{j=JSON.parse(data)}catch(e){return}
  if(ev==="change")refreshFor(j.channels||[]);
  else if(ev==="message"){feedLines.unshift({ts:Date.now(),k:"message",t:j.name+": "+(j.text||"sent something")});if(!(cur==="chats"&&openScope===j.scope))toast(j.name+": "+(j.text||"new message").slice(0,90))}
  else if(ev==="note")feedLines.unshift({ts:j.ts||Date.now(),k:j.category||"note",t:j.title+" · "+j.body});
  if(cur==="overview")renderLiveFeed()}
function throttle(key,ms,fn){var now=Date.now();if(now-(lastRefresh[key]||0)<ms){clearTimeout(lastRefresh[key+"t"]);lastRefresh[key+"t"]=setTimeout(function(){lastRefresh[key]=Date.now();fn()},ms);return}lastRefresh[key]=now;fn()}
function has(ch,names){return ch.some(function(c){return names.some(function(n){return n.charAt(n.length-1)===":"?c.indexOf(n)===0:c===n})})}
function refreshFor(ch){
  if(has(ch,["#chats","dm:","gdm:"]))throttle("chats",700,function(){loadChats(true);refreshInfo()});
  if(has(ch,["#feed"])&&cur==="feed")throttle("feed",1500,loadFeed);
  if(has(ch,["#peers","#presence","#net"]))throttle("peers",1500,function(){refreshInfo();if(cur==="people")loadPeople();if(cur==="network")loadNetwork()});
  if(has(ch,["#coin"]))throttle("coin",1200,function(){refreshInfo();if(cur==="wallet")loadWallet()});
  if(has(ch,["#activity"]))throttle("act",1500,function(){refreshInfo();if(cur==="activity")loadActivity()});
  if(has(ch,["#xfers"]))throttle("xfer",800,function(){refreshInfo();if(cur==="transfers")loadTransfers()});
  if(has(ch,["#jobs","#queue"])&&cur==="market")throttle("mk",2000,function(){R.market($("page"))});
}

/* ---------------- shell data ---------------- */
function refreshInfo(){return api("GET","/v1/info").then(function(j){info=j;$("sideName").textContent=j.me.name||short(j.me.id);
  $("sideDot").className="dot"+(j.node.running?" on":"");$("sideStatus").textContent=j.node.running?(j.counts.peers+" linked · "+j.privacy):"node offline";
  $("sideApi").textContent=(j.api.lan?"Open to your network":"This device only")+" · port "+j.api.port;
  $("nodeBtn").innerHTML=ic("power")+"<span>"+(j.node.running?"Disconnect":"Connect")+"</span>";$("nodeBtn").className="btn sm"+(j.node.running?"":" acc");
  setBadge("activity",j.counts.unreadActivity);setBadge("transfers",j.counts.transfers);
  if(cur==="overview")renderOverviewStats();return j}).catch(function(){})}
$("nodeBtn").onclick=function(){var on=info&&info.node.running,b=$("nodeBtn");if(on){confirmBox("Disconnect the node?","Nobody can reach this device until you connect again.","Disconnect",true).then(function(ok){if(ok)toggleNode(b,on)})}else toggleNode(b,on)};
function toggleNode(b,on){b.disabled=true;api("POST","/v1/node",{action:on?"disconnect":"connect"}).then(function(){toast(on?"Node disconnected":"Connecting…");return refreshInfo()}).catch(function(e){toast(e.message,"err")}).then(function(){b.disabled=false})}

var R={};

/* ================= overview ================= */
R.overview=function(el){
  el.innerHTML='<div class="hero" id="hero"><div class="skel" style="width:60%;height:24px"></div></div>'+
   '<div class="grid g6" id="stats" style="margin-top:14px"></div>'+
   '<div class="grid g2" style="margin-top:14px">'+
     '<div class="card"><h3>'+ic("bolt")+'Live on this node<span class="grow"></span><span class="pill" id="liveCount">0</span></h3><div id="liveFeed"></div></div>'+
     '<div class="col" style="gap:14px">'+
       '<div class="card"><h3>'+ic("plus")+'Quick actions</h3><div class="grid g2">'+
         '<button class="btn" data-q="post">'+ic("feed")+'New post</button><button class="btn" data-q="pay">'+ic("coin")+'Send coins</button>'+
         '<button class="btn" data-q="chats">'+ic("chat")+'Open chats</button><button class="btn" data-q="plugins">'+ic("plug")+'Install a plugin</button></div></div>'+
       '<div class="card"><h3>'+ic("bell")+'Recent activity<span class="grow"></span><button class="btn sm ghost" data-q="activity">See all</button></h3><div class="list" id="ovAct">'+skel(3)+'</div></div>'+
     '</div></div>';
  each(el,"[data-q]",function(b){b.onclick=function(){var q=b.getAttribute("data-q");if(q==="post")newPost();else if(q==="pay")payDialog();else go(q)}});
  renderOverviewStats();renderLiveFeed();
  api("GET","/v1/activity").then(function(j){var box=$("ovAct");if(!box)return;var a=j.activity.slice(0,5);box.innerHTML=a.length?a.map(actRow).join(""):empty("bell","Nothing yet");hydrate(box)}).catch(function(){});
};
function renderOverviewStats(){if(!info||!$("hero"))return;var c=info.counts,up=Math.floor(info.api.uptimeMs/60000);
  $("hero").innerHTML=av(info.me.name,info.me.id,64,true)+'<div class="grow"><h2 class="ell">'+esc(info.me.name||"Unnamed")+'</h2><div class="row wrap" style="gap:8px;margin-top:6px">'+
   '<button class="btn sm ghost mono" id="cpId" title="Copy id" style="padding:2px 8px">'+short(info.me.id)+' '+ic("copy")+'</button>'+
   '<span class="pill '+(info.node.running?"ok":"err")+'">'+(info.node.running?"online":"offline")+'</span>'+
   '<span class="pill blue">'+ic("lock")+esc(info.privacy)+'</span><span class="pill">'+ic("globe")+esc(info.node.relay?host(info.node.relay):"no relay")+'</span></div></div>'+
   '<div class="mut sm side-info" style="text-align:right">Console up '+(up<60?up+" min":Math.floor(up/60)+" h")+'<br>'+info.api.clients+' client'+(info.api.clients===1?"":"s")+' · '+(info.api.lan?"LAN":"local")+'</div>';
  hydrate($("hero"));$("cpId").onclick=function(){copy(info.me.id,"Id")};
  function st(icon,tint,v,l,p){return'<div class="card stat" style="cursor:pointer" data-go="'+p+'">'+tile(icon,tint)+'<div class="v">'+esc(v)+'</div><div class="l">'+esc(l)+'</div></div>'}
  $("stats").innerHTML=st("net","t-green",c.peers,"linked now","network")+st("chat","t-blue",c.chats,"chats","chats")+st("coin","t-warn",info.wallet.mentos,"MNT balance","wallet")+
   st("xfer","t-violet",c.transfers,"moving files","transfers")+st("plug","t-gray",c.plugins,"plugins","plugins")+st("bell","t-red",c.unreadActivity,"unread","activity");
  each($("stats"),"[data-go]",function(b){b.onclick=function(){go(b.getAttribute("data-go"))}});
}
function renderLiveFeed(){var el=$("liveFeed");if(!el)return;feedLines=feedLines.slice(0,60);$("liveCount").textContent=feedLines.length;
  el.innerHTML=feedLines.length?feedLines.slice(0,12).map(function(a){return'<div class="feedline"><span class="when">'+hm(a.ts)+'</span><span class="pill" style="flex:none">'+esc(a.k)+'</span><span class="grow">'+esc(a.t)+'</span></div>'}).join(""):empty("bolt","Waiting for something to happen","Messages, notes and network changes appear here as they arrive.")}

/* ================= chats ================= */
var chats=[],openScope=null,chatQ="";
R.chats=function(el){
  el.innerHTML='<div class="chat" id="chatBox"><div class="left"><div class="head"><div class="search">'+ic("search")+'<input id="chatSearch" placeholder="Search chats"></div></div><div class="chatlist" id="chatList">'+skel(6)+'</div></div>'+
   '<div class="thread"><div class="head" id="threadHead"><span class="mut">Pick a chat</span></div><div class="msgs" id="msgs">'+empty("chat","No chat open","Pick someone on the left.")+'</div>'+
   '<form class="composer" id="sendForm"><textarea id="sendText" rows="1" placeholder="Message · Enter to send, Shift+Enter for a new line" disabled></textarea><button class="btn pri icon" id="sendBtn" style="width:44px;height:44px;border-radius:50%" disabled>'+ic("send")+'</button></form></div></div>';
  $("chatSearch").oninput=function(){chatQ=this.value.toLowerCase();drawChats()};
  var ta=$("sendText");ta.addEventListener("input",function(){ta.style.height="auto";ta.style.height=Math.min(ta.scrollHeight,180)+"px"});
  ta.addEventListener("keydown",function(e){if(e.key==="Enter"&&!e.shiftKey){e.preventDefault();$("sendForm").requestSubmit()}});
  $("sendForm").onsubmit=function(ev){ev.preventDefault();var t=ta.value.trim();if(!t||!openScope)return;ta.value="";ta.style.height="auto";
    api("POST","/v1/message",{scope:openScope,text:t}).then(function(){loadThread(true);loadChats(true)}).catch(function(e){ta.value=t;toast(e.message,"err")})};
  loadChats().then(function(){if(openScope)openChat(openScope)});
};
function loadChats(quiet){return api("GET","/v1/chats").then(function(j){chats=j.chats;setBadge("chats",chats.reduce(function(a,c){return a+(c.unread||0)},0));if(cur==="chats"){drawChats();if(openScope&&quiet)loadThread(false)}}).catch(function(e){if(!quiet)toast(e.message,"err")})}
function drawChats(){var el=$("chatList");if(!el)return;var list=chats.filter(function(c){return!chatQ||(c.title+" "+c.last).toLowerCase().indexOf(chatQ)>=0});
  el.innerHTML=list.length?list.map(function(c){return'<div class="ci'+(c.scope===openScope?" sel":"")+'" data-s="'+esc(c.scope)+'"><div style="position:relative">'+av(c.title,c.group?c.scope:c.peer,44,!c.group)+(c.online?'<span class="dot on" style="position:absolute;right:-2px;bottom:-2px;width:11px;height:11px;box-shadow:0 0 0 2px var(--surface)"></span>':'')+'</div>'+
   '<div class="grow"><div class="row" style="gap:6px"><b class="ell grow">'+esc(c.title)+'</b><span class="xs faint">'+ago(c.ts)+'</span></div><div class="row" style="gap:6px"><span class="sm mut ell grow">'+esc(c.last||"No messages yet")+'</span>'+(c.unread?'<span class="badge">'+c.unread+'</span>':'')+'</div></div></div>'}).join(""):empty("chat",chatQ?"No chat matches":"No chats yet");
  hydrate(el);each(el,"[data-s]",function(x){x.onclick=function(){openChat(x.getAttribute("data-s"))}})}
function openChat(scope){openScope=scope;var box=$("chatBox");if(!box)return;box.classList.add("open");drawChats();var c=chats.filter(function(x){return x.scope===scope})[0];
  $("threadHead").innerHTML='<button class="btn icon ghost back" id="backBtn">'+ic("back")+'</button>'+(c?av(c.title,c.group?c.scope:c.peer,38,!c.group):"")+'<div class="grow"><b class="ell" style="display:block">'+esc(c?c.title:"Chat")+'</b><div class="xs mut">'+(c&&c.online?'<span style="color:var(--accent)">online</span>':(c&&c.group?"group":"offline · messages deliver when they are back"))+'</div></div>'+(c&&!c.group?'<button class="btn sm ghost icon" id="tPay" title="Send coins">'+ic("coin")+'</button>':'');
  hydrate($("threadHead"));$("backBtn").onclick=function(){box.classList.remove("open");openScope=null;drawChats()};if($("tPay"))$("tPay").onclick=function(){payDialog(c.peer)};
  $("sendText").disabled=false;$("sendBtn").disabled=false;$("sendText").focus();$("msgs").innerHTML=skel(5);loadThread(true)}
function loadThread(scroll){if(!openScope)return;var scope=openScope,c=chats.filter(function(x){return x.scope===scope})[0];
  api("GET","/v1/messages?scope="+encodeURIComponent(scope)+"&limit=150").then(function(j){var th=$("msgs");if(!th||scope!==openScope)return;var atEnd=th.scrollTop+th.clientHeight>=th.scrollHeight-40,lastDay="",html="";
    j.messages.forEach(function(m){var d=dayLabel(m.ts);if(d!==lastDay){html+='<div class="day">'+d+'</div>';lastDay=d}var r=m.reactions||{},keys=Object.keys(r);
      html+='<div class="bub'+(m.mine?" me":"")+'">'+(!m.mine&&c&&c.group?'<div class="who">'+esc(m.name)+'</div>':'')+(m.text?linkify(m.text):'<i class="mut">'+(m.media?"📎 "+m.media+" attachment"+(m.media>1?"s":""):"empty message")+'</i>')+
       (keys.length?'<div class="reacts">'+keys.map(function(k){return'<span>'+esc(k)+(r[k].length>1?" "+r[k].length:"")+'</span>'}).join("")+'</div>':'')+'<div class="meta">'+(m.edited?"edited · ":"")+hm(m.ts)+'</div></div>'});
    th.innerHTML=html||empty("chat","Say hello","Messages are end-to-end encrypted.");if(scroll||atEnd)th.scrollTop=th.scrollHeight}).catch(function(){})}

/* ================= feed ================= */
R.feed=function(el){
  el.innerHTML='<div class="feed"><div class="card"><div class="row" style="align-items:flex-start">'+(info?av(info.me.name,info.me.id,42,true):"")+'<div class="grow"><textarea id="postText" rows="3" placeholder="What\'s happening? #tags work"></textarea><div class="row" style="margin-top:8px"><span class="xs faint grow" id="postCount">0 / 5000</span><button class="btn pri" id="postBtn">'+ic("send")+'Post</button></div></div></div></div><div id="posts" class="col" style="gap:14px">'+skel(6)+'</div></div>';
  hydrate(el);var ta=$("postText");ta.oninput=function(){$("postCount").textContent=ta.value.length+" / 5000"};
  ta.addEventListener("keydown",function(e){if(e.key==="Enter"&&(e.ctrlKey||e.metaKey))$("postBtn").click()});
  $("postBtn").onclick=function(){var t=ta.value.trim();if(!t)return;$("postBtn").disabled=true;api("POST","/v1/post",{text:t}).then(function(){ta.value="";$("postCount").textContent="0 / 5000";toast("Posted");loadFeed()}).catch(function(e){toast(e.message,"err")}).then(function(){$("postBtn").disabled=false})};
  loadFeed();
};
function loadFeed(){api("GET","/v1/feed?limit=80").then(function(j){var el=$("posts");if(!el)return;
  el.innerHTML=j.posts.length?j.posts.map(function(p){var pics=p.media.filter(function(x){return x.mime.indexOf("image/")===0}).slice(0,4),imgs="";
    if(pics.length)imgs='<div class="imgs n'+pics.length+'">'+pics.map(function(m){return'<div data-img="/v1/media/post/'+esc(p.id)+'/'+m.i+'"></div>'}).join("")+'</div>';
    return'<article class="card post"><div class="ph">'+av(p.mine&&info?info.me.name:p.name,p.author,42,true)+'<div class="grow"><b>'+esc(p.mine?"You":p.name)+'</b>'+(p.ai?' <span class="pill blue">AI</span>':'')+(p.nsfw?' <span class="pill err">NSFW</span>':'')+'<div class="xs mut">'+ago(p.ts)+(p.edited?" · edited":"")+'</div></div></div>'+
     (p.text?'<div class="txt">'+linkify(p.text)+'</div>':'')+imgs+
     '<div class="acts"><button data-like="'+esc(p.id)+'" data-on="'+(p.liked?1:0)+'" class="'+(p.liked?"on":"")+'">'+ic("heart")+'<span>'+p.likes+'</span></button><button disabled>'+ic("comment")+p.comments+'</button>'+(p.mine?'<button disabled>'+ic("eye")+p.views+'</button>':'')+'</div></article>'}).join(""):'<div class="card">'+empty("feed","Your feed is empty","Follow people to see their posts here.")+'</div>';
  hydrate(el);each(el,"[data-like]",function(b){b.onclick=function(){var on=b.getAttribute("data-on")!=="1",cnt=b.querySelector("span");b.classList.toggle("on",on);b.setAttribute("data-on",on?1:0);cnt.textContent=Math.max(0,(+cnt.textContent)+(on?1:-1));
    api("POST","/v1/like",{id:b.getAttribute("data-like"),on:on}).catch(function(e){toast(e.message,"err");loadFeed()})}})}).catch(function(e){toast(e.message,"err")})}
function newPost(){go("feed");setTimeout(function(){var t=$("postText");if(t)t.focus()},60)}

/* ================= people ================= */
var peopleTab="all",peopleQ="";
R.people=function(el){
  el.innerHTML='<div class="row wrap" style="margin-bottom:14px"><div class="search grow" style="min-width:220px">'+ic("search")+'<input id="pplSearch" placeholder="Search people"></div><div class="chips" id="pplTabs"></div></div><div class="grid g3" id="ppl">'+skel(6)+'</div>';
  $("pplSearch").value=peopleQ;$("pplSearch").oninput=function(){peopleQ=this.value.toLowerCase();loadPeople()};loadPeople();
};
function loadPeople(){api("GET","/v1/people").then(function(j){var tabs={all:"All",online:"Online",following:"Following",followers:"Followers"},el=$("ppl");if(!el)return;
  var counts={all:0,online:0,following:0,followers:0};j.people.forEach(function(p){if(p.blocked)return;counts.all++;if(p.online)counts.online++;if(p.iFollow)counts.following++;if(p.followsMe)counts.followers++});
  $("pplTabs").innerHTML=Object.keys(tabs).map(function(k){return'<button class="chip'+(k===peopleTab?" sel":"")+'" data-t="'+k+'">'+tabs[k]+' <span class="faint">'+counts[k]+'</span></button>'}).join("");
  each($("pplTabs"),"[data-t]",function(b){b.onclick=function(){peopleTab=b.getAttribute("data-t");loadPeople()}});
  var list=j.people.filter(function(p){if(p.blocked)return false;if(peopleTab==="online"&&!p.online)return false;if(peopleTab==="following"&&!p.iFollow)return false;if(peopleTab==="followers"&&!p.followsMe)return false;return!peopleQ||(p.name+" "+p.bio).toLowerCase().indexOf(peopleQ)>=0});
  el.innerHTML=list.length?list.map(function(p){return'<div class="card flat"><div class="row">'+av(p.name,p.id,52,p.avatar)+'<div class="grow"><b class="ell" style="display:block">'+esc(p.name)+'</b><div class="xs mut row" style="gap:6px"><span class="dot '+(p.online?"on":"")+'" style="width:7px;height:7px;box-shadow:none"></span>'+(p.online?"online":(p.lastSeen?"seen "+ago(p.lastSeen):"offline"))+(p.followsMe?' · <span style="color:var(--accent)">follows you</span>':'')+'</div></div></div>'+
   (p.bio?'<p class="sm mut" style="margin:10px 0 0">'+esc(p.bio)+'</p>':'')+'<div class="row" style="margin-top:12px"><button class="btn sm '+(p.iFollow?"":"acc")+'" data-f="'+esc(p.id)+'" data-on="'+(p.iFollow?0:1)+'">'+(p.iFollow?"Following":(p.followsMe?"Follow back":"Follow"))+'</button><button class="btn sm" data-m="'+esc(p.scope)+'">'+ic("chat")+'Message</button><span class="grow"></span><button class="btn sm ghost icon" data-pay="'+esc(p.id)+'" title="Send coins">'+ic("coin")+'</button><button class="btn sm ghost icon" data-c="'+esc(p.id)+'" title="Copy id">'+ic("copy")+'</button></div></div>'}).join(""):'<div class="card" style="grid-column:1/-1">'+empty("people","Nobody here","Add people in the app by scanning their code.")+'</div>';
  hydrate(el);
  each(el,"[data-f]",function(b){b.onclick=function(){b.disabled=true;api("POST","/v1/follow",{id:b.getAttribute("data-f"),on:b.getAttribute("data-on")==="1"}).then(loadPeople).catch(function(e){b.disabled=false;toast(e.message,"err")})}});
  each(el,"[data-m]",function(b){b.onclick=function(){openScope=b.getAttribute("data-m");go("chats")}});
  each(el,"[data-c]",function(b){b.onclick=function(){copy(b.getAttribute("data-c"),"Id")}});
  each(el,"[data-pay]",function(b){b.onclick=function(){payDialog(b.getAttribute("data-pay"))}});
 }).catch(function(e){toast(e.message,"err")})}

/* ================= activity ================= */
var ACT_ICON={follow:["people","t-green"],comment:["comment","t-blue"],reply:["comment","t-blue"],like:["heart","t-red"],coin:["coin","t-warn"],market:["market","t-violet"],xfer:["xfer","t-blue"],mention:["chat","t-blue"],invite:["plus","t-green"],sync:["refresh","t-gray"]};
function actRow(a){var ic2=ACT_ICON[a.kind]||["bell","t-gray"];
  return'<div class="it"><div style="position:relative">'+av(a.name,a.actor,40,true)+'<div style="position:absolute;right:-6px;bottom:-6px;border:2px solid var(--surface);border-radius:9px">'+tile(ic2[0],ic2[1],20)+'</div></div><div class="grow"><div class="ell"><b>'+esc(a.name)+'</b> <span class="mut">'+esc(a.kind)+'</span></div>'+(a.text?'<div class="sm mut ell">'+esc(a.text)+'</div>':'')+'</div><span class="row xs faint" style="gap:6px">'+(a.seen?"":'<span class="dot on" style="width:7px;height:7px;box-shadow:none"></span>')+ago(a.ts)+'</span></div>'}
R.activity=function(el){el.innerHTML='<div class="card"><div class="list" id="act">'+skel(8)+'</div></div>';loadActivity()};
function loadActivity(){api("GET","/v1/activity").then(function(j){var el=$("act");if(!el)return;el.innerHTML=j.activity.length?j.activity.map(actRow).join(""):empty("bell","No activity yet","Follows, comments, likes and payments land here.");hydrate(el)}).catch(function(e){toast(e.message,"err")})}

/* ================= wallet ================= */
var hideBal=pref("mentosHideBal")==="1",txFilter="all",wallet=null;
R.wallet=function(el){
  el.innerHTML='<div class="grid g2"><div class="hero" style="flex-direction:column;align-items:flex-start;gap:6px"><div class="row" style="width:100%"><span class="mut sm grow">Available balance</span><button class="btn sm ghost icon" id="hideBtn"></button></div><div id="bal" style="font-size:44px;font-weight:750;letter-spacing:-.04em;font-variant-numeric:tabular-nums;line-height:1.1">—</div><div class="row wrap" style="margin-top:8px"><button class="btn acc" id="payBtn">'+ic("send")+'Send coins</button><button class="btn" id="cpAddr">'+ic("copy")+'Copy my address</button></div></div>'+
   '<div class="card"><h3>'+ic("coin")+'Last 30 days</h3><div class="grid g2" id="wStats">'+skel(2)+'</div></div></div>'+
   '<div class="card" style="margin-top:14px"><div class="row wrap" style="margin-bottom:10px"><h3 style="margin:0" class="grow">History</h3><div class="chips" id="txTabs"></div></div><div style="overflow-x:auto"><table id="txTable"></table></div></div>';
  $("payBtn").onclick=function(){payDialog()};$("cpAddr").onclick=function(){if(info)copy(info.me.id,"Address")};
  $("hideBtn").onclick=function(){hideBal=!hideBal;pref("mentosHideBal",hideBal?"1":"0");drawWallet()};loadWallet();
};
function loadWallet(){api("GET","/v1/wallet").then(function(j){wallet=j;drawWallet()}).catch(function(e){toast(e.message,"err")})}
var ESCROW=["lock","ack","release","refund","cancel","claim","dispute"];
function drawWallet(){if(!wallet||!$("bal"))return;var me=info?info.me.id:"";$("hideBtn").innerHTML=ic(hideBal?"eye":"eyeoff");$("hideBtn").title=hideBal?"Show balance":"Hide balance";$("bal").innerHTML=(hideBal?"••••••":esc(wallet.mentos))+' <span class="mut" style="font-size:18px">MNT</span>';
  var month=Date.now()-30*864e5,inn=0,out=0,n=0;wallet.txs.forEach(function(t){if(t.ts<month)return;n++;if(t.to===me&&t.from!==me)inn+=t.amount;else if(t.from===me&&t.kind==="send")out+=t.amount});
  function f(m){return hideBal?"•••":(m/100).toFixed(2)}
  $("wStats").innerHTML='<div class="stat" style="padding:0">'+tile("down","t-green")+'<div class="v">'+f(inn)+'</div><div class="l">received</div></div><div class="stat" style="padding:0">'+tile("up","t-gray")+'<div class="v">'+f(out)+'</div><div class="l">sent · '+n+' records</div></div>';
  var tabs={all:"All",in:"Received",out:"Sent",escrow:"Escrow"};$("txTabs").innerHTML=Object.keys(tabs).map(function(k){return'<button class="chip'+(k===txFilter?" sel":"")+'" data-t="'+k+'">'+tabs[k]+'</button>'}).join("");
  each($("txTabs"),"[data-t]",function(b){b.onclick=function(){txFilter=b.getAttribute("data-t");drawWallet()}});
  var list=wallet.txs.filter(function(t){var incoming=t.to===me&&t.from!==me;if(txFilter==="in")return incoming;if(txFilter==="out")return t.from===me&&t.kind==="send";if(txFilter==="escrow")return ESCROW.indexOf(t.kind)>=0;return true});
  $("txTable").innerHTML='<tr><th style="width:46px"></th><th>With</th><th>Kind</th><th>When</th><th class="num">Amount</th></tr>'+(list.length?list.map(function(t){var incoming=(t.to===me&&t.from!==me)||t.kind==="mint";var other=t.kind==="mint"?"Network treasury":(incoming?t.fromName:t.toName);
    var icon=t.kind==="mint"?["star","t-violet"]:ESCROW.indexOf(t.kind)>=0?["lock","t-warn"]:incoming?["down","t-green"]:["up","t-gray"];
    return'<tr class="click" data-i="'+wallet.txs.indexOf(t)+'"><td>'+tile(icon[0],icon[1],32)+'</td><td><b>'+esc(other)+'</b>'+(t.memo?'<div class="xs mut ell" style="max-width:280px">'+esc(t.memo)+'</div>':'')+'</td><td><span class="pill">'+esc(t.kind)+'</span></td><td class="mut sm" title="'+esc(new Date(t.ts).toLocaleString())+'">'+ago(t.ts)+'</td><td class="num mono" style="font-size:14px;color:'+(incoming?"var(--accent)":"var(--ink)")+'">'+(hideBal?"•••":(incoming?"+":"−")+esc(t.mentos))+'</td></tr>'}).join(""):'<tr><td colspan="5">'+empty("coin","No transactions here")+'</td></tr>');
  each($("txTable"),"[data-i]",function(r){r.onclick=function(){txDialog(wallet.txs[+r.getAttribute("data-i")])}})}
function txDialog(t){var me=info?info.me.id:"",incoming=(t.to===me&&t.from!==me)||t.kind==="mint";
  modal('<div style="text-align:center"><div style="display:flex;justify-content:center;margin-bottom:10px">'+tile(incoming?"down":"up",incoming?"t-green":"t-gray",52)+'</div><div class="mut sm">'+esc(t.kind)+'</div><div style="font-size:36px;font-weight:750;letter-spacing:-.03em">'+(incoming?"+":"−")+esc(t.mentos)+' <span class="mut" style="font-size:16px">MNT</span></div><div class="sm mut">'+new Date(t.ts).toLocaleString()+'</div></div>'+
   (t.memo?'<p style="text-align:center;margin:14px 0">“'+esc(t.memo)+'”</p>':'')+'<table style="margin-top:12px"><tr><th>From</th><td>'+esc(t.fromName)+'<div class="mono xs mut">'+esc(t.from)+'</div></td></tr><tr><th>To</th><td>'+esc(t.toName)+'<div class="mono xs mut">'+esc(t.to)+'</div></td></tr><tr><th>Hash</th><td class="mono xs">'+esc(t.hash)+'</td></tr></table>'+
   '<div class="row" style="justify-content:flex-end;margin-top:16px"><button class="btn" data-copy>'+ic("copy")+'Copy hash</button><button class="btn pri" data-close>Done</button></div>',function(m){m.querySelector("[data-copy]").onclick=function(){copy(t.hash,"Hash")}})}
function payDialog(preset){api("GET","/v1/people").then(function(j){var opts=j.people.filter(function(p){return!p.blocked}).map(function(p){return'<option value="'+esc(p.id)+'"'+(p.id===preset?" selected":"")+'>'+esc(p.name)+'</option>'}).join("");
  modal('<h2>Send coins</h2><p class="mut sm" style="margin-top:0">Payments are signed by your node and can\'t be undone.</p><form id="payForm" class="col"><select id="payTo"><option value="">Send to…</option>'+opts+'</select><div class="row"><input id="payAmt" placeholder="Amount (MNT)" inputmode="decimal"><input id="payMemo" placeholder="Note (optional)" maxlength="140"></div><div class="row" style="justify-content:flex-end;margin-top:6px"><button type="button" class="btn" data-close>Cancel</button><button class="btn acc">'+ic("send")+'Review</button></div></form>',function(m,close){
   m.querySelector("#payAmt").focus();
   m.querySelector("#payForm").onsubmit=function(ev){ev.preventDefault();var to=m.querySelector("#payTo").value,amt=m.querySelector("#payAmt").value.trim(),memo=m.querySelector("#payMemo").value.trim();if(!to||!amt||!(+amt>0)){toast("Pick someone and an amount","err");return}
    var name=m.querySelector("#payTo").selectedOptions[0].textContent;close();confirmBox("Send "+amt+" MNT to "+name+"?","This can't be undone.","Send").then(function(ok){if(!ok)return;api("POST","/v1/pay",{to:to,amount:amt,memo:memo}).then(function(){toast("Sent "+amt+" MNT to "+name);refreshInfo();if(cur==="wallet")loadWallet()}).catch(function(e){toast(e.message,"err")})})}})}).catch(function(e){toast(e.message,"err")})}

/* ================= market ================= */
var mKind="";
R.market=function(el){var kinds={"":"Everything",plugin:"Plugins",item:"Shop",task:"Tasks",exchange:"Exchange",resource:"Resources",ad:"Ads"};
  el.innerHTML='<div class="chips" id="mk" style="margin-bottom:14px"></div><div class="grid g3" id="mlist">'+skel(6)+'</div>';
  $("mk").innerHTML=Object.keys(kinds).map(function(k){return'<button class="chip'+(k===mKind?" sel":"")+'" data-k="'+k+'">'+kinds[k]+'</button>'}).join("");
  each($("mk"),"[data-k]",function(b){b.onclick=function(){mKind=b.getAttribute("data-k");R.market(el)}});
  api("GET","/v1/market"+(mKind?"?kind="+mKind:"")).then(function(j){var box=$("mlist");if(!box)return;var look={plugin:["plug","t-violet"],item:["market","t-blue"],task:["check","t-green"],exchange:["coin","t-warn"],resource:["net","t-gray"],ad:["bolt","t-red"]};
   box.innerHTML=j.listings.length?j.listings.map(function(l){var lk=look[l.kind]||["market","t-gray"];return'<div class="card flat"><div class="row">'+tile(lk[0],lk[1])+'<div class="grow"><b class="ell" style="display:block">'+esc(l.title)+'</b><div class="xs mut ell">'+esc(l.kind)+' · '+esc(l.mine?"you":l.name)+' · '+ago(l.ts)+'</div></div><b class="mono" style="color:var(--accent);font-size:14px">'+(l.price?esc(l.mentos):"Free")+'</b></div>'+(l.about?'<p class="sm mut" style="margin:10px 0 0;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden">'+esc(l.about)+'</p>':'')+'</div>'}).join(""):'<div class="card" style="grid-column:1/-1">'+empty("market","Nothing listed","Listings from people on the network show up here.")+'</div>'}).catch(function(e){toast(e.message,"err")})};

/* ================= network ================= */
R.network=function(el){el.innerHTML='<div class="grid g4" id="netStats">'+skel(2)+'</div><div class="grid g2" style="margin-top:14px"><div class="card"><h3>'+ic("people")+'Active connections<span class="grow"></span><button class="btn sm ghost icon" id="netRf" title="Refresh">'+ic("refresh")+'</button></h3><div class="list" id="peers">'+skel(4)+'</div></div><div class="card"><h3>'+ic("globe")+'Relays</h3><div class="list" id="relays">'+skel(3)+'</div><form id="relayForm" class="row" style="margin-top:12px"><input id="relayUrl" placeholder="https://relay.example" class="mono"><button class="btn">Use</button></form><button class="btn sm ghost" id="relayAuto" style="margin-top:8px">'+ic("refresh")+'Back to automatic</button></div></div>';
  $("netRf").onclick=loadNetwork;$("relayForm").onsubmit=function(ev){ev.preventDefault();var u=$("relayUrl").value.trim();if(u)useRelay(u)};$("relayAuto").onclick=function(){useRelay(null)};loadNetwork()};
function loadNetwork(){Promise.all([api("GET","/v1/peers"),api("GET","/v1/status")]).then(function(r){var j=r[0],s=r[1];if(!$("peers"))return;var direct=j.peers.filter(function(p){return p.link==="direct"}).length;
  function st(icon,t,v,l){return'<div class="card stat">'+tile(icon,t)+'<div class="v">'+esc(v)+'</div><div class="l">'+esc(l)+'</div></div>'}
  $("netStats").innerHTML=st("people","t-green",j.peers.length,"linked")+st("bolt","t-warn",direct,"direct paths")+st("globe","t-blue",j.atlas+1,"nodes on the network")+st("net","t-violet",(s.relays||[]).length,"relays measured");
  $("peers").innerHTML=j.peers.length?j.peers.map(function(p){var ms=p.latencyMs,w=ms==null?0:Math.max(8,Math.min(100,100-ms/4));return'<div class="it">'+av(p.name,p.id,38,true)+'<div class="grow"><b class="ell" style="display:block">'+esc(p.name)+'</b><div class="xs mut mono">'+short(p.id)+(p.bps?" · "+bytes(p.bps)+"/s":"")+'</div></div><span class="pill '+(p.link==="direct"?"ok":"blue")+'">'+esc(p.link||"?")+'</span><div style="width:84px"><div class="xs mut num">'+(ms!=null?ms+" ms":"—")+'</div><div class="bar"><div style="width:'+w+'%"></div></div></div></div>'}).join(""):empty("people","No one connected right now",j.atlas+" other nodes are known on the network.");hydrate($("peers"));
  var urls=(s.relays||[]).slice(),counts={};j.relays.forEach(function(x){counts[x.url]=x.nodes;if(urls.indexOf(x.url)<0)urls.push(x.url)});
  $("relays").innerHTML=urls.length?urls.map(function(u){var home=u===s.relay,pin=u===s.preferredRelay;return'<div class="it">'+tile("globe",home?"t-green":"t-gray",32)+'<div class="grow"><div class="mono ell">'+esc(u.replace(/^https?:\/\//,""))+'</div><div class="xs mut">'+(counts[u]||0)+' node'+((counts[u]||0)===1?"":"s")+(home?" · home relay":"")+(pin?" · pinned":"")+'</div></div><button class="btn sm" data-u="'+esc(u)+'"'+(pin?" disabled":"")+'>'+(pin?"In use":"Use")+'</button></div>'}).join(""):empty("globe","No relays known yet");
  each($("relays"),"[data-u]",function(b){b.onclick=function(){useRelay(b.getAttribute("data-u"))}})}).catch(function(e){toast(e.message,"err")})}
function useRelay(u){api("POST","/v1/relay",{url:u}).then(function(){toast(u?"New connections use "+host(u):"Relays are automatic again");loadNetwork()}).catch(function(e){toast(e.message,"err")})}

/* ================= transfers ================= */
R.transfers=function(el){el.innerHTML='<div class="card"><div class="list" id="xf">'+skel(4)+'</div></div>';loadTransfers()};
function loadTransfers(){api("GET","/v1/transfers").then(function(j){var el=$("xf");if(!el)return;var tone={done:"ok",active:"blue",queued:"",offer:"warn",paused:"",failed:"err",declined:"err",cancelled:"err"};
  el.innerHTML=j.transfers.length?j.transfers.map(function(t){var down=t.dir==="inbound",pct=t.size?Math.round(t.done/t.size*100):0;return'<div class="it">'+tile(down?"down":"up",down?"t-green":"t-blue")+'<div class="grow"><div class="row"><b class="ell grow">'+esc(t.file)+'</b><span class="pill '+(tone[t.state]||"")+'">'+esc(t.state)+'</span></div><div class="xs mut">'+(down?"from ":"to ")+esc(t.name)+' · '+bytes(t.done)+' of '+bytes(t.size)+(t.bps?" · "+bytes(t.bps)+"/s":"")+'</div><div class="bar" style="margin-top:6px"><div style="width:'+pct+'%;'+(t.state==="failed"?"background:var(--danger)":"")+'"></div></div></div></div>'}).join(""):empty("xfer","No transfers","Files you send or receive show progress here.")}).catch(function(){})}

/* ================= plugins ================= */
var TEMPLATE='/* @plugin {"id": "hello", "name": "Hello", "version": "0.1.0", "permissions": ["commands", "notify"]} */\nmentos.commands.add("hello", "Say hi", (args) => {\n  mentos.notify("Hello ran");\n  return `Hello ${args || "world"} 👋`;\n});\n';
R.plugins=function(el){
  el.innerHTML='<div class="grid g2"><div class="card"><h3>'+ic("plug")+'Installed<span class="grow"></span><button class="btn sm ghost icon" id="plRf" title="Refresh">'+ic("refresh")+'</button></h3><div class="list" id="plList">'+skel(4)+'</div></div>'+
   '<div class="card"><h3>'+ic("code")+'Install or hot-reload</h3><p class="sm mut" style="margin-top:0">Paste a single-file plugin or a plugin.json link. Installing an id that exists replaces it and restarts it instantly.</p><form id="plForm" class="col"><input id="plUrl" placeholder="https://…/plugin.json" class="mono"><textarea id="plSrc" rows="10" class="mono" spellcheck="false" placeholder="/* @plugin {…} */"></textarea><div class="row"><button type="button" class="btn sm ghost" id="plTpl">Use a template</button><span class="grow"></span><button class="btn pri">'+ic("dl")+'Install</button></div></form></div></div>'+
   '<div class="card" style="margin-top:14px"><h3>'+ic("star")+'From the registries<span class="grow"></span><span class="xs mut" id="regNote"></span></h3><div class="grid g3" id="reg">'+skel(3)+'</div></div>'+
   '<div class="card" style="margin-top:14px"><h3>'+ic("log")+'Plugin log</h3><div class="log" id="plLog" style="height:240px;min-height:0"></div></div>';
  $("plRf").onclick=loadPlugins;$("plTpl").onclick=function(){$("plSrc").value=TEMPLATE};
  $("plSrc").addEventListener("keydown",function(e){if(e.key==="Tab"){e.preventDefault();var s=this.selectionStart;this.value=this.value.slice(0,s)+"  "+this.value.slice(this.selectionEnd);this.selectionStart=this.selectionEnd=s+2}});
  $("plForm").onsubmit=function(ev){ev.preventDefault();var u=$("plUrl").value.trim(),s=$("plSrc").value;if(!u&&!s.trim())return;api("POST","/v1/plugins",u?{url:u}:s).then(function(r){toast(r.error?"Installed but it failed to start: "+r.error:"Installed "+r.id,r.error?"err":"");loadPlugins()}).catch(function(e){toast(e.message,"err")})};
  loadPlugins();loadRegistry();loadLogs();drawLogs();
};
function loadPlugins(){api("GET","/v1/plugins").then(function(j){var el=$("plList");if(!el)return;
  el.innerHTML=j.plugins.length?j.plugins.map(function(p){var st=p.error?'<span class="pill err">error</span>':(p.running?'<span class="pill ok">running</span>':'<span class="pill">off</span>');var meta=[p.commands.map(function(c){return"/"+c}).join(" "),p.pages.length?p.pages.length+" page"+(p.pages.length>1?"s":""):""].filter(Boolean).join(" · ");
   return'<div class="it" style="align-items:flex-start">'+tile("plug","t-violet")+'<div class="grow"><div class="row wrap" style="gap:6px"><b>'+esc(p.name)+'</b><span class="xs mut">v'+esc(p.version)+'</span>'+st+'</div><div class="sm mut ell">'+esc(p.error||p.description||"")+'</div>'+(meta?'<div class="xs mono faint ell">'+esc(meta)+'</div>':'')+'</div><label class="switch" title="Enabled"><input type="checkbox" data-id="'+esc(p.id)+'"'+(p.enabled?" checked":"")+'><span></span></label><button class="btn sm ghost icon" data-r="'+esc(p.id)+'" title="Reload">'+ic("refresh")+'</button><button class="btn sm ghost icon dan" data-d="'+esc(p.id)+'" title="Remove">'+ic("trash")+'</button></div>'}).join(""):empty("plug","No plugins yet","Install one from the registries below, or paste your own.");
  each(el,"input[data-id]",function(c){c.onchange=function(){api("POST","/v1/plugins/"+c.getAttribute("data-id")+"/"+(c.checked?"enable":"disable")).then(loadPlugins).catch(function(e){toast(e.message,"err")})}});
  each(el,"[data-r]",function(b){b.onclick=function(){api("POST","/v1/plugins/"+b.getAttribute("data-r")+"/reload").then(function(r){toast(r.error?"Failed: "+r.error:"Reloaded",r.error?"err":"");loadPlugins()}).catch(function(e){toast(e.message,"err")})}});
  each(el,"[data-d]",function(b){b.onclick=function(){var id=b.getAttribute("data-d");confirmBox("Remove "+id+"?","Its saved data on this device is deleted too.","Remove",true).then(function(ok){if(ok)api("DELETE","/v1/plugins/"+id).then(function(){loadPlugins();loadRegistry()}).catch(function(e){toast(e.message,"err")})})}})}).catch(function(e){toast(e.message,"err")})}
function loadRegistry(){api("GET","/v1/plugins/registry").then(function(j){var el=$("reg");if(!el)return;var failed=Object.keys(j.failed||{}).length;$("regNote").textContent=j.plugins.length+" available"+(failed?" · "+failed+" registry unreachable":"");
  el.innerHTML=j.plugins.length?j.plugins.map(function(p){var have=p.installed,upd=have&&have!==p.version;return'<div class="card flat col" style="gap:8px"><div class="row">'+tile("plug","t-violet")+'<div class="grow"><b class="ell" style="display:block">'+esc(p.name)+'</b><div class="xs mut">'+esc(p.author||"")+' · v'+esc(p.version)+'</div></div></div><p class="sm mut grow" style="margin:0">'+esc(p.description||"")+'</p><div class="row"><span class="xs faint grow ell">'+((p.permissions||[]).map(esc).join(", ")||"no permissions")+'</span>'+(have&&!upd?'<span class="pill ok">'+ic("check")+'installed</span>':'<button class="btn sm acc" data-get="'+esc(p.manifestUrl)+'" data-sha="'+esc(p.sha256||"")+'" data-perm="'+esc((p.permissions||[]).join(", ")||"nothing extra")+'" data-name="'+esc(p.name)+'">'+(upd?"Update":"Install")+'</button>')+'</div></div>'}).join(""):'<div style="grid-column:1/-1">'+empty("star","Couldn't reach the registries")+'</div>';
  each(el,"[data-get]",function(b){b.onclick=function(){confirmBox("Install "+b.getAttribute("data-name")+"?","It will be able to use: "+b.getAttribute("data-perm")+".","Install").then(function(ok){if(!ok)return;b.disabled=true;var body={url:b.getAttribute("data-get")};if(b.getAttribute("data-sha"))body.sha256=b.getAttribute("data-sha");api("POST","/v1/plugins",body).then(function(){toast("Installed");loadPlugins();loadRegistry()}).catch(function(e){b.disabled=false;toast(e.message,"err")})})}})}).catch(function(){var el=$("reg");if(el)el.innerHTML='<div style="grid-column:1/-1">'+empty("star","Couldn't reach the registries")+'</div>'})}

/* ================= logs ================= */
var logLines=[],lastLog=0,logBusy=false,logPaused=false,logKind="all",logQ="";
R.logs=function(el){
  el.innerHTML='<div class="row wrap" style="margin-bottom:12px"><div class="chips" id="lkinds"></div><div class="search grow" style="min-width:200px">'+ic("search")+'<input id="logSearch" placeholder="Filter lines"></div><button class="btn sm" id="logPause"></button><button class="btn sm" id="logDl">'+ic("dl")+'Download</button><button class="btn sm ghost" id="logClear">'+ic("trash")+'Clear</button></div><div class="log" id="logView"></div>';
  var kinds={all:"All",api:"API",ev:"Events",pl:"Plugins",e:"Errors"};$("lkinds").innerHTML=Object.keys(kinds).map(function(k){return'<button class="chip'+(k===logKind?" sel":"")+'" data-k="'+k+'">'+kinds[k]+'</button>'}).join("");
  each($("lkinds"),"[data-k]",function(b){b.onclick=function(){logKind=b.getAttribute("data-k");R.logs(el)}});
  $("logSearch").value=logQ;$("logSearch").oninput=function(){logQ=this.value.toLowerCase();drawLogs(true)};
  function pb(){$("logPause").innerHTML=ic(logPaused?"play":"pause")+(logPaused?"Resume":"Pause")}pb();$("logPause").onclick=function(){logPaused=!logPaused;pb();if(!logPaused)drawLogs(true)};
  $("logClear").onclick=function(){logLines=[];drawLogs(true)};
  $("logDl").onclick=function(){var txt=logLines.map(function(l){return new Date(l.ts).toISOString()+"  "+l.k+"  "+l.t}).join("\n");var a=document.createElement("a");a.href=URL.createObjectURL(new Blob([txt],{type:"text/plain"}));a.download="mentos-log-"+Date.now()+".txt";a.click()};
  loadLogs();drawLogs(true);
};
function loadLogs(){if(logBusy)return;logBusy=true;api("GET","/v1/logs?since="+lastLog).then(function(j){
  j.requests.forEach(function(r){logLines.push({ts:r.ts,c:"api"+(r.status>=400?" e":""),k:"api",t:r.method+" "+r.path+" → "+r.status+" ("+r.ms+" ms) "+r.ip})});
  j.events.forEach(function(e){logLines.push({ts:e.ts,c:"ev",k:e.kind,t:e.text})});
  j.plugins.forEach(function(p){logLines.push({ts:p.ts,c:"pl"+(p.level==="error"?" e":""),k:"plugin",t:p.plugin+": "+p.text})});
  lastLog=j.now;logLines.sort(function(a,b){return a.ts-b.ts});if(logLines.length>3000)logLines=logLines.slice(-3000);drawLogs(false)}).catch(function(){}).then(function(){logBusy=false})}
function drawLogs(force){
  var pl=$("plLog");if(pl){var pls=logLines.filter(function(l){return l.c.indexOf("pl")===0}).slice(-200);pl.innerHTML=pls.length?pls.map(line).join(""):'<div class="faint" style="border:0">Plugin output shows here.</div>';pl.scrollTop=pl.scrollHeight}
  var el=$("logView");if(!el||(logPaused&&!force))return;var list=logLines.filter(function(l){if(logKind==="e"&&l.c.indexOf(" e")<0)return false;if(logKind!=="all"&&logKind!=="e"&&l.c.indexOf(logKind)!==0)return false;return!logQ||(l.k+" "+l.t).toLowerCase().indexOf(logQ)>=0}).slice(-800);
  var end=el.scrollTop+el.clientHeight>=el.scrollHeight-40;el.innerHTML=list.length?list.map(line).join(""):'<div class="faint" style="border:0">Nothing logged yet. Requests, node events and plugin output stream in here.</div>';if(end||force)el.scrollTop=el.scrollHeight}
function line(l){return'<div class="'+l.c+'"><span class="t">'+hms(l.ts)+'</span><span class="k">'+esc(l.k)+'</span><span class="grow">'+esc(l.t)+'</span></div>'}

/* ================= api ================= */
R.api=function(el){
  el.innerHTML='<div class="grid g2"><div class="card"><h3>'+ic("code")+'Routes</h3><p class="sm mut" style="margin-top:0">Every /v1 call needs <span class="mono">Authorization: Bearer &lt;access code&gt;</span>. Click a route to try it.</p><div class="list" id="routes">'+skel(8)+'</div></div>'+
   '<div class="card"><h3>'+ic("play")+'Try it</h3><form id="tryForm" class="col"><div class="row"><select id="tryM" style="width:120px"><option>GET</option><option>POST</option><option>DELETE</option></select><input id="tryP" value="/v1/info" class="mono"></div><textarea id="tryB" rows="4" class="mono" placeholder="JSON body"></textarea><div class="row"><button type="button" class="btn sm ghost" id="tryCurl">'+ic("copy")+'Copy as curl</button><span class="grow"></span><span class="xs mut" id="tryMeta"></span><button class="btn pri">Send</button></div></form><pre class="code" id="tryOut" style="margin-top:12px;min-height:200px">Responses show here.</pre></div></div>';
  fetch("/v1/help").then(function(r){return r.json()}).then(function(j){var box=$("routes");if(!box)return;box.innerHTML=j.routes.map(function(r){var m=r.split(/\s+/)[0],rest=r.slice(m.length).trim(),p=rest.split(/\s+/)[0],note=rest.slice(p.length).trim();return'<div class="it" style="cursor:pointer" data-m="'+esc(m)+'" data-p="'+esc(p)+'"><span class="pill '+(m==="GET"?"ok":m==="POST"?"blue":"err")+'" style="width:64px;justify-content:center">'+esc(m)+'</span><span class="mono grow ell">'+esc(p)+'</span><span class="xs mut ell" style="max-width:45%">'+esc(note)+'</span></div>'}).join("");
   each(box,"[data-m]",function(x){x.onclick=function(){var m=x.getAttribute("data-m");$("tryM").value=m==="DELETE"?"DELETE":m;$("tryP").value=x.getAttribute("data-p").replace("<id>","ID").replace(/[…<>]/g,"");$("tryP").focus()}})});
  $("tryCurl").onclick=function(){var m=$("tryM").value,b=$("tryB").value.trim();copy("curl "+(m==="GET"?"":"-X "+m+" ")+"-H \"Authorization: Bearer "+token+"\" "+(b?"-H \"Content-Type: application/json\" -d '"+b.replace(/'/g,"'\\''")+"' ":"")+location.origin+$("tryP").value.trim(),"curl command")};
  $("tryForm").onsubmit=function(ev){ev.preventDefault();var b=$("tryB").value.trim(),m=$("tryM").value,body;if(b){try{body=JSON.parse(b)}catch(e){body=b}}var t0=performance.now();$("tryOut").textContent="…";
   api(m,$("tryP").value.trim(),m==="GET"?undefined:body).then(function(j){$("tryMeta").textContent="200 · "+Math.round(performance.now()-t0)+" ms";$("tryOut").textContent=JSON.stringify(j,null,2)}).catch(function(e){$("tryMeta").textContent="error";$("tryOut").textContent="Error: "+e.message})};
};

/* ---------------- start ---------------- */
function start(){
  $("login").classList.add("hidden");$("app").classList.remove("hidden");buildNav();
  refreshInfo().then(function(){go((location.hash||"").replace("#","")||"overview")});
  loadChats(true);startLive();
  timers.push(setInterval(function(){if(token)refreshInfo()},15000));
  timers.push(setInterval(function(){if(token&&(cur==="logs"||cur==="plugins"))loadLogs()},2000));
}
if(token){api("GET","/v1/info").then(start).catch(function(){})}else{setTimeout(function(){$("code").focus()},50)}
document.addEventListener("keydown",function(e){if(e.key==="Escape"){var m=document.querySelector(".modal");if(m)m.remove()}});
})();
</script>
</body>
</html>
''';
