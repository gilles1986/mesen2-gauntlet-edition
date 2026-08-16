namespace Mesen.Utilities
{
	/// <summary>
	/// Build-time secret for the challenge leaderboard. This file carries a placeholder and is
	/// the version that ships in the public repository - it builds and runs out of the box.
	///
	/// To build against a real leaderboard, add a file "ChallengeSecrets.Local.cs" next to this
	/// one that declares the same class with your own value:
	///
	///     namespace Mesen.Utilities
	///     {
	///         internal static class ChallengeSecrets
	///         {
	///             public const string HmacSecret = "your-secret-here";
	///         }
	///     }
	///
	/// UI.csproj drops this placeholder from the compilation whenever that file exists, and
	/// .gitignore keeps it out of git. Nothing else needs to be changed.
	///
	/// With the placeholder in place everything in the emulator works normally; only leaderboard
	/// submissions are rejected by the server, because the signature will not match.
	/// </summary>
	internal static class ChallengeSecrets
	{
		public const string HmacSecret = "public-build-no-secret";
	}
}
