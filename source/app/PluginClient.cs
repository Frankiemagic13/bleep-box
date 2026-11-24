using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;

namespace BleepBox
{
    /// Talks to the Bleep Box OBS plugin on http://127.0.0.1:28196
    public sealed class PluginClient
    {
        public const int Port = 28196;

        private static readonly HttpClient Http = new HttpClient
        {
            BaseAddress = new Uri("http://127.0.0.1:" + Port),
            Timeout = TimeSpan.FromMilliseconds(800)
        };

        private static readonly JsonSerializerOptions Opts = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        };

        public async Task<Status> Call(string pathAndQuery)
        {
            try
            {
                string json = await Http.GetStringAsync(pathAndQuery);
                return JsonSerializer.Deserialize<Status>(json, Opts);
            }
            catch
            {
                return null;
            }
        }

        public async Task<List<Device>> GetDevices()
        {
            try
            {
                string json = await Http.GetStringAsync("/devices");
                var list = JsonSerializer.Deserialize<DeviceList>(json, Opts);
                return list?.Devices ?? new List<Device>();
            }
            catch
            {
                return null;
            }
        }

        public static string Q(string value) => Uri.EscapeDataString(value ?? "");
    }

    public sealed class Status
    {
        public bool Ok { get; set; }
        public string Version { get; set; }
        public bool Bleeping { get; set; }
        public double Level { get; set; }
        public int Sources { get; set; }
        public int Capturing { get; set; }
        public string Sound { get; set; }
        public int Volume { get; set; }
        public bool FullMute { get; set; }
        public string Mode { get; set; }
        public int Gain { get; set; }
        public string Device { get; set; }
        public string Custom { get; set; }
    }

    public sealed class DeviceList
    {
        public List<Device> Devices { get; set; }
    }

    public sealed class Device
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public override string ToString() => Name;
    }
}
