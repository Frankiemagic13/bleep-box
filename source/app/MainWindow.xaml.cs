using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using Microsoft.Win32;

namespace BleepBox
{
    public partial class MainWindow : Window
    {
        private static readonly Color Accent = Color.FromRgb(0xFF, 0x8A, 0x3D);
        private static readonly Color Red = Color.FromRgb(0xE5, 0x48, 0x4D);
        private static readonly Color Green = Color.FromRgb(0x4A, 0xDE, 0x80);
        private static readonly Color Grey = Color.FromRgb(0x6B, 0x72, 0x80);
        private static readonly Color Off = Color.FromRgb(0x2A, 0x2E, 0x35);

        private readonly PluginClient client = new PluginClient();
        private readonly DispatcherTimer pollTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(80) };
        private readonly DispatcherTimer hotkeyTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(20) };
        private readonly DispatcherTimer volumeDebounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
        private readonly DispatcherTimer gainDebounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
        private readonly Border[] segments = new Border[30];

        private bool ready;
        private bool suppress;      // true while the UI is updated from a status
        private bool polling;
        private bool connected;
        private bool bleeping;      // last known state from the plugin
        private bool pressing;      // hold mode: button or hotkey is down
        private bool hotkeyWasDown;
        private string mode = "hold";
        private DateTime lastLocalChange = DateTime.MinValue;

        public MainWindow()
        {
            InitializeComponent();

            for (int i = 0; i < segments.Length; i++)
            {
                segments[i] = new Border
                {
                    CornerRadius = new CornerRadius(2),
                    Margin = new Thickness(1.5, 0, 1.5, 0),
                    Background = new SolidColorBrush(Off)
                };
                Meter.Children.Add(segments[i]);
            }

            pollTimer.Tick += async (s, e) => await Poll();
            hotkeyTimer.Tick += (s, e) => CheckHotkey();
            volumeDebounce.Tick += async (s, e) =>
            {
                volumeDebounce.Stop();
                await client.Call("/set?volume=" + (int)VolumeSlider.Value);
            };
            gainDebounce.Tick += async (s, e) =>
            {
                gainDebounce.Stop();
                await client.Call("/set?gain=" + (int)GainSlider.Value);
            };

            ready = true;
            pollTimer.Start();
            hotkeyTimer.Start();
            ShowBleepVisual(false);
        }

        // ---------- window ----------

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        private void Window_SourceInitialized(object sender, EventArgs e)
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            int on = 1;
            DwmSetWindowAttribute(hwnd, 20, ref on, sizeof(int)); // dark title bar
        }

        private void Window_Closing(object sender, System.ComponentModel.CancelEventArgs e)
        {
            if (pressing || bleeping)
                System.Threading.Tasks.Task.Run(() => client.Call("/bleep/off")).Wait(500);
        }

        // ---------- polling ----------

        private async System.Threading.Tasks.Task Poll()
        {
            if (polling) return;
            polling = true;
            try
            {
                Status st = await client.Call("/status");
                if (st == null || !st.Ok)
                {
                    SetConnected(false, null);
                    return;
                }
                if (!connected)
                    await LoadDevices(st.Device);
                SetConnected(true, st);
                ApplyStatus(st);
            }
            finally
            {
                polling = false;
            }
        }

        private void SetConnected(bool on, Status st)
        {
            connected = on;
            if (!on)
            {
                ConnDot.Fill = new SolidColorBrush(Grey);
                ConnText.Text = "OBS plugin not found — open OBS (Bleep Box plugin installed)";
                ObsDot.Fill = new SolidColorBrush(Grey);
                ObsText.Text = "Not found";
                MicState.Text = "OFFLINE";
                MicState.Foreground = new SolidColorBrush(Grey);
                SetMeter(0);
                if (bleeping) { bleeping = false; ShowBleepVisual(pressing); }
                return;
            }
            ConnDot.Fill = new SolidColorBrush(Green);
            ConnText.Text = "Connected to OBS plugin v" + st.Version + " · port " + PluginClient.Port;
            if (st.Sources == 0)
            {
                ObsDot.Fill = new SolidColorBrush(Accent);
                ObsText.Text = "Add the source";
            }
            else if (st.Capturing == 0)
            {
                ObsDot.Fill = new SolidColorBrush(Red);
                ObsText.Text = "Mic error";
            }
            else
            {
                ObsDot.Fill = new SolidColorBrush(Green);
                ObsText.Text = "In use by OBS";
            }
        }

        private void ApplyStatus(Status st)
        {
            bleeping = st.Bleeping;
            ShowBleepVisual(bleeping || pressing);
            SetMeter(st.Level);

            MicState.Text = bleeping ? "MIC MUTED" : (st.Sources > 0 ? "LIVE" : "NO SOURCE");
            MicState.Foreground = new SolidColorBrush(bleeping ? Red : (st.Sources > 0 ? Green : Grey));

            // Do not fight the user while they change a control
            if ((DateTime.Now - lastLocalChange).TotalMilliseconds < 800)
                return;

            suppress = true;
            try
            {
                if (st.Mode != mode)
                {
                    mode = st.Mode == "toggle" ? "toggle" : "hold";
                    (mode == "toggle" ? TogglePill : HoldPill).IsChecked = true;
                    UpdateHint();
                }
                foreach (var rb in FindSoundButtons())
                    if ((string)rb.Tag == st.Sound && rb.IsChecked != true)
                        rb.IsChecked = true;
                if (!VolumeSlider.IsMouseCaptureWithin && (int)VolumeSlider.Value != st.Volume)
                    VolumeSlider.Value = st.Volume;
                if (!GainSlider.IsMouseCaptureWithin && (int)GainSlider.Value != st.Gain)
                    GainSlider.Value = st.Gain;
                if (FullMuteCheck.IsChecked != st.FullMute)
                    FullMuteCheck.IsChecked = st.FullMute;
                CustomText.Text = string.IsNullOrEmpty(st.Custom) ? "No file selected" : System.IO.Path.GetFileName(st.Custom);
                if (!DeviceCombo.IsDropDownOpen)
                {
                    var match = DeviceCombo.Items.OfType<Device>().FirstOrDefault(d => d.Id == st.Device);
                    if (match != null && !ReferenceEquals(DeviceCombo.SelectedItem, match))
                        DeviceCombo.SelectedItem = match;
                }
            }
            finally
            {
                suppress = false;
            }
        }

        private IEnumerable<RadioButton> FindSoundButtons()
        {
            var grid = (UniformGrid)CustomRadio.Parent;
            return grid.Children.OfType<RadioButton>();
        }

        private void SetMeter(double level)
        {
            int lit = 0;
            if (level > 0.0001)
            {
                double db = 20 * Math.Log10(level);          // -60 dB .. 0 dB
                lit = (int)Math.Round((db + 60) / 60 * segments.Length);
                lit = Math.Max(0, Math.Min(segments.Length, lit));
            }
            for (int i = 0; i < segments.Length; i++)
            {
                Color c = i < 20 ? Green : i < 26 ? Color.FromRgb(0xFA, 0xCC, 0x15) : Color.FromRgb(0xF8, 0x71, 0x71);
                var brush = (SolidColorBrush)segments[i].Background;
                Color want = i < lit ? c : Off;
                if (brush.Color != want)
                    segments[i].Background = new SolidColorBrush(want);
            }
        }

        // ---------- bleep button ----------

        private void ShowBleepVisual(bool on)
        {
            if (on)
            {
                BigButton.Background = new SolidColorBrush(Red);
                BigButton.BorderBrush = new SolidColorBrush(Color.FromRgb(0xFF, 0x8A, 0x8D));
                BigIcon.Stroke = Brushes.White;
                BigLabel.Foreground = Brushes.White;
                BigLabel.Text = "BLEEPING";
                BigButton.RenderTransformOrigin = new Point(0.5, 0.5);
                BigButton.RenderTransform = new ScaleTransform(0.96, 0.96);
                BigButton.Effect = new DropShadowEffect { Color = Red, BlurRadius = 50, ShadowDepth = 0, Opacity = 0.7 };
            }
            else
            {
                BigButton.Background = new SolidColorBrush(Color.FromRgb(0x12, 0x14, 0x18));
                BigButton.BorderBrush = new SolidColorBrush(Accent);
                BigIcon.Stroke = new SolidColorBrush(Accent);
                BigLabel.Foreground = new SolidColorBrush(Accent);
                BigLabel.Text = "BLEEP";
                BigButton.RenderTransform = Transform.Identity;
                BigButton.Effect = null;
            }
        }

        private async void Press()
        {
            if (mode == "hold")
            {
                if (pressing) return;
                pressing = true;
                ShowBleepVisual(true);
                await client.Call("/bleep/on");
            }
            else
            {
                Status st = await client.Call("/bleep/toggle");
                if (st != null) { bleeping = st.Bleeping; ShowBleepVisual(bleeping); }
            }
        }

        private async void Release()
        {
            if (mode != "hold" || !pressing) return;
            pressing = false;
            ShowBleepVisual(false);
            await client.Call("/bleep/off");
        }

        private void Big_Down(object sender, MouseButtonEventArgs e)
        {
            BigButton.CaptureMouse();
            Press();
            e.Handled = true;
        }

        private void Big_Up(object sender, MouseButtonEventArgs e)
        {
            BigButton.ReleaseMouseCapture();
            Release();
            e.Handled = true;
        }

        private void Big_Leave(object sender, MouseEventArgs e)
        {
            if (!BigButton.IsMouseCaptured)
                Release();
        }

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int vKey);

        private void CheckHotkey()
        {
            bool down = (GetAsyncKeyState(0x11) & 0x8000) != 0   // Ctrl
                     && (GetAsyncKeyState(0x10) & 0x8000) != 0   // Shift
                     && (GetAsyncKeyState(0x42) & 0x8000) != 0;  // B
            if (down && !hotkeyWasDown) Press();
            if (!down && hotkeyWasDown) Release();
            hotkeyWasDown = down;
        }

        // ---------- controls ----------

        private void UpdateHint()
        {
            HintText.Text = mode == "hold"
                ? "Hold to bleep — or hold your Stream Deck key"
                : "Click once to start, click again to stop";
        }

        private async void Mode_Checked(object sender, RoutedEventArgs e)
        {
            if (!ready) return;
            mode = TogglePill.IsChecked == true ? "toggle" : "hold";
            UpdateHint();
            if (suppress) return;
            lastLocalChange = DateTime.Now;
            if (pressing) Release();
            await client.Call("/set?mode=" + mode);
        }

        private async void Sound_Checked(object sender, RoutedEventArgs e)
        {
            if (!ready || suppress) return;
            lastLocalChange = DateTime.Now;
            string id = (string)((RadioButton)sender).Tag;
            if (id == "custom" && CustomText.Text == "No file selected")
            {
                if (!PickWav()) return;
            }
            await client.Call("/set?sound=" + id);
        }

        private async void ChooseWav_Click(object sender, RoutedEventArgs e)
        {
            if (PickWav())
            {
                suppress = true;
                CustomRadio.IsChecked = true;
                suppress = false;
                await client.Call("/set?sound=custom");
            }
        }

        private bool PickWav()
        {
            var dlg = new OpenFileDialog
            {
                Title = "Choose a bleep sound",
                Filter = "WAV audio (*.wav)|*.wav"
            };
            if (dlg.ShowDialog(this) != true) return false;
            lastLocalChange = DateTime.Now;
            CustomText.Text = System.IO.Path.GetFileName(dlg.FileName);
            _ = client.Call("/set?custom=" + PluginClient.Q(dlg.FileName));
            return true;
        }

        private void VolumeSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
        {
            if (!ready) return;
            VolumeText.Text = (int)VolumeSlider.Value + "%";
            if (suppress) return;
            lastLocalChange = DateTime.Now;
            volumeDebounce.Stop();
            volumeDebounce.Start();
        }

        private void GainSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
        {
            if (!ready) return;
            GainText.Text = (int)GainSlider.Value + "%";
            if (suppress) return;
            lastLocalChange = DateTime.Now;
            gainDebounce.Stop();
            gainDebounce.Start();
        }

        private async void FullMute_Changed(object sender, RoutedEventArgs e)
        {
            if (!ready || suppress) return;
            lastLocalChange = DateTime.Now;
            await client.Call("/set?fullMute=" + (FullMuteCheck.IsChecked == true ? "1" : "0"));
        }

        private async System.Threading.Tasks.Task LoadDevices(string selectedId)
        {
            var list = await client.GetDevices();
            if (list == null) return;
            suppress = true;
            try
            {
                DeviceCombo.Items.Clear();
                foreach (var d in list) DeviceCombo.Items.Add(d);
                var match = list.FirstOrDefault(d => d.Id == selectedId) ?? list.FirstOrDefault();
                DeviceCombo.SelectedItem = match;
            }
            finally
            {
                suppress = false;
            }
        }

        private async void DeviceCombo_DropDownOpened(object sender, EventArgs e)
        {
            if (!connected) return;
            string current = (DeviceCombo.SelectedItem as Device)?.Id;
            await LoadDevices(current);
        }

        private async void DeviceCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (!ready || suppress) return;
            if (DeviceCombo.SelectedItem is Device d)
            {
                lastLocalChange = DateTime.Now;
                await client.Call("/set?device=" + PluginClient.Q(d.Id));
            }
        }
    }
}
