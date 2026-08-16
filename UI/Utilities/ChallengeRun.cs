using System.Collections.Generic;
using System.Text.Json;

namespace Mesen.Utilities
{
	/// <summary>
	/// A completed challenge run, read from the trusted Core persist (set by the embedded,
	/// non-editable engine). Shared by ChallengeSubmit (signing + POST) and
	/// ChallengeSubmitQueue (offline buffering of runs whose submit failed).
	///
	/// JSON is written/read with Utf8JsonWriter / JsonElement (reflection-free) because the
	/// UI is published trimmed/AOT and JsonSerializer&lt;T&gt; is not allowed.
	/// </summary>
	internal class ChallengeRun
	{
		public readonly struct Split
		{
			public readonly string Name;
			public readonly long Frames;
			public Split(string name, long frames) { Name = name; Frames = frames; }
		}

		public string ChallengeId = "";
		public string ChallengeName = "";
		public string Player = "";
		public long TotalFrames = 0;
		public List<Split> Splits = new();
		//How many full-gauntlet attempts (reset-combo restarts) it took to reach this run -
		//tracked persistently by relay.lua (attempts.txt).
		public long Attempts = 1;

		//Captured at submit time so a run buffered offline and re-sent later keeps its original
		//ranked status (config_hash) and identity (link_token) even if the installed challenge
		//or the login state changes in the meantime. The HMAC signature + timestamp + nonce are
		//NOT stored (the server enforces a +/-600s window) - they're regenerated at send time.
		public string ConfigHash = "";
		public string BuildVersion = "";
		public string LinkToken = "";

		public void WriteJson(Utf8JsonWriter w)
		{
			w.WriteStartObject();
			w.WriteString("challenge_id", ChallengeId);
			w.WriteString("challenge_name", ChallengeName);
			w.WriteString("player", Player);
			w.WriteNumber("total_frames", TotalFrames);
			w.WriteNumber("tries", Attempts);
			w.WriteStartArray("splits");
			foreach(Split sp in Splits) {
				w.WriteStartObject();
				w.WriteString("name", sp.Name);
				w.WriteNumber("frames", sp.Frames);
				w.WriteEndObject();
			}
			w.WriteEndArray();
			w.WriteString("config_hash", ConfigHash);
			w.WriteString("build_version", BuildVersion);
			w.WriteString("link_token", LinkToken);
			w.WriteEndObject();
		}

		/// <summary>Parses a run written by <see cref="WriteJson"/>. Returns null for a
		/// malformed/empty entry so a corrupt queue line can't be resubmitted.</summary>
		public static ChallengeRun? FromJson(JsonElement e)
		{
			if(e.ValueKind != JsonValueKind.Object) {
				return null;
			}
			ChallengeRun run = new() {
				ChallengeId = GetString(e, "challenge_id"),
				ChallengeName = GetString(e, "challenge_name"),
				Player = GetString(e, "player"),
				TotalFrames = GetLong(e, "total_frames", 0),
				Attempts = GetLong(e, "tries", 1),
				ConfigHash = GetString(e, "config_hash"),
				BuildVersion = GetString(e, "build_version"),
				LinkToken = GetString(e, "link_token")
			};
			if(e.TryGetProperty("splits", out JsonElement arr) && arr.ValueKind == JsonValueKind.Array) {
				foreach(JsonElement s in arr.EnumerateArray()) {
					run.Splits.Add(new Split(GetString(s, "name"), GetLong(s, "frames", 0)));
				}
			}
			if(run.ChallengeId.Length == 0 || run.TotalFrames <= 0) {
				return null;
			}
			return run;
		}

		private static string GetString(JsonElement e, string name)
			=> e.TryGetProperty(name, out JsonElement v) && v.ValueKind == JsonValueKind.String ? (v.GetString() ?? "") : "";

		private static long GetLong(JsonElement e, string name, long fallback)
			=> e.TryGetProperty(name, out JsonElement v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out long n) ? n : fallback;
	}
}
