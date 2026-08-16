using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;

namespace Mesen.Utilities
{
	/// <summary>
	/// Describes the Lauf inside an extracted replay package: which challenge it belongs to, who
	/// played it, how long it took, and whether it carries ghost data.
	///
	/// This is a seam on purpose - files in, a plain description out. No UI, no network, no
	/// starting of anything. Everything the replay prompt shows comes from here, which is what
	/// keeps the promise in docs/adr/0002: player and time are read from the package itself and
	/// never taken from the link that pointed at it.
	/// </summary>
	public class ChallengeReplayInfo
	{
		//The SNES frame rate the challenge engine and the leaderboard both use (relay.lua fmt()
		//and the backend agree on). Kept here so a replay's time reads exactly like the time
		//submitted for the same run.
		public const double Fps = 60.0988;

		/// <summary>Challenge folder name this replay belongs to (already sanitized).</summary>
		public string ChallengeId { get; private init; } = "";

		/// <summary>Who played the Lauf, from the package header. Empty if the recording predates
		/// the player field.</summary>
		public string Player { get; private init; } = "";

		/// <summary>Total frames over all segments, or 0 when at least one segment doesn't state
		/// its length (see <see cref="HasTotalTime"/>).</summary>
		public int TotalFrames { get; private init; }

		/// <summary>False for old recordings whose segments state neither a frame nor a poll
		/// count - their total can't be reconstructed, so it must not be shown as if it were
		/// exact.</summary>
		public bool HasTotalTime { get; private init; }

		public int SegmentCount { get; private init; }

		/// <summary>Whether the package carries ghost traces. Packages recorded before ghosts were
		/// bundled can be watched but not raced.</summary>
		public bool HasGhosts { get; private init; }

		public string TotalTime => HasTotalTime ? FormatFrames(TotalFrames) : "";

		/// <summary>
		/// Reads an extracted replay folder. Returns null when it holds no readable recording at
		/// all (no first segment, or no challenge in its header) - that's the "this isn't a valid
		/// replay" case the caller reports.
		/// </summary>
		public static ChallengeReplayInfo? FromFolder(string replayDir)
		{
			Dictionary<string, string>? first = ReadHeader(SegmentInputsPath(replayDir, 1));
			if(first == null) {
				return null;
			}

			string challengeId = first.TryGetValue("challenge", out string? id) ? id.Trim() : "";
			if(challengeId.Length == 0) {
				return null;
			}

			int segmentCount = 0;
			int totalFrames = 0;
			bool haveAllLengths = true;

			//Segments are numbered from 1 and written on completion, so the first gap is the end
			//of the run - counting files instead would also pick up unrelated leftovers.
			for(int seg = 1; ; seg++) {
				Dictionary<string, string>? header = seg == 1 ? first : ReadHeader(SegmentInputsPath(replayDir, seg));
				if(header == null) {
					break;
				}
				segmentCount = seg;

				//"frames" is the real segment time. Older recordings only state "polls"; at one
				//input poll per frame that's the same number (relay.lua readRecordedLength does
				//the same fallback), so it stays a faithful total rather than a guess.
				if(TryGetInt(header, "frames", out int frames) || TryGetInt(header, "polls", out frames)) {
					totalFrames += frames;
				} else {
					haveAllLengths = false;
				}
			}

			return new ChallengeReplayInfo() {
				ChallengeId = ChallengeImporter.SanitizeId(challengeId),
				Player = first.TryGetValue("player", out string? p) ? p.Trim() : "",
				SegmentCount = segmentCount,
				TotalFrames = haveAllLengths ? totalFrames : 0,
				HasTotalTime = haveAllLengths && totalFrames > 0,
				HasGhosts = File.Exists(Path.Combine(replayDir, "seg1.ghost"))
			};
		}

		/// <summary>Frames to "M:SS.mmm" - the same formula the engine and the leaderboard use, so
		/// a replay's time matches the time shown for the same run on the website.</summary>
		public static string FormatFrames(int frames)
		{
			double seconds = frames / Fps;
			int minutes = (int)Math.Floor(seconds / 60);
			double rest = seconds - (minutes * 60);
			return minutes.ToString(CultureInfo.InvariantCulture) + ":" + rest.ToString("00.000", CultureInfo.InvariantCulture);
		}

		private static string SegmentInputsPath(string replayDir, int segment)
		{
			return Path.Combine(replayDir, "seg" + segment.ToString(CultureInfo.InvariantCulture) + ".inputs");
		}

		/// <summary>
		/// The "key=value" lines before the first blank line of a recording. Returns null when the
		/// file is missing or unreadable, so a caller can tell "no such segment" from "segment
		/// without that field".
		/// </summary>
		private static Dictionary<string, string>? ReadHeader(string path)
		{
			if(!File.Exists(path)) {
				return null;
			}

			Dictionary<string, string> values = new(StringComparer.OrdinalIgnoreCase);
			try {
				foreach(string line in File.ReadLines(path)) {
					if(string.IsNullOrWhiteSpace(line)) {
						break;   //blank line marks the end of the header
					}
					int eq = line.IndexOf('=');
					if(eq > 0) {
						values[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
					}
				}
			} catch {
				return null;
			}
			return values;
		}

		private static bool TryGetInt(Dictionary<string, string> header, string key, out int value)
		{
			value = 0;
			return header.TryGetValue(key, out string? raw)
				&& int.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out value)
				&& value >= 0;
		}
	}
}
