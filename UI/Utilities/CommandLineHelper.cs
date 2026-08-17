using Mesen.Config;
using Mesen.Debugger.Utilities;
using Mesen.Debugger.ViewModels;
using Mesen.Debugger.Windows;
using Mesen.Interop;
using Mesen.Localization;
using Mesen.Utilities;
using Mesen.ViewModels;
using Mesen.Windows;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Xml.Linq;

namespace Mesen.Utilities;

public class CommandLineHelper
{
	public bool NoVideo { get; private set; }
	public bool NoAudio { get; private set; }
	public bool NoInput { get; private set; }
	public bool Fullscreen { get; private set; }
	public bool LoadLastSessionRequested { get; private set; }
	public string? MovieToRecord { get; private set; } = null;
	public int TestRunnerTimeout { get; private set; } = 100;
	public List<string> LuaScriptsToLoad { get; private set; } = new();
	public List<string> FilesToLoad { get; private set; } = new();

	/// <summary>A .creplay passed on the command line (double-clicked, or handed over by another
	/// instance). Opens the replay prompt instead of loading a ROM - see OpenChallengeReplay.</summary>
	public string? ChallengeReplayToOpen { get; private set; } = null;

	/// <summary>The run id from a mesen-challenge://replay/&lt;id&gt; link clicked on saphros.de.
	/// 0 when there was none. Its replay is downloaded and opened by OpenChallengeReplay.</summary>
	public int ChallengeReplayRunToOpen { get; private set; } = 0;

	private List<string> _errorMessages = new();

	public CommandLineHelper(string[] args, bool forStartup)
	{
		ProcessCommandLineArgs(args, forStartup);
	}

	private void ProcessCommandLineArgs(string[] args, bool forStartup)
	{
		foreach(string arg in args) {
			//Handled before anything treats the argument as a path: a URL is not a file name, and
			//feeding one to Path.GetFullPath would at best produce nonsense. A link addressed to us
			//but malformed is rejected here and reported as a bad link - never passed on, and never
			//acted upon in any other way.
			if(ChallengeReplayLink.HasScheme(arg)) {
				if(ChallengeReplayLink.TryParseRunId(arg, out int replayRunId)) {
					ChallengeReplayRunToOpen = replayRunId;
				} else {
					_errorMessages.Add("Not a valid replay link: " + arg);
				}
				continue;
			}

			string absPath;
			if(Path.IsPathRooted(arg)) {
				absPath = arg;
			} else {
				absPath = Path.GetFullPath(arg, Program.OriginalFolder);
			}

			if(File.Exists(absPath)) {
				string extension = Path.GetExtension(absPath).ToLowerInvariant();
				if(extension == "." + FileDialogHelper.ChallengeReplayExt) {
					//A replay package is not a ROM - it must not reach LoadFiles, or the emulator
					//would try to boot a zip. It opens the replay prompt after the window is up.
					ChallengeReplayToOpen = absPath;
				} else {
					switch(extension) {
						case ".lua": LuaScriptsToLoad.Add(absPath); break;
						default: FilesToLoad.Add(absPath); break;
					}
				}
			} else if(arg.StartsWith("-") || arg.StartsWith("/")) {
				string switchArg = ConvertArg(arg).ToLowerInvariant();
				switch(switchArg) {
					case "novideo": NoVideo = true; break;
					case "noaudio": NoAudio = true; break;
					case "noinput": NoInput = true; break;
					case "fullscreen": Fullscreen = true; break;
					case "enablestdout": ConfigApi.SetEmulationFlag(EmulationFlags.OutputToStdout, true); break;
					case "donotsavesettings": ConfigManager.DisableSaveSettings = true; break;
					case "loadlastsession": LoadLastSessionRequested = true; break;
					default:
						if(switchArg.StartsWith("recordmovie=")) {
							string[] values = switchArg.Split('=');
							if(values.Length <= 1) {
								//invalid
								continue;
							}
							string moviePath = values[1];
							string? folder = Path.GetDirectoryName(moviePath);
							if(string.IsNullOrWhiteSpace(folder)) {
								moviePath = Path.Combine(ConfigManager.MovieFolder, moviePath);
							} else if(!Path.IsPathRooted(moviePath)) {
								moviePath = Path.Combine(Program.OriginalFolder, moviePath);
							}
							if(!moviePath.ToLower().EndsWith("." + FileDialogHelper.MesenMovieExt)) {
								moviePath += "." + FileDialogHelper.MesenMovieExt;
							}
							MovieToRecord = moviePath;
						} else if(switchArg.StartsWith("timeout=")) {
							string[] values = switchArg.Split('=');
							if(values.Length <= 1) {
								//invalid
								continue;
							}
							if(int.TryParse(values[1], out int timeout)) {
								TestRunnerTimeout = timeout;
							}
						} else {
							if(!ConfigManager.ProcessSwitch(switchArg)) {
								_errorMessages.Add(ResourceHelper.GetMessage("InvalidArgument", arg));
							}
						}
						break;
				}
			} else {
				_errorMessages.Add(ResourceHelper.GetMessage("FileNotFound", arg));
			}
		}
	}

