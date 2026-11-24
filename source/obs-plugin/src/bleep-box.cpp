// Bleep Box - OBS plugin
// Adds the "Bleep Box Mic" audio source. The source captures a microphone
// (WASAPI), and when a bleep is active it mutes the mic and mixes in a bleep.
// A small HTTP server on 127.0.0.1:28196 lets the Bleep Box app and the
// Stream Deck plugin start/stop the bleep and change settings.

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <initguid.h>
#include <functiondiscoverykeys_devpkey.h>

#include <obs-module.h>
#include <util/platform.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("bleep-box", "en-US")

MODULE_EXPORT const char *obs_module_description(void)
{
	return "Bleep Box: a mic source that mutes and bleeps on command.";
}

static const int kPort = 28196;
static const char *kVersion = "1.0.0";
static const double kRate = 48000.0;
static const double kPi = 3.14159265358979323846;

enum Sound { S_CLASSIC, S_CENSOR, S_DOLPHIN, S_QUACK, S_HORN, S_CUSTOM, S_COUNT };
static const char *kSoundIds[S_COUNT] = {"classic", "censor", "dolphin", "quack", "horn", "custom"};

struct BleepSource;

struct Global {
	std::atomic<bool> bleeping{false};
	std::atomic<int> sound{S_CLASSIC};
	std::atomic<int> overrideSound{-1};
	std::atomic<int> volume{80};
	std::atomic<int> overrideVolume{-1};
	std::atomic<bool> fullMute{true};
	std::atomic<int> mode{0}; // 0 = hold, 1 = toggle (used by the app)
	std::mutex customMutex;
	std::vector<float> custom;
	std::string customPath;
	std::mutex srcMutex;
	std::set<BleepSource *> sources;
};
static Global g;

struct BleepSource {
	obs_source_t *source = nullptr;
	std::thread thread;
	std::atomic<bool> stop{false};
	std::mutex cfgMutex;
	std::string deviceId;
	std::atomic<int> gainPct{100};
	std::atomic<float> level{0.0f};
	std::atomic<bool> capturing{false};
	// Synth state (capture thread only)
	double p1 = 0, p2 = 0, p3 = 0;
	double t = 0;
	float env = 0.0f;
	bool wasOn = false;
	size_t customPos = 0;
};

// ---------- helpers ----------

static std::wstring to_wide(const std::string &s)
{
	if (s.empty())
		return L"";
	int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
	std::wstring w(n, L'\0');
	MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], n);
	w.resize(n - 1);
	return w;
}

static std::string to_utf8(const wchar_t *w)
{
	if (!w || !*w)
		return "";
	int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
	std::string s(n, '\0');
	WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], n, nullptr, nullptr);
	s.resize(n - 1);
	return s;
}

static std::string json_escape(const std::string &s)
{
	std::string o;
	for (char c : s) {
		switch (c) {
		case '"': o += "\\\""; break;
		case '\\': o += "\\\\"; break;
		case '\n': o += "\\n"; break;
		case '\r': o += "\\r"; break;
		case '\t': o += "\\t"; break;
		default:
			if ((unsigned char)c < 0x20) {
				char b[8];
				snprintf(b, sizeof(b), "\\u%04x", c);
				o += b;
			} else {
				o += c;
			}
		}
	}
	return o;
}

static int sound_from_id(const std::string &id)
{
	for (int i = 0; i < S_COUNT; i++)
		if (id == kSoundIds[i])
			return i;
	return -1;
}

template<class T> static void safe_release(T *&p)
{
	if (p) {
		p->Release();
		p = nullptr;
	}
}

// ---------- custom WAV ----------

