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
	/// Opens a replay package (.creplay) without going through a file dialog: unpack it, work out
	/// which Lauf it holds, ask what to do with it, start it.
	///
	/// This is the shared path behind every way a replay can arrive - double-clicking a shared
	/// file today, a Play button on saphros.de next - so all of them behave identically. The
	/// menu entries that pick a file themselves reuse the unpacking half of it.
	/// </summary>
	public static class ChallengeReplayLauncher
	{
		//The two menu flows each keep their own fixed folder (picking a file replaces what you
		//last picked, which is what you'd expect there).
		public const string WatchTempDir = "temp_replay";
		public const string RaceTempDir = "temp_ghost";

		//Opening replays by double-click can't share a fixed folder: opening a second replay
		//while the first is still playing would delete the very files the engine is reading
		//between segments. So every open gets a folder of its own, and stale ones are cleared
		//out only while nothing is running - at which point nothing can be reading any of them.
		private const string OpenTempDirPrefix = "open_";

		public static string ReplaysRoot => Path.Combine(ChallengeManager.ChallengesRoot, "replays");

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
			string tempDir = Path.Combine(ReplaysRoot, tempDirName);
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

		/// <summary>
		/// The full open-a-replay flow. Reports every failure itself and never throws, so callers
		/// (startup arguments, the single-instance pipe) can fire it and forget.
		/// </summary>
		public static async Task OpenAsync(Window? parent, string packagePath)
		{
			Window? owner = parent ?? ApplicationHelper.GetActiveOrMainWindow();
			if(owner == null) {
				//No window to own the prompt (and nowhere to report anything either). Only
				//reachable before the main window exists, which the callers already avoid.
				return;
			}
			const string title = "Replay";

			string tempDir;
			try {
				if(!File.Exists(packagePath)) {
					await MessageBox.Show(owner, "That replay file no longer exists.", title, MessageBoxButtons.OK, MessageBoxIcon.Error);
					return;
				}
				PruneOpenedReplays();
				tempDir = ExtractPackage(packagePath, OpenTempDirPrefix + Guid.NewGuid().ToString("N"));
			} catch(Exception ex) {
				await MessageBox.Show(owner, "Failed to open the replay: " + ex.Message, title, MessageBoxButtons.OK, MessageBoxIcon.Error);
				return;
			}

			ChallengeReplayInfo? info = ChallengeReplayInfo.FromFolder(tempDir);
			if(info == null) {
				DiscardFolder(tempDir);
				await MessageBox.Show(owner,
					"This file doesn't look like a valid replay (no challenge information found inside).",
					title, MessageBoxButtons.OK, MessageBoxIcon.Error);
				return;
			}

			if(!IsChallengeInstalled(info.ChallengeId)) {
				//The common case for a shared run. Installing it from here is a separate step -
				//until then, say plainly what's missing and how to get it.
				DiscardFolder(tempDir);
				await MessageBox.Show(owner, NotInstalledMessage(info.ChallengeId),
					"Challenge not installed", MessageBoxButtons.OK, MessageBoxIcon.Warning);
				return;
			}

			ChallengeReplayPromptViewModel model = new(info, GetChallengeDisplayName(info.ChallengeId), ChallengeManager.IsActive);
			ChallengeReplayAction action = await ChallengeReplayPromptWindow.AskAsync(owner, model);

			//Only now is a running challenge allowed to end - both start paths stop it themselves.
			switch(action) {
				case ChallengeReplayAction.Watch:
					ChallengeManager.StartReplay(info.ChallengeId, tempDir, info.Player);
					break;

				case ChallengeReplayAction.Race:
					//A normal, scored run of the challenge with the shared Lauf's ghost overlaid.
					ChallengeManager.StartChallenge(info.ChallengeId, tempDir);
					break;

				default:
					//Cancelled: nothing was started, so leave nothing behind either.
					DiscardFolder(tempDir);
					break;
			}
		}

		/// <summary>
		/// Removes the folders left behind by earlier opens - but only while no challenge is
		/// running, because a running replay or ghost race is reading from one of them.
		/// </summary>
		private static void PruneOpenedReplays()
		{
			if(!ChallengeManager.IsInactive || !Directory.Exists(ReplaysRoot)) {
				return;
			}
			foreach(string dir in Directory.GetDirectories(ReplaysRoot, OpenTempDirPrefix + "*")) {
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
