using System;
using System.Net;
using System.Net.Sockets;
using System.Threading.Tasks;
using NAudio.Wave;
using Zeroconf;

namespace MultipointBridgeWin
{
    class Program
    {
        static async Task Main(string[] args)
        {
            Console.WriteLine("🚀 Multipoint Bridge Windows Client Starting...");

            string targetIp = "";

            // 1. Try to discover Android receiver
            Console.WriteLine("📡 Scanning for Multipoint receivers...");
            var results = await ZeroconfResolver.ResolveAsync("_multipoint._udp.local.");
            
            foreach (var result in results)
            {
                Console.WriteLine($"✨ Found: {result.DisplayName} at {result.IPAddress}");
                targetIp = result.IPAddress;
                break;
            }

            if (string.IsNullOrEmpty(targetIp))
            {
                Console.Write("⚠️  No receiver found automatically. Enter Android IP: ");
                targetIp = Console.ReadLine() ?? "";
            }

            if (string.IsNullOrEmpty(targetIp)) return;

            // 2. Setup UDP Client
            using var udpClient = new UdpClient();
            var endPoint = new IPEndPoint(IPAddress.Parse(targetIp), 9999);
            Console.WriteLine($"✅ Streaming to {targetIp}:9999");

            // Start Heartbeat Thread
            string deviceName = Environment.MachineName;
            byte[] idMsg = System.Text.Encoding.UTF8.GetBytes($"MSG:NAME:{deviceName}");
            var heartbeatCts = new System.Threading.CancellationTokenSource();
            
            Task.Run(async () => {
                while (!heartbeatCts.Token.IsCancellationRequested) {
                    try {
                        udpClient.Send(idMsg, idMsg.Length, endPoint);
                        // Console.WriteLine("👤 Heartbeat sent");
                    } catch {}
                    await Task.Delay(3000);
                }
            });

            Console.WriteLine($"👤 Identity Heartbeat started: {deviceName}");

            // 3. Setup WASAPI Loopback Capture
            // This captures whatever is playing on the default output device
            using var capture = new WasapiLoopbackCapture();

            // Android expects 48kHz, 16-bit Stereo PCM
            // We'll wrap the capture with a Resampler/formatter if needed
            // But WASAPI loopback usually matches system settings.
            
            Console.WriteLine($"🎙️  Capture Format: {capture.WaveFormat}");

            capture.DataAvailable += (s, e) =>
            {
                // Convert float samples to 16-bit PCM if necessary
                // WASAPI Loopback is usually IEEE Float
                byte[] buffer;
                if (capture.WaveFormat.Encoding == WaveFormatEncoding.IeeeFloat)
                {
                    buffer = ConvertFloatTo16Bit(e.Buffer, e.BytesRecorded);
                }
                else
                {
                    buffer = new byte[e.BytesRecorded];
                    Array.Copy(e.Buffer, buffer, e.BytesRecorded);
                }

                if (buffer.Length > 0)
                {
                    udpClient.Send(buffer, buffer.Length, endPoint);
                }
            };

            capture.RecordingStopped += (s, e) =>
            {
                Console.WriteLine("🛑 Recording stopped.");
            };

            capture.StartRecording();
            Console.WriteLine("🟢 Streaming! Press any key to stop...");
            Console.ReadKey();
            capture.StopRecording();
        }

        static byte[] ConvertFloatTo16Bit(byte[] input, int length)
        {
            int samples = length / 4;
            byte[] output = new byte[samples * 2];
            
            for (int i = 0; i < samples; i++)
            {
                float sample = BitConverter.ToSingle(input, i * 4);
                
                // Clamp to -1 to 1 range
                if (sample > 1.0f) sample = 1.0f;
                if (sample < -1.0f) sample = -1.0f;

                short shortSample = (short)(sample * 32767);
                byte[] bytes = BitConverter.GetBytes(shortSample);
                output[i * 2] = bytes[0];
                output[i * 2 + 1] = bytes[1];
            }
            return output;
        }
    }
}