static bool load_wav(const std::string &path, std::vector<float> &out)
{
	out.clear();
	FILE *f = _wfopen(to_wide(path).c_str(), L"rb");
	if (!f)
		return false;
	std::vector<uint8_t> b;
	fseek(f, 0, SEEK_END);
	long size = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (size <= 44 || size > 64 * 1024 * 1024) {
		fclose(f);
		return false;
	}
	b.resize((size_t)size);
	size_t got = fread(b.data(), 1, b.size(), f);
	fclose(f);
	if (got != b.size() || memcmp(b.data(), "RIFF", 4) != 0 || memcmp(b.data() + 8, "WAVE", 4) != 0)
		return false;

	auto rd16 = [&](size_t o) { return (uint32_t)(b[o] | (b[o + 1] << 8)); };
	auto rd32 = [&](size_t o) { return (uint32_t)(b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | ((uint32_t)b[o + 3] << 24)); };

	uint32_t fmtTag = 0, channels = 0, rate = 0, bits = 0;
	size_t dataOff = 0, dataLen = 0;
	size_t pos = 12;
	while (pos + 8 <= b.size()) {
		uint32_t len = rd32(pos + 4);
		size_t body = pos + 8;
		if (memcmp(&b[pos], "fmt ", 4) == 0 && body + 16 <= b.size()) {
			fmtTag = rd16(body);
			channels = rd16(body + 2);
			rate = rd32(body + 4);
			bits = rd16(body + 14);
			if (fmtTag == 0xFFFE && len >= 26 && body + 26 <= b.size())
				fmtTag = rd16(body + 24);
		} else if (memcmp(&b[pos], "data", 4) == 0) {
			dataOff = body;
			dataLen = std::min<size_t>(len, b.size() - body);
		}
		pos = body + len + (len & 1);
	}
	if (!dataOff || !channels || !rate || !bits)
		return false;
	if (!(fmtTag == 1 || fmtTag == 3))
		return false;

	size_t bytesPer = bits / 8;
	size_t frameBytes = bytesPer * channels;
	size_t frames = dataLen / frameBytes;
	std::vector<float> mono(frames);
	for (size_t i = 0; i < frames; i++) {
		double acc = 0;
		for (uint32_t c = 0; c < channels; c++) {
			const uint8_t *p = &b[dataOff + i * frameBytes + c * bytesPer];
			double v = 0;
			if (fmtTag == 3 && bits == 32) {
				float fv;
				memcpy(&fv, p, 4);
				v = fv;
			} else if (bits == 8) {
				v = (p[0] - 128) / 128.0;
			} else if (bits == 16) {
				v = (int16_t)(p[0] | (p[1] << 8)) / 32768.0;
			} else if (bits == 24) {
				int32_t x = (p[0] << 8) | (p[1] << 16) | (p[2] << 24);
				v = (x >> 8) / 8388608.0;
			} else if (bits == 32) {
				int32_t x = (int32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24));
				v = x / 2147483648.0;
			}
			acc += v;
		}
		mono[i] = (float)(acc / channels);
	}
	// Resample to 48 kHz (linear)
	if (rate == 48000) {
		out.swap(mono);
	} else {
		double ratio = (double)rate / kRate;
		size_t outN = (size_t)(frames / ratio);
		out.resize(outN);
		for (size_t i = 0; i < outN; i++) {
			double src = i * ratio;
			size_t a = (size_t)src;
			double fr = src - a;
			float va = mono[std::min(a, frames - 1)];
			float vb = mono[std::min(a + 1, frames - 1)];
			out[i] = (float)(va + (vb - va) * fr);
		}
	}
	return !out.empty();
}

// ---------- settings file ----------

static std::string settings_path()
{
	char *dir = obs_module_config_path("");
	if (dir) {
		os_mkdirs(dir);
		bfree(dir);
	}
	char *p = obs_module_config_path("settings.json");
	std::string s = p ? p : "";
	bfree(p);
	return s;
}

static void save_settings()
{
	obs_data_t *d = obs_data_create();
	obs_data_set_string(d, "sound", kSoundIds[g.sound.load()]);
	obs_data_set_int(d, "volume", g.volume.load());
	obs_data_set_bool(d, "full_mute", g.fullMute.load());
	obs_data_set_string(d, "mode", g.mode.load() == 1 ? "toggle" : "hold");
	{
		std::lock_guard<std::mutex> lk(g.customMutex);
		obs_data_set_string(d, "custom_path", g.customPath.c_str());
	}
	std::string path = settings_path();
	if (!path.empty())
		obs_data_save_json_safe(d, path.c_str(), "tmp", "bak");
	obs_data_release(d);
}

