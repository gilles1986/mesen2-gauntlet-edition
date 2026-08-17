using ReactiveUI.Fody.Helpers;

namespace Mesen.Config
{
	/// <summary>
	/// Settings for the embedded Kaizo challenge mode. Read by ChallengeManager and
	/// injected into the engine (e.g. as __SHOW_PBS). Kept separate so more display
	/// toggles can be added here later.
	/// </summary>
	public enum ChallengeHudSize
	{
		//Value = HUD size type (1 = Big, 2 = Normal, 3 = Small, 4 = Smaller)
		Big = 1,
		Normal = 2,
		Small = 3,
		Smaller = 4
	}

	public enum ChallengeInputDisplayPosition
	{
		BottomRight,
		TopRight,
		BottomLeft
	}

	//SNES controller buttons for the configurable reset shortcut. The member names lowercased
	//(A -> "a", Select -> "select", ...) match the engine's emu.getInput() keys, so they inject
	//directly. None = "unused" (see ChallengeConfig.ResetButton1/2).
	public enum ChallengeResetButton
	{
		None,
		A, B, X, Y, L, R,
		Select, Start,
		Up, Down, Left, Right
	}

	//When a fail condition triggers, restart the WHOLE run instead of just reloading the segment.
	//One setting rather than two switches because both variants share the same trigger - the
	//challenge's own games.lua "fail" conditions - and differ only in where they apply.
	public enum ChallengeAutoReset
	{
		//Classic: a fail reloads the current segment, the run (and its clock) carries on.
		Off,
		//Only in segment 1, where a fail puts you back at the start of the run anyway.
		FirstSegmentOnly,
		//In every segment: any fail ends the attempt and starts over.
		EverySegment
	}

	//What opening a replay does - by double-click or from a play button on saphros.de.
	public enum ChallengeReplayOpen
	{
		//Show the prompt and let the player pick each time.
		Ask,
		//Go straight to watching the run.
		Watch,
		//Go straight to racing its ghost.
		Race
	}

	public class ChallengeConfig : BaseConfig<ChallengeConfig>
	{
		//Legacy free-text player name. The Settings UI no longer exposes this field
		//(Twitch login replaced it), but it's kept so installs that already had a name
		//saved keep submitting under it for challenges that don't require Twitch login.
		[Reactive] public string PlayerName { get; set; } = "";

		//Twitch account linked via the device-login flow (Challenge Settings > Login
		//with Twitch). When linked, this identity is used instead of PlayerName for
		//both the HUD/leaderboard name and leaderboard-submit authentication.
		[Reactive] public bool IsTwitchLinked { get; set; } = false;
		[Reactive] public string TwitchLinkToken { get; set; } = "";
		[Reactive] public string TwitchLogin { get; set; } = "";
		[Reactive] public string TwitchDisplayName { get; set; } = "";
		[Reactive] public string TwitchAvatarUrl { get; set; } = "";

		//Show the challenge announcements published on saphros.de: the startup popup (for
		//announcements that ask for one) and the banner in Browse / Manage Challenges. Off =
		//nothing is fetched and nothing is shown. See ChallengeAnnouncements.
		[Reactive] public bool ShowAnnouncements { get; set; } = true;

		//Id of the last announcement the player closed. The startup popup is shown once per
		//announcement, so this suppresses it on every following launch until the server
		//publishes a new one. Written straight to the live config (not held for OK/Cancel like
		//the display settings) since it isn't something the Settings dialog edits.
		[Reactive] public int LastDismissedAnnouncementId { get; set; } = 0;

		//What opening a replay does. "Ask" shows the prompt every time; Watch/Race skip it and get
		//on with it. Skipping only applies when the choice is actually free: if the challenge still
		//has to be installed, if a challenge is running that would be ended, or if Race was chosen
		//for a replay without ghost data, the prompt appears anyway - those are decisions the player
		//hasn't pre-authorised by picking a default. The window itself always appears, since it is
		//also where the download progress and any failure are shown.
		[Reactive] public ChallengeReplayOpen ReplayOpenMode { get; set; } = ChallengeReplayOpen.Ask;

