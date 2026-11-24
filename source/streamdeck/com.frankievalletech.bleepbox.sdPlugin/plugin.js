/* Bleep Box - Stream Deck plugin
 * Key down/up -> HTTP calls to the Bleep Box OBS plugin on 127.0.0.1:28196.
 */
'use strict';

const BASE = 'http://127.0.0.1:28196';
const POLL_MS = 300;

const OFFLINE_SVG =
  '<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144">' +
  '<rect width="144" height="144" rx="20" fill="#121418"/>' +
  '<rect x="6" y="6" width="132" height="132" rx="16" fill="none" stroke="#4B5058" stroke-width="4" stroke-dasharray="10 8"/>' +
  '<path d="M72 34 L108 98 H36 Z" fill="none" stroke="#9AA0A8" stroke-width="6" stroke-linejoin="round"/>' +
  '<path d="M72 58 V76" stroke="#9AA0A8" stroke-width="6" stroke-linecap="round"/>' +
  '<circle cx="72" cy="87" r="3.5" fill="#9AA0A8"/>' +
  '<text x="72" y="124" font-family="Segoe UI, Arial" font-size="16" font-weight="700" fill="#9AA0A8" text-anchor="middle">APP OFF</text>' +
  '</svg>';
const OFFLINE_IMAGE = 'data:image/svg+xml;charset=utf8,' + encodeURIComponent(OFFLINE_SVG);

let ws = null;
let pluginUUID = null;
const keys = {};          // context -> { settings, down, shown }
let online = null;        // null = unknown
let appBleeping = false;

function send(obj) {
  if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj));
}

function setState(context, state) {
  send({ event: 'setState', context, payload: { state } });
}

function setImage(context, image) {
  const payload = { target: 0 };
  if (image) payload.image = image;
  send({ event: 'setImage', context, payload });
}

function showAlert(context) {
  send({ event: 'showAlert', context });
}

function bleepQuery(settings) {
  const p = [];
  const s = settings || {};
  if (s.sound === 'none') {
    p.push('volume=0');
  } else {
    if (s.sound && s.sound !== 'app') p.push('sound=' + encodeURIComponent(s.sound));
    if (s.useAppVolume === false && typeof s.volume === 'number') p.push('volume=' + s.volume);
  }
  return p.length ? '?' + p.join('&') : '';
}

async function call(path) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 800);
  try {
    const r = await fetch(BASE + path, { cache: 'no-store', signal: ctrl.signal });
    if (!r.ok) return null;
    return await r.json();
  } catch (e) {
    return null;
  } finally {
    clearTimeout(t);
  }
}

function render(context) {
  const k = keys[context];
  if (!k) return;
  const want = online === false ? 'off' : (appBleeping || k.down ? 'on' : 'ready');
  if (k.shown === want) return;
  if (want === 'off') {
    setImage(context, OFFLINE_IMAGE);
  } else {
    if (k.shown === 'off' || k.shown === undefined) setImage(context, null); // back to manifest image
    setState(context, want === 'on' ? 1 : 0);
  }
  k.shown = want;
}

function renderAll() {
  Object.keys(keys).forEach(render);
}

async function onKeyDown(context) {
  const k = keys[context];
  if (!k) return;
  const mode = (k.settings && k.settings.mode) || 'hold';
  let st;
  if (mode === 'toggle') {
    st = await call('/bleep/toggle' + bleepQuery(k.settings));
  } else {
    k.down = true;
    render(context);
    st = await call('/bleep/on' + bleepQuery(k.settings));
  }
  if (!st) {
    k.down = false;
    online = false;
    showAlert(context);
  } else {
    online = true;
    appBleeping = !!st.bleeping;
  }
  renderAll();
}

async function onKeyUp(context) {
  const k = keys[context];
  if (!k) return;
  const mode = (k.settings && k.settings.mode) || 'hold';
  // A toggle key does nothing on key up. Stream Deck moves a 2-state key to the
  // next state on its own, so put the right state back.
  if (mode === 'toggle') {
    k.shown = undefined;
    render(context);
    return;
  }
  k.down = false;
  const st = await call('/bleep/off');
  if (st) appBleeping = !!st.bleeping;
  k.shown = undefined;
  renderAll();
}

async function poll() {
  const st = await call('/status');
  const nowOnline = !!st;
  const nowBleeping = !!(st && st.bleeping);
  if (nowOnline !== online || nowBleeping !== appBleeping) {
    online = nowOnline;
    appBleeping = nowBleeping;
    renderAll();
  }
}

function handle(msg) {
  const { event, context, payload } = msg;
  switch (event) {
    case 'willAppear':
      keys[context] = { settings: (payload && payload.settings) || {}, down: false, shown: undefined };
      render(context);
      break;
    case 'willDisappear':
      delete keys[context];
      break;
    case 'didReceiveSettings':
      if (keys[context]) keys[context].settings = (payload && payload.settings) || {};
      break;
    case 'keyDown':
      if (keys[context] && payload) keys[context].settings = payload.settings || keys[context].settings;
      onKeyDown(context);
      break;
    case 'keyUp':
      onKeyUp(context);
      break;
    default:
      break;
  }
}

// Called by Stream Deck
// eslint-disable-next-line no-unused-vars
function connectElgatoStreamDeckSocket(inPort, inPluginUUID, inRegisterEvent, inInfo) {
  pluginUUID = inPluginUUID;
  ws = new WebSocket('ws://127.0.0.1:' + inPort);
  ws.onopen = () => send({ event: inRegisterEvent, uuid: pluginUUID });
  ws.onmessage = (e) => {
    try {
      handle(JSON.parse(e.data));
    } catch (err) {
      console.error(err);
    }
  };
  setInterval(poll, POLL_MS);
  poll();
}

if (typeof module !== 'undefined') module.exports = { bleepQuery };