static void set_custom_path(const std::string &path)
{
	std::vector<float> data;
	bool ok = !path.empty() && load_wav(path, data);
	std::lock_guard<std::mutex> lk(g.customMutex);
	g.customPath = path;
	g.custom.swap(data);
	if (!path.empty() && !ok)
		blog(LOG_WARNING, "[bleep-box] could not read WAV file: %s", path.c_str());
}

static void load_settings()
{
	std::string path = settings_path();
	if (path.empty())
		return;
	obs_data_t *d = obs_data_create_from_json_file_safe(path.c_str(), "bak");
	if (!d)
		return;
	int s = sound_from_id(obs_data_get_string(d, "sound"));
	if (s >= 0)
		g.sound = s;
	if (obs_data_has_user_value(d, "volume"))
		g.volume = std::clamp((int)obs_data_get_int(d, "volume"), 0, 100);
	if (obs_data_has_user_value(d, "full_mute"))
		g.fullMute = obs_data_get_bool(d, "full_mute");
	g.mode = strcmp(obs_data_get_string(d, "mode"), "toggle") == 0 ? 1 : 0;
	set_custom_path(obs_data_get_string(d, "custom_path"));
	obs_data_release(d);
}

// ---------- bleep synth ----------

static inline double wrap(double p)
{
	return p - std::floor(p);
}

static float synth(BleepSource *s, int snd)
{
	double ts = s->t / kRate;
	s->t += 1.0;
	double v = 0;
	switch (snd) {
	case S_CLASSIC:
		s->p1 = wrap(s->p1 + 1000.0 / kRate);
		v = 0.5 * std::sin(2 * kPi * s->p1);
		break;
	case S_CENSOR: {
		s->p1 = wrap(s->p1 + 1000.0 / kRate);
		double p = 2 * kPi * s->p1;
		v = 0.4 * (std::sin(p) + std::sin(3 * p) / 3 + std::sin(5 * p) / 5);
		break;
	}
	case S_DOLPHIN: {
		double f = 2600 + 1800 * std::sin(2 * kPi * 7 * ts);
		s->p1 = wrap(s->p1 + f / kRate);
		double am = 0.6 + 0.4 * std::sin(2 * kPi * 23 * ts);
		v = 0.4 * am * std::sin(2 * kPi * s->p1);
		break;
	}
	case S_QUACK: {
		const double per = 0.32, len = 0.2;
		double pos = std::fmod(ts, per);
		if (pos < len) {
			double f = 380 - 150 * pos / len;
			s->p1 = wrap(s->p1 + f / kRate);
			double saw = 2 * s->p1 - 1;
			double e = std::sin(kPi * pos / len);
			v = 0.35 * e * (0.7 * saw + 0.3 * std::sin(2 * kPi * s->p1 * 3));
		}
		break;
	}
	case S_HORN: {
		s->p1 = wrap(s->p1 + 440.0 / kRate);
		s->p2 = wrap(s->p2 + 554.37 / kRate);
		s->p3 = wrap(s->p3 + 659.25 / kRate);
		double x = ((2 * s->p1 - 1) + (2 * s->p2 - 1) + (2 * s->p3 - 1)) * 0.5;
		v = 0.35 * std::tanh(x * 1.5);
		break;
	}
	case S_CUSTOM:
		// Caller holds g.customMutex
		if (!g.custom.empty()) {
			v = g.custom[s->customPos % g.custom.size()];
			s->customPos++;
		}
		break;
	}
	return (float)v;
}

