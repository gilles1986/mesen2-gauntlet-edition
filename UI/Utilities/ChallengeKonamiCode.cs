using Avalonia.Controls;
using Avalonia.Threading;
using Mesen.Config;
using Mesen.Interop;
using System;
using System.Collections.Generic;

namespace Mesen.Utilities
{
	/// <summary>
	/// Hidden easter egg: the Konami code (Up Up Down Down Left Right Left Right B A Start) on
	/// player 1's SNES pad opens a page in the browser - but only on the idle main window, never
	/// while a game is loaded.
	///
	/// Why polling works with no game running: the core's ShortcutKeyHandler runs its own thread
	/// that refreshes the key state every 50 ms regardless of emulation, and MainWindow pushes
	/// keyboard presses into the same state (InputApi.SetKeyState). So GetPressedKeys() is live on
	/// the game-selection screen too - which is the only place this could ever be entered, since
	/// there is no emulation loop (and no Lua engine) there to hook into.
	///
	/// Buttons are resolved through the player's own SNES mapping (all four mapping slots of
	/// Snes.Port1), so it works with whatever gamepad or keyboard layout they configured.
	///
	/// Deliberately not configurable and not mentioned in any menu - it's an easter egg. Since it
	/// only ever runs with no game loaded, it cannot disturb a challenge run.
	/// </summary>
	public static class ChallengeKonamiCode
	{
		/// <summary>
		/// Where the code sends the player. It points at saphros.de rather than at the video
		/// itself on purpose: the target is a redirect the dashboard owns, so the video can be
		/// swapped any time without shipping a new emulator build.
		/// </summary>
		public const string RewardUrl = "https://saphros.de/api/challenge/easter-egg.php?id=konami";

		private enum Btn { Up, Down, Left, Right, A, B, X, Y, L, R, Select, Start }

		private static readonly Btn[] Sequence = {
			Btn.Up, Btn.Up, Btn.Down, Btn.Down, Btn.Left, Btn.Right, Btn.Left, Btn.Right, Btn.B, Btn.A, Btn.Start
		};

		//Every button that belongs to the pad. A press of one of these that isn't the expected
		//next one cancels the code; anything else (mouse, an unmapped key) is simply ignored.
		private static readonly Btn[] PadButtons = {
			Btn.Up, Btn.Down, Btn.Left, Btn.Right, Btn.A, Btn.B, Btn.X, Btn.Y, Btn.L, Btn.R, Btn.Select, Btn.Start
		};

		//How many correct presses arm the code - see IsArmed. One short of the full directional
		//prefix on purpose: the last direction and the B after it can land in the same 50 ms poll
		//window, and the game-selection screen may well look at that B before we've counted the
		//direction. Arming a step early closes that race.
		private const int ArmAfterStep = 7;

		//Matches the core's own polling interval; going faster cannot see more presses.
		private const int PollIntervalMs = 50;

		//A half-entered code expires, so a stray Up from ten minutes ago can't complete one later.
		private const int StepTimeoutMs = 2000;

		//How long the code stays armed after it fired. Both this and the game-selection screen
		//poll on their own timers, so that screen may well look at the final Start press only
		//after we've already handled it and cleared the sequence - and it starts a game on any
		//face button. The guard therefore has to outlive the trigger instead of ending with it.
		private const int PostTriggerGuardMs = 1000;

		private static DispatcherTimer? _timer;
		private static Window? _parent;
		private static List<ushort> _heldKeys = new();
		private static int _index;
		private static long _lastStepMs;
		private static long _firedMs;

		/// <summary>
		/// True while the directional prefix is in and the code hasn't expired - i.e. the next
		/// B / A / Start presses belong to the code - and for a moment after it fired.
		///
		/// The game-selection screen reads this: it starts the selected game on <em>any</em> face
		/// button (see StateGrid), which would otherwise swallow the last three presses and load a
		/// game instead. The window is two seconds after seven exact presses, so normal launching
		/// is unaffected.
		/// </summary>
		public static bool IsArmed => (_index >= ArmAfterStep && !IsExpired) || Environment.TickCount64 - _firedMs < PostTriggerGuardMs;

