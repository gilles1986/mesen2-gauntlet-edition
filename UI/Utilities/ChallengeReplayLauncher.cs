using Avalonia.Controls;
using Mesen.ViewModels;
using Mesen.Windows;
using System;
using System.IO;
using System.IO.Compression;
using System.Threading.Tasks;

namespace Mesen.Utilities
{
	/// <summary>
	/// Opens a replay without going through a file dialog: get hold of the package, work out which
	/// Lauf it holds, ask what to do with it, start it.
	///
	/// Both ways in share this one path - double-clicking a shared .creplay and a Play button on
	/// saphros.de - so they behave identically. The only difference is how the package is obtained,
	/// which is why that step is a delegate: a local file is already there, a link means a
	/// download. The menu entries that pick a file themselves reuse the unpacking half.
	/// </summary>
	public static class ChallengeReplayLauncher
	{
		/// <summary>A replay that has been unpacked, read and confirmed to belong to an installed
		/// challenge - everything needed to show the prompt and start it.</summary>
		public class PreparedReplay
		{
			public ChallengeReplayInfo Info { get; }
			public string ExtractedDir { get; }
			public string ChallengeName { get; }

			/// <summary>False when the challenge this replay belongs to isn't installed yet. Not a
			/// failure: the prompt offers to install it, so this is the normal case for someone
			/// clicking play on a challenge they haven't played.</summary>
			public bool ChallengeInstalled { get; }

			public PreparedReplay(ChallengeReplayInfo info, string extractedDir, string challengeName, bool challengeInstalled)
			{
				Info = info;
				ExtractedDir = extractedDir;
				ChallengeName = challengeName;
				ChallengeInstalled = challengeInstalled;
			}
		}

		//The two menu flows each keep their own fixed folder (picking a file replaces what you
		//last picked, which is what you'd expect there).
		public const string WatchTempDir = "temp_replay";
		public const string RaceTempDir = "temp_ghost";

		//Opening replays by double-click or link can't share a fixed folder: opening a second
		//replay while the first is still playing would delete the very files the engine is reading
		//between segments. So every open gets a folder of its own, and stale ones are cleared out
		//only while nothing is running - at which point nothing can be reading any of them.
		private const string OpenTempDirPrefix = "open_";

		/// <summary>The message shown when a replay names a challenge that isn't installed. Shared
		/// so the menu flows and the double-click flow can't drift apart.</summary>
		public static string NotInstalledMessage(string challengeId)
		{
			return $"This replay is for the challenge \"{challengeId}\", which isn't installed on your copy.\n\n" +
				"Install it first via Challenge → Browse / Manage Challenges…, then open the file again.";
		}

		/// <summary>
		/// Unpacks a replay package into challenges/replays/&lt;tempDirName&gt;, replacing whatever
		/// was there. Throws on unreadable/corrupt packages - the caller reports it.
		/// </summary>
		public static string ExtractPackage(string packagePath, string tempDirName)
		{
			string tempDir = Path.Combine(ChallengeManager.ReplaysRoot, tempDirName);
			if(Directory.Exists(tempDir)) {
				Directory.Delete(tempDir, true);
			}
			Directory.CreateDirectory(tempDir);
			ZipFile.ExtractToDirectory(packagePath, tempDir);
			return tempDir;
		}

		/// <summary>True when the challenge this replay belongs to is installed on this copy.</summary>
		public static bool IsChallengeInstalled(string challengeId)
		{
			return File.Exists(Path.Combine(ChallengeManager.ChallengesRoot, challengeId, "games.lua"));
		}

		/// <summary>The challenge's display name, or "" when it isn't installed (then the id is
		/// all we have to show).</summary>
		public static string GetChallengeDisplayName(string challengeId)
		{
			foreach((string folder, string name) in ChallengeManager.GetChallengeList()) {
				if(string.Equals(folder, challengeId, StringComparison.OrdinalIgnoreCase)) {
					return name;
				}
			}
			return "";
		}

		/// <summary>Opens a replay package that is already on disk (double-click, or a .creplay
		/// passed on the command line).</summary>
		public static Task OpenFileAsync(Window? parent, string packagePath)
		{
			//No run id: nothing was downloaded, so there is nothing to re-fetch or rename - and a
			//local file that isn't a valid replay will fail the same way every time.
			return OpenAsync(parent, () => Task.FromResult(packagePath), null);
		}

		/// <summary>Opens the replay of a Lauf on saphros.de, downloading it if it isn't cached.
		/// This is what a Play button on the website ends up calling.</summary>
		public static Task OpenRunAsync(Window? parent, int runId)
		{
			return OpenAsync(parent, () => ChallengeReplayDownload.EnsureAsync(runId), runId);
		}