static void process(BleepSource *s, const float *in, UINT32 frames, int ch, bool silent, std::vector<float> &L,
		    std::vector<float> &R)
{
	L.resize(frames);
	R.resize(frames);
	const bool on = g.bleeping.load();
	int snd = g.overrideSound.load();
	if (snd < 0)
		snd = g.sound.load();
	int vol = g.overrideVolume.load();
	if (vol < 0)
		vol = g.volume.load();
	const float bvol = vol / 100.0f;
	const bool full = g.fullMute.load();
	const float gain = s->gainPct.load() / 100.0f;
	const float fadeStep = 1.0f / (float)(0.006 * kRate); // 6 ms fade

	if (on && !s->wasOn) {
		s->t = 0;
		s->customPos = 0;
		s->p1 = s->p2 = s->p3 = 0;
	}
	s->wasOn = on;

	std::unique_lock<std::mutex> lk(g.customMutex, std::defer_lock);
	if (snd == S_CUSTOM)
		lk.lock();

	float peak = 0.0f;
	for (UINT32 i = 0; i < frames; i++) {
		float l = silent ? 0.0f : in[i * ch] * gain;
		float r = silent ? 0.0f : (ch > 1 ? in[i * ch + 1] * gain : l);
		float target = on ? 1.0f : 0.0f;
		if (s->env < target)
			s->env = std::min(target, s->env + fadeStep);
		else if (s->env > target)
			s->env = std::max(target, s->env - fadeStep);
		float micMul = full ? (1.0f - s->env) : (1.0f - 0.8f * s->env);
		l *= micMul;
		r *= micMul;
		peak = std::max(peak, std::max(std::fabs(l), std::fabs(r)));
		float b = 0.0f;
		if (s->env > 0.0f)
			b = synth(s, snd) * bvol * s->env;
		L[i] = std::clamp(l + b, -1.0f, 1.0f);
		R[i] = std::clamp(r + b, -1.0f, 1.0f);
	}
	if (lk.owns_lock())
		lk.unlock();

	float prev = s->level.load();
	s->level = std::max(peak, prev * 0.85f);

	obs_source_audio out = {};
	out.data[0] = (const uint8_t *)L.data();
	out.data[1] = (const uint8_t *)R.data();
	out.frames = frames;
	out.speakers = SPEAKERS_STEREO;
	out.format = AUDIO_FORMAT_FLOAT_PLANAR;
	out.samples_per_sec = 48000;
	out.timestamp = os_gettime_ns() - (uint64_t)frames * 1000000000ULL / 48000ULL;
	obs_source_output_audio(s->source, &out);
}

// ---------- WASAPI capture ----------

