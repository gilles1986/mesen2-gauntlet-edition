using Mesen.Utilities;
using ReactiveUI.Fody.Helpers;
using System;
using System.Threading.Tasks;

namespace Mesen.ViewModels
{
	/// <summary>
	/// Drives the replay prompt through its three states: fetching the replay, showing which Lauf
	/// it is, or explaining why it couldn't be fetched.
	///
	/// It is one window rather than a chain of message boxes on purpose - this is the one-click
	/// path from the website, so a failure has to be reported and retried in place instead of
	/// bouncing the player through dialogs. Nothing here changes the emulator's state; a running
	/// challenge is only stopped once the caller acts on the choice.
	///
	/// Everything it displays comes from the downloaded package (see ChallengeReplayInfo), never
	/// from the link that pointed at it - docs/adr/0002.
	/// </summary>
	public class ChallengeReplayPromptViewModel : ViewModelBase
	{
		[Reactive] public bool IsLoading { get; set; } = true;
		[Reactive] public bool IsReady { get; set; }
		[Reactive] public bool HasError { get; set; }

		[Reactive] public string ErrorMessage { get; set; } = "";

		/// <summary>Retry only makes sense for something that can go differently next time - a
		/// download. Opening a local file that isn't a replay will fail identically forever.</summary>
		[Reactive] public bool CanRetry { get; set; }

		[Reactive] public string ChallengeName { get; set; } = "";
		[Reactive] public string Player { get; set; } = "";
		[Reactive] public bool HasPlayer { get; set; }
		[Reactive] public string TotalTime { get; set; } = "";
		[Reactive] public bool HasTotalTime { get; set; }
		[Reactive] public string Segments { get; set; } = "";

		/// <summary>Packages recorded before ghosts were bundled can be watched but not raced.</summary>
		[Reactive] public bool CanRace { get; set; }

		//No "a challenge is running" warning: to open a replay you have to click a link or a file,
		//and during a real run both hands are on the controller - it cannot happen. Anything that
		//IS running when a replay starts is a previous replay or a practice segment, where nothing
		//is at stake. The start paths stop whatever is active by themselves.

		/// <summary>The challenge this replay belongs to isn't installed. Announced before the
		/// choice, then installed as part of confirming it - so the player clicks once, not twice.</summary>
		[Reactive] public bool IsChallengeMissing { get; set; }

		/// <summary>An install is running. The actions are disabled meanwhile, and the status line
		/// below says what is happening - a challenge package is several megabytes, so silence here
		/// would read as a hang.</summary>
		[Reactive] public bool IsInstalling { get; set; }
		[Reactive] public string InstallStatus { get; set; } = "";

		/// <summary>The prepared replay once loading succeeded - what the caller starts.</summary>
		public ChallengeReplayLauncher.PreparedReplay? Prepared { get; private set; }

		private readonly Func<Task<ChallengeReplayLauncher.PreparedReplay>> _prepare;
		private readonly bool _retryable;
		private Task _loading = Task.CompletedTask;

		public ChallengeReplayPromptViewModel(Func<Task<ChallengeReplayLauncher.PreparedReplay>> prepare, bool retryable)
		{
			_prepare = prepare;
			_retryable = retryable;
		}

		/// <summary>
		/// The fetch currently in flight, so a caller that closed the window early can still wait
		/// for it and clean up what it produced.
		/// </summary>
		public Task Completion => _loading;

		/// <summary>Starts (or restarts) the fetch. The result arrives through the reactive state,
		/// so nothing needs to await this.</summary>
		public void BeginLoad()
		{
			_loading = LoadAsync();
		}

		/// <summary>
		/// Runs the fetch. Never throws: a failure becomes the error state, which is the whole
		/// point of showing this window before the work starts.
		/// </summary>
		private async Task LoadAsync()
		{
			IsLoading = true;
			IsReady = false;
			HasError = false;
			ErrorMessage = "";
			//Cleared too, so a successful retry doesn't leave a dead "Try again" button sitting
			//next to the Watch/Race buttons.
			CanRetry = false;
			Prepared = null;

			try {
				ChallengeReplayLauncher.PreparedReplay prepared = await _prepare();
				Apply(prepared);
			} catch(ChallengeReplayException ex) {
				//Already worded for the player.
				Fail(ex.Message);
			} catch(Exception ex) {
				Fail("Couldn't open the replay: " + ex.Message);
			}
		}

		private void Apply(ChallengeReplayLauncher.PreparedReplay prepared)
		{
			ChallengeReplayInfo info = prepared.Info;

			ChallengeName = prepared.ChallengeName.Length > 0 ? prepared.ChallengeName : info.ChallengeId;
			Player = info.Player;
			HasPlayer = info.Player.Length > 0;
			TotalTime = info.TotalTime;
			HasTotalTime = info.TotalTime.Length > 0;
			Segments = info.SegmentCount == 1 ? "1 segment" : info.SegmentCount + " segments";
			CanRace = info.HasGhosts;

			IsChallengeMissing = !prepared.ChallengeInstalled;

			Prepared = prepared;
			IsLoading = false;
			HasError = false;
			IsReady = true;
		}

		/// <summary>Puts the window into its error state from outside the fetch - used when the
		/// install that a confirmation triggered couldn't be completed.</summary>
		public void ShowError(string message)
		{
			Fail(message);
		}

		/// <summary>The challenge was just installed, so the missing-challenge warning goes away and
		/// the prompt can show its real name instead of the slug.</summary>
		public void OnChallengeInstalled(string challengeName)
		{
			IsChallengeMissing = false;
			InstallStatus = "";
			if(challengeName.Length > 0) {
				ChallengeName = challengeName;
			}
		}

		private void Fail(string message)
		{
			ErrorMessage = message;
			CanRetry = _retryable;
			IsLoading = false;
			IsReady = false;
			HasError = true;
		}
	}
}
