using Avalonia;
using Avalonia.Interactivity;
using Avalonia.Markup.Xaml;
using Mesen.Utilities;
using Mesen.ViewModels;
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
	/// Asks what should happen with a replay that is about to be started - watch it, or race its
	/// ghost - after showing which Lauf it actually is (challenge, player, time, segments).
	///
	/// It is deliberately one window rather than a chain of message boxes: this is the whole
	/// point of the one-click path from the website, and warnings (a running challenge, a package
	/// without ghost data) belong next to the choice they affect, not in front of it.
	///
	/// Nothing here changes the emulator's state - a running challenge is only stopped once the
	/// caller acts on the returned choice.
	/// </summary>
	public class ChallengeReplayPromptWindow : MesenWindow
	{
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

		/// <summary>Shows the prompt and returns the chosen action (Cancel if dismissed).</summary>
		public static Task<ChallengeReplayAction> AskAsync(Visual? parent, ChallengeReplayPromptViewModel model)
		{
			ChallengeReplayPromptWindow wnd = new() { DataContext = model };
			return wnd.ShowCenteredDialog<ChallengeReplayAction>(parent);
		}

		private void Watch_Click(object sender, RoutedEventArgs e)
		{
			Close(ChallengeReplayAction.Watch);
		}

		private void Race_Click(object sender, RoutedEventArgs e)
		{
			Close(ChallengeReplayAction.Race);
		}

		private void Cancel_Click(object sender, RoutedEventArgs e)
		{
			Close(ChallengeReplayAction.Cancel);
		}
	}
}