		//Register this copy of the emulator as the handler for .creplay replay files, so a shared
		//replay opens with a double-click. Rewritten on every launch (the Challenge Edition is a
		//portable exe, so the registration has to follow it when it's moved); turning this off
		//removes the entries again. Windows only. See FileAssociationHelper and docs/adr/0002.
		[Reactive] public bool AssociateReplayFiles { get; set; } = true;

		//Show the player's local per-segment / total personal bests in the challenge HUD.
		[Reactive] public bool ShowPersonalBests { get; set; } = true;

		//Show the title screen (logo + per-segment hack/author credits) when a challenge is
		//loaded. Unlike the other display toggles this one never reaches the engine - the screen
		//is a C# window shown before the first ROM loads (see ChallengeTitleWindow). Challenges
		//packed without a challenge.json have no credits to show and skip it regardless.
		[Reactive] public bool ShowTitleScreen { get; set; } = true;

		//Show the segment counter ("Segment X/Y") and the current segment's name on the live
		//HUD. Injected as __HUD_SEGMENT. Streamers who overlay their own segment info (or want
		//a minimal timer-only HUD) can turn this off.
		[Reactive] public bool ShowSegmentInfo { get; set; } = true;

		//Show the live +/- delta against the segment PB while playing. Injected as __HUD_DELTA.
		//Only has an effect when personal bests are shown and a PB exists for the segment.
		[Reactive] public bool ShowDelta { get; set; } = true;

		//Size of the challenge/practice HUD. Injected into the engine as __HUD_SS (the enum
		//value is the script-HUD surface scale; higher = smaller HUD).
		[Reactive] public ChallengeHudSize HudSize { get; set; } = ChallengeHudSize.Normal;

		//Show the on-screen SNES controller input display (live and in replays). Injected as
		//__INPUT_DISPLAY.
		[Reactive] public bool ShowInputDisplay { get; set; } = false;

		//Position of the input display on screen (BottomRight, TopRight, BottomLeft). Injected as
		//__INPUT_DISPLAY_POS.
		[Reactive] public ChallengeInputDisplayPosition InputDisplayPosition { get; set; } = ChallengeInputDisplayPosition.BottomRight;

		//Show the semi-transparent personal-best ghost overlay while playing. Injected as
		//__GHOST ("off"/"pb"). Off = no ghost file is loaded, no drawing overhead.
		[Reactive] public bool ShowGhost { get; set; } = true;

		//Ghost tint colors (ARGB UInt32; only the RGB part is used - the engine applies its own
		//fill/border transparency so the ghost always stays semi-transparent). GhostColor is your
		//own PB ghost (default white); RaceGhostColor is a foreign ghost from "Race a Ghost from
		//File..." (default orange) so you can tell your ghost and the opponent apart at a glance.
		//Injected as __GHOST_COLOR (the engine gets whichever one applies to the active ghost).
		[Reactive] public uint GhostColor { get; set; } = 0xFFFFFFFF;
		[Reactive] public uint RaceGhostColor { get; set; } = 0xFFFF9020;

		//Overall ghost opacity in percent (0 = invisible, 100 = near-solid). Applies to both the
		//PB and race ghost. The engine derives the fill/border alpha from this (the name label
		//has its own opacity below). Injected as __GHOST_OPACITY. 75 reproduces the classic look.
		[Reactive] public int GhostOpacity { get; set; } = 30;

		//Opacity of the ghost's name label in percent (0 = invisible, 100 = solid), independent of
		//the ghost-body opacity above - keep it high to read who the ghost is even over a very
		//faint ghost, or fade it too. Injected as __GHOST_NAME_OPACITY. 100 = classic solid name.
		[Reactive] public int GhostNameOpacity { get; set; } = 100;

		//Draw only the ghost's outline (border), no translucent fill. Injected as __GHOST_OUTLINE.
		//For players who want a minimal, less obtrusive marker. Combines with opacity/name-only.
		[Reactive] public bool GhostOutlineOnly { get; set; } = false;

