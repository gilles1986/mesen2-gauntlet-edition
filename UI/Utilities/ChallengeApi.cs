using System;
using System.Security.Cryptography;
using System.Text;

namespace Mesen.Utilities
{
	/// <summary>
	/// Shared constants + HMAC signing for the saphros.de challenge API (used by
	/// ChallengeSubmit; a single place for the secret/base URL).
	/// </summary>
	internal static class ChallengeApi
	{
		// NOTE: "Casual" anti-cheat only. This secret is compiled into the build and can be
		// extracted; it is just a deterrent. It must match CHALLENGE_HMAC_SECRET on the
		// saphros.de server. Replace before shipping and keep both sides in sync.
		public const string HmacSecret = "72147875578249186686397822266499";
		public const string BaseUrl = "https://saphros.de/api/challenge/";

		public static string HmacHex(string canonical)
		{
			using HMACSHA256 hmac = new(Encoding.UTF8.GetBytes(HmacSecret));
			byte[] hash = hmac.ComputeHash(Encoding.UTF8.GetBytes(canonical));
			return Convert.ToHexString(hash).ToLowerInvariant();
		}
	}
}
