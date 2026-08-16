using Mesen.Config;
using Mesen.Interop;
using System.IO.Compression;
using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Mesen.Utilities
{
	/// <summary>
	/// Server-side half of the leaderboard submit (AP5). The embedded engine writes a
	/// "submit_request.txt" into the challenge directory when the player presses START on
	/// the done screen; this class signs the run (HMAC) and POSTs it to the saphros.de
	/// leaderboard API, then writes "submit_result.txt" back for the engine to display.
	///
	/// The contract with the backend is defined server-side. Signing here
	/// MUST stay byte-for-byte identical to the server's verification.
	///
	/// JSON is written with Utf8JsonWriter / parsed with JsonDocument (both reflection-free)
	/// because the UI is published trimmed/AOT and JsonSerializer&lt;T&gt; is not allowed.
	/// </summary>
	public static class ChallengeSubmit
	{
		//HMAC secret + API base URL live in ChallengeApi.
		private const string RequestFileName = "submit_request.txt";
		private const string ResultFileName = "submit_result.txt";

		private static readonly HttpClient _http = ChallengeHttp.Create(TimeSpan.FromSeconds(15));
		private static int _busy = 0;

		//Result of one submit POST. GotResponse == false means a network-level failure (no
		//connection / DNS / timeout) -> the run can be buffered offline and retried later.
		private readonly struct SendOutcome
		{
			public readonly bool GotResponse;
			public readonly bool HttpOk;
			public readonly string ResponseText;
			public SendOutcome(bool gotResponse, bool httpOk, string responseText)
			{
				GotResponse = gotResponse;
				HttpOk = httpOk;
				ResponseText = responseText;
			}
		}

		/// <summary>Handles one submit request (fire-and-forget from the file watcher).</summary>
		public static async void ProcessRequest(string challengeDir)
		{
			//Guard against the watcher firing Created+Changed for the same file.
			if(Interlocked.Exchange(ref _busy, 1) == 1) {
				return;
			}

			string triggerFile = Path.Combine(challengeDir, RequestFileName);
			string resultFile = Path.Combine(challengeDir, ResultFileName);

			try {
				//One-shot gate: the trigger file's existence dedupes the watcher's
				//Created+Changed events for the same write. The content is intentionally
				//ignored — the run data is read from the Core's persisted state (set by the
				//embedded, non-editable engine), so a forged trigger can't inject a fake time.
				if(!File.Exists(triggerFile)) {
					return;
				}
				try { File.Delete(triggerFile); } catch { }

				//"relay_finished" is set to 1 only by the engine, and only on a real full
				//completion -> a forged/early trigger cannot submit a partial run as finished.
				if(DebugApi.GetChallengePersist("relay_finished") != "1") {
					WriteResult(resultFile, false, "Submit failed: no completed run");
					return;
				}

				ChallengeRun run = ReadRunFromPersist();
				if(run.ChallengeId.Length == 0 || run.TotalFrames <= 0) {
					WriteResult(resultFile, false, "Submit failed: no run data");
					return;
				}

				// Package this completed run's input logs into a .creplay (local replay file);
				// path is reused below for the optional recording upload after a successful submit.
				string? replayPath = ArchiveCompletedRunRecordings(challengeDir, run.ChallengeId);

				//Prefer the linked Twitch identity over whatever the engine persisted (it was
				//set from ConfigManager.Config.Challenge at run start, but login state may have
				//changed since - CurrentPlayerName always reflects the live config).
				run.Player = ChallengeManager.CurrentPlayerName;

				if(string.IsNullOrWhiteSpace(run.Player) || run.Player == "Player1") {
					//The engine's done screen keeps this message up and lets the player press START
					//again, so logging in here (Challenge > Settings) and retrying doesn't lose the run.
					WriteResult(resultFile, false, "To submit, log in with Twitch under Challenge > Settings");
					return;
				}

				//Snapshot the fields a run needs to be (re)signed later, so a run buffered offline
				//keeps its original ranked status + identity even if the config/login changes.
				run.ConfigHash = ComputeConfigHash(challengeDir);
				//Report the Challenge Edition version (bumps every challenge release, from
				//version.txt) rather than the Mesen core version (rarely changes) - that's the
				//build that actually produced the run. Part of the signed payload; the server
				//just stores it, so changing the value doesn't affect signature verification.
				run.BuildVersion = ChallengeEditionInfo.VersionString;
				run.LinkToken = ConfigManager.Config.Challenge.IsTwitchLinked ? ConfigManager.Config.Challenge.TwitchLinkToken : "";

				//A finished run is our cue to retry previously-buffered offline runs (oldest first),
				//so they go out before the current one. Best-effort + silent; still-offline runs stay.
				await FlushQueue(challengeDir);

				SendOutcome outcome = await SendRun(run);
				if(!outcome.GotResponse) {
					//No connection: buffer the run and let the player know it isn't lost. It will be
					//re-sent automatically the next time they complete a run for this challenge.
					ChallengeSubmitQueue.Enqueue(challengeDir, run);
					WriteResult(resultFile, false, "Offline - run saved, will retry next run");
					return;
				}

				var result = BuildResultMessage(outcome.HttpOk, outcome.ResponseText);
				WriteResult(resultFile, result);

				//Play the unlock jingle right as the engine's popup appears (it polls the
				//result file we just wrote). Only when this submit actually unlocked something.
				if(result.ok && result.achievements.Count > 0) {
					ChallengeSound.PlayAchievement();
				}

				//Optional: upload the run's replay package so the server can offer it for download
				//or verify it later. Best-effort and fire-and-forget - a missing endpoint or any
				//failure must never affect the (already succeeded) submit. Only on an accepted run.
				if(result.ok && replayPath != null) {
					_ = UploadRecording(replayPath, run);
				}
			} catch(Exception ex) {
				WriteResult(resultFile, false, "Submit failed: " + ex.Message);
			} finally {
				Interlocked.Exchange(ref _busy, 0);
			}
		}

		/// <summary>
		/// Signs a run (fresh timestamp + nonce, per the canonical string below) and POSTs
		/// it. A stored signature can't be replayed (the server enforces a +/-600s window), so
		/// buffered runs are re-signed here each time. Never throws: a network-level failure is
		/// reported via SendOutcome.GotResponse == false so the caller can queue for retry.
		/// </summary>
		private static async Task<SendOutcome> SendRun(ChallengeRun run)
		{
			long timestamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
			string nonce = Guid.NewGuid().ToString("N");

			//Canonical string — order and separators are fixed and must match the server.
			string canonical = string.Join("\n", new[] {
				run.ChallengeId,
				run.TotalFrames.ToString(),
				run.Player,
				run.ConfigHash,
				run.BuildVersion,
				timestamp.ToString(),
				nonce
			});
			string signature = ChallengeApi.HmacHex(canonical);
			string json = BuildPayloadJson(run, timestamp, nonce, signature);

			try {
				using StringContent body = new(json, Encoding.UTF8, "application/json");
				HttpResponseMessage resp = await _http.PostAsync(ChallengeApi.BaseUrl + "submit.php", body);
				string respText = await resp.Content.ReadAsStringAsync();
				return new SendOutcome(true, resp.IsSuccessStatusCode, respText);
			} catch {
				//No connection / DNS / timeout -> let the caller buffer the run for later.
				return new SendOutcome(false, false, "");
			}
		}

		/// <summary>
		/// Best-effort upload of a completed run's replay package (.creplay) so the server can
		/// offer it for download / verify it later. Fire-and-forget: never throws, and any failure
		/// (including a not-yet-existing endpoint or being offline) is swallowed. Signed like a
		/// submit — with a dedicated "recording" canonical so the signature can't be replayed as a
		/// run submission — so the server can (optionally) authenticate it and match it to the run.
		/// Backend endpoint: recording-upload.php.
		/// </summary>
		private static async Task UploadRecording(string replayPath, ChallengeRun run)
		{
			try {
				if(!File.Exists(replayPath)) {
					return;
				}
				byte[] fileBytes = await File.ReadAllBytesAsync(replayPath);
				string fileHash = Convert.ToHexString(SHA256.HashData(fileBytes)).ToLowerInvariant();

				long timestamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
				string nonce = Guid.NewGuid().ToString("N");
				string canonical = string.Join("\n", new[] {
					"recording",
					run.ChallengeId,
					run.TotalFrames.ToString(),
					run.Player,
					run.ConfigHash,
					fileHash,
					timestamp.ToString(),
					nonce
				});
				string signature = ChallengeApi.HmacHex(canonical);

				using MultipartFormDataContent form = new() {
					{ new StringContent(run.ChallengeId), "challenge_id" },
					{ new StringContent(run.Player), "player" },
					{ new StringContent(run.TotalFrames.ToString()), "total_frames" },
					{ new StringContent(run.ConfigHash), "config_hash" },
					{ new StringContent(fileHash), "file_sha256" },
					{ new StringContent(timestamp.ToString()), "timestamp" },
					{ new StringContent(nonce), "nonce" },
					{ new StringContent(signature), "signature" }
				};
				if(run.LinkToken.Length > 0) {
					form.Add(new StringContent(run.LinkToken), "link_token");
				}
				form.Add(new ByteArrayContent(fileBytes), "recording", Path.GetFileName(replayPath));

				await _http.PostAsync(ChallengeApi.BaseUrl + "recording-upload.php", form);
			} catch {
				//Best-effort: endpoint may not exist yet / no connection / etc. Never affects the submit.
			}
		}

		/// <summary>
		/// Best-effort, silent retry of previously-buffered offline runs (oldest first). A run
		/// that gets any server response (accepted or rejected) is dropped from the queue; the
		/// first network failure means we're still offline, so it and the rest stay buffered.
		/// </summary>
		private static async Task FlushQueue(string challengeDir)
		{
			List<ChallengeRun> queued = ChallengeSubmitQueue.Load(challengeDir);
			if(queued.Count == 0) {
				return;
			}

			bool changed = false;
			while(queued.Count > 0) {
				SendOutcome outcome = await SendRun(queued[0]);
				if(!outcome.GotResponse) {
					break;   //still offline -> leave this and the remaining runs queued
				}
				queued.RemoveAt(0);   //resolved (submitted or permanently rejected)
				changed = true;
			}

			if(changed) {
				ChallengeSubmitQueue.Save(challengeDir, queued);
			}
		}

		private static string BuildPayloadJson(ChallengeRun run, long timestamp, string nonce, string signature)
		{
			using MemoryStream stream = new();
			using(Utf8JsonWriter w = new(stream)) {
				w.WriteStartObject();
				w.WriteString("challenge_id", run.ChallengeId);
				w.WriteString("challenge_name", run.ChallengeName);
				w.WriteString("player", run.Player);
				w.WriteNumber("total_frames", run.TotalFrames);
				w.WriteNumber("tries", run.Attempts);
				w.WriteStartArray("splits");
				foreach(ChallengeRun.Split sp in run.Splits) {
					w.WriteStartObject();
					w.WriteString("name", sp.Name);
					w.WriteNumber("frames", sp.Frames);
					w.WriteEndObject();
				}
				w.WriteEndArray();
				w.WriteString("config_hash", run.ConfigHash);
				w.WriteString("build_version", run.BuildVersion);
				w.WriteNumber("timestamp", timestamp);
				w.WriteString("nonce", nonce);
				w.WriteString("signature", signature);
				//Identifies the linked Twitch account (if any) so the server can stamp/require
				//it - see the server-side device-login-confirm.php.
				if(run.LinkToken.Length > 0) {
					w.WriteString("link_token", run.LinkToken);
				}
				w.WriteEndObject();
			}
			return Encoding.UTF8.GetString(stream.ToArray());
		}

		private static (bool ok, string message, List<(string Name, string Desc)> achievements) BuildResultMessage(bool httpOk, string respText)
		{
			List<(string Name, string Desc)> achievements = new();
			try {
				using JsonDocument doc = JsonDocument.Parse(respText);
				JsonElement root = doc.RootElement;
				bool ok = httpOk && root.TryGetProperty("ok", out JsonElement okEl) && okEl.ValueKind == JsonValueKind.True;
				if(ok) {
					string msg = "Submitted!";
					if(root.TryGetProperty("rank", out JsonElement rankEl) && rankEl.TryGetInt32(out int rank)) {
						msg += " Rank #" + rank;
					}
					if(root.TryGetProperty("is_ranked", out JsonElement rankedEl) && rankedEl.ValueKind == JsonValueKind.False) {
						msg += " (practice)";
					}

					//Achievements unlocked by this submission, as reported by the server. Passed to
					//the engine as extra "ach;" lines in submit_result.txt so the done screen can
					//show an unlock popup. Icons are emoji -> skipped (the script HUD font is
					//ASCII-only); name/desc are sanitized for the same reason.
					if(root.TryGetProperty("newly_unlocked_achievements", out JsonElement achArr) && achArr.ValueKind == JsonValueKind.Array) {
						foreach(JsonElement e in achArr.EnumerateArray()) {
							string name = ToHudText(e.TryGetProperty("name", out JsonElement nameEl) ? nameEl.GetString() : null);
							string desc = ToHudText(e.TryGetProperty("desc", out JsonElement descEl) ? descEl.GetString() : null);
							if(name.Length > 0) {
								achievements.Add((name, desc));
							}
						}
					}
					return (true, msg, achievements);
				}

				string err = root.TryGetProperty("error", out JsonElement errEl) ? (errEl.GetString() ?? "unknown") : "unknown";
				return (false, FriendlyError(err), achievements);
			} catch {
				return (false, "Submit failed: bad server response", achievements);
			}
		}

		/// <summary>
		/// Reduces a server string to single-line printable ASCII (the engine's HUD font
		/// can't render emoji/umlauts) and strips ';' (field separator in the result file).
		/// </summary>
		private static string ToHudText(string? text)
		{
			if(string.IsNullOrEmpty(text)) {
				return "";
			}
			StringBuilder sb = new();
			foreach(char c in text) {
				if(c >= 0x20 && c < 0x7F) {
					sb.Append(c == ';' ? ',' : c);
				}
			}
			return sb.ToString().Trim();
		}

		/// <summary>Maps a server error code to a short, player-readable message.</summary>
		private static string FriendlyError(string code)
		{
			switch(code) {
				case "inactive":
					//Challenge doesn't exist (anymore) or its submission window is closed/
					//deactivated server-side (HTTP 400) -> the run simply can't be submitted.
					return "Challenge is closed for submissions";
				case "login_required":
					//Retryable on the done screen: log in via Challenge > Settings, then press START again.
					return "To submit, log in with Twitch under Challenge > Settings";
				default:
					return "Submit rejected: " + code;
			}
		}

		private static ChallengeRun ReadRunFromPersist()
		{
			ChallengeRun run = new();
			run.ChallengeId = DebugApi.GetChallengePersist("relay_id").Trim();
			run.ChallengeName = DebugApi.GetChallengePersist("relay_challenge");
			run.Player = DebugApi.GetChallengePersist("relay_name");
			long.TryParse(DebugApi.GetChallengePersist("relay_total"), out run.TotalFrames);
			if(!long.TryParse(DebugApi.GetChallengePersist("relay_attempts"), out run.Attempts) || run.Attempts < 1) {
				run.Attempts = 1;
			}

			run.Splits = ParseSplits(DebugApi.GetChallengePersist("relay_splits"));
			return run;
		}

		/// <summary>Parses relay.lua's "name;frames|name;frames|..." splits format.</summary>
		private static List<ChallengeRun.Split> ParseSplits(string? splitsStr)
		{
			List<ChallengeRun.Split> list = new();
			if(string.IsNullOrEmpty(splitsStr)) {
				return list;
			}
			//The engine strips ';' and '|' from segment names, so this is unambiguous.
			foreach(string item in splitsStr.Split('|', StringSplitOptions.RemoveEmptyEntries)) {
				int sep = item.LastIndexOf(';');
				if(sep > 0 && long.TryParse(item.Substring(sep + 1), out long frames)) {
					list.Add(new ChallengeRun.Split(item.Substring(0, sep), frames));
				}
			}
			return list;
		}

		private static string ComputeConfigHash(string challengeDir)
		{
			//SHA-256 over games.lua. (AP6 may extend this to also cover the .bps patches.)
			try {
				byte[] data = File.ReadAllBytes(Path.Combine(challengeDir, "games.lua"));
				return Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
			} catch {
				return "";
			}
		}


		private static void WriteResult(string resultFile, (bool ok, string message, List<(string Name, string Desc)> achievements) result)
		{
			try {
				//Line 1 = ok|error, line 2 = display message, lines 3+ = "ach;<name>;<desc>"
				//per achievement unlocked by this submit (all read by the engine).
				StringBuilder sb = new();
				sb.Append(result.ok ? "ok" : "error").Append('\n');
				sb.Append(result.message).Append('\n');
				foreach((string name, string desc) in result.achievements) {
					sb.Append("ach;").Append(name).Append(';').Append(desc).Append('\n');
				}
				File.WriteAllText(resultFile, sb.ToString());
			} catch { }
		}

		private static void WriteResult(string resultFile, bool ok, string message)
		{
			WriteResult(resultFile, (ok, message, new List<(string Name, string Desc)>()));
		}

		/// <summary>
		/// Packages the just-completed run's per-segment .inputs logs into a single replay file
		/// (a .creplay = a renamed .zip) under challenges/replays/, and returns its path (or null
		/// if there was nothing to archive). The file is what "Watch Replay from File..." opens
		/// and what the optional recording upload sends.
		/// </summary>
		public static string? ArchiveCompletedRunRecordings(string challengeDir, string challengeId)
		{
			try {
				string recordingsPath = Path.Combine(challengeDir, "recordings");
				if(!Directory.Exists(recordingsPath)) {
					return null;
				}

				var inputFiles = Directory.GetFiles(recordingsPath, "seg*.inputs");
				if(inputFiles.Length == 0) {
					return null;
				}

				string replaysRoot = Path.Combine(ChallengeManager.ChallengesRoot, "replays");
				Directory.CreateDirectory(replaysRoot);

				string timestamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
				string replayName = $"run_{challengeId}_{timestamp}.creplay";
				string replayPath = Path.Combine(replaysRoot, replayName);

				//Ghost position logs (recordings/pb_seg<idx>.ghost) enable "Race a Ghost from File...":
				//stored flat as seg<idx>.ghost so the receiver's engine finds them by segment index.
				//Older packages without these simply can't be raced (only watched).
				var ghostFiles = Directory.GetFiles(recordingsPath, "pb_seg*.ghost");

				using(var zip = ZipFile.Open(replayPath, ZipArchiveMode.Create)) {
					foreach(var file in inputFiles) {
						zip.CreateEntryFromFile(file, Path.GetFileName(file));
					}
					foreach(var file in ghostFiles) {
						//pb_seg3.ghost -> seg3.ghost
						string entryName = Path.GetFileName(file).Replace("pb_seg", "seg");
						zip.CreateEntryFromFile(file, entryName);
					}
				}
				return replayPath;
			} catch {
				return null;
			}
		}
	}
}
