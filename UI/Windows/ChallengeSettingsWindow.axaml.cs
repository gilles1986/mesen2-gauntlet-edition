using Avalonia;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Markup.Xaml;
using Mesen.Config;
using Mesen.Utilities;
using Mesen.ViewModels;
using System.Collections.Generic;
using System.IO;

namespace Mesen.Windows
{
	public class ChallengeSettingsWindow : MesenWindow
	{
		public ChallengeSettingsWindow()
		{
			InitializeComponent();
#if DEBUG
			this.AttachDevTools();
#endif
			//Don't leave a login poll loop running in the background after the window closes.
			Closing += (s, e) => (DataContext as ChallengeSettingsViewModel)?.CancelLogin();
		}

		private void InitializeComponent()
		{
			AvaloniaXamlLoader.Load(this);
		}

		/// <summary>
		/// Takes the emulator's replay entries out of Windows and tells the player what else it
		/// keeps on their PC. There is no installer to uninstall, so without this nobody would ever
		/// learn that anything was written to the registry - and someone who deletes the folder
		/// first no longer has this dialog to switch it off with.
		///
		/// It deliberately deletes NO data. The challenges folder holds personal bests, attempt
		/// counts and downloaded replays - somebody's run history. Naming the paths and opening the
		/// folder is the right amount of help; removing them stays a deliberate act in Explorer.
		/// </summary>
		private async void RemoveWindowsIntegration_OnClick(object sender, RoutedEventArgs e)
		{
			DialogResult confirm = await MessageBox.Show(this,
				"Remove this emulator's Windows entries for replays?\n\n" +
				"Double-clicking a .creplay file, and the play button next to a run on saphros.de, " +
				"will stop opening this emulator.\n\n" +
				"Nothing is deleted: your challenges, personal bests and downloaded replays stay.",
				"Challenge Settings", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
			if(confirm != DialogResult.Yes) {
				return;
			}

			//Written straight to the live config and saved, not held for OK/Cancel like the display
			//settings - same reasoning as the Twitch login: this is a deliberate, effortful action,
			//and leaving it to be undone by Cancel would re-register the entries on the next launch
			//after we just told the player they were gone.
			ConfigManager.Config.Challenge.AssociateReplayFiles = false;
			ConfigManager.Config.Save();
			((ChallengeSettingsViewModel)DataContext!).Config.AssociateReplayFiles = false;
			FileAssociationHelper.UpdateChallengeReplayAssociation(false);

			List<string> folders = new();
			foreach(string folder in new[] { ChallengeManager.ChallengesRoot, ChallengeManager.StreamRoot, ConfigManager.HomeFolder }) {
				if(Directory.Exists(folder) && !folders.Contains(folder)) {
					folders.Add(folder);
				}
			}

			string message = "The Windows entries are gone.\n\n" +
				"To remove the emulator completely, delete its folder along with:\n\n  • " +
				string.Join("\n  • ", folders) +
				"\n\nThose hold your challenges, personal bests, downloaded replays and settings, " +
				"so they are left for you to delete yourself.\n\nOpen the first of them now?";

			DialogResult open = await MessageBox.Show(this, message, "Challenge Settings", MessageBoxButtons.YesNo, MessageBoxIcon.Info);
			if(open == DialogResult.Yes && folders.Count > 0) {
				//ShellExecute on a directory opens it in Explorer; this path is Windows-only anyway.
				ApplicationHelper.OpenBrowser(folders[0]);
			}
		}

		private void Ok_OnClick(object sender, RoutedEventArgs e)
		{
			((ChallengeSettingsViewModel)DataContext!).SaveConfig();
			Close(true);
		}

		private void Cancel_OnClick(object sender, RoutedEventArgs e)
		{
			Close(false);
		}

		private async void LoginWithTwitch_OnClick(object sender, RoutedEventArgs e)
		{
			await ((ChallengeSettingsViewModel)DataContext!).LoginWithTwitchAsync();
		}

		private void CancelLogin_OnClick(object sender, RoutedEventArgs e)
		{
			((ChallengeSettingsViewModel)DataContext!).CancelLogin();
		}

		private async void LogoutOfTwitch_OnClick(object sender, RoutedEventArgs e)
		{
			await ((ChallengeSettingsViewModel)DataContext!).LogoutOfTwitchAsync();
		}

		private void ResetStreamStats_OnClick(object sender, RoutedEventArgs e)
		{
			ChallengeManager.ResetStreamStats();
			//Brief confirmation; re-enables next time the window opens (fresh instance).
			if(sender is Button b) {
				b.Content = "Session stats reset";
				b.IsEnabled = false;
			}
		}
	}
}
