using Mesen.Config;
using System;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;

namespace Mesen.Utilities
{
	/// <summary>
	/// Checks saphros.de for a newer Challenge Edition build and applies it.
	///
	/// The Challenge Edition is published as a single self-contained Mesen.exe inside a
	/// ZIP (see Challenge/PACKAGE_LAYOUT.md), so "updating" just means swapping that exe.
	/// We reuse Mesen's existing, proven exe-swap machinery (UpdateHelper.LaunchUpdate ->
	/// relaunch with "--update" -> AttemptUpdate), which already handles the Windows file
	/// lock (a running exe can't be overwritten): the freshly-extracted exe is launched as
	/// the updater, kills the old process, waits for the lock to release, backs up + copies
	/// over the install, then relaunches.
	///
	/// The version compared is ChallengeEditionInfo.Version (from the embedded
	/// Challenge/version.txt, independent of the underlying Mesen core version) — bump that
	/// file for each release, matching the version string the moderator uploads with the ZIP.
	///
	/// JSON is parsed with JsonDocument (reflection-free), consistent with the other
	/// challenge helpers (the UI is published trimmed/AOT).
	/// </summary>
	public static class ChallengeUpdater
	{
		private const string ReleasesUrl = "https://saphros.de/api/challenge/emulator-releases.php";
		private const string SiteBaseUrl = "https://saphros.de";
		private static readonly HttpClient _http = ChallengeHttp.Create(TimeSpan.FromMinutes(5));

		public class ChallengeRelease
		{
			public Version Version = new();
			public string VersionString = "";
			public string DownloadUrl = "";
			public string CreatedAt = "";
		}

		/// <summary>Version of the currently running Challenge Edition build.</summary>
		public static Version InstalledVersion => ChallengeEditionInfo.Version;

		/// <summary>
		/// Fetches the newest release from saphros.de. Returns it only if it is newer than
		/// the installed build (else null). Never throws — returns null on any error so a
		/// failed/offline check can't block startup.
		/// </summary>
		public static async Task<ChallengeRelease?> CheckForUpdateAsync()
		{
			try {
				string json = await _http.GetStringAsync(ReleasesUrl);
				using JsonDocument doc = JsonDocument.Parse(json);
				JsonElement root = doc.RootElement;

				if(!root.TryGetProperty("ok", out JsonElement okEl) || okEl.ValueKind != JsonValueKind.True) {
					return null;
				}
				if(!root.TryGetProperty("releases", out JsonElement arr) || arr.ValueKind != JsonValueKind.Array) {
					return null;
				}

				//emulator-releases.php returns newest-first (ORDER BY id DESC); pick the first
				//entry whose version parses and download_path is present.
				foreach(JsonElement e in arr.EnumerateArray()) {
					string versionStr = GetStr(e, "version");
					string downloadPath = GetStr(e, "download_path");
					if(versionStr.Length == 0 || downloadPath.Length == 0) {
						continue;
					}
					if(!Version.TryParse(versionStr, out Version? version)) {
						continue;
					}

					if(version > InstalledVersion) {
						return new ChallengeRelease {
							Version = version,
							VersionString = versionStr,
							DownloadUrl = downloadPath.StartsWith("http") ? downloadPath : SiteBaseUrl + downloadPath,
							CreatedAt = GetStr(e, "created_at")
						};
					}
					//The newest release isn't newer than us -> nothing to do.
					return null;
				}
			} catch {
				//Offline / server error / bad JSON -> treat as "no update available".
			}
			return null;
		}

		/// <summary>
		/// Downloads the release ZIP (reporting 0-100 progress), extracts the bundled
		/// Mesen.exe into the Backups folder, and hands it to UpdateHelper.LaunchUpdate,
		/// which relaunches it as the updater. On success the caller should shut the app
		/// down so the updater can replace the (now-unlocked) exe.
		/// </summary>
		public static async Task<bool> DownloadAndLaunchAsync(ChallengeRelease release, IProgress<int>? progress)
		{
			//Download to memory with progress (the exe is large; stream it).
			using HttpResponseMessage response = await _http.GetAsync(release.DownloadUrl, HttpCompletionOption.ResponseHeadersRead);
			response.EnsureSuccessStatusCode();

			long? length = response.Content.Headers.ContentLength;
			using Stream contentStream = await response.Content.ReadAsStreamAsync();
			using MemoryStream zipStream = new();

			byte[] buffer = new byte[0x10000];
			long readTotal = 0;
			while(true) {
				int byteCount = await contentStream.ReadAsync(buffer);
				if(byteCount == 0) {
					break;
				}
				await zipStream.WriteAsync(buffer.AsMemory(0, byteCount));
				readTotal += byteCount;
				if(length is > 0) {
					progress?.Report((int)(readTotal * 100 / length.Value));
				}
			}

			//Extract the bundled Mesen.exe into the Backups folder (stable, writable path).
			zipStream.Position = 0;
			using ZipArchive archive = new(zipStream);
			ZipArchiveEntry? exeEntry = null;
			foreach(ZipArchiveEntry entry in archive.Entries) {
				if(string.Equals(entry.Name, "Mesen.exe", StringComparison.OrdinalIgnoreCase)) {
					exeEntry = entry;
					break;
				}
				if(exeEntry == null && entry.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) {
					exeEntry = entry; //fallback: first .exe in the archive
				}
			}
			if(exeEntry == null || exeEntry.Length == 0) {
				return false;
			}

			string destExe = Path.Combine(ConfigManager.BackupFolder, "Mesen_Challenge_" + release.VersionString + ".exe");
			exeEntry.ExtractToFile(destExe, true);

			//Reuse Mesen's exe-swap: relaunches destExe with "--update <src> <dest> <backup>".
			return UpdateHelper.LaunchUpdate(destExe);
		}

		private static string GetStr(JsonElement e, string prop)
		{
			return e.TryGetProperty(prop, out JsonElement v) && v.ValueKind == JsonValueKind.String ? (v.GetString() ?? "") : "";
		}
	}
}
