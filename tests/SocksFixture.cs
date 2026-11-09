using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace IpRegion.Tests
{
    // A real, loopback-only SOCKS5 peer. Never forwards traffic outside the test.
    public sealed class SocksFixture : IDisposable
    {
        private readonly TcpListener listener;
        private readonly CancellationTokenSource stop = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        public int Port { get; }
        public string Destination { get; private set; }
        public string Username { get; private set; }
        public string Password { get; private set; }
        public byte AddressType { get; private set; }
        public Task Completion { get; }

        public SocksFixture(bool authentication)
        {
            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            Port = ((IPEndPoint)listener.LocalEndpoint).Port;
            Completion = Serve(authentication);
        }

        private async Task<byte[]> Read(Stream stream, int count)
        {
            var bytes = new byte[count];
            await stream.ReadExactlyAsync(bytes, stop.Token);
            return bytes;
        }

        private async Task Serve(bool authentication)
        {
            using var socket = await listener.AcceptTcpClientAsync(stop.Token);
            using var stream = socket.GetStream();
            var greeting = await Read(stream, 2);
            await Read(stream, greeting[1]);
            await stream.WriteAsync(new byte[] { 5, authentication ? (byte)2 : (byte)0 }, stop.Token);
            if (authentication)
            {
                var auth = await Read(stream, 2);
                Username = Encoding.UTF8.GetString(await Read(stream, auth[1]));
                var passwordLength = (await Read(stream, 1))[0];
                Password = Encoding.UTF8.GetString(await Read(stream, passwordLength));
                await stream.WriteAsync(new byte[] { 1, 0 }, stop.Token);
            }
            var request = await Read(stream, 4);
            AddressType = request[3];
            if (AddressType == 3)
            {
                var length = (await Read(stream, 1))[0];
                Destination = Encoding.ASCII.GetString(await Read(stream, length));
            }
            else
            {
                Destination = new IPAddress(await Read(stream, AddressType == 1 ? 4 : 16)).ToString();
            }
            await Read(stream, 2);
            await stream.WriteAsync(new byte[] { 5, 0, 0, 1, 127, 0, 0, 1, 0, 80 }, stop.Token);
            var header = new StringBuilder();
            while (!header.ToString().EndsWith("\r\n\r\n", StringComparison.Ordinal))
            {
                header.Append((char)(await Read(stream, 1))[0]);
                if (header.Length > 8192) throw new IOException("Oversized test request");
            }
            var body = "{\"country\":\"DE\"}";
            var reply = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + body.Length + "\r\nConnection: close\r\n\r\n" + body);
            await stream.WriteAsync(reply, stop.Token);
        }

        public void Dispose()
        {
            stop.Cancel();
            listener.Stop();
            stop.Dispose();
        }
    }
}
