using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

namespace Mesen.Utilities
{
	/// <summary>
	/// Builds the HttpClients used to talk to saphros.de (catalog, login, submissions,
	/// updates).
	///
	/// Why not a plain <c>new HttpClient()</c>: on a connection that advertises IPv6
	/// without actually routing it - a broken router or ISP, where the AAAA record
	/// resolves but the connection black-holes - .NET walks the resolved addresses with
	/// no per-address deadline. The dead IPv6 attempt then eats the entire request
	/// timeout and the working IPv4 address is never reached, so every saphros.de feature
	/// fails (and the Twitch login just times out) while the same user's browser works
	/// fine, because browsers give up on a stalled address after ~250ms and switch
	/// families ("Happy Eyeballs", RFC 8305).
	///
	/// The connect callback below caps each individual address attempt, so a black-holed
	/// address family costs a few seconds once per connection instead of failing the request.
	/// </summary>
	public static class ChallengeHttp
	{
		//Long enough for a slow but working connection to complete its TCP handshake,
		//short enough that a black-holed address family is skipped well inside even our
		//shortest request timeout.
		private const int ConnectTimeoutMs = 3000;

		public static HttpClient Create(TimeSpan timeout)
		{
			SocketsHttpHandler handler = new() {
				ConnectCallback = ConnectAsync
			};
			return new HttpClient(handler) { Timeout = timeout };
		}

		private static async ValueTask<Stream> ConnectAsync(SocketsHttpConnectionContext context, CancellationToken ct)
		{
			DnsEndPoint endPoint = context.DnsEndPoint;

			IPAddress[] addresses = IPAddress.TryParse(endPoint.Host, out IPAddress? literal)
				? new[] { literal }
				: await Dns.GetHostAddressesAsync(endPoint.Host, ct).ConfigureAwait(false);

			Exception? lastError = null;
			foreach(IPAddress address in Order(addresses)) {
				Socket socket = new(address.AddressFamily, SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
				try {
					using CancellationTokenSource attemptCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
					attemptCts.CancelAfter(ConnectTimeoutMs);
					await socket.ConnectAsync(address, endPoint.Port, attemptCts.Token).ConfigureAwait(false);
					return new NetworkStream(socket, ownsSocket: true);
				} catch(Exception ex) {
					socket.Dispose();
					if(ct.IsCancellationRequested) {
						throw;   //the request itself was cancelled or timed out - don't keep trying
					}
					lastError = ex;   //unreachable or stalled address: move on to the next one
				}
			}

			throw lastError ?? new SocketException((int)SocketError.HostNotFound);
		}

		/// <summary>
		/// Interleaves the address families, IPv4 first. RFC 8305 would prefer IPv6, but
		/// these are small API calls where the family makes no practical difference, and
		/// broken IPv6 is by far the more common failure - so the order that avoids a
		/// stall for those users wins. A host that resolves to only one family (an
		/// IPv6-only network with DNS64, for instance) is unaffected either way.
		/// </summary>
		private static IEnumerable<IPAddress> Order(IPAddress[] addresses)
		{
			List<IPAddress> v4 = new();
			List<IPAddress> v6 = new();
			foreach(IPAddress a in addresses) {
				(a.AddressFamily == AddressFamily.InterNetwork ? v4 : v6).Add(a);
			}

			for(int i = 0; i < Math.Max(v4.Count, v6.Count); i++) {
				if(i < v4.Count) {
					yield return v4[i];
				}
				if(i < v6.Count) {
					yield return v6[i];
				}
			}
		}
	}
}