		//Stream overlay: when on, the engine writes live run stats (PBs, deaths, session totals,
		//nemesis segment, ...) to a "stream" folder next to Mesen.exe on each run event - a
		//self-contained overlay.html (OBS browser source) plus stats.json and text/*.txt for OBS
		//text sources. Injected as __STREAM_OVERLAY (+ __STREAM_DIR). Off = no files, no overhead.
		[Reactive] public bool StreamOverlay { get; set; } = false;

		//Number of frames a freeze-frame preview of the segment's starting screen is shown
		//before play (and the timer) begins, so the player can prepare their inputs. Injected
		//into the engine as __PREVIEW_FRAMES. 0 = no preview (start immediately).
		[Reactive] public int PreviewFrames { get; set; } = 60;

		//Configurable reset shortcut: which button(s) must be held (~0.5s) to restart. The combo
		//is the non-None buttons among the two: pick two for a safe combo (default L+R), or set
		//button 2 to None for a single button. Injected as __RESET_BUTTONS (comma-joined, e.g.
		//"l,r"). If BOTH are None, nothing is injected and the challenge's own default combo is
		//kept - so leaving these alone never changes existing behavior.
		[Reactive] public ChallengeResetButton ResetButton1 { get; set; } = ChallengeResetButton.None;
		[Reactive] public ChallengeResetButton ResetButton2 { get; set; } = ChallengeResetButton.None;

		//Reset on a quick tap instead of holding the combo ~0.5s. Injected as __RESET_HOLD_FRAMES
		//(1 = fires the instant the combo is detected; 30 = the classic half-second hold). Off by
		//default so accidental combo presses during play don't restart the run.
		[Reactive] public bool ResetOnTap { get; set; } = false;

		//After a death (fail condition) mid-run, pause the segment timer and show the "GET READY"
		//freeze-frame before play resumes. The time already spent still counts - only the pause
		//itself is free prep time, like the preview at segment start. Injected as __FAIL_PREVIEW.
		//No effect when PreviewFrames is 0 or during replays (recordings stay in sync either way,
		//because input polls only advance during actual play).
		[Reactive] public bool PreviewOnDeath { get; set; } = false;

		//Mute the hack's music but keep sound effects: injected as __MUTE_MUSIC, the engine holds
		//the N-SPC/AddMusicK master music volume in SPC RAM ($57) at 0 every frame. That only
		//scales music (all 8 voices); sound effects write their DSP voice volumes directly and
		//stay audible. A pure SPC-RAM value - emulation/timing (and the ROM file) are unaffected,
		//so runs stay fair. See ChallengeManager.BuildEngineSource / relay.lua applyMusicMute.
		[Reactive] public bool MuteMusic { get; set; } = false;

		//Restart the whole run when a fail triggers, instead of reloading the segment and letting
		//the clock run on. Injected as __AUTO_RESET ("off" / "first" / "always"). Counts as a new
		//attempt, exactly like the reset combo. Driven by the challenge's own games.lua "fail"
		//conditions, so it works for retro-game challenges too - not just SMW hacks.
		//No effect in practice mode (there, restarting the segment is the point) or during replays.
		//
		//Defaults to FirstSegmentOnly because that is what players do by hand anyway: a fail in the
		//first segment puts them back at the start of the run, so the only thing carrying on is a
		//clock on an already-spoiled attempt. It can never keep a better time - a reset only ever
		//discards a run - so it cannot flatter anyone's leaderboard entry. It does make the attempt
		//counter climb faster, and it changes behaviour for existing installs (their settings.json
		//has no AutoReset field yet, so they pick up this default) - worth a line in the release
		//announcement.
		[Reactive] public ChallengeAutoReset AutoReset { get; set; } = ChallengeAutoReset.FirstSegmentOnly;

		//OBSOLETE - replaced by AutoReset. Kept only so an existing settings.json that had it on
		//is carried over instead of silently losing the setting; Configuration.RemoveObsoleteConfig
		//maps it to AutoReset.EverySegment once and then clears it. Do not read this anywhere else.
		//(The old implementation also used a different trigger: an SMW-only death check on the
		//player-animation state, independent of the fail conditions.)
		[Reactive] public bool AutoResetOnDeath { get; set; } = false;
	}
}
