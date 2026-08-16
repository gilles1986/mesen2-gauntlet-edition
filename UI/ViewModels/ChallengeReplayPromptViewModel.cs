using Mesen.Utilities;

namespace Mesen.ViewModels
{
	/// <summary>
	/// What the replay prompt shows about a Lauf before it is started: which challenge it belongs
	/// to, who played it, how long it took - plus the two warnings that decide what happens on
	/// confirm (a running challenge will be stopped) and what can be chosen at all (a package
	/// without ghost traces can't be raced).
	///
	/// Everything here comes from ChallengeReplayInfo, i.e. from the package itself.
	/// </summary>
	public class ChallengeReplayPromptViewModel : ViewModelBase
	{
		public string ChallengeName { get; }
		public string Player { get; }
		public string TotalTime { get; }
		public string Segments { get; }

		/// <summary>Old recordings carry no player name; showing an empty row would just look
		/// broken.</summary>
		public bool HasPlayer => Player.Length > 0;

		/// <summary>Recordings that don't state their segment lengths can't be totalled, so the
		/// time row is hidden rather than showing a made-up 0:00.000.</summary>
		public bool HasTotalTime => TotalTime.Length > 0;

		/// <summary>Packages recorded before ghosts were bundled can be watched but not raced.</summary>
		public bool CanRace { get; }
		public bool CannotRace => !CanRace;

		/// <summary>A challenge is running right now. Starting the replay ends it - which is why
		/// this is shown before the choice is made, and why nothing is stopped until then.</summary>
		public bool IsChallengeRunning { get; }

		public ChallengeReplayPromptViewModel(ChallengeReplayInfo info, string challengeName, bool isChallengeRunning)
		{
			ChallengeName = challengeName.Length > 0 ? challengeName : info.ChallengeId;
			Player = info.Player;
			TotalTime = info.TotalTime;
			Segments = info.SegmentCount == 1 ? "1 segment" : info.SegmentCount + " segments";
			CanRace = info.HasGhosts;
			IsChallengeRunning = isChallengeRunning;
		}
	}
}
