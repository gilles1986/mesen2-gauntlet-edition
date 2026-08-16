using System;
using System.IO;
using System.Reflection;

namespace Mesen.Utilities
{
	/// <summary>
	/// Exposes the Challenge Edition version + build date, read once from the embedded
	/// <c>Challenge/version.txt</c> (logical name <c>Mesen.ChallengeEngine.version.txt</c>,
	/// see UI.csproj). That file is the single source of truth — bumping the version only
	/// means editing it and rebuilding, no C# changes.
	///
	/// Consumed by AboutWindow (display) and ChallengeUpdater (the "am I outdated?" check).
	/// </summary>
	public static class ChallengeEditionInfo
	{
		private const string ResourceName = "Mesen.ChallengeEngine.version.txt";

		public static string VersionString { get; }
		public static string BuildDate { get; }
		public static Version Version { get; }

		static ChallengeEditionInfo()
		{
			string versionStr = "0.0";
			string buildDate = "";

			try {
				string? content = ReadEmbedded();
				if(content != null) {
					foreach(string rawLine in content.Split('\n')) {
						string line = rawLine.Trim();
						if(line.Length == 0 || line.StartsWith("#")) {
							continue;   //skip blanks + comments
						}
						int eq = line.IndexOf('=');
						if(eq <= 0) {
							continue;
						}
						string key = line.Substring(0, eq).Trim().ToLowerInvariant();
						string value = line.Substring(eq + 1).Trim();
						if(key == "version" && value.Length > 0) {
							versionStr = value;
						} else if(key == "date") {
							buildDate = value;
						}
					}
				}
			} catch {
				//Fall back to the 0.0 defaults if the resource is missing/unreadable.
			}

			VersionString = versionStr;
			BuildDate = buildDate;
			Version = Version.TryParse(versionStr, out Version? v) ? v : new Version(0, 0);
		}

		private static string? ReadEmbedded()
		{
			Assembly assembly = Assembly.GetExecutingAssembly();
			using Stream? stream = assembly.GetManifestResourceStream(ResourceName);
			if(stream == null) {
				return null;
			}
			using StreamReader sr = new(stream);
			return sr.ReadToEnd();
		}
	}
}
