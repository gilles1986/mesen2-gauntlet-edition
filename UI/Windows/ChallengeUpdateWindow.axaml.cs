using Avalonia;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Markup.Xaml;
using Avalonia.Threading;
using Mesen.Utilities;
using Mesen.ViewModels;
using System;
using System.ComponentModel;
using System.Threading.Tasks;

namespace Mesen.Windows
{
	public partial class ChallengeUpdateWindow : MesenWindow
	{
		private readonly ChallengeUpdateViewModel _model;

		public ChallengeUpdateWindow() : this(new ChallengeUpdateViewModel()) { }

		public ChallengeUpdateWindow(ChallengeUpdateViewModel model)
		{
			_model = model;
			DataContext = model;
			InitializeComponent();
#if DEBUG
			this.AttachDevTools();
#endif
		}

		private void InitializeComponent()
		{
			AvaloniaXamlLoader.Load(this);
		}

		protected override void OnClosing(WindowClosingEventArgs e)
		{
			base.OnClosing(e);
			//Don't let the user close the window mid-download (would leave a half-written file).
			if(_model.IsUpdating) {
				e.Cancel = true;
			}
		}

		private void Update_OnClick(object sender, RoutedEventArgs e)
		{
			_model.Progress = 0;
			_model.IsUpdating = true;

			IProgress<int> progress = new Progress<int>(p => _model.Progress = p);

			Task.Run(async () => {
				bool launched;
				try {
					launched = await ChallengeUpdater.DownloadAndLaunchAsync(_model.Release, progress);
				} catch(Exception ex) {
					Dispatcher.UIThread.Post(() => {
						_model.IsUpdating = false;
						MesenMsgBox.ShowException(ex);
					});
					return;
				}

				Dispatcher.UIThread.Post(() => {
					_model.IsUpdating = false;
					if(launched) {
						//Updater process is running; close so the exe unlocks and it can be replaced.
						Close(true);
					} else {
						MessageBox.Show(this, "The update could not be downloaded. Please try again later or download the latest version from saphros.de.", "Challenge Edition Update", MessageBoxButtons.OK, MessageBoxIcon.Error);
					}
				});
			});
		}

		private void Later_OnClick(object sender, RoutedEventArgs e)
		{
			Close(false);
		}
	}
}
