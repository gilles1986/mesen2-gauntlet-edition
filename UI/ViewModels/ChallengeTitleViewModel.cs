using Mesen.Utilities;
using System.Collections.ObjectModel;

namespace Mesen.ViewModels
{
	/// <summary>
	/// Backs the title screen shown once per challenge load (see ChallengeTitleWindow).
	/// Everything here is fixed at construction - the screen is read-only and closes on Start.
	/// </summary>
	public class ChallengeTitleViewModel : ViewModelBase
	{
		public string ChallengeName { get; }
		public string Date { get; }
		public bool HasDate => Date.Length > 0;
		public string Description { get; }
		public bool HasDescription => Description.Length > 0;
		public ObservableCollection<ChallengeTitleSegment> Segments { get; } = new();

		public ChallengeTitleViewModel(ChallengeMetadata meta, string fallbackName)
		{
			ChallengeName = meta.Name.Length > 0 ? meta.Name : fallbackName;
			Date = meta.Date;
			Description = meta.Description;

			int number = 1;
			foreach(ChallengeMetadata.SegmentInfo s in meta.Segments) {
				Segments.Add(new ChallengeTitleSegment(number++, s));
			}
		}
	}

	public class ChallengeTitleSegment
	{
		public string Number { get; }
		public string Name { get; }

		/// <summary>
		/// The credit line under the segment name, e.g. "Celery · Jordan". Composed here rather
		/// than in XAML so the partial cases stay in one place: either half may be missing, and
		/// a missing half must not leave a stray separator behind.
		/// </summary>
		public string Credit { get; }
		public bool HasCredit => Credit.Length > 0;

		public ChallengeTitleSegment(int number, ChallengeMetadata.SegmentInfo s)
		{
			Number = number.ToString();
			Name = s.Name;

			if(s.HackName.Length > 0 && s.HackAuthor.Length > 0) {
				Credit = s.HackName + "  ·  " + s.HackAuthor;
			} else {
				//Whichever one we have (or nothing at all).
				Credit = s.HackName.Length > 0 ? s.HackName : s.HackAuthor;
			}
		}
	}
}