		/// <summary>
		/// The shared flow. Shows the prompt immediately - so a slow download or a cold start isn't
		/// a few seconds of nothing happening - then fetches, then asks. Reports every failure
		/// inside that window and never throws, so callers (startup arguments, the single-instance
		/// pipe) can fire it and forget.
		/// </summary>
		private static async Task OpenAsync(Window? parent, Func<Task<string>> acquirePackage, int? runId)
		{
			Window? owner = parent ?? ApplicationHelper.GetActiveOrMainWindow();
			if(owner == null) {
				//No window to own the prompt (and nowhere to report anything either). Only
				//reachable before the main window exists, which the callers already avoid.
				return;
			}

			//Retry only makes sense for a download - fetching the same broken local file again
			//would fail identically.
			ChallengeReplayPromptViewModel model = new(() => PrepareAsync(acquirePackage, runId), retryable: runId.HasValue);
			ChallengeReplayAction action = await ChallengeReplayPromptWindow.AskAsync(owner, model);

			//The window can be closed while the fetch is still running. Wait for it, or its
			//extracted folder would be left behind with nobody left to clean it up.
			await model.Completion;

			PreparedReplay? prepared = model.Prepared;
			if(prepared == null) {
				return;   //never got as far as a replay (failed, or cancelled before it finished)
			}

			//Only now is a running challenge allowed to end - both start paths stop it themselves.
			switch(action) {
				case ChallengeReplayAction.Watch:
					ChallengeManager.StartReplay(prepared.Info.ChallengeId, prepared.ExtractedDir, prepared.Info.Player);
					break;

				case ChallengeReplayAction.Race:
					//A normal, scored run of the challenge with the shared Lauf's ghost overlaid.
					ChallengeManager.StartChallenge(prepared.Info.ChallengeId, prepared.ExtractedDir);
					break;

				default:
					//Cancelled: nothing was started, so leave nothing behind either.
					DiscardFolder(prepared.ExtractedDir);
					break;
			}
		}

		/// <summary>
		/// Gets the package, unpacks it and reads it. Throws <see cref="ChallengeReplayException"/>
		/// with a message fit to show whenever that can't be completed.
		/// </summary>
		private static async Task<PreparedReplay> PrepareAsync(Func<Task<string>> acquirePackage, int? runId)
		{
			string packagePath = await acquirePackage();
			if(!File.Exists(packagePath)) {
				throw new ChallengeReplayException("That replay file no longer exists.");
			}

			//Unpacking and reading are plain file work: off the UI thread, so the window paints its
			//loading state even for an already-cached package where nothing else awaits.
			return await Task.Run(() => {
				//Deliberately outside the try below: a failure to tidy up old folders says nothing
				//about this package, and must not be reported as "damaged" - let alone discard a
				//perfectly good download.
				PruneOpenedReplays();

				string tempDir;
				try {
					tempDir = ExtractPackage(packagePath, OpenTempDirPrefix + Guid.NewGuid().ToString("N"));
				} catch(Exception ex) {
					//A truncated or corrupted package lands here. Drop a broken download so a retry
					//fetches it again instead of failing on the same bytes forever.
					DiscardDownload(packagePath, runId);
					throw new ChallengeReplayException("The replay file is damaged and couldn't be opened (" + ex.Message + ").");
				}

				ChallengeReplayInfo? info = ChallengeReplayInfo.FromFolder(tempDir);
				if(info == null) {
					DiscardFolder(tempDir);
					DiscardDownload(packagePath, runId);
					throw new ChallengeReplayException("This file doesn't look like a valid replay (no challenge information found inside).");
				}

				//A missing challenge is NOT an error here - it is the normal case for a run someone
				//clicked on the website. The prompt says so and offers to install it on confirm,
				//which is the whole point of a one-click path.
				bool installed = IsChallengeInstalled(info.ChallengeId);

				//Now that the challenge is known, give a fresh download its readable name.
				if(runId.HasValue) {
					ChallengeReplayDownload.Adopt(packagePath, runId.Value, info.ChallengeId);
				}

				//An uninstalled challenge has no local name yet, so the slug stands in until the
				//install replaces it.
				return new PreparedReplay(info, tempDir, GetChallengeDisplayName(info.ChallengeId), installed);
			});
		}

		/// <summary>Throws away an unusable download so a retry re-fetches it. Does nothing for a
		/// local file the player picked themselves - that is not ours to delete.</summary>
		private static void DiscardDownload(string packagePath, int? runId)
		{
			if(runId.HasValue) {
				ChallengeReplayDownload.Discard(packagePath);
			}
		}

		/// <summary>
		/// Removes the folders left behind by earlier opens - but only while no challenge is
		/// running, because a running replay or ghost race is reading from one of them.
		/// </summary>
		private static void PruneOpenedReplays()
		{
			if(!ChallengeManager.IsInactive || !Directory.Exists(ChallengeManager.ReplaysRoot)) {
				return;
			}
			foreach(string dir in Directory.GetDirectories(ChallengeManager.ReplaysRoot, OpenTempDirPrefix + "*")) {
				DiscardFolder(dir);
			}
		}

		private static void DiscardFolder(string dir)
		{
			try {
				if(Directory.Exists(dir)) {
					Directory.Delete(dir, true);
				}
			} catch {
				//Leftovers are harmless - the next prune gets them.
			}
		}
	}
}
