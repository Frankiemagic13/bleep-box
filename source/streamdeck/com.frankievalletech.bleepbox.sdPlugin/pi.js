/* Bleep Box - Property Inspector */
'use strict';

let piWs = null;
let piUUID = null;
let settings = {};

const $ = (id) => document.getElementById(id);

function save() {
  if (!piWs || piWs.readyState !== 1) return;
  piWs.send(JSON.stringify({ event: 'setSettings', context: piUUID, payload: settings }));
}

function fill() {
  $('mode').value = settings.mode || 'hold';
  $('sound').value = settings.sound || 'app';
  const useApp = settings.useAppVolume !== false;
  $('useAppVolume').checked = useApp;
  const vol = typeof settings.volume === 'number' ? settings.volume : 80;
  $('volume').value = vol;
  $('volText').textContent = vol + '%';
  $('volRow').style.display = useApp ? 'none' : 'grid';
}

function bind() {
  $('mode').addEventListener('change', (e) => { settings.mode = e.target.value; save(); });
  $('sound').addEventListener('change', (e) => { settings.sound = e.target.value; save(); });
  $('useAppVolume').addEventListener('change', (e) => {
    settings.useAppVolume = e.target.checked;
    if (typeof settings.volume !== 'number') settings.volume = 80;
    fill();
    save();
  });
  $('volume').addEventListener('input', (e) => {
    settings.volume = parseInt(e.target.value, 10);
    $('volText').textContent = settings.volume + '%';
  });
  $('volume').addEventListener('change', save);
}

async function checkStatus() {
  try {
    const r = await fetch('http://127.0.0.1:28196/status', { cache: 'no-store' });
    const st = await r.json();
    $('dot').style.background = st.sources > 0 ? '#4ADE80' : '#FF8A3D';
    $('statusText').textContent = st.sources > 0
      ? 'Bleep Box connected (' + (st.platform === 'mac' ? 'Mac app' : 'OBS plugin') + ' v' + st.version + ')'
      : (st.platform === 'mac' ? 'Bleep Box app found, but the audio is stopped' : 'OBS plugin found, but add the Bleep Box Mic source');
  } catch (e) {
    $('dot').style.background = '#777';
    $('statusText').textContent = 'Bleep Box not found. Mac: open the Bleep Box app. Windows: open OBS.';
  }
}

// Called by Stream Deck
// eslint-disable-next-line no-unused-vars
function connectElgatoStreamDeckSocket(inPort, inUUID, inRegisterEvent, inInfo, inActionInfo) {
  piUUID = inUUID;
  try {
    const info = JSON.parse(inActionInfo);
    settings = (info.payload && info.payload.settings) || {};
  } catch (e) {
    settings = {};
  }
  fill();
  bind();
  piWs = new WebSocket('ws://127.0.0.1:' + inPort);
  piWs.onopen = () => piWs.send(JSON.stringify({ event: inRegisterEvent, uuid: inUUID }));
  piWs.onmessage = (e) => {
    const msg = JSON.parse(e.data);
    if (msg.event === 'didReceiveSettings' && msg.payload) {
      settings = msg.payload.settings || {};
      fill();
    }
  };
  checkStatus();
  setInterval(checkStatus, 1500);
}
