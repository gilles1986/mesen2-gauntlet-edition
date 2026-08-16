using Mesen.Config;
using Mesen.Utilities;
using ReactiveUI.Fody.Helpers;
using System;
using System.Threading;
using System.Threading.Tasks;

namespace Mesen.ViewModels
{
	public class ChallengeSettingsViewModel : ViewModelBase
	{
		[Reactive] public ChallengeConfig Config { get; set; }

		//Twitch login is a deliberate, effortful action (switching to a browser to
		//authenticate) - unlike the other settings here, it's written to the live config
		//and saved to disk immediately (see ChallengeTwitchAuth), not held for OK/Cancel.
		//These just mirror that live state so the open dialog reflects it right away.
		[Reactive] public bool IsLoggingIn { get; set; } = false;
		[Reactive] public string LoginStatusText { get; set; } = "";

		private CancellationTokenSource? _loginCts;

		public ChallengeSettingsViewModel()
		{
			//Edit a clone; only written back to the live config on OK (except the Twitch
			//fields, which LoginAsync/LogoutAsync already committed to the live config).
			Config = ConfigManager.Config.Challenge.Clone();
		}

		public void SaveConfig()
		{
			//Preserve whatever the live Twitch link state currently is (Login/Logout may
			//have changed it since this dialog opened) rather than overwriting it with
			//this clone's now-stale copy.
			ChallengeConfig live = ConfigManager.Config.Challenge;
			Config.IsTwitchLinked = live.IsTwitchLinked;
			Config.TwitchLinkToken = live.TwitchLinkToken;
			Config.TwitchLogin = live.TwitchLogin;
			Config.TwitchDisplayName = live.TwitchDisplayName;
			Config.TwitchAvatarUrl = live.TwitchAvatarUrl;

			//Same reasoning for the dismissed-announcement marker: it's written by the
			//announcement popup, not edited here, so this clone must never roll it back.
			Config.LastDismissedAnnouncementId = live.LastDismissedAnnouncementId;

			ConfigManager.Config.Challenge = Config.Clone();

			//Unlike the display settings (which the engine picks up on its next load), the file
			//association is system state - apply it now so turning it off actually releases the
			//.creplay extension instead of waiting for the next launch.
			FileAssociationHelper.UpdateChallengeReplayAssociation(ConfigManager.Config.Challenge.AssociateReplayFiles);
		}

		/// <summary>The replay file association is a Windows-only registry entry, so the option
		/// is hidden where it would do nothing (see docs/adr/0002).</summary>
		public bool IsWindows => OperatingSystem.IsWindows();

		public async Task LoginWithTwitchAsync()
		{
			if(IsLoggingIn) {
				return;
			}

			IsLoggingIn = true;
			LoginStatusText = "Contacting server...";
			_loginCts = new CancellationTokenSource();

			ChallengeTwitchAuth.LoginOutcome outcome = await ChallengeTwitchAuth.LoginAsync(
				info => LoginStatusText = info.BrowserOpened
					? "Waiting for browser login... code: " + info.UserCode
					//The browser didn't launch - the login still works if the page is opened by hand.
					: "Couldn't open your browser. Open this page yourself: " + info.VerificationUrl,
				_loginCts.Token
			);

			SyncFromLiveConfig();
			IsLoggingIn = false;
			LoginStatusText = outcome.Result switch {
				ChallengeTwitchAuth.LoginResult.Success => "",
				ChallengeTwitchAuth.LoginResult.Cancelled => "Login cancelled.",
				ChallengeTwitchAuth.LoginResult.Expired => "Login timed out, please try again.",
				_ => "Login failed: " + outcome.Error
			};
			_loginCts = null;
		}

		public void CancelLogin()
		{
			_loginCts?.Cancel();
		}

		public async Task LogoutOfTwitchAsync()
		{
			await ChallengeTwitchAuth.LogoutAsync();
			SyncFromLiveConfig();
		}

		private void SyncFromLiveConfig()
		{
			ChallengeConfig live = ConfigManager.Config.Challenge;
			Config.IsTwitchLinked = live.IsTwitchLinked;
			Config.TwitchLinkToken = live.TwitchLinkToken;
			Config.TwitchLogin = live.TwitchLogin;
			Config.TwitchDisplayName = live.TwitchDisplayName;
			Config.TwitchAvatarUrl = live.TwitchAvatarUrl;
		}
	}
}
