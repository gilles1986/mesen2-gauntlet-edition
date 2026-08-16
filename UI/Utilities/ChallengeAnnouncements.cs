using System;
using System.Globalization;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;

namespace Mesen.Utilities
{
	/// <summary>
	/// Reads the challenge announcements / teasers published on saphros.de (announcements.php).
	/// The server returns at most one announcement for the "emulator" platform - the one that is
	/// currently active - or none at all.
	///
	/// Shown in two places (see ChallengeAnnouncementWindow): as a startup popup when the
	/// announcement asks for one (show_popup) and hasn't been dismissed yet, and as a passive
	/// banner at the top of Browse / Manage Challenges. Both are suppressed entirely by
	/// ChallengeConfig.ShowAnnouncements.
	///
	/// JSON is parsed with JsonDocument (reflection-free) like the other challenge helpers,
	/// because the UI is published trimmed/AOT.
	/// </summary>
	public static class ChallengeAnnouncements
	{
		private const string AnnouncementsUrl = "https://saphros.de/api/challenge/announcements.php?platform=emulator";

		//Deliberately short: an announcement is decoration around startup and the challenge
		//browser, and neither may sit and wait on a slow or unreachable server.
		private static readonly HttpClient _http = ChallengeHttp.Create(TimeSpan.FromSeconds(10));

		public class Announcement
		{
			//Server-side id; identifies the announcement for the "already dismissed" check
			//(ChallengeConfig.LastDismissedAnnouncementId).
			public int Id;

			public string Title = "";
			public string Message = "";

			//Short tag ("Upcoming", "Live", ...) plus the style it should be drawn in
			//("upcoming"/"info"/"warning"/"success"); see ChallengeAnnouncementViewModel.
			public string BadgeText = "";
			public string BadgeType = "";

			//Local time (the API sends UTC).
			public DateTime? StartAt;
			public DateTime? EndAt;

			//Slug of the linked challenge, if any, plus how far along it is:
			//"ready" = published and installable, "upcoming_preview"/"upcoming_teaser" = not yet.
			public string ChallengeId = "";
			public string ChallengeStatus = "";

			//Name / teaser text from challenge_info - for a teaser this is all there is to show.
			public string ChallengeName = "";
			public string TeaserText = "";

			//Optional URL for a "More info" button, opened in the user's browser.
			public string CustomLink = "";

			//The announcement wants a modal popup at startup (else it's banner-only).
			public bool ShowPopup;

			/// <summary>
			/// The linked challenge is published, so it can be installed straight from the
			/// announcement. Teasers/previews have nothing to download yet.
			/// </summary>
			public bool IsChallengeReady => ChallengeStatus == "ready" && ChallengeId.Length > 0;
		}

		/// <summary>
		/// Fetches the active emulator announcement, or null if there is none. Never throws -
		/// offline, a server error or an unexpected response all mean "no announcement", because
		/// this must never delay startup or break the challenge browser.
		/// </summary>
		public static async Task<Announcement?> FetchAsync()
		{
			try {
				return Parse(await _http.GetStringAsync(AnnouncementsUrl));
			} catch {
				//Offline / server error / bad JSON -> treat as "no announcement".
				return null;
			}
		}

		/// <summary>
		/// Reads one announcements.php response. Returns null for every "nothing to show" case:
		/// ok != true, no announcement, an inactive one, or one without a headline. Deliberately
		/// tolerant about types - PHP/PDO reports integer and boolean columns as strings often
		/// enough that insisting on JSON numbers would break the feature at the first backend change.
		/// </summary>
		private static Announcement? Parse(string json)
		{
			using JsonDocument doc = JsonDocument.Parse(json);
			JsonElement root = doc.RootElement;

			if(root.ValueKind != JsonValueKind.Object) {
				return null;
			}
			if(!root.TryGetProperty("ok", out JsonElement okEl) || okEl.ValueKind != JsonValueKind.True) {
				return null;
			}
			if(!root.TryGetProperty("announcement", out JsonElement a) || a.ValueKind != JsonValueKind.Object) {
				return null;   //null / missing -> nothing active right now
			}

			//The server only returns what's active, but it also states the flag - honor it.
			if(a.TryGetProperty("is_active", out JsonElement activeEl) && activeEl.ValueKind == JsonValueKind.False) {
				return null;
			}

			Announcement result = new() {
				Id = GetInt(a, "id"),
				Title = GetStr(a, "title"),
				Message = GetStr(a, "message"),
				BadgeText = GetStr(a, "badge_text"),
				BadgeType = GetStr(a, "badge_type"),
				StartAt = GetDate(a, "start_at"),
				EndAt = GetDate(a, "end_at"),
				ChallengeId = GetStr(a, "challenge_id"),
				ChallengeStatus = GetStr(a, "challenge_status"),
				CustomLink = GetStr(a, "custom_link"),
				ShowPopup = GetBool(a, "show_popup")
			};

			if(a.TryGetProperty("challenge_info", out JsonElement info) && info.ValueKind == JsonValueKind.Object) {
				result.ChallengeName = GetStr(info, "name");
				result.TeaserText = GetStr(info, "teaser_text");
				if(result.ChallengeId.Length == 0) {
					result.ChallengeId = GetStr(info, "id");
				}
			}

			//Only http(s) links are ever handed to the browser - not file:// or anything else
			//that could be turned into a local "open this" from a server response.
			if(!result.CustomLink.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
			   !result.CustomLink.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) {
				result.CustomLink = "";
			}

			//Without a headline there is nothing worth showing.
			return result.Title.Length > 0 ? result : null;
		}

		private static string GetStr(JsonElement e, string prop)
		{
			return e.TryGetProperty(prop, out JsonElement v) && v.ValueKind == JsonValueKind.String ? (v.GetString() ?? "") : "";
		}

		/// <summary>Number or numeric string (PHP/PDO happily reports integer columns as strings).</summary>
		private static int GetInt(JsonElement e, string prop)
		{
			if(!e.TryGetProperty(prop, out JsonElement v)) {
				return 0;
			}
			if(v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out int n)) {
				return n;
			}
			if(v.ValueKind == JsonValueKind.String && int.TryParse(v.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out int s)) {
				return s;
			}
			return 0;
		}

		/// <summary>Accepts true, 1 and "1"/"true" - same reason as GetInt.</summary>
		private static bool GetBool(JsonElement e, string prop)
		{
			if(!e.TryGetProperty(prop, out JsonElement v)) {
				return false;
			}
			return v.ValueKind switch {
				JsonValueKind.True => true,
				JsonValueKind.Number => v.TryGetInt32(out int n) && n != 0,
				JsonValueKind.String => v.GetString() is "1" or "true" or "True",
				_ => false
			};
		}

		/// <summary>
		/// ISO timestamp -> local time. A string without a zone is read as UTC, which is what the
		/// API documents it sends.
		/// </summary>
		private static DateTime? GetDate(JsonElement e, string prop)
		{
			string s = GetStr(e, prop);
			if(s.Length == 0) {
				return null;
			}
			if(!DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture,
				DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out DateTimeOffset value)) {
				return null;
			}
			return value.LocalDateTime;
		}
	}
}
