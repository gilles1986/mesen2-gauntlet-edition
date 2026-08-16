using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Mesen.Utilities
{
	/// <summary>
	/// Local buffer of completed runs whose leaderboard submit failed at the network level
	/// (no connection / timeout). It is deliberately NOT flushed on a timer or at startup:
	/// the next time the player completes a run for the same challenge, ChallengeSubmit
	/// re-signs and re-sends the queued runs alongside it (see ChallengeSubmit.ProcessRequest).
	///
	/// "Casual" tamper resistance only, matching the rest of the challenge anti-cheat model:
	/// the file has no extension (a binary blob that doesn't invite editing) and is AES-encrypted
	/// with a key derived from the shared HMAC secret, so a player can't trivially open it and
	/// edit a time. The key is compiled into the build and thus extractable - it's a deterrent,
	/// not real protection. Tampering with the ciphertext just makes the queue undecryptable, in
	/// which case it is dropped rather than resubmitted.
	/// </summary>
	internal static class ChallengeSubmitQueue
	{
		//No file extension on purpose (see class summary).
		private const string QueueFileName = "submit_pending";
		//Cap so a permanently-offline player can't grow the file without bound (oldest dropped).
		private const int MaxQueued = 25;

		private static byte[] Key => SHA256.HashData(Encoding.UTF8.GetBytes(ChallengeApi.HmacSecret));

		public static void Enqueue(string challengeDir, ChallengeRun run)
		{
			List<ChallengeRun> runs = Load(challengeDir);
			runs.Add(run);
			if(runs.Count > MaxQueued) {
				runs.RemoveRange(0, runs.Count - MaxQueued);
			}
			Save(challengeDir, runs);
		}

		/// <summary>Loads the queued runs (oldest first). Returns an empty list if the file is
		/// absent, corrupt, or tampered with.</summary>
		public static List<ChallengeRun> Load(string challengeDir)
		{
			List<ChallengeRun> runs = new();
			string path = Path.Combine(challengeDir, QueueFileName);
			if(!File.Exists(path)) {
				return runs;
			}
			try {
				byte[]? json = Decrypt(File.ReadAllBytes(path));
				if(json == null) {
					return runs;   //corrupt / tampered -> treat as empty
				}
				using JsonDocument doc = JsonDocument.Parse(json);
				if(doc.RootElement.ValueKind != JsonValueKind.Array) {
					return runs;
				}
				foreach(JsonElement e in doc.RootElement.EnumerateArray()) {
					ChallengeRun? run = ChallengeRun.FromJson(e);
					if(run != null) {
						runs.Add(run);
					}
				}
			} catch {
				//Unreadable queue -> drop it rather than blocking future submits.
			}
			return runs;
		}

		public static void Save(string challengeDir, List<ChallengeRun> runs)
		{
			string path = Path.Combine(challengeDir, QueueFileName);
			try {
				if(runs.Count == 0) {
					if(File.Exists(path)) {
						File.Delete(path);
					}
					return;
				}
				using MemoryStream stream = new();
				using(Utf8JsonWriter w = new(stream)) {
					w.WriteStartArray();
					foreach(ChallengeRun run in runs) {
						run.WriteJson(w);
					}
					w.WriteEndArray();
				}
				File.WriteAllBytes(path, Encrypt(stream.ToArray()));
			} catch {
				//Best-effort persistence; a failure here just means the run isn't buffered.
			}
		}

		//AES-CBC with a random IV prepended to the ciphertext. Key is the SHA-256 of the shared
		//HMAC secret (32 bytes -> AES-256).
		private static byte[] Encrypt(byte[] plain)
		{
			using Aes aes = Aes.Create();
			aes.Key = Key;
			aes.GenerateIV();
			using ICryptoTransform enc = aes.CreateEncryptor();
			byte[] cipher = enc.TransformFinalBlock(plain, 0, plain.Length);
			byte[] output = new byte[aes.IV.Length + cipher.Length];
			Buffer.BlockCopy(aes.IV, 0, output, 0, aes.IV.Length);
			Buffer.BlockCopy(cipher, 0, output, aes.IV.Length, cipher.Length);
			return output;
		}

		private static byte[]? Decrypt(byte[] data)
		{
			if(data.Length <= 16) {
				return null;
			}
			try {
				using Aes aes = Aes.Create();
				aes.Key = Key;
				byte[] iv = new byte[16];
				Buffer.BlockCopy(data, 0, iv, 0, 16);
				aes.IV = iv;
				using ICryptoTransform dec = aes.CreateDecryptor();
				return dec.TransformFinalBlock(data, 16, data.Length - 16);
			} catch {
				return null;   //wrong key / tampered ciphertext / bad padding
			}
		}
	}
}