	public void OnAfterInit(MainWindow wnd)
	{
		if(Fullscreen && FilesToLoad.Count == 0) {
			wnd.ToggleFullscreen();
			Fullscreen = false;
		}
	}

	private static string ConvertArg(string arg)
	{
		arg = arg.Trim();
		if(arg.StartsWith("--")) {
			arg = arg.Substring(2);
		} else if(arg.StartsWith("-") || arg.StartsWith("/")) {
			arg = arg.Substring(1);
		}
		return arg;
	}

	public static bool IsTestRunner(string[] args)
	{
		return args.Any(arg => CommandLineHelper.ConvertArg(arg).ToLowerInvariant() == "testrunner");
	}

	public void ProcessPostLoadCommandSwitches(MainWindow wnd)
	{
		if(LuaScriptsToLoad.Count > 0) {
			foreach(string luaScript in LuaScriptsToLoad) {
				ScriptWindow? existingWnd = DebugWindowManager.GetDebugWindow<ScriptWindow>(wnd => !string.IsNullOrWhiteSpace(wnd.Model.FilePath) && Path.GetFullPath(wnd.Model.FilePath) == Path.GetFullPath(luaScript));
				if(existingWnd != null) {
					//Script is already opened, skip it
					continue;
				}

				ScriptWindowViewModel model = new(null);
				model.LoadScript(luaScript);
				DebugWindowManager.OpenDebugWindow(() => new ScriptWindow(model));
			}

			//Shift focus back to main window after opening the script window(s)
			wnd.BringToFront();
		}

		if(MovieToRecord != null) {
			if(RecordApi.MovieRecording()) {
				RecordApi.MovieStop();
			}
			RecordMovieOptions options = new RecordMovieOptions(MovieToRecord, "", "", RecordMovieFrom.StartWithSaveData);
			RecordApi.MovieRecord(options);
		}

		if(Fullscreen) {
			wnd.ToggleFullscreen();
		}

		if(LoadLastSessionRequested) {
			Task.Run(() => {
				EmuApi.ExecuteShortcut(new ExecuteShortcutParams() { Shortcut = Config.Shortcuts.EmulatorShortcut.LoadLastSession });
			});
		}
	}

	/// <summary>
	/// Opens the replay that was passed on the command line, if any. Called once the main window
	/// exists, because the prompt is a modal dialog - and it brings the window forward first, so
	/// a double-click (or a click on the website) surfaces an already-running emulator instead of
	/// leaving the dialog hidden behind the browser.
	/// </summary>
	public void OpenChallengeReplay(MainWindow wnd)
	{
		//One shot - a re-entrant call must not open the same replay twice. Both are cleared even
		//though only one can be acted on: the prompt is modal, so a second replay would have
		//nowhere to go, and leaving one pending would make it pop up at some later moment.
		int runId = ChallengeReplayRunToOpen;
		string? path = ChallengeReplayToOpen;
		ChallengeReplayRunToOpen = 0;
		ChallengeReplayToOpen = null;

		if(runId > 0) {
			//A link wins over a file path: it is the more specific request of the two.
			wnd.BringToFront();
			_ = ChallengeReplayLauncher.OpenRunAsync(wnd, runId);
		} else if(path != null) {
			wnd.BringToFront();
			_ = ChallengeReplayLauncher.OpenFileAsync(wnd, path);
		}
	}

	/// <summary>True when this invocation was asked to open a replay - a link or a .creplay. The
	/// startup path uses it to hold back its own popups, since the replay prompt is modal and the
	/// main window can only own one modal dialog at a time.</summary>
	public bool HasChallengeReplayToOpen => ChallengeReplayRunToOpen > 0 || ChallengeReplayToOpen != null;

