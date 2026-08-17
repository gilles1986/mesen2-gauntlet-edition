using System;
using System.Globalization;

namespace Mesen.Utilities
{
	/// <summary>
	/// Parses the replay links the website hands to the emulator: <c>mesen-challenge://replay/1234</c>.
	///
	/// This is the ONLY place that touches input coming from a browser, and it is deliberately
	/// strict: the link carries a run id and nothing else. It can name no download address, no
	/// player and no time - the emulator builds the download URL from its own compiled-in base and
	/// reads player/time out of the package it fetched. A crafted link therefore cannot point the
	/// emulator at a foreign server, and cannot lie about what it is going to play.
	/// See docs/adr/0002-replay-einstieg-per-protokoll-handler.md.
	///
	/// Pure by design (no IO, no UI) so this rule is verifiable in one place instead of being
	/// spread through the dialog and download code.
	/// </summary>
	public static class ChallengeReplayLink
	{
		public const string Scheme = "mesen-challenge";

		//The single supported path type. Anything else is rejected rather than guessed at, so a
		//future link shape can't be silently misread by an older build.
		private const string ReplayPath = "replay";

		//A run id is a positive SQLite rowid. Nine digits can never overflow Int32, which lets the
		//length check reject absurd values before parsing rather than relying on overflow behaviour.
		private const int MaxRunIdDigits = 9;

		/// <summary>
		/// True if this argument is addressed to us at all, whether or not it is well-formed.
		/// Callers use it to keep a malformed link out of path handling (a URL is not a file name)
		/// and to report it as a bad link rather than a missing file.
		/// </summary>
		public static bool HasScheme(string? url)
		{
			return url != null && url.TrimStart().StartsWith(Scheme + ":", StringComparison.OrdinalIgnoreCase);
		}

		/// <summary>
		/// True if <paramref name="url"/> is a well-formed replay link, with its run id.
		/// Everything else - a foreign scheme, an unknown path type, a non-numeric, zero, negative
		/// or oversized id, appended query/fragment parameters, extra path segments, an empty path
		/// - returns false without any side effect.
		/// </summary>
		public static bool TryParseRunId(string? url, out int runId)
		{
			runId = 0;
			if(string.IsNullOrWhiteSpace(url)) {
				return false;
			}

			string text = url.Trim();
			const string prefix = Scheme + "://";
			if(!text.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) {
				return false;
			}

			//Windows hands the URL over with a trailing slash often enough to accept them.
			string rest = text.Substring(prefix.Length).TrimEnd('/');

			//No query, fragment or parameter may ride along - that is the whole point of the
			//id-only contract, so anything of the sort is a reason to reject, not to ignore.
			if(rest.IndexOfAny(new[] { '?', '#', '&', '=', '\\' }) >= 0) {
				return false;
			}

			string[] parts = rest.Split('/');
			if(parts.Length != 2 || !parts[0].Equals(ReplayPath, StringComparison.OrdinalIgnoreCase)) {
				return false;
			}

			string id = parts[1];
			if(id.Length == 0 || id.Length > MaxRunIdDigits) {
				return false;
			}

			//Digits only. This is what rejects "-1", "+1", " 1", "1e5", "0x10" and unicode digits
			//before they ever reach the parser.
			foreach(char c in id) {
				if(!char.IsAsciiDigit(c)) {
					return false;
				}
			}

			if(!int.TryParse(id, NumberStyles.None, CultureInfo.InvariantCulture, out int parsed) || parsed <= 0) {
				return false;
			}

			runId = parsed;
			return true;
		}
	}
}
