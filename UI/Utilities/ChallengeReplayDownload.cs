using System;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading.Tasks;

namespace Mesen.Utilities
{
	/// <summary>
	/// A failure that already carries a sentence fit to put in front of the player. Thrown instead
	/// of letting raw HTTP/IO exceptions reach the UI, so "the run was deleted" doesn't arrive as
	/// "Response status code does not indicate success: 404".
	/// </summary>
	public class ChallengeReplayException : Exception
	{
		public ChallengeReplayException(string message) : base(message) { }
	}

	/// <summary>
	/// Fetches the replay of a Lauf from saphros.de and keeps it.
	///
	/// The download URL is built here from the compiled-in API base and nothing but the run id -
	/// a link can never supply an address (docs/adr/0002). Downloads are kept for good under
	/// challenges/replays/downloaded/: a run id is immutable on the server, so a package can never
	/// go stale, and clicking the same Play button again costs nothing.
	/// </summary>
	public static class ChallengeReplayDownload
	{
		//Guards against a wrong endpoint (or a captive-portal login page) filling the disk. The
		//server caps recordings far below this.
		private const int MaxPackageBytes = 8 * 1024 * 1024;

		//Generous timeout: a replay is only 50-150 KB, but a phone-tethered connection can still be
		//slow. The buffer cap is the gate that actually holds - Content-Length is absent on a
		//chunked response, so without it an oversized body would be read in full before any check.
		private static readonly HttpClient _http = CreateClient();

		private static HttpClient CreateClient()
		{
			HttpClient client = ChallengeHttp.Create(TimeSpan.FromSeconds(30));
			client.MaxResponseContentBufferSize = MaxPackageBytes;
			return client;
		}

		public static string DownloadedRoot => Path.Combine(ChallengeManager.ReplaysRoot, "downloaded");

		/// <summary>
		/// The local path of this Lauf's replay, downloading it only if it isn't there yet.
		/// The file is named &lt;challenge&gt;_run&lt;id&gt;.creplay once the challenge is known; a
		/// freshly downloaded one is renamed by <see cref="Adopt"/> after it has been read.
		/// Throws <see cref="ChallengeReplayException"/> with a readable message on any failure.
		/// </summary>
		public static async Task<string> EnsureAsync(int runId)
		{
			string cached = FindCached(runId);
			if(cached.Length > 0) {
				return cached;
			}

			byte[] data;
			try {
				Directory.CreateDirectory(DownloadedRoot);
				using HttpResponseMessage response = await _http.GetAsync(
					ChallengeApi.BaseUrl + "recording-download.php?run=" + runId.ToString(CultureInfo.InvariantCulture));

				if(!response.IsSuccessStatusCode) {
					throw new ChallengeReplayException(DescribeStatus(response.StatusCode));
				}

				long? length = response.Content.Headers.ContentLength;
				if(length > MaxPackageBytes) {
					throw new ChallengeReplayException("That replay is unexpectedly large and was not downloaded.");
				}

				data = await response.Content.ReadAsByteArrayAsync();
			} catch(ChallengeReplayException) {
				throw;
			} catch(Exception) {
				//No connection, DNS failure, timeout, TLS problem - all the same to the player.
				throw new ChallengeReplayException(
					"Couldn't reach saphros.de. Check your internet connection and try again.");
			}

			if(data.Length == 0 || data.Length > MaxPackageBytes) {
				throw new ChallengeReplayException("The downloaded replay is damaged. Please try again.");
			}

			//Written to a side file and moved into place only once it is complete. Writing straight
			//to the cached name would mean a disk-full or a kill mid-write leaves a truncated file
			//under the very name FindCached trusts - poisoning the cache for good, since nothing
			//downloads it again. Same pattern as ChallengeCatalog's install.
			string path = Path.Combine(DownloadedRoot, PendingName(runId));
			string partial = path + ".part";
			try {
				await File.WriteAllBytesAsync(partial, data);
				if(File.Exists(path)) {
					File.Delete(path);
				}
				File.Move(partial, path);
			} catch(Exception ex) {
				try { File.Delete(partial); } catch { }
				throw new ChallengeReplayException("Couldn't save the downloaded replay: " + ex.Message);
			}
			return path;
		}

		/// <summary>
		/// Renames a freshly downloaded package now that its challenge is known, so the folder
		/// stays readable for humans. Best-effort: the file works either way, and its run id -
		/// the part <see cref="FindCached"/> matches on - is in both names.
		/// </summary>
		public static void Adopt(string packagePath, int runId, string challengeId)
		{
			try {
				if(Path.GetFileName(packagePath) != PendingName(runId)) {
					return;   //already adopted, or not one of ours
				}
				string target = Path.Combine(DownloadedRoot, challengeId + "_run" + runId.ToString(CultureInfo.InvariantCulture) + ".creplay");
				if(File.Exists(target)) {
					File.Delete(packagePath);
				} else {
					File.Move(packagePath, target);
				}
			} catch {
				//Cosmetic only.
			}
		}

		/// <summary>Deletes a downloaded package that turned out to be unusable, so a retry
		/// actually re-downloads instead of failing on the same broken file forever.</summary>
		public static void Discard(string packagePath)
		{
			try {
				if(File.Exists(packagePath) && Path.GetFullPath(packagePath).StartsWith(Path.GetFullPath(DownloadedRoot), StringComparison.OrdinalIgnoreCase)) {
					File.Delete(packagePath);
				}
			} catch { }
		}

		/// <summary>The already-downloaded package for this run id, or "" if there is none. Matched
		/// on the run id, since the challenge prefix isn't known before the first download.</summary>
		private static string FindCached(int runId)
		{
			try {
				if(!Directory.Exists(DownloadedRoot)) {
					return "";
				}
				string suffix = PendingName(runId);
				foreach(string file in Directory.GetFiles(DownloadedRoot, "*" + suffix)) {
					string name = Path.GetFileName(file);
					//"*run12.creplay" would also match "..._run123412.creplay"; require that the
					//run number is the whole trailing segment.
					if(name.Equals(suffix, StringComparison.OrdinalIgnoreCase)
						|| name.EndsWith("_" + suffix, StringComparison.OrdinalIgnoreCase)) {
						return file;
					}
				}
			} catch { }
			return "";
		}

		private static string PendingName(int runId)
		{
			return "run" + runId.ToString(CultureInfo.InvariantCulture) + ".creplay";
		}

		private static string DescribeStatus(HttpStatusCode status)
		{
			return status switch {
				HttpStatusCode.NotFound => "That run no longer exists on saphros.de - its replay may have been removed.",
				HttpStatusCode.TooManyRequests => "Too many replay downloads from your connection. Please wait a few minutes and try again.",
				HttpStatusCode.Forbidden or HttpStatusCode.Unauthorized => "saphros.de refused the download for this run.",
				_ => "saphros.de couldn't deliver this replay (error " + (int)status + "). Please try again later."
			};
		}
	}
}