		private static bool IsExpired => Environment.TickCount64 - _lastStepMs > StepTimeoutMs;

		/// <summary>Starts watching. Call once, after the core is initialized.</summary>
		public static void Attach(Window parent)
		{
			if(_timer != null) {
				return;   //there is only ever one main window
			}

			_parent = parent;
			_timer = new DispatcherTimer(TimeSpan.FromMilliseconds(PollIntervalMs), DispatcherPriority.Background, (s, e) => Poll());
			_timer.Start();

			parent.Closed += (s, e) => {
				_timer?.Stop();
				_timer = null;
				_parent = null;
			};
		}

		private static void Poll()
		{
			//Nothing to do while a game is loaded (that includes every challenge run) or while the
			//window is in the background - which it is right after firing, since the browser takes
			//over the foreground.
			if(_parent == null || !_parent.IsActive || EmuApi.IsRunning()) {
				Reset();
				return;
			}

			List<ushort> keys = InputApi.GetPressedKeys();
			foreach(ushort key in keys) {
				if(!_heldKeys.Contains(key)) {
					OnKeyPressed(key);   //edge, not hold - a held button must not count twice
				}
			}
			_heldKeys = keys;
		}

		private static void OnKeyPressed(ushort key)
		{
			if(_index > 0 && IsExpired) {
				_index = 0;
			}

			if(IsButton(Sequence[_index], key)) {
				_index++;
				_lastStepMs = Environment.TickCount64;
				if(_index >= Sequence.Length) {
					Trigger();
				}
				return;
			}

			//Not a pad button at all (mouse click, some keyboard shortcut) - none of our business,
			//and it must not cancel a code that's halfway in.
			if(!IsPadButton(key)) {
				return;
			}

			//Wrong button: start over. A wrong button that happens to be the code's first one
			//starts the new attempt right there, so Up Up Up Down Down ... still works.
			_index = IsButton(Sequence[0], key) ? 1 : 0;
			_lastStepMs = Environment.TickCount64;
		}

		private static bool IsButton(Btn button, ushort key)
		{
			if(key == 0) {
				return false;
			}

			//All four mapping slots, so the code works on whichever one the player actually uses
			//(gamepad on slot 1, keyboard on slot 2, ...).
			ControllerConfig port = ConfigManager.Config.Snes.Port1;
			return KeyOf(port.Mapping1, button) == key
				|| KeyOf(port.Mapping2, button) == key
				|| KeyOf(port.Mapping3, button) == key
				|| KeyOf(port.Mapping4, button) == key;
		}

		private static bool IsPadButton(ushort key)
		{
			foreach(Btn button in PadButtons) {
				if(IsButton(button, key)) {
					return true;
				}
			}
			return false;
		}

		private static ushort KeyOf(KeyMapping mapping, Btn button)
		{
			return button switch {
				Btn.Up => mapping.Up,
				Btn.Down => mapping.Down,
				Btn.Left => mapping.Left,
				Btn.Right => mapping.Right,
				Btn.A => mapping.A,
				Btn.B => mapping.B,
				Btn.X => mapping.X,
				Btn.Y => mapping.Y,
				Btn.L => mapping.L,
				Btn.R => mapping.R,
				Btn.Select => mapping.Select,
				_ => mapping.Start
			};
		}

		private static void Trigger()
		{
			_firedMs = Environment.TickCount64;
			Reset();
			ApplicationHelper.OpenBrowser(RewardUrl);
		}

		private static void Reset()
		{
			_index = 0;
			if(_heldKeys.Count > 0) {
				_heldKeys = new List<ushort>();
			}
		}
	}
}