// Returns true when it stopped because s->stop was set, false on error.
static bool run_capture(BleepSource *s, const std::string &devId)
{
	IMMDeviceEnumerator *en = nullptr;
	IMMDevice *dev = nullptr;
	IAudioClient *ac = nullptr;
	IAudioCaptureClient *cc = nullptr;
	WAVEFORMATEX *mix = nullptr;
	HANDLE ev = nullptr;
	bool stoppedCleanly = false;
	HRESULT hr;

	do {
		hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
				      (void **)&en);
		if (FAILED(hr))
			break;
		if (devId.empty() || devId == "default") {
			hr = en->GetDefaultAudioEndpoint(eCapture, eConsole, &dev);
		} else {
			std::wstring w = to_wide(devId);
			hr = en->GetDevice(w.c_str(), &dev);
		}
		if (FAILED(hr))
			break;
		hr = dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void **)&ac);
		if (FAILED(hr))
			break;
		hr = ac->GetMixFormat(&mix);
		if (FAILED(hr))
			break;

		WORD ch = mix->nChannels >= 2 ? 2 : 1;
		WAVEFORMATEX wf = {};
		wf.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
		wf.nChannels = ch;
		wf.nSamplesPerSec = 48000;
		wf.wBitsPerSample = 32;
		wf.nBlockAlign = (WORD)(ch * 4);
		wf.nAvgBytesPerSec = 48000 * wf.nBlockAlign;

		ev = CreateEventW(nullptr, FALSE, FALSE, nullptr);
		if (!ev)
			break;
		hr = ac->Initialize(AUDCLNT_SHAREMODE_SHARED,
				    AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
					    AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
				    200000 /* 20 ms */, 0, &wf, nullptr);
		if (FAILED(hr))
			break;
		hr = ac->SetEventHandle(ev);
		if (FAILED(hr))
			break;
		hr = ac->GetService(__uuidof(IAudioCaptureClient), (void **)&cc);
		if (FAILED(hr))
			break;
		hr = ac->Start();
		if (FAILED(hr))
			break;

		s->capturing = true;
		blog(LOG_INFO, "[bleep-box] capture started (%d ch)", (int)ch);
		std::vector<float> L, R;
		bool failed = false;
		while (!s->stop && !failed) {
			DWORD w = WaitForSingleObject(ev, 100);
			if (w != WAIT_OBJECT_0)
				continue;
			UINT32 packet = 0;
			while (SUCCEEDED(hr = cc->GetNextPacketSize(&packet)) && packet > 0) {
				BYTE *data = nullptr;
				UINT32 frames = 0;
				DWORD flags = 0;
				hr = cc->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
				if (FAILED(hr))
					break;
				process(s, (const float *)data, frames, ch, (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0, L,
					R);
				cc->ReleaseBuffer(frames);
			}
			if (FAILED(hr))
				failed = true;
		}
		ac->Stop();
		stoppedCleanly = !failed;
	} while (false);

	s->capturing = false;
	s->level = 0.0f;
	if (FAILED(hr))
		blog(LOG_WARNING, "[bleep-box] capture error 0x%08lx, will retry", (unsigned long)hr);
	safe_release(cc);
	safe_release(ac);
	safe_release(dev);
	safe_release(en);
	if (mix)
		CoTaskMemFree(mix);
	if (ev)
		CloseHandle(ev);
	return stoppedCleanly && s->stop;
}

static void capture_loop(BleepSource *s, std::string devId)
{
	HRESULT hi = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
	while (!s->stop) {
		if (!run_capture(s, devId)) {
			for (int i = 0; i < 20 && !s->stop; i++)
				Sleep(50);
		}
	}
	if (SUCCEEDED(hi))
		CoUninitialize();
}

static void stop_capture(BleepSource *s)
{
	s->stop = true;
	if (s->thread.joinable())
		s->thread.join();
}

static void start_capture(BleepSource *s)
{
	stop_capture(s);
	s->stop = false;
	std::string id;
	{
		std::lock_guard<std::mutex> lk(s->cfgMutex);
		id = s->deviceId;
	}
	s->thread = std::thread(capture_loop, s, id);
}

// ---------- device list ----------

struct Device {
	std::string id, name;
};

static std::vector<Device> list_devices()
{
	std::vector<Device> out;
	HRESULT hi = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
	IMMDeviceEnumerator *en = nullptr;
	IMMDeviceCollection *col = nullptr;
	if (SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
				       __uuidof(IMMDeviceEnumerator), (void **)&en)) &&
	    SUCCEEDED(en->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, &col))) {
		UINT count = 0;
		col->GetCount(&count);
		for (UINT i = 0; i < count; i++) {
			IMMDevice *dev = nullptr;
			if (FAILED(col->Item(i, &dev)))
				continue;
			LPWSTR wid = nullptr;
			IPropertyStore *ps = nullptr;
			Device d;
			if (SUCCEEDED(dev->GetId(&wid))) {
				d.id = to_utf8(wid);
				CoTaskMemFree(wid);
			}
			if (SUCCEEDED(dev->OpenPropertyStore(STGM_READ, &ps))) {
				PROPVARIANT pv;
				PropVariantInit(&pv);
				if (SUCCEEDED(ps->GetValue(PKEY_Device_FriendlyName, &pv)) && pv.vt == VT_LPWSTR)
					d.name = to_utf8(pv.pwszVal);
				PropVariantClear(&pv);
				ps->Release();
			}
			dev->Release();
			if (!d.id.empty())
				out.push_back(d.name.empty() ? Device{d.id, d.id} : d);
		}
	}
	safe_release(col);
	safe_release(en);
	if (SUCCEEDED(hi))
		CoUninitialize();
	return out;
}

