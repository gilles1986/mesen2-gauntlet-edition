using Avalonia;
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
	/// <summary>What the player chose to do with a replay.</summary>
	public enum ChallengeReplayAction
	{
		//Must stay 0: closing the window with Escape or the title bar yields default(TResult).
		Cancel = 0,
		Watch,
		Race
	}

	/// <summary>
	/// Asks what should happen with a replay - watch it, or race its ghost - after showing which
	/// Lauf it actually is (challenge, player, time, segments).
	///
	/// The window opens first and fetches afterwards: the replay may still have to be downloaded
	/// from saphros.de, and a one-click path from the website must not spend seconds looking like
	/// nothing happened. Failures are reported and retried in here for the same reason.
	///
	/// Nothing here changes the emulator's state - a running challenge is only stopped once the
	/// caller acts on the returned choice.
	/// </summary>
	public class ChallengeReplayPromptWindow : MesenWindow
	{
		private ChallengeReplayPromptViewModel Model => (ChallengeReplayPromptViewModel)DataContext!;

		//The fetch runs detached from the dialog, so it can finish after the player closed the
		//window. Closing an already-closed window must not be attempted.
		private bool _closed;

		public ChallengeReplayPromptWindow()
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

		/// <summary>Shows the prompt, starts the fetch, and returns the chosen action (Cancel if
		/// dismissed - including while it was still loading).</summary>
		public static Task<ChallengeReplayAction> AskAsync(Visual? parent, ChallengeReplayPromptViewModel model)
		{
			ChallengeReplayPromptWindow wnd = new() { DataContext = model };
			return wnd.ShowCenteredDialog<ChallengeReplayAction>(parent);
		}

		protected override void OnOpened(EventArgs e)
		{
			base.OnOpened(e);

			//Started here rather than in the constructor so the window is already on screen while
			//the download runs. The result arrives through the view model's state; failures become
			//the error state rather than an exception.
			Model.BeginLoad();
			_ = AutoConfirmWhenReadyAsync();
		}

		protected override void OnClosed(EventArgs e)
		{
			_closed = true;
			base.OnClosed(e);
		}

		/// <summary>
		/// Honours the player's chosen default (Challenge → Settings → Opening a replay) by skipping
		/// the question - but only when the choice is genuinely free. Picking a default authorises
		/// "watch" or "race", not installing a challenge, not ending a run that is in progress, and
		/// not silently watching when racing was asked for and is impossible. Each of those falls
		/// back to the prompt, which is on screen anyway.
		/// </summary>
		private async Task AutoConfirmWhenReadyAsync()
		{
			await Model.Completion;

			ChallengeReplayOpen mode = ConfigManager.Config.Challenge.ReplayOpenMode;
			if(_closed || mode == ChallengeReplayOpen.Ask || !Model.IsReady) {
				return;
			}
			//Installing a challenge is a bigger step than watching a run, and picking a default
			//didn't authorise it - that one still asks.
			if(Model.IsChallengeMissing) {
				return;
			}
			if(mode == ChallengeReplayOpen.Race && !Model.CanRace) {
				return;
			}

			await ConfirmAsync(mode == ChallengeReplayOpen.Race ? ChallengeReplayAction.Race : ChallengeReplayAction.Watch);
		}

		private void Retry_Click(object sender, RoutedEventArgs e)
		{
			Model.BeginLoad();
		}

		private async void Watch_Click(object sender, RoutedEventArgs e)
		{
			await ConfirmAsync(ChallengeReplayAction.Watch);
		}

		private async void Race_Click(object sender, RoutedEventArgs e)
		{
			await ConfirmAsync(ChallengeReplayAction.Race);
		}

		/// <summary>Acts on a chosen action: installs the challenge first if it isn't there, and only
		/// closes once that succeeded - otherwise the reason stays on screen.</summary>
		private async Task ConfirmAsync(ChallengeReplayAction action)
		{
			if(await EnsureChallengeInstalledAsync() && !_closed) {
				Close(action);
			}
		}

		/// <summary>
		/// Installs the replay's challenge if it isn't there yet, so confirming costs one click
		/// rather than sending the player off to the challenge browser and back. Returns false if
		/// it couldn't be done (or the player backed out) - then the window stays open with the
		/// reason on screen, instead of starting a replay that has no challenge to run in.
		///
		/// Deliberately the same steps as ChallengeBrowserWindow.InstallItem: same catalog, same
		/// clean-ROM prompt, same failure wording.
		/// </summary>
		private async Task<bool> EnsureChallengeInstalledAsync()
		{
			ChallengeReplayLauncher.PreparedReplay? prepared = Model.Prepared;
			if(prepared == null) {
				return false;
			}
			if(prepared.ChallengeInstalled) {
				return true;
			}

			string challengeId = prepared.Info.ChallengeId;
			Model.IsInstalling = true;
			Model.InstallStatus = "Looking up the challenge…";
			try {
				//The replay only names the challenge's slug, so the download URL has to come from
				//the catalog - the same source the challenge browser installs from.
				List<ChallengeCatalog.CatalogEntry> entries = await ChallengeCatalog.FetchAsync();
				ChallengeCatalog.CatalogEntry? entry = null;
				foreach(ChallengeCatalog.CatalogEntry candidate in entries) {
					if(string.Equals(ChallengeImporter.SanitizeId(candidate.Id), challengeId, StringComparison.OrdinalIgnoreCase)) {
						entry = candidate;
						break;
					}
				}

				if(entry == null) {
					Model.ShowError("This replay's challenge (\"" + challengeId + "\") isn't available for download, " +
						"so it can't be installed automatically. If you have the .cha package, import it via " +
						"Challenge → Import Challenge…, then open the replay again.");
					return false;
				}

				//Prompts for + validates the SMW ROM on first use and explains any failure itself,
				//so null just means "don't install" - back to the prompt, nothing half-installed.
				Model.InstallStatus = "Waiting for the Super Mario World ROM…";
				string? cleanRom = await ChallengeManager.EnsureCleanRomAsync(this);
				if(cleanRom == null) {
					Model.IsInstalling = false;
					Model.InstallStatus = "";
					return false;
				}

				Model.InstallStatus = "Installing '" + entry.Name + "'…";
				await ChallengeCatalog.InstallAsync(entry, cleanRom);
				Model.OnChallengeInstalled(entry.Name);
				return true;
			} catch(Exception ex) {
				Model.ShowError("Installing the challenge failed: " + ex.Message);
				return false;
			} finally {
				Model.IsInstalling = false;
			}
		}

		private void Cancel_Click(object sender, RoutedEventArgs e)
		{
			Close(ChallengeReplayAction.Cancel);
		}
	}
}
