using Mesen.Config;
using System;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Mesen.Utilities
{
	/// <summary>
	/// Client for the saphros.de "device login" flow (Challenge Settings > Login with
	/// Twitch). Mesen has no browser/cookies and must not embed the Twitch client
	/// secret, so it can't do the OAuth exchange itself - instead it mirrors the OAuth
	/// Device Authorization Grant pattern (like a smart-TV app login):
	///
	/// 1. Mesen asks the server for a (secret) device_code + (short, human) user_code.
	/// 2. Mesen opens the user's browser to a saphros.de page pre-filled with user_code;
	///    the user logs in with Twitch there (existing, fully server-side OAuth flow).
	/// 3. Mesen polls with device_code until the server reports the user_code as
	///    confirmed, then receives a persistent link_token identifying the Twitch
	///    account. That link_token (not any Twitch secret) is what gets sent with
	///    future leaderboard submissions (see ChallengeSubmit).
	///
	/// JSON is hand-parsed with JsonDocument, matching ChallengeSubmit/ChallengeCatalog
	/// (the UI is published trimmed/AOT, so JsonSerializer&lt;T&gt; is not available).
	/// </summary>
	public static class ChallengeTwitchAuth
	{
		private const string ApiBaseUrl = "https://saphros.de/api/challenge/";
		private const int RequestTimeoutSeconds = 30;
		private static readonly HttpClient _http = ChallengeHttp.Create(TimeSpan.FromSeconds(RequestTimeoutSeconds));

		public enum LoginResult { Success, Cancelled, Expired, Error }

		/// <summary>Outcome of <see cref="LoginAsync"/>; <see cref="Error"/> carries the
		/// user-readable reason when <see cref="Result"/> is <see cref="LoginResult.Error"/>.</summary>
		public class LoginOutcome
		{
			public LoginResult Result;
			public string Error = "";

			public LoginOutcome(LoginResult result, string error = "")
			{
				Result = result;
				Error = error;
			}
		}

		/// <summary>What the user needs to complete the login in their browser. Handed to the
		/// caller once the server issued a code, so the UI can show the code - and the URL
		/// itself if the browser could not be launched.</summary>
		public class DeviceLoginInfo
		{
			public string UserCode = "";
			public string VerificationUrl = "";
			public bool BrowserOpened;
		}

		/// <summary>
		/// Runs the full device-login flow. Calls <paramref name="onWaitingForUser"/> once
		/// the browser has been opened (with the short code, for display), and polls until
		/// the user confirms it in their browser, the code expires, or cancellation is
		/// requested. On success, writes the linked identity into the live config and saves it.
		/// </summary>
		public static async Task<LoginOutcome> LoginAsync(Action<DeviceLoginInfo> onWaitingForUser, CancellationToken ct)
		{
			try {
				string startJson;
				using(HttpResponseMessage startResp = await _http.PostAsync(ApiBaseUrl + "device-login-start.php", new StringContent("", Encoding.UTF8, "application/json"), ct)) {
					startJson = await startResp.Content.ReadAsStringAsync(ct);
					if(!startResp.IsSuccessStatusCode) {
						//A plain "login failed" here is a dead end for the user (and for support):
						//name the status so a missing/broken endpoint or a blocking proxy is visible.
						return new LoginOutcome(LoginResult.Error, "the server answered with HTTP " + (int)startResp.StatusCode + " (" + startResp.ReasonPhrase + ").");
					}
				}

				using JsonDocument startDoc = ParseOrNull(startJson) ?? throw new FormatException();
				JsonElement startRoot = startDoc.RootElement;
				if(startRoot.ValueKind != JsonValueKind.Object) {
					throw new FormatException();
				}
				if(!startRoot.TryGetProperty("ok", out JsonElement okEl) || okEl.ValueKind != JsonValueKind.True) {
					return new LoginOutcome(LoginResult.Error, "the server rejected the login request.");
				}

				string deviceCode = GetStr(startRoot, "device_code");
				string userCode = GetStr(startRoot, "user_code");
				string verificationUrlComplete = GetStr(startRoot, "verification_url_complete");
				int expiresIn = startRoot.TryGetProperty("expires_in", out JsonElement expEl) && expEl.TryGetInt32(out int exp) ? exp : 600;
				int pollInterval = startRoot.TryGetProperty("poll_interval", out JsonElement pollEl) && pollEl.TryGetInt32(out int pi) ? Math.Max(2, pi) : 3;

				if(deviceCode.Length == 0 || userCode.Length == 0) {
					return new LoginOutcome(LoginResult.Error, "the server returned an incomplete login code.");
				}

				//A failed browser launch must not strand the user: report it so the UI can show
				//the URL to open by hand - the code stays valid either way.
				bool browserOpened = true;
				try {
					ApplicationHelper.OpenBrowser(verificationUrlComplete);
				} catch {
					browserOpened = false;
				}
				onWaitingForUser(new DeviceLoginInfo() {
					UserCode = userCode,
					VerificationUrl = verificationUrlComplete,
					BrowserOpened = browserOpened
				});

				DateTime deadline = DateTime.UtcNow.AddSeconds(expiresIn);
				while(DateTime.UtcNow < deadline) {
					if(ct.IsCancellationRequested) {
						return new LoginOutcome(LoginResult.Cancelled);
					}

					await Task.Delay(TimeSpan.FromSeconds(pollInterval), ct);

					string pollJson;
					try {
						pollJson = await _http.GetStringAsync(ApiBaseUrl + "device-login-poll.php?device_code=" + Uri.EscapeDataString(deviceCode), ct);
					} catch(OperationCanceledException) when(ct.IsCancellationRequested) {
						return new LoginOutcome(LoginResult.Cancelled);
					} catch {
						continue; //transient network error/timeout - keep polling until the deadline
					}

					//A garbled answer (error page, truncated response) is treated like a transient
					//failure rather than aborting a login the user may still be completing.
					using JsonDocument? pollDoc = ParseOrNull(pollJson);
					if(pollDoc == null) {
						continue;
					}
					JsonElement pollRoot = pollDoc.RootElement;
					if(pollRoot.ValueKind != JsonValueKind.Object || !pollRoot.TryGetProperty("ok", out JsonElement pollOkEl) || pollOkEl.ValueKind != JsonValueKind.True) {
						continue;
					}

					string status = GetStr(pollRoot, "status");
					if(status == "expired") {
						return new LoginOutcome(LoginResult.Expired);
					}
					if(status == "confirmed") {
						ChallengeConfig cfg = ConfigManager.Config.Challenge;
						cfg.IsTwitchLinked = true;
						cfg.TwitchLinkToken = GetStr(pollRoot, "link_token");
						cfg.TwitchLogin = GetStr(pollRoot, "twitch_login");
						cfg.TwitchDisplayName = GetStr(pollRoot, "twitch_display_name");
						cfg.TwitchAvatarUrl = GetStr(pollRoot, "twitch_avatar_url");
						ConfigManager.Config.Save();
						return new LoginOutcome(LoginResult.Success);
					}
					//status == "pending" -> keep polling
				}

				return new LoginOutcome(LoginResult.Expired);
			} catch(OperationCanceledException) when(ct.IsCancellationRequested) {
				return new LoginOutcome(LoginResult.Cancelled);
			} catch(OperationCanceledException) {
				//HttpClient reports its own timeout as a cancellation - NOT the user cancelling.
				//Reporting that as "login cancelled" hid every connectivity problem there is.
				return new LoginOutcome(LoginResult.Error, "saphros.de did not respond within " + RequestTimeoutSeconds + " seconds (check your internet connection, firewall/antivirus or proxy).");
			} catch(HttpRequestException ex) {
				return new LoginOutcome(LoginResult.Error, "could not reach saphros.de - " + Describe(ex));
			} catch(FormatException) {
				return new LoginOutcome(LoginResult.Error, "the server returned an unexpected response.");
			} catch(JsonException) {
				return new LoginOutcome(LoginResult.Error, "the server returned an unexpected response.");
			} catch(Exception ex) {
				return new LoginOutcome(LoginResult.Error, Describe(ex));
			}
		}

		private static JsonDocument? ParseOrNull(string json)
		{
			try {
				return JsonDocument.Parse(json);
			} catch(JsonException) {
				return null;
			}
		}

		/// <summary>Exception text including the inner message, which is usually the specific
		/// one (TLS handshake, DNS, connection refused) while the outer is generic.</summary>
		private static string Describe(Exception ex)
		{
			string msg = ex.Message;
			if(ex.InnerException != null && ex.InnerException.Message.Length > 0 && !msg.Contains(ex.InnerException.Message)) {
				msg += " (" + ex.InnerException.Message + ")";
			}
			return msg;
		}

		/// <summary>Clears the local Twitch link (and best-effort revokes it server-side).</summary>
		public static async Task LogoutAsync()
		{
			ChallengeConfig cfg = ConfigManager.Config.Challenge;
			string token = cfg.TwitchLinkToken;

			cfg.IsTwitchLinked = false;
			cfg.TwitchLinkToken = "";
			cfg.TwitchLogin = "";
			cfg.TwitchDisplayName = "";
			cfg.TwitchAvatarUrl = "";
			ConfigManager.Config.Save();

			if(token.Length > 0) {
				try {
					using MemoryStream stream = new();
					using(Utf8JsonWriter w = new(stream)) {
						w.WriteStartObject();
						w.WriteString("link_token", token);
						w.WriteEndObject();
					}
					using StringContent body = new(Encoding.UTF8.GetString(stream.ToArray()), Encoding.UTF8, "application/json");
					await _http.PostAsync(ApiBaseUrl + "device-login-revoke.php", body);
				} catch {
					//best-effort only - the local link is already cleared either way
				}
			}
		}

		private static string GetStr(JsonElement e, string prop)
		{
			return e.TryGetProperty(prop, out JsonElement v) && v.ValueKind == JsonValueKind.String ? (v.GetString() ?? "") : "";
		}
	}
}
