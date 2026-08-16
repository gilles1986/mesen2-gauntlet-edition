using Avalonia;
using Avalonia.Interactivity;
using Avalonia.Markup.Xaml;
using Mesen.Config;
using Mesen.Utilities;
using Mesen.ViewModels;
using System.Threading.Tasks;

namespace Mesen.Windows
{
	/// <summary>
	/// The title screen shown once when a challenge is loaded: logo, challenge name and the
	/// per-segment credits (hack + author) from challenge.json. It appears before the first ROM
	/// is loaded, so there is no running emulation to pause - "Cancel" simply starts nothing.
	///
	/// Deliberately tied to loading, not to the run: reset (L+R), segment changes and fail
	/// reloads never pass through here, so they never show it again.
	/// </summary>
	public class ChallengeTitleWindow : MesenWindow
	{
		public ChallengeTitleWindow()
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

		/// <summary>
		/// Shows the title screen for an installed challenge and returns true if the player
		/// wants to start it. Returns true without showing anything when the screen is turned
		/// off in Challenge Settings, or when the challenge has no usable challenge.json (packed
		/// before the file existed, or unreadable) - those start exactly the way they always did.
		/// </summary>
		public static async Task<bool> ConfirmStartAsync(Visual? parent, string challengeDir, string fallbackName)
		{
			if(!ConfigManager.Config.Challenge.ShowTitleScreen) {
				return true;
			}

			ChallengeMetadata? meta = ChallengeMetadata.TryLoad(challengeDir);
			if(meta == null) {
				return true;
			}

			ChallengeTitleWindow wnd = new() {
				DataContext = new ChallengeTitleViewModel(meta, fallbackName)
			};
			return await wnd.ShowCenteredDialog<bool>(parent);
		}

		private void Start_Click(object sender, RoutedEventArgs e)
		{
			Close(true);
		}

		private void Cancel_Click(object sender, RoutedEventArgs e)
		{
			Close(false);
		}
	}
}
