using Avalonia;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Markup.Xaml;
using Mesen.Utilities;
using Mesen.ViewModels;

namespace Mesen.Windows
{
	public class ChallengeSettingsWindow : MesenWindow
	{
		public ChallengeSettingsWindow()
		{
			InitializeComponent();
#if DEBUG
			this.AttachDevTools();
#endif
			//Don't leave a login poll loop running in the background after the window closes.
			Closing += (s, e) => (DataContext as ChallengeSettingsViewModel)?.CancelLogin();
		}

		private void InitializeComponent()
		{
			AvaloniaXamlLoader.Load(this);
		}

		private void Ok_OnClick(object sender, RoutedEventArgs e)
		{
			((ChallengeSettingsViewModel)DataContext!).SaveConfig();
			Close(true);
		}

		private void Cancel_OnClick(object sender, RoutedEventArgs e)
		{
			Close(false);
		}

		private async void LoginWithTwitch_OnClick(object sender, RoutedEventArgs e)
		{
			await ((ChallengeSettingsViewModel)DataContext!).LoginWithTwitchAsync();
		}

		private void CancelLogin_OnClick(object sender, RoutedEventArgs e)
		{
			((ChallengeSettingsViewModel)DataContext!).CancelLogin();
		}

		private async void LogoutOfTwitch_OnClick(object sender, RoutedEventArgs e)
		{
			await ((ChallengeSettingsViewModel)DataContext!).LogoutOfTwitchAsync();
		}

		private void ResetStreamStats_OnClick(object sender, RoutedEventArgs e)
		{
			ChallengeManager.ResetStreamStats();
			//Brief confirmation; re-enables next time the window opens (fresh instance).
			if(sender is Button b) {
				b.Content = "Session stats reset";
				b.IsEnabled = false;
			}
		}
	}
}
