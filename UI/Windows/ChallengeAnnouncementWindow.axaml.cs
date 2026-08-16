using Avalonia;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Markup.Xaml;
using Mesen.Config;
using Mesen.Utilities;
using Mesen.ViewModels;
using System;
using System.Collections.Generic;
using System.Threading.Tasks;

namespace Mesen.Windows
{
	/// <summary>
	/// Shows a single challenge announcement / teaser from saphros.de: badge, title, dates,
	/// message and - when the announcement links an already published challenge - a button that
	/// installs (or, once installed, starts) it without a detour through the challenge browser.
	///
	/// Closing the window records the announcement's id as dismissed, so the startup popup
	/// appears once per announcement. The banner in Browse / Manage Challenges is not affected by
	/// that; it keeps showing the current announcement for as long as the server publishes it.
	/// </summary>
	public class ChallengeAnnouncementWindow : MesenWindow
	{
		private ChallengeAnnouncementViewModel Model => (ChallengeAnnouncementViewModel)DataContext!;

		public ChallengeAnnouncementWindow()
		{
			InitializeComponent();
#if DEBUG
			this.AttachDevTools();
#endif
		}

		private void InitializeComponent()
		{
			AvaloniaXamlLoader.Load(this);
		}

		/// <summary>
		/// Startup path: fetches the current announcement and shows it if it asks for a popup and
		/// hasn't been seen yet. Does nothing at all when announcements are turned off, when the
		/// server has none, or when it can't be reached - it must never hold up startup.
		/// </summary>
		public static async Task ShowStartupPopupAsync(Window parent)
		{
			if(!ConfigManager.Config.Challenge.ShowAnnouncements) {
				return;
			}

			ChallengeAnnouncements.Announcement? announcement = await ChallengeAnnouncements.FetchAsync();
			if(announcement == null || !announcement.ShowPopup) {
				return;
			}
			if(announcement.Id != 0 && announcement.Id == ConfigManager.Config.Challenge.LastDismissedAnnouncementId) {
				return;   //already shown once - it stays available in the challenge browser
			}

			await ShowAsync(parent, announcement);
		}

		/// <summary>Shows an announcement that was already fetched (challenge browser banner).</summary>
		public static async Task ShowAsync(Visual? parent, ChallengeAnnouncements.Announcement announcement)
		{
			ChallengeAnnouncementWindow wnd = new() {
				DataContext = new ChallengeAnnouncementViewModel(announcement)
			};
			await wnd.ShowCenteredDialog(parent);
		}

		protected override void OnClosed(EventArgs e)
		{
			base.OnClosed(e);

			//Seen it - don't pop it up again on the next launch. Written to the live config
			//directly (and saved) because nothing else in this window is an OK/Cancel edit.
			int id = (DataContext as ChallengeAnnouncementViewModel)?.Data.Id ?? 0;
			if(id != 0 && ConfigManager.Config.Challenge.LastDismissedAnnouncementId != id) {
				ConfigManager.Config.Challenge.LastDismissedAnnouncementId = id;
				ConfigManager.Config.Save();
			}
		}

		private void Close_Click(object sender, RoutedEventArgs e)
		{
			Close();
		}

		private void Link_Click(object sender, RoutedEventArgs e)
		{
			//Only ever an http(s) URL - ChallengeAnnouncements drops anything else.
			ApplicationHelper.OpenBrowser(Model.Link);
		}

		private void Play_Click(object sender, RoutedEventArgs e)
		{
			string folder = Model.ChallengeFolder;
			//Close first: StartChallenge puts up its own dialogs (title screen, login prompt),
			//which can't open while this one still owns the modal.
			Close();
			ChallengeManager.StartChallenge(folder);
		}

		private async void Install_Click(object sender, RoutedEventArgs e)
		{
			Model.Busy = true;
			Model.Status = "Looking up the challenge...";
			try {
				//The announcement only carries the challenge's slug, so the download URL still has
				//to come from the catalog - the same source the challenge browser installs from.
				List<ChallengeCatalog.CatalogEntry> entries = await ChallengeCatalog.FetchAsync();
				ChallengeCatalog.CatalogEntry? entry = null;
				foreach(ChallengeCatalog.CatalogEntry candidate in entries) {
					if(string.Equals(candidate.Id, Model.Data.ChallengeId, StringComparison.OrdinalIgnoreCase)) {
						entry = candidate;
						break;
					}
				}

				if(entry == null) {
					Model.Status = "This challenge isn't available for download yet.";
					return;
				}

				//Prompts for + validates the SMW ROM on first use (and explains any failure
				//itself), so a null result just means "don't install".
				string? cleanRom = await ChallengeManager.EnsureCleanRomAsync(this);
				if(cleanRom == null) {
					Model.Status = "";
					return;
				}

				Model.Status = "Installing '" + entry.Name + "'...";
				await ChallengeCatalog.InstallAsync(entry, cleanRom);
				Model.RefreshInstalled();
				Model.Status = "Installed '" + entry.Name + "'.";
			} catch(Exception ex) {
				Model.Status = "Install failed: " + ex.Message;
			} finally {
				Model.Busy = false;
			}
		}
	}
}