	public void LoadFiles()
	{
		foreach(string file in FilesToLoad) {
			LoadRomHelper.LoadFile(file);
		}

		foreach(string msg in _errorMessages) {
			DisplayMessageHelper.DisplayMessage("Error", msg);
		}
	}

	public static Dictionary<string, string> GetAvailableSwitches()
	{
		Dictionary<string, string> result = new();

		string general = @"--doNotSaveSettings - Prevent settings from being saved to the disk (useful to prevent command line options from becoming the default settings)
--enableStdout - Writes the log window's content to stdout
--fullscreen - Start in fullscreen mode
--loadLastSession - Resumes the game in the state it was left in when it was last played.
--recordMovie=""filename.mmo"" - Start recording a movie after the specified game is loaded.
--testRunner [lua script] [rom file] - Runs a Lua script in headless mode (use emu.exit(...) to stop execution)
";

		result["General"] = general;
		result["Audio"] = GetSwichesForObject("audio.", typeof(AudioConfig));
		result["Emulation"] = GetSwichesForObject("emulation.", typeof(EmulationConfig));
		result["Input"] = GetSwichesForObject("input.", typeof(InputConfig));
		result["Video"] = GetSwichesForObject("video.", typeof(VideoConfig));
		result["Preferences"] = GetSwichesForObject("preferences.", typeof(PreferencesConfig));
		result["NES"] = GetSwichesForObject("nes.", typeof(NesConfig));
		result["SNES"] = GetSwichesForObject("snes.", typeof(SnesConfig));
		result["Game Boy"] = GetSwichesForObject("gameBoy.", typeof(GameboyConfig));
		result["GBA"] = GetSwichesForObject("gba.", typeof(GbaConfig));
		result["PC Engine"] = GetSwichesForObject("pcEngine.", typeof(PcEngineConfig));
		result["SMS"] = GetSwichesForObject("sms.", typeof(SmsConfig));
		result["WS"] = GetSwichesForObject("ws.", typeof(WsConfig));
		result["CV"] = GetSwichesForObject("cv.", typeof(CvConfig));

		return result;
	}

	private static string GetSwichesForObject(string prefix, Type type)
	{
		StringBuilder sb = new();

#pragma warning disable IL2070 // 'this' argument does not satisfy 'DynamicallyAccessedMembersAttribute' in call to target method. The parameter of method does not have matching annotations.
		foreach(PropertyInfo info in type.GetProperties()) {
			if(!info.CanWrite) {
				continue;
			}

			string name = char.ToLowerInvariant(info.Name[0]) + info.Name.Substring(1);
			if(info.PropertyType == typeof(int) || info.PropertyType == typeof(uint) || info.PropertyType == typeof(double)) {
				MinMaxAttribute? minMaxAttribute = info.GetCustomAttribute(typeof(MinMaxAttribute)) as MinMaxAttribute;
				if(minMaxAttribute != null) {
					sb.AppendLine("--" + prefix + name + "=[" + minMaxAttribute.Min.ToString() + " - " + minMaxAttribute.Max.ToString() + "]");
				}
			} else if(info.PropertyType == typeof(bool)) {
				sb.AppendLine("--" + prefix + name + "=[true | false]");
			} else if(info.PropertyType.IsEnum) {
				if(info.PropertyType != typeof(ControllerType)) {
					ValidValuesAttribute? validValuesAttribute = info.GetCustomAttribute(typeof(ValidValuesAttribute)) as ValidValuesAttribute;
					if(validValuesAttribute != null) {
						sb.AppendLine("--" + prefix + name + "=[" + string.Join(" | ", validValuesAttribute.ValidValues.Select(v => Enum.GetName(info.PropertyType, v))) + "]");
					} else {
						sb.AppendLine("--" + prefix + name + "=[" + string.Join(" | ", Enum.GetNames(info.PropertyType)) + "]");
					}
				}
			} else if(info.PropertyType.IsClass && !info.PropertyType.IsGenericType) {
				string content = GetSwichesForObject(prefix + name + ".", info.PropertyType);
				if(content.Length > 0) {
					sb.Append(content);
				}
			}
		}
#pragma warning restore IL2070 // 'this' argument does not satisfy 'DynamicallyAccessedMembersAttribute' in call to target method. The parameter of method does not have matching annotations.

		return sb.ToString();
	}
}
