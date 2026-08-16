using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

namespace Mesen.Utilities
{
	/// <summary>
	/// Plays the achievement-unlock jingle. Mesen's Lua API can't play arbitrary sounds
	/// (only muteAudio), so the C# submit path — which already knows when achievements
	/// unlock (see ChallengeSubmit) — handles it instead.
	///
	/// Windows-only via winmm's PlaySound (no extra dependency). We always play from a file
	/// path (SND_FILENAME|SND_ASYNC): async so it doesn't block the submit thread, and from
	/// a file rather than a managed byte[] to avoid the GC-moving-the-buffer-mid-playback
	/// gotcha of SND_MEMORY|SND_ASYNC. The bundled jingle is extracted to temp once; a
	/// user-supplied "achievement.wav" next to Mesen.exe overrides it (streamers can drop in
	/// their own). Any failure is swallowed — sound is purely cosmetic.
	/// </summary>
	public static class ChallengeSound
	{
		private const string ResourceName = "Mesen.ChallengeEngine.achievement.wav";

		[Flags]
		private enum SoundFlags : uint
		{
			SND_ASYNC = 0x0001,
			SND_NODEFAULT = 0x0002,
			SND_FILENAME = 0x00020000,
		}

		[DllImport("winmm.dll", CharSet = CharSet.Unicode, SetLastError = false)]
		private static extern bool PlaySound(string? pszSound, IntPtr hmod, SoundFlags fdwSound);

		private static string? _bundledPath;
		private static bool _extractTried;

		/// <summary>Plays the achievement jingle (fire-and-forget). No-op off Windows.</summary>
		public static void PlayAchievement()
		{
			if(!OperatingSystem.IsWindows()) {
				return;
			}

			try {
				string? soundPath = ResolveSoundPath();
				if(soundPath != null) {
					PlaySound(soundPath, IntPtr.Zero, SoundFlags.SND_FILENAME | SoundFlags.SND_ASYNC | SoundFlags.SND_NODEFAULT);
				}
			} catch {
				//Cosmetic only — never let a missing sound device break a submit.
			}
		}

		/// <summary>User override next to the exe if present, else the extracted bundled jingle.</summary>
		private static string? ResolveSoundPath()
		{
			string? exeDir = Path.GetDirectoryName(Program.ExePath) ?? Program.OriginalFolder;
			string custom = Path.Combine(exeDir, "achievement.wav");
			if(File.Exists(custom)) {
				return custom;
			}
			return GetBundledPath();
		}

		/// <summary>Extracts the embedded jingle to a stable temp file once; returns its path.</summary>
		private static string? GetBundledPath()
		{
			if(_extractTried) {
				return _bundledPath != null && File.Exists(_bundledPath) ? _bundledPath : null;
			}
			_extractTried = true;
			try {
				Assembly assembly = Assembly.GetExecutingAssembly();
				using Stream? stream = assembly.GetManifestResourceStream(ResourceName);
				if(stream == null) {
					return null;
				}
				string path = Path.Combine(Path.GetTempPath(), "mesen_achievement.wav");
				using(FileStream fs = File.Create(path)) {
					stream.CopyTo(fs);
				}
				_bundledPath = path;
			} catch {
				_bundledPath = null;
			}
			return _bundledPath;
		}
	}
}
