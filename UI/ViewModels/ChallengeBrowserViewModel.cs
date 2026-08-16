using Mesen.Config;
using Mesen.Utilities;
using ReactiveUI.Fody.Helpers;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Threading.Tasks;

namespace Mesen.ViewModels
{
	public class ChallengeBrowserViewModel : ViewModelBase
	{
		[Reactive] public ObservableCollection<ChallengeBrowserItem> Items { get; set; } = new();
		[Reactive] public bool IsLoading { get; set; }
		[Reactive] public string Status { get; set; } = "";

		//Current announcement, shown as a banner above the list (null = none / turned off /
		//server unreachable). The same data the startup popup uses.
		[Reactive] public ChallengeAnnouncementViewModel? Announcement { get; set; }
		[Reactive] public bool HasAnnouncement { get; set; }

		/// <summary>
		/// Fetches the catalog from the server, marks which entries are installed, and appends
		/// every locally installed challenge that has no catalog entry (manual .cha imports, or
		/// challenges the server no longer lists) so those can be deleted here too. A failed
		/// fetch still lists the local installs - deleting must work offline.
		/// </summary>
		public async Task LoadAsync()
		{
			IsLoading = true;
			Status = "Loading challenges...";

			//Started before the catalog request and awaited after it, so the announcement rides
			//along instead of adding its own wait. It never throws - no announcement, no banner.
			Task<ChallengeAnnouncements.Announcement?> announcementTask = ConfigManager.Config.Challenge.ShowAnnouncements
				? ChallengeAnnouncements.FetchAsync()
				: Task.FromResult<ChallengeAnnouncements.Announcement?>(null);

			string? error = null;
			List<ChallengeCatalog.CatalogEntry> entries = new();
			try {
				entries = await ChallengeCatalog.FetchAsync();
			} catch(Exception ex) {
				error = ex.Message;
			}

			Items.Clear();
			HashSet<string> catalogFolders = new(StringComparer.OrdinalIgnoreCase);
			foreach(ChallengeCatalog.CatalogEntry e in entries) {
				Items.Add(new ChallengeBrowserItem(e));
				catalogFolders.Add(ChallengeImporter.SanitizeId(e.Id));
			}

			foreach((string folder, string name) in ChallengeManager.GetChallengeList()) {
				if(!catalogFolders.Contains(folder)) {
					Items.Add(ChallengeBrowserItem.CreateLocal(folder, name));
				}
			}

			ChallengeAnnouncements.Announcement? announcement = await announcementTask;
			Announcement = announcement == null ? null : new ChallengeAnnouncementViewModel(announcement);
			HasAnnouncement = Announcement != null;

			RefreshInstalled();
			if(error != null) {
				Status = "Catalog unavailable (" + error + ") - installed challenges are still listed.";
			} else {
				Status = Items.Count == 0 ? "No challenges available." : (Items.Count + " challenge(s) available.");
			}
			IsLoading = false;
		}

		/// <summary>Re-checks the local install state for every listed challenge.</summary>
		public void RefreshInstalled()
		{
			foreach(ChallengeBrowserItem item in Items) {
				item.Installed = ChallengeCatalog.IsFolderInstalled(item.Folder);
			}
			//The banner offers Install/Play for the challenge it links, so it tracks the same state.
			Announcement?.RefreshInstalled();
		}

		/// <summary>Drops local-only entries that are no longer installed (nothing left to show).</summary>
		public void RemoveIfLocalOnly(ChallengeBrowserItem item)
		{
			if(item.IsLocalOnly) {
				Items.Remove(item);
			}
		}
	}

	public class ChallengeBrowserItem : ViewModelBase
	{
		public ChallengeCatalog.CatalogEntry Data { get; }

		public string Name => Data.Name;
		public bool IsActive => Data.IsActive;

		/// <summary>Folder under challenges/ this entry installs to / was found in.</summary>
		public string Folder { get; }

		/// <summary>
		/// True for a challenge that only exists locally (imported from a .cha file, or dropped
		/// from the catalog): there is nothing to download, so only Delete is offered.
		/// </summary>
		public bool IsLocalOnly { get; }

		public bool CanInstall => !IsLocalOnly;

		[Reactive] public bool Installed { get; set; }
		[Reactive] public bool Busy { get; set; }

		public ChallengeBrowserItem(ChallengeCatalog.CatalogEntry data, bool isLocalOnly = false)
		{
			Data = data;
			//A local entry is named after the folder it was found in - keep it verbatim (a
			//manually renamed folder wouldn't survive SanitizeId).
			Folder = isLocalOnly ? data.Id : ChallengeImporter.SanitizeId(data.Id);
			IsLocalOnly = isLocalOnly;
		}

		/// <summary>Entry for an installed challenge folder that has no catalog entry.</summary>
		public static ChallengeBrowserItem CreateLocal(string folder, string displayName)
		{
			return new ChallengeBrowserItem(new ChallengeCatalog.CatalogEntry() {
				Id = folder,
				Name = displayName
			}, true);
		}
	}
}
