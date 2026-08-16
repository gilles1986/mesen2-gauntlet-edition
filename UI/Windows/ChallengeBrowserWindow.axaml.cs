using Avalonia;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Markup.Xaml;
using Mesen.Utilities;
using Mesen.ViewModels;
using System;
using System.Threading.Tasks;

namespace Mesen.Windows
{
	public class ChallengeBrowserWindow : MesenWindow
	{
		private ChallengeBrowserViewModel Model => (ChallengeBrowserViewModel)DataContext!;

		public ChallengeBrowserWindow()
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

		protected override void OnOpened(EventArgs e)
		{
			base.OnOpened(e);
			_ = Model.LoadAsync();
		}

		private async void Refresh_Click(object sender, RoutedEventArgs e)
		{
			await Model.LoadAsync();
		}

		private async void Install_Click(object sender, RoutedEventArgs e)
		{
			if((sender as Control)?.DataContext is ChallengeBrowserItem item) {
				await InstallItem(item);
			}
		}

		private async void Delete_Click(object sender, RoutedEventArgs e)
		{
			if((sender as Control)?.DataContext is not ChallengeBrowserItem item) {
				return;
			}

			//Deleting the folder underneath a running challenge would break it mid-run (and the
			//locked files would make the delete fail half-way anyway).
			if(ChallengeManager.ActiveChallengeFolder.Equals(item.Folder, StringComparison.OrdinalIgnoreCase)) {
				await MessageBox.Show(this,
					"'" + item.Name + "' is currently running. Stop the challenge before deleting it.",
					"Browse Challenges", MessageBoxButtons.OK, MessageBoxIcon.Warning);
				return;
			}

			DialogResult confirm = await MessageBox.Show(this,
				"Delete the installed challenge '" + item.Name + "'? This removes its local files, " +
				"including its personal bests and ghosts.",
				"Browse Challenges", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
			if(confirm != DialogResult.Yes) {
				return;
			}

			item.Busy = true;
			try {
				ChallengeCatalog.DeleteFolder(item.Folder);
				item.Installed = false;
				//A locally imported challenge has no catalog entry left to show once it's gone.
				Model.RemoveIfLocalOnly(item);
			} catch(Exception ex) {
				await MessageBox.Show(this,
					"Delete failed: " + ex.Message + "\n(Is the challenge currently running?)",
					"Browse Challenges", MessageBoxButtons.OK, MessageBoxIcon.Error);
			} finally {
				item.Busy = false;
			}
		}

		/// <summary>
		/// Opens the announcement banner's full popup. It can install the linked challenge, so
		/// the list's install state is re-checked once it closes.
		/// </summary>
		private async void Announcement_Click(object sender, RoutedEventArgs e)
		{
			if((sender as Control)?.DataContext is ChallengeAnnouncementViewModel announcement) {
				await ChallengeAnnouncementWindow.ShowAsync(this, announcement.Data);
				Model.RefreshInstalled();
			}
		}

		private void Close_Click(object sender, RoutedEventArgs e)
		{
			Close();
		}

		private async Task InstallItem(ChallengeBrowserItem item)
		{
			//Prompts for + validates the SMW ROM on first use (EnsureCleanRomAsync explains
			//any failure itself), so we just bail out quietly if it comes back null.
			string? cleanRom = await ChallengeManager.EnsureCleanRomAsync(this);
			if(cleanRom == null) {
				return;
			}

			item.Busy = true;
			try {
				await ChallengeCatalog.InstallAsync(item.Data, cleanRom);
				item.Installed = true;
				await MessageBox.Show(this, "Installed '" + item.Name + "'.",
					"Browse Challenges", MessageBoxButtons.OK, MessageBoxIcon.Info);
			} catch(Exception ex) {
				await MessageBox.Show(this, "Install failed: " + ex.Message,
					"Browse Challenges", MessageBoxButtons.OK, MessageBoxIcon.Error);
			} finally {
				item.Busy = false;
			}
		}
	}
}
