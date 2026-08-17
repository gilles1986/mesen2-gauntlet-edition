using Avalonia.Controls;
using Avalonia.Threading;
using Mesen.Config;
using Mesen.Interop;
using Mesen.ViewModels;
using Mesen.Windows;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace Mesen.Utilities
{
	/// <summary>
	/// Drives the embedded, non-editable Kaizo challenge engine (AP1) and the
	/// challenge lockdown mode (AP2).
	///
	/// The engine (formerly the loose <c>relay.lua</c>) is shipped as an embedded
	/// resource and injected through <see cref="DebugApi.LoadScript"/> with no script
	/// window, so the player cannot edit it. The actual challenge data (games.lua +
	/// ROMs/states) lives in a <c>challenges/</c> folder next to the executable; the
	/// user picks/starts a challenge from the "Challenge" menu (see GetAvailableChallenges
	/// / StartChallenge).
	///
	/// Because the engine relies on being re-run after every ROM switch (the multi
	/// segment relay mechanism), this class re-injects the engine on every GameLoaded
	/// notification while a challenge is active - mirroring what the ScriptWindow does
	/// for regular scripts.
	/// </summary>
	public static class ChallengeManager
	{
		private enum ChallengeState
		{
			Inactive,
			//A bootstrap ROM is being loaded so that the debugger/engine can start
			//(LoadScript is a no-op while no ROM is running).
			Pending,
			//The engine is loaded and the lockdown is active.
			Active
		}

		//Logical name of the embedded engine resource (see UI.csproj). Deliberately not
		//a ".lua" name so it stays out of the auto-enumerated "Built-in Scripts" menu.
		private const string EngineResourceName = "Mesen.ChallengeEngine.relay.lua.txt";

		private static ChallengeState _state = ChallengeState.Inactive;
		private static string _challengeDir = "";
		private static int _scriptId = -1;
		private static FileSystemWatcher? _submitWatcher;
		private static FileSystemWatcher? _reloadWatcher;
		private static FileSystemWatcher? _exportWatcher;
		private static bool _exportBusy = false;   //guards against a mashed SELECT opening multiple dialogs
		private static bool _forceReset = false;
		private static int _practiceSegment = 0;   //>0 = practice that segment (no scoring/submit)
		private static string _replayDir = "";
		private static string _replayPlayer = "";   //name shown during replay (from the replay's header)
		private static string _ghostDir = "";        //>"" = race a foreign ghost from this dir (seg<idx>.ghost) instead of the local PB ghost

		private static bool _overclockSaved = false;
		private static uint _savedPpuExtraScanlinesBeforeNmi;
		private static uint _savedPpuExtraScanlinesAfterNmi;
		private static uint _savedGsuClockSpeed;
		private static int _savedSpcClockSpeedAdjustment;

		public static bool IsActive => _state == ChallengeState.Active;
		public static bool IsInactive => _state == ChallengeState.Inactive;

		/// <summary>
		/// Folder name (under challenges/) of the challenge that is currently loaded, or "" when
		/// none is. Used to keep the browser from deleting the files out from under a running
		/// challenge.
		/// </summary>
		public static string ActiveChallengeFolder => _state == ChallengeState.Inactive || _challengeDir.Length == 0
			? ""
			: Path.GetFileName(_challengeDir.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));

		/// <summary>
		/// The identity used for the HUD and leaderboard submissions: the linked Twitch
		/// display name if logged in, otherwise the legacy free-text name (kept only for
		/// installs that already had one saved - the Settings UI no longer exposes it).
		/// </summary>
		public static string CurrentPlayerName {
			get {
				ChallengeConfig cfg = ConfigManager.Config.Challenge;
				if(cfg.IsTwitchLinked) {
					//Prefer the display name, but fall back to the login (always set when linked)
					//so a missing/blank display name from the server doesn't make a logged-in user
					//look logged-out ("Please log in with Twitch" / "Submit failed: not logged in").
					string name = (cfg.TwitchDisplayName ?? "").Trim();
					if(name.Length == 0) {
						name = (cfg.TwitchLogin ?? "").Trim();
					}
					return name;
				}
				return cfg.PlayerName ?? "";
			}
		}

		/// <summary>Called from MainWindow on every GameLoaded notification.</summary>
		public static void OnGameLoaded()
		{
			switch(_state) {
				case ChallengeState.Pending:
					if(!VerifyRomHash()) {
						Stop();
						return;
					}
					if(StartEngine()) {
						_state = ChallengeState.Active;
						EmuApi.SetChallengeMode(true);

						//Clamp emulation speed to 100% (the speed-change shortcuts are blocked
						//by the lockdown, but the speed could otherwise still be preset).
						ConfigManager.Config.Emulation.EmulationSpeed = 100;
						ConfigManager.Config.Emulation.ApplyConfig();

						//Save original overclock settings if not already saved
						if (!_overclockSaved) {
							_savedPpuExtraScanlinesBeforeNmi = ConfigManager.Config.Snes.PpuExtraScanlinesBeforeNmi;
							_savedPpuExtraScanlinesAfterNmi = ConfigManager.Config.Snes.PpuExtraScanlinesAfterNmi;
							_savedGsuClockSpeed = ConfigManager.Config.Snes.GsuClockSpeed;
							_savedSpcClockSpeedAdjustment = ConfigManager.Config.Snes.SpcClockSpeedAdjustment;
							_overclockSaved = true;
						}

						//Clamp overclock settings to defaults during the challenge
						ConfigManager.Config.Snes.PpuExtraScanlinesBeforeNmi = 0;
						ConfigManager.Config.Snes.PpuExtraScanlinesAfterNmi = 0;
						ConfigManager.Config.Snes.GsuClockSpeed = 100;
						ConfigManager.Config.Snes.SpcClockSpeedAdjustment = 40;
						ConfigManager.Config.Snes.ApplyConfig();
					} else {
						//Could not start (no debugger/ROM yet) - bail out of challenge mode.
						_state = ChallengeState.Inactive;
					}
					break;

				case ChallengeState.Active:
					if(!VerifyRomHash()) {
						Stop();
						return;
					}
					//A ROM switch triggered by the engine (emu.loadRom) restarts the
					//script, just like the ScriptWindow does for regular scripts.
					RestartEngine();
					break;
			}
		}

		/// <summary>Stops the challenge and releases the lockdown.</summary>
		public static void Stop()
		{
			if(_state == ChallengeState.Inactive) {
				return;
			}

			if(_scriptId >= 0) {
				DebugApi.RemoveScript(_scriptId);
				_scriptId = -1;
			}

			if(_submitWatcher != null) {
				_submitWatcher.EnableRaisingEvents = false;
				_submitWatcher.Dispose();
				_submitWatcher = null;
			}

			if(_reloadWatcher != null) {
				_reloadWatcher.EnableRaisingEvents = false;
				_reloadWatcher.Dispose();
				_reloadWatcher = null;
			}

			if(_exportWatcher != null) {
				_exportWatcher.EnableRaisingEvents = false;
				_exportWatcher.Dispose();
				_exportWatcher = null;
			}

			EmuApi.SetChallengeMode(false);
			_state = ChallengeState.Inactive;
			_challengeDir = "";
			_practiceSegment = 0;
			_replayDir = "";
			_replayPlayer = "";
			_ghostDir = "";

			//Restore original overclock settings if saved
			if (_overclockSaved) {
				ConfigManager.Config.Snes.PpuExtraScanlinesBeforeNmi = _savedPpuExtraScanlinesBeforeNmi;
				ConfigManager.Config.Snes.PpuExtraScanlinesAfterNmi = _savedPpuExtraScanlinesAfterNmi;
				ConfigManager.Config.Snes.GsuClockSpeed = _savedGsuClockSpeed;
				ConfigManager.Config.Snes.SpcClockSpeedAdjustment = _savedSpcClockSpeedAdjustment;
				ConfigManager.Config.Snes.ApplyConfig();
				_overclockSaved = false;
			}
		}

		private static bool StartEngine()
		{
			string? code = GetEngineCode();
			if(code == null) {
				DisplayMessageHelper.DisplayMessage("Challenge", "Challenge engine could not be loaded.");
				return false;
			}

			int id = DebugApi.LoadScript("__challenge__", _challengeDir + Path.DirectorySeparatorChar, code, -1);
			if(id < 0) {
				return false;
			}

			_scriptId = id;
			EnsureSubmitWatcher();
			EnsureReloadWatcher();
			EnsureExportWatcher();
			return true;
		}

		/// <summary>
		/// Watches the challenge directory for the engine's "submit_request.txt" (written
		/// when the player presses START on the done screen) and hands it to ChallengeSubmit.
		/// </summary>
		private static void EnsureSubmitWatcher()
		{
			if(_submitWatcher != null || !Directory.Exists(_challengeDir)) {
				return;
			}

			_submitWatcher = new FileSystemWatcher(_challengeDir, "submit_request.txt") {
				NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size
			};
			FileSystemEventHandler handler = (s, e) => ChallengeSubmit.ProcessRequest(_challengeDir);
			_submitWatcher.Created += handler;
			_submitWatcher.Changed += handler;
			_submitWatcher.EnableRaisingEvents = true;
		}

		/// <summary>
		/// Watches for the engine's "reload_request.txt" (written on an L+R reset while the
		/// current ROM is already segment 1's) and re-injects the engine with a freshly built
		/// header. This is how changed Challenge Settings take effect without a full restart:
		/// the persist store (segment/total/splits) survives a script reload, so re-injecting
		/// with __FORCE_RESET both applies the new settings and resets the run to segment 1.
		/// </summary>
		private static void EnsureReloadWatcher()
		{
			if(_reloadWatcher != null || !Directory.Exists(_challengeDir)) {
				return;
			}

			_reloadWatcher = new FileSystemWatcher(_challengeDir, "reload_request.txt") {
				NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size
			};
			FileSystemEventHandler handler = (s, e) => {
				//The watcher fires on a background (thread-pool) thread; marshal onto the UI
				//thread before touching the debugger (DebugApi.LoadScript/RemoveScript).
				Dispatcher.UIThread.Post(() => {
					if(_state != ChallengeState.Active) {
						return;
					}
					//Created + Changed can both fire for one write; the UI-thread posts run
					//sequentially, so consuming (deleting) the file makes the second post a
					//no-op and prevents a double re-injection.
					try {
						if(!File.Exists(e.FullPath)) {
							return;
						}
						File.Delete(e.FullPath);
					} catch {
						return;
					}
					_forceReset = true;            //re-injected engine starts a fresh run at segment 1
					RestartEngine();               //re-injected header carries the new settings, incl. __MUTE_MUSIC
				});
			};
			_reloadWatcher.Created += handler;
			_reloadWatcher.Changed += handler;
			_reloadWatcher.EnableRaisingEvents = true;
		}

		/// <summary>
		/// Watches for the engine's "export_request.txt" (written when the player presses SELECT on
		/// the done screen) and exports the just-completed run: packages the current recordings
		/// (segment inputs + ghosts) into a .creplay and opens a Save-As dialog. Purely local — no
		/// login or network needed, so it works even when a submit would be blocked.
		/// </summary>
		private static void EnsureExportWatcher()
		{
			if(_exportWatcher != null || !Directory.Exists(_challengeDir)) {
				return;
			}

			_exportWatcher = new FileSystemWatcher(_challengeDir, "export_request.txt") {
				NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size
			};
			FileSystemEventHandler handler = (s, e) => {
				//Watcher fires on a thread-pool thread; the file dialog must run on the UI thread.
				Dispatcher.UIThread.Post(() => {
					//Created + Changed can both fire for one write; deleting the trigger makes the
					//second post a no-op.
					try {
						if(!File.Exists(e.FullPath)) {
							return;
						}
						File.Delete(e.FullPath);
					} catch {
						return;
					}
					HandleExportRequest(Path.GetDirectoryName(e.FullPath) ?? _challengeDir);
				});
			};
			_exportWatcher.Created += handler;
			_exportWatcher.Changed += handler;
			_exportWatcher.EnableRaisingEvents = true;
		}

		/// <summary>
		/// Archives the challenge's current recordings into a shareable .creplay and prompts the
		/// player to save a copy. Runs on the UI thread. Best-effort: any failure is surfaced as a
		/// message but never disrupts the run.
		/// </summary>
		private static async void HandleExportRequest(string challengeDir)
		{
			if(_exportBusy) {
				return;   //a dialog is already open - ignore repeated SELECT presses
			}
			_exportBusy = true;
			try {
				//The folder name is the challenge id (used only for the archive's file name).
				string challengeId = Path.GetFileName(challengeDir.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
				string? packagePath = ChallengeSubmit.ArchiveCompletedRunRecordings(challengeDir, challengeId);
				if(packagePath == null) {
					DisplayMessageHelper.DisplayMessage("Challenge", "Nothing to export - no completed run recordings found.");
					return;
				}

				string? dest = await FileDialogHelper.SaveFile(null, Path.GetFileName(packagePath),
					ApplicationHelper.GetActiveOrMainWindow(), FileDialogHelper.ChallengeReplayExt);
				if(dest == null) {
					return;   //cancelled - the run is still archived under challenges/replays
				}

				File.Copy(packagePath, dest, true);
				DisplayMessageHelper.DisplayMessage("Challenge", "Run exported. Share the .creplay so others can watch it or race its ghost.");
			} catch(Exception ex) {
				DisplayMessageHelper.DisplayMessage("Challenge", "Export failed: " + ex.Message);
			} finally {
				_exportBusy = false;
			}
		}

		private static void RestartEngine()
		{
			string? code = GetEngineCode();
			if(code == null) {
				return;
			}

			if(_scriptId >= 0) {
				DebugApi.RemoveScript(_scriptId);
			}
			_scriptId = DebugApi.LoadScript("__challenge__", _challengeDir + Path.DirectorySeparatorChar, code, -1);
		}

		/// <summary>
		/// Builds the engine source: a small header that injects the challenge directory
		/// (so the engine resolves games.lua / ROMs / states from there) followed by the
		/// engine body.
		/// </summary>
		private static string? GetEngineCode()
		{
			string? body = GetEngineBody();
			if(body == null) {
				return null;
			}

			//Forward slashes + trailing slash, matching what relay.lua expects for its
			//SCRIPT_DIR. A path will never contain "]==]", so the long bracket is safe.
			string dir = _challengeDir.Replace('\\', '/');
			if(!dir.EndsWith("/")) {
				dir += "/";
			}

			//Injected launch settings the engine reads as globals. They take effect on the
			//next engine (re)load (i.e. the next segment), so toggling between segments/runs
			//is effectively live.
			string header = "__CHALLENGE_DIR = [==[" + dir + "]==]\n";
			header += "__SHOW_PBS = " + (ConfigManager.Config.Challenge.ShowPersonalBests ? "true" : "false") + "\n";
			header += "__HUD_SEGMENT = " + (ConfigManager.Config.Challenge.ShowSegmentInfo ? "true" : "false") + "\n";
			header += "__HUD_DELTA = " + (ConfigManager.Config.Challenge.ShowDelta ? "true" : "false") + "\n";
			header += "__HUD_SS = " + (int)ConfigManager.Config.Challenge.HudSize + "\n";
			header += "__INPUT_DISPLAY = " + (ConfigManager.Config.Challenge.ShowInputDisplay ? "true" : "false") + "\n";
			header += "__INPUT_DISPLAY_POS = [==[" + ConfigManager.Config.Challenge.InputDisplayPosition.ToString().ToLowerInvariant() + "]==]\n";
			//When racing a foreign ghost the ghost is always shown (that's the whole point),
			//regardless of the ShowGhost display toggle; otherwise it follows the setting.
			bool ghostOn = ConfigManager.Config.Challenge.ShowGhost || !string.IsNullOrEmpty(_ghostDir);
			header += "__GHOST = [==[" + (ghostOn ? "pb" : "off") + "]==]\n";
			//The engine tints the ghost with this RGB (own PB vs. foreign race ghost get different
			//colors so they're distinguishable). Only RGB is passed; the engine adds transparency.
			uint ghostRgb = (string.IsNullOrEmpty(_ghostDir)
				? ConfigManager.Config.Challenge.GhostColor
				: ConfigManager.Config.Challenge.RaceGhostColor) & 0xFFFFFFu;
			header += "__GHOST_COLOR = " + ghostRgb + "\n";
			header += "__GHOST_OPACITY = " + Math.Clamp(ConfigManager.Config.Challenge.GhostOpacity, 0, 100) + "\n";
			header += "__GHOST_NAME_OPACITY = " + Math.Clamp(ConfigManager.Config.Challenge.GhostNameOpacity, 0, 100) + "\n";
			header += "__GHOST_OUTLINE = " + (ConfigManager.Config.Challenge.GhostOutlineOnly ? "true" : "false") + "\n";
			if(!string.IsNullOrEmpty(_ghostDir)) {
				string gd = _ghostDir.Replace('\\', '/');
				if(!gd.EndsWith("/")) {
					gd += "/";
				}
				//The engine loads seg<idx>.ghost from here instead of recordings/pb_seg<idx>.ghost.
				//The ghost's player name is read from the file header, so no separate name is needed.
				header += "__GHOST_DIR = [==[" + gd + "]==]\n";
			}
			//Auto-reset on fail: "off" keeps the classic behaviour (a fail reloads the segment and
			//the run carries on), "first" only resets in segment 1 - where a fail puts the player
			//back at the start of the run anyway, so otherwise just the clock keeps running on a
			//spoiled run - and "always" ends the attempt on any fail.
			string autoResetMode = ConfigManager.Config.Challenge.AutoReset switch {
				ChallengeAutoReset.FirstSegmentOnly => "first",
				ChallengeAutoReset.EverySegment => "always",
				_ => "off"
			};
			header += "__AUTO_RESET = [==[" + autoResetMode + "]==]\n";
			//"Mute music (keep sound effects)": the engine holds the N-SPC/AddMusicK master music
			//volume in SPC RAM at 0 every frame (mutes music on all 8 channels; SFX write their DSP
			//voice volumes directly and stay audible). Replaces the old mixer-channel muting, which
			//couldn't reach voices 7/8 (music) and silenced SFX on 1-6.
			header += "__MUTE_MUSIC = " + (ConfigManager.Config.Challenge.MuteMusic ? "true" : "false") + "\n";
			//Stream overlay: when enabled, make sure the stream/ folder + overlay.html exist and
			//point the engine at it (absolute, forward slashes) so it can write stats.json/text there.
			bool streamOn = ConfigManager.Config.Challenge.StreamOverlay;
			header += "__STREAM_OVERLAY = " + (streamOn ? "true" : "false") + "\n";
			if(streamOn) {
				EnsureStreamOverlay();
				header += "__STREAM_DIR = [==[" + StreamRoot.Replace('\\', '/') + "]==]\n";
			}
			//Configurable reset shortcut: the non-None buttons form the combo. Inject only when the
			//user chose at least one - otherwise the engine keeps the challenge's own default combo.
			List<string> resetButtons = new();
			if(ConfigManager.Config.Challenge.ResetButton1 != ChallengeResetButton.None) {
				resetButtons.Add(ConfigManager.Config.Challenge.ResetButton1.ToString().ToLowerInvariant());
			}
			if(ConfigManager.Config.Challenge.ResetButton2 != ChallengeResetButton.None) {
				resetButtons.Add(ConfigManager.Config.Challenge.ResetButton2.ToString().ToLowerInvariant());
			}
			if(resetButtons.Count > 0) {
				header += "__RESET_BUTTONS = [==[" + string.Join(",", resetButtons) + "]==]\n";
			}
			//Tap (1 frame) vs. the classic ~0.5s hold (30 frames) to trigger a reset.
			header += "__RESET_HOLD_FRAMES = " + (ConfigManager.Config.Challenge.ResetOnTap ? 1 : 30) + "\n";
			header += "__PREVIEW_FRAMES = " + Math.Max(0, ConfigManager.Config.Challenge.PreviewFrames) + "\n";
			header += "__FAIL_PREVIEW = " + (ConfigManager.Config.Challenge.PreviewOnDeath ? "true" : "false") + "\n";
			if(_practiceSegment > 0) {
				header += "__PRACTICE_SEGMENT = " + _practiceSegment + "\n";
			}
			//Version stamps written into every recording header: which emulator core and which
			//engine produced this Lauf. Only written, never checked - a recording made by a
			//different build can desync, but a warning about it is worthless until there is a
			//stock of recordings that actually carry the fields.
			header += "__EMU_VERSION = [==[" + EmuApi.GetMesenVersion().ToString() + "]==]\n";
			header += "__ENGINE_VERSION = [==[" + ChallengeEditionInfo.VersionString + "]==]\n";
			string playerName = CurrentPlayerName;
			if(playerName.Trim().Length > 0) {
				//Long bracket can't contain "]==]"; player names won't, so this is safe.
				header += "__PLAYER = [==[" + playerName.Trim() + "]==]\n";
			}
			if(!string.IsNullOrEmpty(_replayDir)) {
				string repDir = _replayDir.Replace('\\', '/');
				if(!repDir.EndsWith("/")) {
					repDir += "/";
				}
				header += "__REPLAY_DIR = [==[" + repDir + "]==]\n";
				if(_replayPlayer.Trim().Length > 0) {
					//Long bracket can't contain "]==]"; player names won't, so this is safe.
					header += "__REPLAY_PLAYER = [==[" + _replayPlayer.Trim() + "]==]\n";
				}
			}
			if(_forceReset) {
				header += "__FORCE_RESET = true\n";
				_forceReset = false;
			}
			return header + body;
		}

		private static string? GetEngineBody()
		{
#if DEBUG
			//During development, allow loading the engine from a loose file so it can be
			//iterated on without rebuilding. This override is compiled out of release
			//builds, so shipped builds can only use the embedded (non-editable) engine.
			string? overridePath = Environment.GetEnvironmentVariable("MESEN_CHALLENGE_ENGINE");
			if(string.IsNullOrWhiteSpace(overridePath) || !File.Exists(overridePath)) {
				string local = Path.Combine(_challengeDir, "relay.lua");
				overridePath = File.Exists(local) ? local : null;
			}
			if(!string.IsNullOrWhiteSpace(overridePath) && File.Exists(overridePath)) {
				return FileHelper.ReadAllText(overridePath);
			}
#endif

			Assembly assembly = Assembly.GetExecutingAssembly();
			using Stream? stream = assembly.GetManifestResourceStream(EngineResourceName);
			if(stream == null) {
				return null;
			}
			using StreamReader sr = new StreamReader(stream);
			return sr.ReadToEnd();
		}

		public static string ChallengesRoot
		{
			get
			{
				string? exeDir = Path.GetDirectoryName(Program.ExePath);
				return Path.Combine(exeDir ?? Program.OriginalFolder, "challenges");
			}
		}

		/// <summary>Where archived, shared and downloaded replays live, plus the folders they are
		/// unpacked into. Owned here rather than by one of the replay classes, so those don't have
		/// to reach into each other for it.</summary>
		public static string ReplaysRoot => Path.Combine(ChallengesRoot, "replays");

		/// <summary>Folder (next to Mesen.exe) the stream overlay writes into: overlay.html +
		/// stats.json + text/*.txt. A stable path so an OBS browser/text source keeps working
		/// across challenges.</summary>
		public static string StreamRoot
		{
			get
			{
				string? exeDir = Path.GetDirectoryName(Program.ExePath);
				return Path.Combine(exeDir ?? Program.OriginalFolder, "stream");
			}
		}

		/// <summary>Ensures the stream/ folder (+ text/ subfolder) exists and drops the current
		/// overlay.html from the embedded resource. Best-effort: overlay failures never disrupt a
		/// run. Overwrites overlay.html so page updates ship, but leaves stats.json/session.dat.</summary>
		private static void EnsureStreamOverlay()
		{
			try {
				string dir = StreamRoot;
				Directory.CreateDirectory(dir);
				Directory.CreateDirectory(Path.Combine(dir, "text"));
				Assembly asm = Assembly.GetExecutingAssembly();
				using Stream? s = asm.GetManifestResourceStream("Mesen.ChallengeEngine.overlay.html");
				if(s != null) {
					using StreamReader sr = new(s);
					File.WriteAllText(Path.Combine(dir, "overlay.html"), sr.ReadToEnd());
				}
			} catch {
				//best-effort only
			}
		}

		/// <summary>Resets the stream overlay's session stats by deleting session.dat. The engine
		/// re-creates a fresh session on the next run event; records (PBs) are unaffected.</summary>
		public static void ResetStreamStats()
		{
			try {
				string sessionFile = Path.Combine(StreamRoot, "session.dat");
				if(File.Exists(sessionFile)) {
					File.Delete(sessionFile);
				}
			} catch {
				//best-effort only
			}
		}

		//Clean Super Mario World (USA) reference ROM: 512 KiB, headerless CRC32. A 512-byte
		//copier header is auto-detected and stripped before the checksum is verified.
		private const int CleanRomSize = 0x80000;         //524288
		private const uint CleanRomCrc32 = 0xB19ED489;    //SMW (USA), no header

		/// <summary>
		/// Returns the path to the user-provided clean ROM (clean.smc / clean.sfc next to
		/// the executable), or null if neither exists.
		/// </summary>
		public static string? GetCleanRomPath()
		{
			string? exeDir = Path.GetDirectoryName(Program.ExePath) ?? Program.OriginalFolder;
			foreach(string name in new[] { "clean.sfc", "clean.smc" }) {
				string path = Path.Combine(exeDir, name);
				if(File.Exists(path)) {
					return path;
				}
			}
			return null;
		}

		/// <summary>
		/// Returns the clean ROM path, or — if none is set up yet — prompts the user to pick
		/// their Super Mario World (US) ROM, validates it against the known SMW checksum
		/// (auto-stripping a 512-byte copier header), and copies a canonical headerless
		/// clean.smc next to the executable. Returns null if the user cancels or the file
		/// isn't a valid clean SMW (US) ROM (with a clear message shown in that case).
		/// </summary>
		public static async Task<string?> EnsureCleanRomAsync(Window? parent)
		{
			string? existing = GetCleanRomPath();
			if(existing != null) {
				return existing;
			}

			DialogResult choice = await MessageBox.Show(parent,
				"No clean Super Mario World (US) ROM was found next to Mesen.\n\n" +
				"Click OK to select your Super Mario World (US) ROM now — Mesen copies it as " +
				"'clean.smc', so you only have to do this once. (Challenges are built as patches " +
				"against this ROM; for legal reasons it can't be bundled.)",
				"Super Mario World (US) ROM needed", MessageBoxButtons.OKCancel, MessageBoxIcon.Info);
			if(choice != DialogResult.OK) {
				return null;
			}

			string? romPath = await FileDialogHelper.OpenFile(null, parent, FileDialogHelper.RomExt);
			if(romPath == null) {
				return null;   //user cancelled the picker
			}

			byte[] data;
			try {
				data = File.ReadAllBytes(romPath);
			} catch(Exception ex) {
				await MessageBox.Show(parent, "Could not read the selected file:\n" + ex.Message,
					"Super Mario World (US) ROM needed", MessageBoxButtons.OK, MessageBoxIcon.Error);
				return null;
			}

			//Accept a headerless 512 KiB ROM, or one with a 512-byte copier header.
			int offset;
			if(data.Length == CleanRomSize) {
				offset = 0;
			} else if(data.Length == CleanRomSize + 512) {
				offset = 512;
			} else {
				await MessageBox.Show(parent,
					"That file doesn't look like a Super Mario World ROM (unexpected size " + data.Length +
					" bytes; expected 524288, or 524800 with a copier header).\n\n" +
					"Make sure you're selecting the raw .smc/.sfc ROM, not a .zip or a different game.",
					"Not a Super Mario World (US) ROM", MessageBoxButtons.OK, MessageBoxIcon.Error);
				return null;
			}

			if(BpsPatcher.ComputeCrc32(data, offset, CleanRomSize) != CleanRomCrc32) {
				await MessageBox.Show(parent,
					"That ROM is not a clean Super Mario World (US) copy.\n\n" +
					"It may be the wrong region (JP/EU), an already-modified ROM hack, or a bad dump. " +
					"Please select an unmodified US copy and try again.",
					"Not a Super Mario World (US) ROM", MessageBoxButtons.OK, MessageBoxIcon.Error);
				return null;
			}

			//Write a canonical, headerless clean.smc next to the executable.
			string exeDir = Path.GetDirectoryName(Program.ExePath) ?? Program.OriginalFolder;
			string dest = Path.Combine(exeDir, "clean.smc");
			try {
				byte[] headerless = new byte[CleanRomSize];
				Array.Copy(data, offset, headerless, 0, CleanRomSize);
				File.WriteAllBytes(dest, headerless);
			} catch(Exception ex) {
				await MessageBox.Show(parent,
					"Could not save clean.smc:\n" + ex.Message + "\n\n" +
					"Make sure Mesen's folder is writable (avoid Program Files / read-only locations).",
					"Super Mario World (US) ROM needed", MessageBoxButtons.OK, MessageBoxIcon.Error);
				return null;
			}

			return dest;
		}

		/// <summary>
		/// Optional minimum Challenge Edition version this challenge requires (games.lua's
		/// 'min_version' field, e.g. min_version = "1.7"). Null if unspecified/unparseable.
		/// Used to block starting a challenge on an emulator that's too old for it.
		/// </summary>
		public static Version? GetMinVersion(string folderName)
		{
			//Read directly (not via FileHelper.ReadAllText, which pops an error dialog on a
			//missing file) since this runs first in StartChallenge — a missing games.lua just
			//means "no gate", and StartChallenge's own ROM check reports the real problem.
			string gamesLua = Path.Combine(ChallengesRoot, folderName, "games.lua");
			if(!File.Exists(gamesLua)) {
				return null;
			}
			string content;
			try {
				content = File.ReadAllText(gamesLua);
			} catch {
				return null;
			}
			Match m = Regex.Match(content, "min_version\\s*=\\s*([\"'])(?<v>[^\"']+)\\1");
			return m.Success && Version.TryParse(m.Groups["v"].Value.Trim(), out Version? v) ? v : null;
		}

		/// <summary>
		/// Reads the first segment's ROM from games.lua and resolves it the same way
		/// relay.lua does (relative paths live under "&lt;challengeDir&gt;/games/").
		/// This is only needed to bootstrap a running ROM; the engine itself re-loads
		/// (and patches) the correct ROM once it is running.
		/// </summary>
		private static string? GetFirstSegmentRomPath(string challengeDir)
		{
			return GetSegmentRomPath(challengeDir, 1);
		}

		/// <summary>
		/// Resolves the ROM path of the (1-based) segment from games.lua, the same way
		/// relay.lua does (relative paths live under "&lt;challengeDir&gt;/games/").
		/// </summary>
		private static string? GetSegmentRomPath(string challengeDir, int segmentIndex)
		{
			string? content = FileHelper.ReadAllText(Path.Combine(challengeDir, "games.lua"));
			if(content == null) {
				return null;
			}

			MatchCollection matches = Regex.Matches(content, "rom\\s*=\\s*([\"'])(?<v>.*?)\\1");
			if(segmentIndex < 1 || segmentIndex > matches.Count) {
				return null;
			}

			string rom = matches[segmentIndex - 1].Groups["v"].Value.Trim();
			if(rom.Length == 0) {
				return null;
			}
			return Path.IsPathRooted(rom) ? rom : Path.Combine(challengeDir, "games", rom);
		}

		/// <summary>Segment display names (from games.lua's per-segment "name" fields), in order.</summary>
		public static List<string> GetSegmentNames(string folderName)
		{
			List<string> names = new();
			string? content = FileHelper.ReadAllText(Path.Combine(ChallengesRoot, folderName, "games.lua"));
			if(content == null) {
				return names;
			}
			foreach(Match m in Regex.Matches(content, "\\bname\\s*=\\s*([\"'])(?<v>.*?)\\1")) {
				names.Add(m.Groups["v"].Value.Trim());
			}
			return names;
		}

		public static string[] GetAvailableChallenges()
		{
			string root = ChallengesRoot;
			if(!Directory.Exists(root)) {
				return Array.Empty<string>();
			}

			return Directory.GetDirectories(root)
				.Where(dir => File.Exists(Path.Combine(dir, "games.lua")))
				.Select(dir => Path.GetFileName(dir))
				.Where(name => !name.StartsWith("."))
				.OrderBy(name => name, StringComparer.OrdinalIgnoreCase)
				.ToArray();
		}

		/// <summary>
		/// Lists the available challenges with both the folder name (used to start them)
		/// and the display name read from games.lua's "challenge" field (folder name as
		/// fallback). Sorted by display name.
		/// </summary>
		public static List<(string Folder, string Name)> GetChallengeList()
		{
			List<(string Folder, string Name)> list = new();
			string root = ChallengesRoot;
			if(!Directory.Exists(root)) {
				return list;
			}

			foreach(string dir in Directory.GetDirectories(root)) {
				string folder = Path.GetFileName(dir);
				if(folder.StartsWith(".") || !File.Exists(Path.Combine(dir, "games.lua"))) {
					continue;
				}
				list.Add((folder, ReadChallengeName(dir) ?? folder));
			}
			list.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase));
			return list;
		}

		private static string? ReadChallengeName(string challengeDir)
		{
			string? content = FileHelper.ReadAllText(Path.Combine(challengeDir, "games.lua"));
			if(content == null) {
				return null;
			}
			Match m = Regex.Match(content, "challenge\\s*=\\s*([\"'])(?<v>.*?)\\1");
			return m.Success && m.Groups["v"].Value.Trim().Length > 0 ? m.Groups["v"].Value.Trim() : null;
		}

		/// <summary>True if this installed challenge's server-side flag requires a linked
		/// Twitch account to submit runs (recorded locally at install time - see
		/// ChallengeCatalog.InstallAsync; manually-imported .cha files default to false).</summary>
		public static bool RequiresTwitchLogin(string folderName)
		{
			//Optional file: absent for manual imports / installs made before this flag existed.
			//Read it directly (NOT via FileHelper.ReadAllText, which pops an error dialog when
			//a file is missing) so a missing flag simply means "no login required".
			string flagFile = Path.Combine(ChallengesRoot, folderName, ChallengeCatalog.RequiresTwitchLoginFileName);
			if(!File.Exists(flagFile)) {
				return false;
			}
			try {
				return File.ReadAllText(flagFile).Trim() == "1";
			} catch {
				return false;
			}
		}

		/// <summary>
		/// Starts a normal (scored) challenge run. If <paramref name="ghostDir"/> is given, the
		/// engine races a foreign ghost loaded from that directory (seg&lt;idx&gt;.ghost) instead of
		/// the player's own local PB ghost — used by "Race a Ghost from File...". The player's own
		/// recordings/PBs are written as usual; the foreign ghost dir is read-only display data.
		/// </summary>
		public static async void StartChallenge(string folderName, string? ghostDir = null)
		{
			ChallengeConfig cfg = ConfigManager.Config.Challenge;

			//Emulator too old for this challenge? Stop early with a clear "update" message.
			//This is how a breaking change is handled: bump the challenge's games.lua
			//'min_version' when you ship an incompatible engine/format change.
			Version? minVersion = GetMinVersion(folderName);
			if(minVersion != null && minVersion > ChallengeEditionInfo.Version) {
				await MessageBox.Show(ApplicationHelper.GetActiveOrMainWindow(),
					"This challenge requires Mesen Challenge Edition v" + minVersion + " or newer, " +
					"but you're running v" + ChallengeEditionInfo.Version + ".\n\n" +
					"Please update the emulator and try again. If an update is available, Mesen offers " +
					"it at startup; you can also download the latest version from saphros.de/challenges.",
					"Emulator update required", MessageBoxButtons.OK, MessageBoxIcon.Warning);
				return;
			}

			if(RequiresTwitchLogin(folderName) && !cfg.IsTwitchLinked) {
				DialogResult choice = await MessageBox.Show(null,
					"This challenge requires a linked Twitch account to submit runs to the leaderboard.\n\n" +
					"Yes = open Challenge Settings to log in (then start the challenge again)\n" +
					"No = start anyway, but you won't be able to submit\n" +
					"Cancel = don't start",
					"Twitch Login Required", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);

				if(choice == DialogResult.Cancel) {
					return;
				}
				if(choice == DialogResult.Yes) {
					await new ChallengeSettingsWindow() {
						DataContext = new ChallengeSettingsViewModel()
					}.ShowCenteredDialog(ApplicationHelper.GetActiveOrMainWindow());
					return;
				}
				//No -> fall through and start anyway (practice/won't submit)
			}

			string playerName = CurrentPlayerName;
			if(string.IsNullOrWhiteSpace(playerName)) {
				DisplayMessageHelper.DisplayMessage("Challenge", "Please log in with Twitch in Challenge Settings first.");
				return;
			}

			//Resolving the ROM is a pure read of games.lua, so it happens before anything is torn
			//down - there's no point crediting (or stopping a running run for) a challenge that
			//can't start anyway.
			string challengeDir = Path.Combine(ChallengesRoot, folderName);
			string? firstRom = GetFirstSegmentRomPath(challengeDir);
			if(firstRom == null || !File.Exists(firstRom)) {
				DisplayMessageHelper.DisplayMessage("Challenge", firstRom == null
					? "Challenge ROM could not be resolved from games.lua."
					: "Missing ROM '" + Path.GetFileName(firstRom) + "'. For retro-game challenges you must place the game ROM into: " + Path.Combine(challengeDir, "games"));
				return;
			}

			//Title screen: logo + per-segment credits, shown once per load. Challenges without a
			//readable challenge.json skip it silently. It runs before Stop() on purpose, so
			//backing out here can't kill a challenge that's currently running.
			if(!await ChallengeTitleWindow.ConfirmStartAsync(ApplicationHelper.GetActiveOrMainWindow(), challengeDir, folderName)) {
				return;
			}

			if(_state != ChallengeState.Inactive) {
				Stop();
			}

			_challengeDir = challengeDir;
			_state = ChallengeState.Pending;
			_forceReset = true;
			_practiceSegment = 0;
			_replayDir = "";
			_replayPlayer = "";
			_ghostDir = ghostDir ?? "";

			try {
				Directory.CreateDirectory(Path.Combine(challengeDir, "recordings"));
			} catch {}

			LoadRomHelper.LoadFile(firstRom);
		}

		/// <summary>
		/// Starts a single segment in practice mode (no scoring / PBs / submit). The engine
		/// loops the chosen segment; the player exits via Challenge > Stop.
		/// </summary>
		public static void StartPractice(string folderName, int segmentIndex)
		{
			if(_state != ChallengeState.Inactive) {
				Stop();
			}

			string challengeDir = Path.Combine(ChallengesRoot, folderName);
			string? rom = GetSegmentRomPath(challengeDir, segmentIndex);
			if(rom == null || !File.Exists(rom)) {
				DisplayMessageHelper.DisplayMessage("Challenge", rom == null
					? "Segment ROM could not be resolved from games.lua."
					: "Missing ROM '" + Path.GetFileName(rom) + "'. For retro-game challenges you must place the game ROM into: " + Path.Combine(challengeDir, "games"));
				return;
			}

			_challengeDir = challengeDir;
			_state = ChallengeState.Pending;
			_forceReset = false;          //practice doesn't touch the run persist
			_practiceSegment = segmentIndex;
			_replayDir = "";
			_replayPlayer = "";
			_ghostDir = "";

			try {
				Directory.CreateDirectory(Path.Combine(challengeDir, "recordings"));
			} catch {}

			LoadRomHelper.LoadFile(rom);
		}

		public static void StartReplay(string folderName, string replayDir, string? player = null)
		{
			if(_state != ChallengeState.Inactive) {
				Stop();
			}

			string challengeDir = Path.Combine(ChallengesRoot, folderName);
			string? firstRom = GetFirstSegmentRomPath(challengeDir);
			if(firstRom == null || !File.Exists(firstRom)) {
				DisplayMessageHelper.DisplayMessage("Challenge Replay", "Challenge first ROM could not be located: " + (firstRom ?? "<none>"));
				return;
			}

			_challengeDir = challengeDir;
			_replayDir = replayDir;
			_replayPlayer = player ?? "";
			_ghostDir = "";
			_state = ChallengeState.Pending;
			_forceReset = true;
			_practiceSegment = 0;

			LoadRomHelper.LoadFile(firstRom);
		}

		private static bool VerifyRomHash()
		{
			try {
				string? romPath = EmuApi.GetRomInfo()?.RomPath;
				if(string.IsNullOrEmpty(romPath) || string.IsNullOrEmpty(_challengeDir)) {
					return true;
				}

				string romName = Path.GetFileName(romPath);
				string gamesLuaPath = Path.Combine(_challengeDir, "games.lua");
				if(!File.Exists(gamesLuaPath)) {
					return true;
				}

				string luaContent = File.ReadAllText(gamesLuaPath);
				
				// Find segment block containing: rom = "romName"
				string romPattern = @"rom\s*=\s*[""']" + Regex.Escape(romName) + @"[""']";
				Match romMatch = Regex.Match(luaContent, romPattern);
				if(!romMatch.Success) {
					return true;
				}

				int matchIdx = romMatch.Index;
				int startBrace = -1;
				int braceDepth = 0;
				for(int i = matchIdx; i >= 0; i--) {
					if(luaContent[i] == '}') {
						braceDepth--;
					} else if(luaContent[i] == '{') {
						braceDepth++;
						if(braceDepth == 1) {
							startBrace = i;
							break;
						}
					}
				}

				if(startBrace == -1) {
					return true;
				}

				int endBrace = -1;
				braceDepth = 1;
				for(int i = startBrace + 1; i < luaContent.Length; i++) {
					if(luaContent[i] == '{') {
						braceDepth++;
					} else if(luaContent[i] == '}') {
						braceDepth--;
						if(braceDepth == 0) {
							endBrace = i;
							break;
						}
					}
				}

				if(endBrace == -1) {
					return true;
				}

				string segmentBlock = luaContent.Substring(startBrace, endBrace - startBrace + 1);

				// Extract rom_hash and state_hash
				Match romHashMatch = Regex.Match(segmentBlock, @"rom_hash\s*=\s*[""'](?<hash>[a-fA-F0-9]+)[""']");
				Match stateMatch = Regex.Match(segmentBlock, @"state\s*=\s*([""'])(?<state>.*?)\1");
				Match stateHashMatch = Regex.Match(segmentBlock, @"state_hash\s*=\s*[""'](?<hash>[a-fA-F0-9]+)[""']");

				// 1. Verify ROM hash
				if(romHashMatch.Success) {
					string expectedRomHash = romHashMatch.Groups["hash"].Value.Trim().ToLowerInvariant();
					if(!File.Exists(romPath)) {
						DisplayMessageHelper.DisplayMessage("Challenge Verification", $"ROM file not found: {romName}");
						return false;
					}
					byte[] romBytes = File.ReadAllBytes(romPath);
					using var sha256 = SHA256.Create();
					byte[] hashBytes = sha256.ComputeHash(romBytes);
					string actualRomHash = Convert.ToHexString(hashBytes).ToLowerInvariant();

					if(actualRomHash != expectedRomHash) {
						DisplayMessageHelper.DisplayMessage("Challenge Verification Failed", 
							$"ROM file '{romName}' has been modified!\n\n" +
							$"Expected Hash: {expectedRomHash}\n" +
							$"Actual Hash: {actualRomHash}\n\n" +
							"The challenge has been aborted.");
						return false;
					}
				}

				// 2. Verify State hash
				if(stateMatch.Success && stateHashMatch.Success) {
					string statePathRelative = stateMatch.Groups["state"].Value.Trim();
					string expectedStateHash = stateHashMatch.Groups["hash"].Value.Trim().ToLowerInvariant();
					
					// Resolve path: SCRIPT_DIR + "games/" + state
					string statePath = Path.Combine(_challengeDir, "games", statePathRelative);
					if(!File.Exists(statePath)) {
						statePath = Path.Combine(_challengeDir, statePathRelative);
					}

					if(File.Exists(statePath)) {
						byte[] stateBytes = File.ReadAllBytes(statePath);
						using var sha256 = SHA256.Create();
						byte[] hashBytes = sha256.ComputeHash(stateBytes);
						string actualStateHash = Convert.ToHexString(hashBytes).ToLowerInvariant();

						if(actualStateHash != expectedStateHash) {
							DisplayMessageHelper.DisplayMessage("Challenge Verification Failed", 
								$"State file '{statePathRelative}' has been modified!\n\n" +
								$"Expected Hash: {expectedStateHash}\n" +
								$"Actual Hash: {actualStateHash}\n\n" +
								"The challenge has been aborted.");
							return false;
						}
					} else {
						DisplayMessageHelper.DisplayMessage("Challenge Verification Failed", 
							$"Required state file not found: {statePathRelative}");
						return false;
					}
				}
			} catch(Exception ex) {
				DisplayMessageHelper.DisplayMessage("Challenge Verification Error", $"An error occurred during verification: {ex.Message}");
				return false;
			}

			return true;
		}
	}
}
