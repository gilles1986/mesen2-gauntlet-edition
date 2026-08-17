using System;

namespace Mesen.Utilities
{
	/// <summary>
	/// Minimal BPS (beat) patch applier, used at challenge-import time to turn the
	/// shipped <c>.bps</c> patches into playable ROMs against the user's clean ROM.
	/// Verifies the clean ROM against the patch's source CRC and auto-strips a 512-byte
	/// copier header if present.
	/// </summary>
	public static class BpsPatcher
	{
		private static readonly uint[] _crcTable = BuildCrcTable();

		private static uint[] BuildCrcTable()
		{
			uint[] t = new uint[256];
			for(uint i = 0; i < 256; i++) {
				uint c = i;
				for(int k = 0; k < 8; k++) {
					c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
				}
				t[i] = c;
			}
			return t;
		}

		private static uint Crc32(byte[] data, int offset, int length)
		{
			uint c = 0xFFFFFFFF;
			for(int i = 0; i < length; i++) {
				c = _crcTable[(c ^ data[offset + i]) & 0xFF] ^ (c >> 8);
			}
			return c ^ 0xFFFFFFFF;
		}

		/// <summary>CRC32 over a slice of a byte array. Exposed so the clean-ROM picker can
		/// verify a selected ROM against the known Super Mario World (US) checksum.</summary>
		public static uint ComputeCrc32(byte[] data, int offset, int length) => Crc32(data, offset, length);

		private static long DecodeNumber(byte[] patch, ref int pos)
		{
			long data = 0, shift = 1;
			while(true) {
				byte x = patch[pos++];
				data += (x & 0x7f) * shift;
				if((x & 0x80) != 0) {
					break;
				}
				shift <<= 7;
				data += shift;
			}
			return data;
		}

		private static uint ReadU32Le(byte[] data, int offset)
		{
			return (uint)(data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24));
		}

		/// <summary>
		/// Applies a BPS patch to the given source ROM and returns the patched ROM.
		/// Throws with a user-readable message on any mismatch.
		/// </summary>
		public static byte[] Apply(byte[] source, byte[] patch)
		{
			if(patch.Length < 4 + 12 || patch[0] != 'B' || patch[1] != 'P' || patch[2] != 'S' || patch[3] != '1') {
				throw new Exception("Not a valid BPS patch file.");
			}

			int pos = 4;
			long sourceSize = DecodeNumber(patch, ref pos);
			long targetSize = DecodeNumber(patch, ref pos);
			long metaSize = DecodeNumber(patch, ref pos);
			pos += (int)metaSize; //skip metadata

			//Match the clean ROM to the patch's expected source, stripping a 512-byte
			//copier header if that's what makes the sizes line up.
			byte[] src = source;
			int srcOffset = 0;
			if(source.Length != sourceSize) {
				if(source.Length == sourceSize + 512) {
					srcOffset = 512;
				} else {
					throw new Exception($"Clean ROM size doesn't match this patch (expected {sourceSize} bytes, got {source.Length}).");
				}
			}

			uint expectedSourceCrc = ReadU32Le(patch, patch.Length - 12);
			uint expectedTargetCrc = ReadU32Le(patch, patch.Length - 8);
			if(Crc32(src, srcOffset, (int)sourceSize) != expectedSourceCrc) {
				throw new Exception("Clean ROM doesn't match this challenge (wrong version/region, or the ROM is bad/headered).");
			}

			byte[] target = new byte[targetSize];
			int outputOffset = 0;
			int sourceRelativeOffset = 0;
			int targetRelativeOffset = 0;
			int end = patch.Length - 12; //stop before the 3 CRC32 footers

			while(pos < end) {
				long data = DecodeNumber(patch, ref pos);
				long command = data & 3;
				long length = (data >> 2) + 1;

				switch(command) {
					case 0: //SourceRead
						for(long i = 0; i < length; i++) {
							target[outputOffset] = src[srcOffset + outputOffset];
							outputOffset++;
						}
						break;

					case 1: //TargetRead
						for(long i = 0; i < length; i++) {
							target[outputOffset++] = patch[pos++];
						}
						break;

					case 2: { //SourceCopy
						long d = DecodeNumber(patch, ref pos);
						sourceRelativeOffset += (int)(((d & 1) != 0 ? -1 : 1) * (d >> 1));
						for(long i = 0; i < length; i++) {
							target[outputOffset++] = src[srcOffset + sourceRelativeOffset++];
						}
						break;
					}

					case 3: { //TargetCopy
						long d = DecodeNumber(patch, ref pos);
						targetRelativeOffset += (int)(((d & 1) != 0 ? -1 : 1) * (d >> 1));
						for(long i = 0; i < length; i++) {
							target[outputOffset++] = target[targetRelativeOffset++];
						}
						break;
					}
				}
			}

			if(Crc32(target, 0, target.Length) != expectedTargetCrc) {
				throw new Exception("Patched ROM checksum mismatch (corrupt patch?).");
			}

			return target;
		}
	}
}
