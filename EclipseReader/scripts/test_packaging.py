"""Synthetic unit fixtures for packaging validation. Never produce an installable app."""
import struct
import unittest
from verify_ipa import verify_binary

def fixture(platform=2, cpu=0x0100000C):
    header = struct.pack('<8I', 0xFEEDFACF, cpu, 0, 2, 1, 24, 0, 0)
    return header + struct.pack('<6I', 0x32, 24, platform, 0x110000, 0x120000, 0)

class BinaryValidationTests(unittest.TestCase):
    def test_accepts_arm64_ios_metadata(self):
        verify_binary(fixture())
    def test_rejects_simulator(self):
        with self.assertRaises(ValueError): verify_binary(fixture(platform=7))
    def test_rejects_macos(self):
        with self.assertRaises(ValueError): verify_binary(fixture(platform=1))
    def test_rejects_wrong_architecture(self):
        with self.assertRaises(ValueError): verify_binary(fixture(cpu=0x01000007))
    def test_rejects_source_text(self):
        with self.assertRaises(ValueError): verify_binary(b'import SwiftUI\n' * 10)
    def test_rejects_truncated_executable(self):
        with self.assertRaises(ValueError): verify_binary(fixture()[:-1])
    def test_rejects_invalid_command_length(self):
        data = bytearray(fixture()); struct.pack_into('<I', data, 36, 4)
        with self.assertRaises(ValueError): verify_binary(bytes(data))

if __name__ == '__main__':
    unittest.main()
