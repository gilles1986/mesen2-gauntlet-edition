using Avalonia.Media;
using Mesen.Utilities;
using ReactiveUI.Fody.Helpers;
using System;

namespace Mesen.ViewModels
{
	/// <summary>
	/// Backs both views of a challenge announcement: the popup (ChallengeAnnouncementWindow) and
	/// the banner at the top of Browse / Manage Challenges. Everything that isn't the install
	/// state is fixed once the announcement is fetched, so only that part is reactive.
	/// </summary>
	public class ChallengeAnnouncementViewModel : ViewModelBase
	{
		public ChallengeAnnouncements.Announcement Data { get; }

		public string Title => Data.Title;
		public string Message => Data.Message;
		public bool HasMessage => Data.Message.Length > 0;

		public string BadgeText => Data.BadgeText;
		public bool HasBadge => Data.BadgeText.Length > 0;

		/// <summary>
		/// Badge background per badge_type. These are dark enough for white text on both of
		/// Mesen's themes, so unlike the accent colors of the title screen they don't need a
		/// per-theme variant.
		/// </summary>
		public IBrush BadgeBrush => new SolidColorBrush(Color.Parse(Data.BadgeType switch {
			"upcoming" => "#6A4DBC",   //purple
			"info" => "#2166B8",       //blue
			"warning" => "#B35C0F",    //orange
			"success" => "#2E7D3B",    //green
			_ => "#55555F"             //unknown type: neutral gray rather than nothing
		}));

		/// <summary>"20 Aug 2026, 19:00 - 28 Aug 2026, 00:00" (local time), or just one side of it.</summary>
		public string DateRange {
			get {
				string start = Format(Data.StartAt);
				string end = Format(Data.EndAt);
				if(start.Length > 0 && end.Length > 0) {
					return start + "  -  " + end;
				}
				if(start.Length > 0) {
					return "From " + start;
				}
				return end.Length > 0 ? "Until " + end : "";
			}
		}
		public bool HasDateRange => DateRange.Length > 0;

		/// <summary>
		/// The linked challenge's own name/teaser, shown as a separate block below the message.
		/// For a teaser this is the "More info to come..." line the server sends.
		/// </summary>
		public string ChallengeName => Data.ChallengeName;
		public bool HasChallengeName => Data.ChallengeName.Length > 0;
		public string TeaserText => Data.TeaserText;
		public bool HasTeaserText => Data.TeaserText.Length > 0;
		public bool HasChallengeInfo => HasChallengeName || HasTeaserText;

		public bool HasLink => Data.CustomLink.Length > 0;
		public string Link => Data.CustomLink;

		/// <summary>Folder the linked challenge installs into, or "" when none is linked.</summary>
		public string ChallengeFolder => Data.ChallengeId.Length > 0 ? ChallengeImporter.SanitizeId(Data.ChallengeId) : "";

		//Install/play state of the linked challenge. Only a "ready" challenge has anything to
		//download - a teaser's .cha isn't published yet, so no button is offered for it.
		[Reactive] public bool IsInstalled { get; set; }
		[Reactive] public bool Busy { get; set; }
		[Reactive] public string Status { get; set; } = "";

		/// <summary>
		/// True when the announcement links a published challenge. The window then shows either
		/// Install or Play, picked by IsInstalled (two buttons rather than one with a computed
		/// caption, so the swap follows the reactive property - same as the challenge browser).
		/// </summary>
		public bool HasChallengeAction => Data.IsChallengeReady;

		//For the XAML designer only.
		public ChallengeAnnouncementViewModel() : this(new ChallengeAnnouncements.Announcement()) { }

		public ChallengeAnnouncementViewModel(ChallengeAnnouncements.Announcement data)
		{
			Data = data;
			RefreshInstalled();
		}

		public void RefreshInstalled()
		{
			IsInstalled = Data.IsChallengeReady && ChallengeCatalog.IsFolderInstalled(ChallengeFolder);
		}

		private static string Format(DateTime? value)
		{
			return value == null ? "" : value.Value.ToString("d MMM yyyy, HH:mm");
		}
	}
}