// ---------- OBS source ----------

static const char *bs_get_name(void *)
{
	return obs_module_text("BleepBoxMic");
}

static void bs_update(void *data, obs_data_t *settings)
{
	BleepSource *s = (BleepSource *)data;
	std::string id = obs_data_get_string(settings, "device_id");
	s->gainPct = (int)obs_data_get_int(settings, "gain");
	bool changed;
	{
		std::lock_guard<std::mutex> lk(s->cfgMutex);
		changed = id != s->deviceId || !s->thread.joinable();
		s->deviceId = id;
	}
	if (changed)
		start_capture(s);
}

static void *bs_create(obs_data_t *settings, obs_source_t *source)
{
	BleepSource *s = new BleepSource();
	s->source = source;
	{
		std::lock_guard<std::mutex> lk(g.srcMutex);
		g.sources.insert(s);
	}
	bs_update(s, settings);
	return s;
}

static void bs_destroy(void *data)
{
	BleepSource *s = (BleepSource *)data;
	{
		std::lock_guard<std::mutex> lk(g.srcMutex);
		g.sources.erase(s);
	}
	stop_capture(s);
	delete s;
}

static void bs_defaults(obs_data_t *settings)
{
	obs_data_set_default_string(settings, "device_id", "default");
	obs_data_set_default_int(settings, "gain", 100);
}

