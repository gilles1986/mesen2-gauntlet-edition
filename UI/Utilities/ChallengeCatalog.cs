using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;

namespace Mesen.Utilities
{
	/// <summary>
	/// Talks to the saphros.de challenge catalog (all.php) so the user can browse the
	/// available challenges, see which are installed, and install/reinstall/delete them.
	///
	/// JSON is parsed with JsonDocument (reflection-free) because the UI is published
	/// trimmed/AOT and JsonSerializer&lt;T&gt; is not allowed (same constraint as ChallengeSubmit).
	/// </summary>
	public static class ChallengeCatalog
	{
		private const string CatalogUrl = "https://saphros.de/api/challenge/all.php";
		private static readonly HttpClient _http = ChallengeHttp.Create(TimeSpan.FromSeconds(20));

		public class CatalogEntry
		{
			public string Id = "";
			public string Name = "";
			public string DownloadUrl = "";
			public bool IsActive = true;
			public bool RequiresTwitchLogin = false;
		}

		//Name of the local sidecar file (written at install time) that records whether
		//this challenge requires a linked Twitch account to submit runs. Read offline by
		//ChallengeManager.StartChallenge, since the server's flag isn't otherwise available
		//once a challenge is installed.
		public const string RequiresTwitchLoginFileName = "requires_twitch_login.txt";

		/// <summary>Fetches the list of challenges from the server. Throws on network/parse errors.</summary>
		public static async Task<List<CatalogEntry>> FetchAsync()
		{
			string json = await _http.GetStringAsync(CatalogUrl);

			List<CatalogEntry> list = new();
			using JsonDocument doc = JsonDocument.Parse(json);
			JsonElement root = doc.RootElement;

			if(!root.TryGetProperty("ok", out JsonElement okEl) || okEl.ValueKind != JsonValueKind.True) {
				throw new Exception("The server returned an unexpected response.");
			}

			if(root.TryGetProperty("challenges", out JsonElement arr) && arr.ValueKind == JsonValueKind.Array) {
				foreach(JsonElement e in arr.EnumerateArray()) {
					CatalogEntry c = new() {
						Id = GetStr(e, "id"),
						Name = GetStr(e, "name"),
						DownloadUrl = GetStr(e, "download_url"),
						//Absent or non-false is treated as active.
						IsActive = !e.TryGetProperty("is_active", out JsonElement a) || a.ValueKind != JsonValueKind.False,
						RequiresTwitchLogin = e.TryGetProperty("requires_twitch_login", out JsonElement rtl) && rtl.ValueKind == JsonValueKind.True
					};
					if(c.Id.Length > 0 && c.DownloadUrl.Length > 0) {
						if(c.Name.Length == 0) {
							c.Name = c.Id;
						}
						list.Add(c);
					}
				}
			}
			return list;
		}

		/// <summary>
		/// Downloads the challenge package and installs it (validate + BPS-patch against the
		/// clean ROM). Overwrites any existing install of the same id (used for reinstall too).
		/// Throws with a user-readable message on failure.
		/// </summary>
		public static async Task InstallAsync(CatalogEntry entry, string cleanRomPath)
		{
			byte[] data = await _http.GetByteArrayAsync(entry.DownloadUrl);

			string tmp = Path.Combine(Path.GetTempPath(), "mesen_cha_" + Guid.NewGuid().ToString("N") + ".cha");
			try {
				await File.WriteAllBytesAsync(tmp, data);
				string id = ChallengeImporter.Validate(tmp).Id;
				string destDir = Path.Combine(ChallengeManager.ChallengesRoot, id);
				ChallengeImporter.Import(tmp, cleanRomPath, destDir);

				//Record the server's login requirement locally so StartChallenge can read
				//it offline (manual .cha imports have no catalog entry and default to false).
				//Best-effort: the challenge is already installed at this point, so a failed
				//flag write must not turn a successful install into a reported failure. A
				//missing flag simply defaults to "no login required".
				try {
					File.WriteAllText(Path.Combine(destDir, RequiresTwitchLoginFileName), entry.RequiresTwitchLogin ? "1" : "0");
				} catch { }
			} finally {
				try { File.Delete(tmp); } catch { }
			}
		}

		/// <summary>
		/// True if challenges/&lt;folder&gt;/games.lua exists. Callers holding a catalog id pass
		/// ChallengeImporter.SanitizeId(id) - that's the folder an install lands in.
		/// </summary>
		public static bool IsFolderInstalled(string folder)
		{
			string? dir = ResolveFolder(folder);
			return dir != null && File.Exists(Path.Combine(dir, "games.lua"));
		}

		/// <summary>
		/// Removes challenges/&lt;folder&gt; (folder name used as-is, so folders that don't match
		/// the sanitized id - e.g. manually renamed ones - are handled too). Throws on failure.
		/// </summary>
		public static void DeleteFolder(string folder)
		{
			string dir = ResolveFolder(folder) ?? throw new Exception("Invalid challenge folder name.");
			if(Directory.Exists(dir)) {
				Directory.Delete(dir, true);
			}
		}

		/// <summary>
		/// challenges/&lt;folder&gt;, or null if the name isn't a plain single folder name (guards
		/// against an empty name or path traversal wiping something outside the challenges root).
		/// </summary>
		private static string? ResolveFolder(string folder)
		{
			if(folder.Length == 0 || folder == "." || folder == ".." || folder.IndexOfAny(new[] { '/', '\\', ':' }) >= 0) {
				return null;
			}
			return Path.Combine(ChallengeManager.ChallengesRoot, folder);
		}

		private static string GetStr(JsonElement e, string prop)
		{
			return e.TryGetProperty(prop, out JsonElement v) && v.ValueKind == JsonValueKind.String ? (v.GetString() ?? "") : "";
		}
	}
}
