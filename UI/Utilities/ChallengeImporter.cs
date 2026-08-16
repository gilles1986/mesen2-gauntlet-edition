using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace Mesen.Utilities
{
	/// <summary>
	/// Imports a challenge shipped as a ZIP (games.lua + games/*.bps + games/states/*.state).
	/// The .bps patches are applied to the user's clean ROM at import time (producing .smc
	/// files that games.lua references), and the result is placed in challenges/&lt;id&gt;/.
	/// </summary>
	public static class ChallengeImporter
	{
		//Shown when the selected file is not a readable ZIP (truncated/corrupt download, a
		//renamed non-archive, or the extracted folder/loose files instead of the package).
		private const string CorruptPackageMessage =
			"This challenge file is corrupt or is not a valid challenge package (.cha/.zip). " +
			"Import the original packaged file directly (don't extract it first), and try " +
			"re-downloading it if the problem persists.";

		/// <summary>
		/// Opens the challenge archive, translating the cryptic ZIP "end of central directory"
		/// error (and similar) into a clear, user-readable message.
		/// </summary>
		private static ZipArchive OpenPackage(string zipPath)
		{
			try {
				return ZipFile.OpenRead(zipPath);
			} catch(InvalidDataException) {
				throw new Exception(CorruptPackageMessage);
			}
		}

		/// <summary>
		/// Validates that the ZIP is a legitimate challenge package and returns a
		/// <see cref="ChallengePackageInfo"/> (sanitized id, external ROMs, whether it has
		/// SMW-patch segments). Throws with a user-readable message otherwise. Checks: no unsafe
		/// paths; games.lua present with 'id' and 'challenge'; every segment ROM referenced in
		/// games.lua either ships a games/&lt;name&gt;.bps (or full ROM) or is marked
		/// 'external = true'; every games/*.bps is actually a BPS patch.
		/// </summary>
		public static ChallengePackageInfo Validate(string zipPath)
		{
			using ZipArchive zip = OpenPackage(zipPath);

			//Safety: reject path-traversal / absolute entries.
			foreach(ZipArchiveEntry e in zip.Entries) {
				string n = e.FullName.Replace('\\', '/');
				if(n.StartsWith("/") || n.Contains("../") || (n.Length > 1 && n[1] == ':')) {
					throw new Exception("ZIP contains unsafe file paths.");
				}
			}

			ZipArchiveEntry gamesLua = FindGamesLua(zip) ?? throw new Exception("Not a challenge package (no games.lua).");
			string baseDir = GetEntryDir(gamesLua);

			string content;
			using(StreamReader sr = new(gamesLua.Open())) {
				content = sr.ReadToEnd();
			}

			Match idMatch = Regex.Match(content, "id\\s*=\\s*([\"'])(?<v>.*?)\\1");
			if(!idMatch.Success || idMatch.Groups["v"].Value.Trim().Length == 0) {
				throw new Exception("games.lua is missing a stable 'id' field.");
			}
			if(!Regex.IsMatch(content, "challenge\\s*=\\s*([\"']).*?\\1")) {
				throw new Exception("games.lua is missing a 'challenge' name.");
			}

			HashSet<string> entries = new(zip.Entries.Select(e => e.FullName.Replace('\\', '/')), StringComparer.OrdinalIgnoreCase);
			string gamesPrefix = baseDir + "games/";

			ChallengePackageInfo info = new() { Id = SanitizeId(idMatch.Groups["v"].Value.Trim()) };

			//Each segment ROM referenced in games.lua must either ship a patch/full ROM inside the
			//package, or be marked 'external = true' - a retro-game ROM (e.g. DKC2) the player must
			//supply themselves (dropped into the challenge's games/ folder, verified by rom_hash).
			//Lazy .*? with a back-referenced quote so ROM names may contain the OTHER quote
			//character (e.g. an apostrophe in "Diddy's Kong Quest ...").
			MatchCollection romMatches = Regex.Matches(content, "rom\\s*=\\s*([\"'])(?<v>.*?)\\1");
			bool anyRom = false;
			foreach(Match rm in romMatches) {
				string rom = rm.Groups["v"].Value.Trim();
				if(rom.Length == 0 || Path.IsPathRooted(rom) || rom.StartsWith("/")) {
					continue;
				}
				anyRom = true;

				if(IsSegmentExternal(content, rm.Index)) {
					if(!info.ExternalRoms.Contains(rom, StringComparer.OrdinalIgnoreCase)) {
						info.ExternalRoms.Add(rom);
					}
					continue;   //player supplies this ROM; nothing required inside the package
				}

				string baseName = Path.GetFileNameWithoutExtension(rom);
				if(entries.Contains(gamesPrefix + baseName + ".bps") || entries.Contains(gamesPrefix + rom)) {
					info.HasPatchedSegments = true;
				} else {
					throw new Exception($"ZIP is missing the patch for segment ROM '{rom}' (expected games/{baseName}.bps).");
				}
			}
			if(!anyRom) {
				throw new Exception("games.lua defines no segment ROMs.");
			}

			//Every games/*.bps (top level) must actually be a BPS patch.
			foreach(ZipArchiveEntry e in zip.Entries) {
				string n = e.FullName.Replace('\\', '/');
				if(!n.StartsWith(gamesPrefix, StringComparison.OrdinalIgnoreCase) || !n.EndsWith(".bps", StringComparison.OrdinalIgnoreCase)) {
					continue;
				}
				if(n.Substring(gamesPrefix.Length).Contains('/')) {
					continue; //not directly in games/
				}
				byte[] magic = new byte[4];
				using Stream s = e.Open();
				int got = 0;
				while(got < 4) {
					int r = s.Read(magic, got, 4 - got);
					if(r == 0) {
						break;
					}
					got += r;
				}
				if(got < 4 || magic[0] != 'B' || magic[1] != 'P' || magic[2] != 'S' || magic[3] != '1') {
					throw new Exception($"'{n}' is not a valid BPS patch.");
				}
			}

			return info;
		}

		private static string GetEntryDir(ZipArchiveEntry entry)
		{
			string n = entry.FullName.Replace('\\', '/');
			int idx = n.LastIndexOf('/');
			return idx >= 0 ? n.Substring(0, idx + 1) : "";
		}

		/// <summary>
		/// True if the games.lua segment table that contains the 'rom = ...' at <paramref name="romIndex"/>
		/// is flagged 'external = true' (its ROM is supplied by the player, not shipped in the package).
		/// Walks out to the enclosing { } block and looks for the marker inside it.
		/// </summary>
		private static bool IsSegmentExternal(string content, int romIndex)
		{
			int depth = 0, start = -1;
			for(int i = romIndex; i >= 0; i--) {
				if(content[i] == '}') {
					depth--;
				} else if(content[i] == '{') {
					depth++;
					if(depth == 1) {
						start = i;
						break;
					}
				}
			}
			if(start < 0) {
				return false;
			}
			int d = 1, end = -1;
			for(int i = start + 1; i < content.Length; i++) {
				if(content[i] == '{') {
					d++;
				} else if(content[i] == '}') {
					d--;
					if(d == 0) {
						end = i;
						break;
					}
				}
			}
			string block = end > start ? content.Substring(start, end - start + 1) : content.Substring(start);
			return Regex.IsMatch(block, "external\\s*=\\s*true");
		}

		/// <summary>
		/// Extracts the ZIP, applies every games/*.bps to the clean ROM (-&gt; .smc) and
		/// places the result at destDir. Any existing destDir is replaced (the caller is
		/// expected to have confirmed). Throws with a user-readable message on failure.
		/// </summary>
		public static void Import(string zipPath, string cleanRomPath, string destDir)
		{
			string root = ChallengeManager.ChallengesRoot;
			Directory.CreateDirectory(root);

			//Work inside the challenges root so the final move stays on the same volume.
			string tempDir = Path.Combine(root, ".import_tmp_" + Guid.NewGuid().ToString("N"));
			try {
				try {
					ZipFile.ExtractToDirectory(zipPath, tempDir);
				} catch(InvalidDataException) {
					throw new Exception(CorruptPackageMessage);
				}

				string challengeRoot = LocateChallengeRoot(tempDir);

				string gamesDir = Path.Combine(challengeRoot, "games");
				if(!Directory.Exists(gamesDir)) {
					throw new Exception("ZIP is missing the 'games' folder.");
				}

				//Apply any SMW-hack patches (.bps -> .smc). A retro-only challenge ships no
				//patches (its ROMs are external and supplied by the player), so zero is fine.
				string[] bpsFiles = Directory.GetFiles(gamesDir, "*.bps", SearchOption.TopDirectoryOnly);
				if(bpsFiles.Length > 0) {
					if(string.IsNullOrEmpty(cleanRomPath) || !File.Exists(cleanRomPath)) {
						throw new Exception("This challenge needs the clean Super Mario World (US) ROM to import its patches.");
					}
					byte[] clean = File.ReadAllBytes(cleanRomPath);
					foreach(string bps in bpsFiles) {
						byte[] patched = BpsPatcher.Apply(clean, File.ReadAllBytes(bps));
						File.WriteAllBytes(Path.ChangeExtension(bps, ".smc"), patched);
						File.Delete(bps);
					}
				}

				if(Directory.Exists(destDir)) {
					Directory.Delete(destDir, true);
				}
				Directory.Move(challengeRoot, destDir);
			} finally {
				if(Directory.Exists(tempDir)) {
					try { Directory.Delete(tempDir, true); } catch { }
				}
			}
		}

		private static ZipArchiveEntry? FindGamesLua(ZipArchive zip)
		{
			ZipArchiveEntry? best = null;
			int bestDepth = int.MaxValue;
			foreach(ZipArchiveEntry e in zip.Entries) {
				if(Path.GetFileName(e.FullName).Equals("games.lua", StringComparison.OrdinalIgnoreCase)) {
					int depth = e.FullName.Replace('\\', '/').TrimEnd('/').Count(c => c == '/');
					if(depth < bestDepth) {
						best = e;
						bestDepth = depth;
					}
				}
			}
			return best;
		}

		private static string LocateChallengeRoot(string tempDir)
		{
			if(File.Exists(Path.Combine(tempDir, "games.lua"))) {
				return tempDir;
			}
			foreach(string sub in Directory.GetDirectories(tempDir)) {
				if(File.Exists(Path.Combine(sub, "games.lua"))) {
					return sub;
				}
			}
			throw new Exception("Could not find games.lua in the ZIP.");
		}

		/// <summary>
		/// Turns a challenge id into the folder name used under challenges/. Public so the
		/// challenge catalog can map a server id to its local install folder.
		/// </summary>
		public static string SanitizeId(string id)
		{
			StringBuilder sb = new();
			foreach(char c in id.ToLowerInvariant()) {
				sb.Append(char.IsLetterOrDigit(c) || c == '-' || c == '_' ? c : '-');
			}
			string s = sb.ToString().Trim('-');
			return s.Length > 0 ? s : "challenge";
		}
	}

	/// <summary>
	/// Result of <see cref="ChallengeImporter.Validate"/>: the challenge id, any external
	/// (player-supplied) ROM filenames the package references, and whether it contains at
	/// least one SMW-hack segment that needs the clean ROM to patch.
	/// </summary>
	public class ChallengePackageInfo
	{
		public string Id = "";
		public List<string> ExternalRoms = new();
		public bool HasPatchedSegments;
	}
}
