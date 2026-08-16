using Mesen.Utilities;
using ReactiveUI.Fody.Helpers;

namespace Mesen.ViewModels
{
	public class ChallengeUpdateViewModel : ViewModelBase
	{
		public ChallengeUpdater.ChallengeRelease Release { get; }

		public string LatestVersion { get; }
		public string InstalledVersion { get; }
		public string ReleaseDate { get; }

		[Reactive] public bool IsUpdating { get; set; } = false;
		[Reactive] public int Progress { get; set; } = 0;

		public ChallengeUpdateViewModel() : this(new ChallengeUpdater.ChallengeRelease()) { }

		public ChallengeUpdateViewModel(ChallengeUpdater.ChallengeRelease release)
		{
			Release = release;
			LatestVersion = release.VersionString;
			InstalledVersion = ChallengeUpdater.InstalledVersion.ToString();
			//created_at is an ISO-ish string from the server; show the date part only.
			ReleaseDate = release.CreatedAt.Length >= 10 ? release.CreatedAt.Substring(0, 10) : release.CreatedAt;
		}
	}
}
