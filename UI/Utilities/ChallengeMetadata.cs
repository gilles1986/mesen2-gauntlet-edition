using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace Mesen.Utilities
{
	/// <summary>
	/// Reads challenge.json - the display-only sidecar that challenge-builder packs into every
	/// .cha next to games.lua. Where games.lua drives the run (segment chain, ROM/state paths,
	/// done/fail conditions), this file carries what the title screen shows: description, date,
	/// and per segment the hack name and its author.
	///
	/// JSON is parsed with JsonDocument (reflection-free) because the UI is published
	/// trimmed/AOT and JsonSerializer&lt;T&gt; is not allowed (same constraint as ChallengeCatalog).
	/// </summary>
	public class ChallengeMetadata
	{
		public const string FileName = "challenge.json";

		public string Name = "";
		public string Date = "";
		public string Description = "";
		public List<SegmentInfo> Segments = new();

		public class SegmentInfo
		{
			public string Name = "";
			public string HackName = "";
			public string HackAuthor = "";
		}

		/// <summary>
		/// Loads the metadata for an installed challenge, or returns null when there is nothing
		/// to show a title screen from - no challenge.json (challenges packed before the file
		/// existed), unreadable/malformed JSON, or no segments in it.
		///
		/// Never throws: the title screen is cosmetic and must never stop a challenge from
		/// starting. A challenge without metadata simply starts the way it always did.
		/// </summary>
		public static ChallengeMetadata? TryLoad(string challengeDir)
		{
			try {
				string path = Path.Combine(challengeDir, FileName);
				if(!File.Exists(path)) {
					return null;
				}

				using JsonDocument doc = JsonDocument.Parse(File.ReadAllText(path));
				JsonElement root = doc.RootElement;
				if(root.ValueKind != JsonValueKind.Object) {
					return null;
				}

				ChallengeMetadata meta = new() {
					Name = GetStr(root, "name"),
					Date = GetStr(root, "date"),
					Description = GetStr(root, "description")
				};

				if(root.TryGetProperty("segments", out JsonElement arr) && arr.ValueKind == JsonValueKind.Array) {
					foreach(JsonElement e in arr.EnumerateArray()) {
						if(e.ValueKind != JsonValueKind.Object) {
							continue;
						}
						//Every field is optional - the screen shows what's known and leaves the
						//rest out (no "Unknown" placeholders).
						meta.Segments.Add(new SegmentInfo {
							Name = GetStr(e, "name"),
							HackName = GetStr(e, "hackName"),
							HackAuthor = GetStr(e, "hackAuthor")
						});
					}
				}

				return meta.Segments.Count > 0 ? meta : null;
			} catch(Exception) {
				return null;
			}
		}

		private static string GetStr(JsonElement el, string name)
		{
			return el.TryGetProperty(name, out JsonElement v) && v.ValueKind == JsonValueKind.String
				? (v.GetString() ?? "").Trim()
				: "";
		}
	}
}