static obs_properties_t *bs_properties(void *)
{
	obs_properties_t *props = obs_properties_create();
	obs_property_t *list = obs_properties_add_list(props, "device_id", obs_module_text("Device"),
						       OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
	obs_property_list_add_string(list, obs_module_text("DefaultDevice"), "default");
	for (const Device &d : list_devices())
		obs_property_list_add_string(list, d.name.c_str(), d.id.c_str());
	obs_property_t *gain = obs_properties_add_int_slider(props, "gain", obs_module_text("Gain"), 0, 300, 1);
	obs_property_int_set_suffix(gain, "%");
	obs_properties_add_text(props, "info", obs_module_text("Info"), OBS_TEXT_INFO);
	return props;
}

// ---------- HTTP control server ----------

static std::thread g_httpThread;
static std::atomic<bool> g_httpStop{false};

static std::string url_decode(const std::string &s)
{
	std::string o;
	for (size_t i = 0; i < s.size(); i++) {
		if (s[i] == '+') {
			o += ' ';
		} else if (s[i] == '%' && i + 2 < s.size()) {
			char hex[3] = {s[i + 1], s[i + 2], 0};
			o += (char)strtol(hex, nullptr, 16);
			i += 2;
		} else {
			o += s[i];
		}
	}
	return o;
}

static std::map<std::string, std::string> parse_query(const std::string &q)
{
	std::map<std::string, std::string> m;
	size_t pos = 0;
	while (pos <= q.size()) {
		size_t amp = q.find('&', pos);
		if (amp == std::string::npos)
			amp = q.size();
		std::string kv = q.substr(pos, amp - pos);
		size_t eq = kv.find('=');
		if (!kv.empty()) {
			if (eq == std::string::npos)
				m[url_decode(kv)] = "";
			else
				m[url_decode(kv.substr(0, eq))] = url_decode(kv.substr(eq + 1));
		}
		pos = amp + 1;
	}
	return m;
}

static bool parse_bool(const std::string &v)
{
	return v == "1" || v == "true" || v == "yes" || v == "on";
}

static std::string status_json()
{
	float level = 0.0f;
	int count = 0, capturing = 0;
	std::string device = "default";
	int gain = 100;
	{
		std::lock_guard<std::mutex> lk(g.srcMutex);
		for (BleepSource *s : g.sources) {
			level = std::max(level, s->level.load());
			count++;
			if (s->capturing)
				capturing++;
			if (count == 1) {
				std::lock_guard<std::mutex> lk2(s->cfgMutex);
				device = s->deviceId;
				gain = s->gainPct.load();
			}
		}
	}
	std::string custom;
	{
		std::lock_guard<std::mutex> lk(g.customMutex);
		custom = g.customPath;
	}
	char buf[512];
	snprintf(buf, sizeof(buf),
		 "{\"ok\":true,\"version\":\"%s\",\"bleeping\":%s,\"level\":%.4f,\"sources\":%d,\"capturing\":%d,"
		 "\"sound\":\"%s\",\"volume\":%d,\"fullMute\":%s,\"mode\":\"%s\",\"gain\":%d,",
		 kVersion, g.bleeping ? "true" : "false", level, count, capturing, kSoundIds[g.sound.load()],
		 g.volume.load(), g.fullMute ? "true" : "false", g.mode.load() == 1 ? "toggle" : "hold", gain);
	std::string out = buf;
	out += "\"device\":\"" + json_escape(device) + "\",\"custom\":\"" + json_escape(custom) + "\"}";
	return out;
}

static std::string devices_json()
{
	std::string out = "{\"ok\":true,\"devices\":[{\"id\":\"default\",\"name\":\"Default microphone\"}";
	for (const Device &d : list_devices())
		out += ",{\"id\":\"" + json_escape(d.id) + "\",\"name\":\"" + json_escape(d.name) + "\"}";
	out += "]}";
	return out;
}

static void apply_source_settings(const std::map<std::string, std::string> &q)
{
	auto dev = q.find("device");
	auto gain = q.find("gain");
	if (dev == q.end() && gain == q.end())
		return;
	std::vector<obs_source_t *> srcs;
	{
		std::lock_guard<std::mutex> lk(g.srcMutex);
		for (BleepSource *s : g.sources) {
			obs_source_t *ref = obs_source_get_ref(s->source);
			if (ref)
				srcs.push_back(ref);
		}
	}
	for (obs_source_t *src : srcs) {
		obs_data_t *d = obs_data_create();
		if (dev != q.end())
			obs_data_set_string(d, "device_id", dev->second.c_str());
		if (gain != q.end())
			obs_data_set_int(d, "gain", std::clamp(atoi(gain->second.c_str()), 0, 300));
		obs_source_update(src, d);
		obs_data_release(d);
		obs_source_release(src);
	}
}

static void apply_overrides(const std::map<std::string, std::string> &q)
{
	auto snd = q.find("sound");
	g.overrideSound = snd != q.end() ? sound_from_id(snd->second) : -1;
	auto vol = q.find("volume");
	g.overrideVolume = vol != q.end() ? std::clamp(atoi(vol->second.c_str()), 0, 100) : -1;
}

static std::string http_response(int code, const std::string &body)
{
	const char *txt = code == 200 ? "OK" : code == 204 ? "No Content" : "Not Found";
	char hdr[512];
	snprintf(hdr, sizeof(hdr),
		 "HTTP/1.1 %d %s\r\n"
		 "Content-Type: application/json\r\n"
		 "Access-Control-Allow-Origin: *\r\n"
		 "Access-Control-Allow-Methods: GET, OPTIONS\r\n"
		 "Access-Control-Allow-Headers: *\r\n"
		 "Access-Control-Allow-Private-Network: true\r\n"
		 "Cache-Control: no-store\r\n"
		 "Connection: close\r\n"
		 "Content-Length: %zu\r\n\r\n",
		 code, txt, body.size());
	return std::string(hdr) + body;
}

static std::string handle_request(const char *req)
{
	std::string r(req);
	size_t sp1 = r.find(' ');
	size_t sp2 = sp1 == std::string::npos ? std::string::npos : r.find(' ', sp1 + 1);
	if (sp2 == std::string::npos)
		return http_response(404, "{\"ok\":false}");
	std::string method = r.substr(0, sp1);
	std::string target = r.substr(sp1 + 1, sp2 - sp1 - 1);
	if (method == "OPTIONS")
		return http_response(204, "");

	std::string path = target, query;
	size_t qm = target.find('?');
	if (qm != std::string::npos) {
		path = target.substr(0, qm);
		query = target.substr(qm + 1);
	}
	auto q = parse_query(query);

	if (path == "/status") {
		return http_response(200, status_json());
	} else if (path == "/bleep/on") {
		apply_overrides(q);
		g.bleeping = true;
		return http_response(200, status_json());
	} else if (path == "/bleep/off") {
		g.bleeping = false;
		return http_response(200, status_json());
	} else if (path == "/bleep/toggle") {
		if (!g.bleeping)
			apply_overrides(q);
		g.bleeping = !g.bleeping;
		return http_response(200, status_json());
	} else if (path == "/devices") {
		return http_response(200, devices_json());
	} else if (path == "/set") {
		bool save = false;
		if (q.count("custom")) {
			set_custom_path(q["custom"]);
			save = true;
		}
		if (q.count("sound")) {
			int s = sound_from_id(q["sound"]);
			if (s >= 0) {
				g.sound = s;
				save = true;
			}
		}
		if (q.count("volume")) {
			g.volume = std::clamp(atoi(q["volume"].c_str()), 0, 100);
			save = true;
		}
		if (q.count("fullMute")) {
			g.fullMute = parse_bool(q["fullMute"]);
			save = true;
		}
		if (q.count("mode")) {
			g.mode = q["mode"] == "toggle" ? 1 : 0;
			save = true;
		}
		apply_source_settings(q);
		if (save)
			save_settings();
		return http_response(200, status_json());
	}
	return http_response(404, "{\"ok\":false,\"error\":\"unknown path\"}");
}

static void http_loop()
{
	WSADATA wsa;
	if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0)
		return;
	SOCKET ls = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (ls == INVALID_SOCKET) {
		WSACleanup();
		return;
	}
	BOOL excl = TRUE;
	setsockopt(ls, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char *)&excl, sizeof(excl));
	sockaddr_in a = {};
	a.sin_family = AF_INET;
	a.sin_port = htons((u_short)kPort);
	inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
	if (bind(ls, (sockaddr *)&a, sizeof(a)) == SOCKET_ERROR || listen(ls, 16) == SOCKET_ERROR) {
		blog(LOG_ERROR, "[bleep-box] cannot open control port %d (is it in use?)", kPort);
		closesocket(ls);
		WSACleanup();
		return;
	}
	blog(LOG_INFO, "[bleep-box] control server on http://127.0.0.1:%d", kPort);
	while (!g_httpStop) {
		fd_set fs;
		FD_ZERO(&fs);
		FD_SET(ls, &fs);
		timeval tv = {0, 200000};
		if (select(0, &fs, nullptr, nullptr, &tv) <= 0)
			continue;
		SOCKET c = accept(ls, nullptr, nullptr);
		if (c == INVALID_SOCKET)
			continue;
		DWORD to = 1000;
		setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, (const char *)&to, sizeof(to));
		char buf[4096];
		int n = recv(c, buf, sizeof(buf) - 1, 0);
		if (n > 0) {
			buf[n] = 0;
			std::string resp = handle_request(buf);
			send(c, resp.data(), (int)resp.size(), 0);
		}
		shutdown(c, SD_BOTH);
		closesocket(c);
	}
	closesocket(ls);
	WSACleanup();
}

// ---------- module ----------

bool obs_module_load(void)
{
	load_settings();

	obs_source_info info = {};
	info.id = "bleep_box_mic";
	info.type = OBS_SOURCE_TYPE_INPUT;
	info.output_flags = OBS_SOURCE_AUDIO;
	info.get_name = bs_get_name;
	info.create = bs_create;
	info.destroy = bs_destroy;
	info.update = bs_update;
	info.get_defaults = bs_defaults;
	info.get_properties = bs_properties;
	info.icon_type = OBS_ICON_TYPE_AUDIO_INPUT;
	obs_register_source(&info);

	g_httpStop = false;
	g_httpThread = std::thread(http_loop);
	blog(LOG_INFO, "[bleep-box] loaded v%s", kVersion);
	return true;
}

void obs_module_unload(void)
{
	g_httpStop = true;
	if (g_httpThread.joinable())
		g_httpThread.join();
}
