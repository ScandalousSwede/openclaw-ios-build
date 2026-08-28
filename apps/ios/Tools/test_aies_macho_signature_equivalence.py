#!/usr/bin/env python3

from __future__ import annotations

import pathlib
import struct
import tempfile
import unittest

import aies_macho_signature_equivalence as macho


ARM64_UUID = bytes.fromhex("3a220704db683766b184a671ba773657")
ARM64_32_UUID = bytes.fromhex("33b192aba62f366e9f0f226ff0d522a6")


def superblob(allocation: int, payload: bytes) -> bytes:
    child = struct.pack(">II", 0xFADE0C02, 8 + len(payload)) + payload
    declared = 20 + len(child)
    if declared > allocation:
        raise ValueError("signature allocation is too small")
    value = (
        struct.pack(">III", macho.CSMAGIC_EMBEDDED_SIGNATURE, declared, 1)
        + struct.pack(">II", 0, 20)
        + child
    )
    return value + bytes(allocation - len(value))


def thin_macho(
    cpu_type: int,
    cpu_subtype: int,
    uuid: bytes,
    signature_allocation: int,
    signature_payload: bytes,
) -> bytes:
    is_64 = cpu_type == macho.CPU_TYPE_ARM64
    header_size = 32 if is_64 else 28
    text_command_size = (72 + 80) if is_64 else (56 + 68)
    linkedit_command_size = 72 if is_64 else 56
    sizeofcmds = text_command_size + linkedit_command_size + 24 + 16
    header = struct.pack(
        "<IIIIIIII" if is_64 else "<IIIIIII",
        macho.MH_MAGIC_64 if is_64 else macho.MH_MAGIC,
        cpu_type,
        cpu_subtype,
        2,
        4,
        sizeofcmds,
        0x200085,
        *([0] if is_64 else []),
    )
    if is_64:
        text = struct.pack(
            "<II16sQQQQiiII",
            macho.LC_SEGMENT_64,
            text_command_size,
            b"__TEXT" + bytes(10),
            0,
            0x4000,
            0,
            0x4000,
            5,
            5,
            1,
            0,
        )
        section = struct.pack(
            "<16s16sQQIIIIIIII",
            b"__text" + bytes(10),
            b"__TEXT" + bytes(10),
            0x1000,
            0x100,
            0x1000,
            2,
            0,
            0,
            0x80000400,
            0,
            0,
            0,
        )
        linkedit_filesize = 0x1000 + signature_allocation
        linkedit = struct.pack(
            "<II16sQQQQiiII",
            macho.LC_SEGMENT_64,
            linkedit_command_size,
            b"__LINKEDIT" + bytes(6),
            0x4000,
            ((linkedit_filesize + 0x3FFF) // 0x4000) * 0x4000,
            0x4000,
            linkedit_filesize,
            1,
            1,
            0,
            0,
        )
    else:
        text = struct.pack(
            "<II16sIIIIiiII",
            macho.LC_SEGMENT,
            text_command_size,
            b"__TEXT" + bytes(10),
            0,
            0x4000,
            0,
            0x4000,
            5,
            5,
            1,
            0,
        )
        section = struct.pack(
            "<16s16sIIIIIIIII",
            b"__text" + bytes(10),
            b"__TEXT" + bytes(10),
            0x1000,
            0x100,
            0x1000,
            2,
            0,
            0,
            0x80000400,
            0,
            0,
        )
        linkedit_filesize = 0x1000 + signature_allocation
        linkedit = struct.pack(
            "<II16sIIIIiiII",
            macho.LC_SEGMENT,
            linkedit_command_size,
            b"__LINKEDIT" + bytes(6),
            0x4000,
            ((linkedit_filesize + 0x3FFF) // 0x4000) * 0x4000,
            0x4000,
            linkedit_filesize,
            1,
            1,
            0,
            0,
        )
    commands = (
        text
        + section
        + linkedit
        + struct.pack("<II16s", macho.LC_UUID, 24, uuid)
        + struct.pack("<IIII", macho.LC_CODE_SIGNATURE, 16, 0x5000, signature_allocation)
    )
    prefix = bytearray(0x5000)
    prefix[: len(header + commands)] = header + commands
    for index in range(0x1000, 0x1100):
        prefix[index] = (index * 17 + cpu_subtype) & 0xFF
    for index in range(0x4000, 0x5000):
        prefix[index] = (index * 29 + cpu_subtype) & 0xFF
    return bytes(prefix) + superblob(signature_allocation, signature_payload)


def fat_macho(signature_allocation: int, signature_payload: bytes) -> bytes:
    slices = [
        (
            macho.CPU_TYPE_ARM64_32,
            1,
            thin_macho(
                macho.CPU_TYPE_ARM64_32,
                1,
                ARM64_32_UUID,
                signature_allocation,
                signature_payload + b"-watch",
            ),
        ),
        (
            macho.CPU_TYPE_ARM64,
            0,
            thin_macho(
                macho.CPU_TYPE_ARM64,
                0,
                ARM64_UUID,
                signature_allocation,
                signature_payload + b"-phone",
            ),
        ),
    ]
    header_size = 8 + len(slices) * 20
    entries: list[tuple[int, int, int, int, int]] = []
    output = bytearray(struct.pack(">II", macho.FAT_MAGIC, len(slices)) + bytes(len(slices) * 20))
    cursor = header_size
    for cpu_type, cpu_subtype, value in slices:
        offset = (cursor + 0x3FFF) & ~0x3FFF
        output.extend(bytes(offset - len(output)))
        output.extend(value)
        entries.append((cpu_type, cpu_subtype, offset, len(value), 14))
        cursor = offset + len(value)
    for index, entry in enumerate(entries):
        struct.pack_into(">IIIII", output, 8 + index * 20, *entry)
    return bytes(output)


class MachOSignatureEquivalenceTests(unittest.TestCase):
    def compare(self, archive: bytes, ipa: bytes) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            archive_path = root / "archive-executable"
            ipa_path = root / "ipa-executable"
            archive_path.write_bytes(archive)
            ipa_path.write_bytes(ipa)
            return macho.compare_macho_payloads(archive_path, ipa_path)

    def assert_rejected(self, archive: bytes, ipa: bytes, code: str) -> None:
        with self.assertRaisesRegex(macho.MachOEquivalenceError, f"^{code}:"):
            self.compare(archive, ipa)

    def test_signature_only_fat_changes_pass_and_shift_second_slice(self) -> None:
        report = self.compare(fat_macho(0x4000, b"archive"), fat_macho(0x2000, b"ipa"))
        self.assertEqual(report["status"], "signature_aware_payload_equivalent")
        self.assertEqual(report["architecture_count"], 2)
        architectures = report["architectures"]
        self.assertNotEqual(architectures[1]["archive"]["fat_offset"], architectures[1]["ipa"]["fat_offset"])
        self.assertTrue(all(len(item["normalized_fields"]) == 3 for item in architectures))

    def test_signature_only_thin_changes_pass(self) -> None:
        archive = thin_macho(macho.CPU_TYPE_ARM64, 0, ARM64_UUID, 0x4000, b"archive")
        ipa = thin_macho(macho.CPU_TYPE_ARM64, 0, ARM64_UUID, 0x2000, b"ipa")
        self.assertEqual(
            self.compare(archive, ipa)["container_format"], "thin"
        )

    def test_instruction_and_constant_mutations_fail(self) -> None:
        archive = fat_macho(0x4000, b"archive")
        for inner_offset in (0x1000, 0x4000):
            ipa = bytearray(fat_macho(0x2000, b"ipa"))
            first_slice = struct.unpack_from(">I", ipa, 16)[0]
            ipa[first_slice + inner_offset] ^= 1
            self.assert_rejected(archive, bytes(ipa), "UNRECOGNIZED_NON_SIGNATURE_DIFFERENCE")

    def test_changed_uuid_fails(self) -> None:
        archive = fat_macho(0x4000, b"archive")
        ipa = bytearray(fat_macho(0x2000, b"ipa"))
        first_slice = struct.unpack_from(">I", ipa, 16)[0]
        uuid_offset = first_slice + 28 + 124 + 56 + 8
        ipa[uuid_offset] ^= 1
        self.assert_rejected(archive, bytes(ipa), "UUID_MISMATCH")

    def test_changed_non_signature_load_command_and_section_size_fail(self) -> None:
        archive = fat_macho(0x4000, b"archive")
        for relative_offset in (24, 28 + 56 + 36):
            ipa = bytearray(fat_macho(0x2000, b"ipa"))
            first_slice = struct.unpack_from(">I", ipa, 16)[0]
            ipa[first_slice + relative_offset] ^= 1
            self.assert_rejected(archive, bytes(ipa), "UNRECOGNIZED_NON_SIGNATURE_DIFFERENCE")

    def test_changed_architecture_or_alignment_fails(self) -> None:
        archive = fat_macho(0x4000, b"archive")
        ipa = bytearray(fat_macho(0x2000, b"ipa"))
        struct.pack_into(">I", ipa, 8, macho.CPU_TYPE_ARM64)
        self.assert_rejected(archive, bytes(ipa), "FAT_THIN_CPU_MISMATCH")
        ipa = bytearray(fat_macho(0x2000, b"ipa"))
        struct.pack_into(">I", ipa, 24, 13)
        self.assert_rejected(archive, bytes(ipa), "NONCANONICAL_FAT_OFFSET")

    def test_extra_slice_and_malformed_container_fail(self) -> None:
        archive = fat_macho(0x4000, b"archive")
        ipa = bytearray(fat_macho(0x2000, b"ipa"))
        struct.pack_into(">I", ipa, 4, 3)
        self.assert_rejected(archive, bytes(ipa), "NONCANONICAL_FAT_OFFSET")
        self.assert_rejected(archive, b"not-macho", "UNSUPPORTED_MACHO_MAGIC")

    def test_signature_offset_and_nonderived_linkedit_changes_fail(self) -> None:
        archive = fat_macho(0x4000, b"archive")
        ipa = bytearray(fat_macho(0x2000, b"ipa"))
        first_slice = struct.unpack_from(">I", ipa, 16)[0]
        # arm64_32: header 28, text command 124, linkedit command 56,
        # UUID command 24, then LC_CODE_SIGNATURE.dataoff at +8.
        dataoff_field = first_slice + 28 + 124 + 56 + 24 + 8
        struct.pack_into("<I", ipa, dataoff_field, 0x4FF0)
        self.assert_rejected(archive, bytes(ipa), "NONSIGNATURE_LINKEDIT_SIZE")

        ipa = bytearray(fat_macho(0x2000, b"ipa"))
        first_slice = struct.unpack_from(">I", ipa, 16)[0]
        linkedit_filesize = first_slice + 28 + 124 + 36
        struct.pack_into("<I", ipa, linkedit_filesize, 0x3001)
        self.assert_rejected(archive, bytes(ipa), "INVALID_LINKEDIT_RANGE")

    def test_malformed_superblob_fails(self) -> None:
        archive = fat_macho(0x4000, b"archive")
        for mutation_offset in (0, 24):
            ipa = bytearray(fat_macho(0x2000, b"ipa"))
            first_slice = struct.unpack_from(">I", ipa, 16)[0]
            ipa[first_slice + 0x5000 + mutation_offset] ^= 1
            self.assert_rejected(archive, bytes(ipa), "MALFORMED_CODE_SIGNATURE")

    def test_opaque_bytes_inside_terminal_signature_allocation_are_recorded(self) -> None:
        archive = fat_macho(0x4000, b"archive")
        ipa = bytearray(fat_macho(0x2000, b"ipa"))
        first_slice = struct.unpack_from(">I", ipa, 16)[0]
        ipa[first_slice + 0x5000 + 0x100] = 0xA5
        report = self.compare(archive, bytes(ipa))
        self.assertGreater(
            report["architectures"][0]["ipa"]["signature_padding_nonzero_count"],
            0,
        )

    def test_fat_padding_and_trailing_bytes_fail(self) -> None:
        archive = fat_macho(0x4000, b"archive")
        ipa = bytearray(fat_macho(0x2000, b"ipa"))
        ipa[100] = 1
        self.assert_rejected(archive, bytes(ipa), "NONZERO_FAT_PADDING")
        self.assert_rejected(archive, fat_macho(0x2000, b"ipa") + b"x", "TRAILING_FAT_BYTES")

    def test_unknown_architecture_fails_closed(self) -> None:
        value = bytearray(
            thin_macho(macho.CPU_TYPE_ARM64, 0, ARM64_UUID, 0x2000, b"ipa")
        )
        struct.pack_into("<I", value, 4, 7)
        self.assert_rejected(bytes(value), bytes(value), "UNSUPPORTED_ARCHITECTURE")


if __name__ == "__main__":
    unittest.main()
