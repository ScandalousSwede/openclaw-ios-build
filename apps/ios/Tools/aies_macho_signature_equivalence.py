#!/usr/bin/env python3
"""Fail-closed Mach-O payload equivalence across Apple re-signing.

The verifier compares each architecture independently. It ignores only the
terminal code-signature blob and three fields whose values are arithmetically
derived from that blob's allocation size. Every other byte remains covered by
the canonical comparison.
"""

from __future__ import annotations

import hashlib
import pathlib
import struct
from dataclasses import dataclass
from typing import Any


FAT_MAGIC = 0xCAFEBABE
MH_MAGIC = 0xFEEDFACE
MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT = 0x1
LC_UUID = 0x1B
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0

CPU_TYPE_ARM64 = 0x0100000C
CPU_TYPE_ARM64_32 = 0x0200000C
SUPPORTED_PAGE_SIZES = {
    CPU_TYPE_ARM64: 0x4000,
    CPU_TYPE_ARM64_32: 0x4000,
}


class MachOEquivalenceError(ValueError):
    """An executable contains an unsupported or non-signature difference."""


def _fail(code: str, detail: str) -> None:
    raise MachOEquivalenceError(f"{code}: {detail}")


def _sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) & ~(alignment - 1)


def _architecture_name(cpu_type: int, cpu_subtype: int) -> str:
    if cpu_type == CPU_TYPE_ARM64:
        return "arm64"
    if cpu_type == CPU_TYPE_ARM64_32:
        return "arm64_32"
    return f"cpu-{cpu_type:#010x}-subtype-{cpu_subtype:#010x}"


@dataclass(frozen=True)
class ContainerSlice:
    index: int
    cpu_type: int
    cpu_subtype: int
    offset: int
    size: int
    align_exponent: int
    value: bytes


@dataclass(frozen=True)
class ThinMachO:
    cpu_type: int
    cpu_subtype: int
    is_64: bool
    uuid: str
    dataoff: int
    datasize: int
    signature_declared_size: int
    signature_padding_size: int
    signature_padding_nonzero_count: int
    signature_padding_sha256: str
    signature_allocation_sha256: str
    signature_superblob_sha256: str
    linkedit_fileoff: int
    linkedit_vmaddr: int
    linkedit_filesize: int
    linkedit_vmsize: int
    signature_datasize_offset: int
    linkedit_filesize_offset: int
    linkedit_vmsize_offset: int
    canonical: bytes


def _read_u32(value: bytes, offset: int, endian: str, label: str) -> int:
    if offset < 0 or offset + 4 > len(value):
        _fail("TRUNCATED_MACHO", label)
    return struct.unpack_from(f"{endian}I", value, offset)[0]


def _read_u64(value: bytes, offset: int, endian: str, label: str) -> int:
    if offset < 0 or offset + 8 > len(value):
        _fail("TRUNCATED_MACHO", label)
    return struct.unpack_from(f"{endian}Q", value, offset)[0]


def _parse_code_signature(
    value: bytes, dataoff: int, datasize: int
) -> tuple[int, int, int, str, str, str]:
    if dataoff % 16 != 0:
        _fail("INVALID_CODE_SIGNATURE_RANGE", "dataoff is not 16-byte aligned")
    if datasize <= 0 or dataoff + datasize != len(value):
        _fail("NONTERMINAL_CODE_SIGNATURE", "signature must occupy the terminal range")
    signature = value[dataoff:]
    if len(signature) < 12:
        _fail("MALFORMED_CODE_SIGNATURE", "SuperBlob header is truncated")
    magic, declared_size, count = struct.unpack_from(">III", signature, 0)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        _fail("MALFORMED_CODE_SIGNATURE", f"unexpected SuperBlob magic {magic:#x}")
    index_end = 12 + count * 8
    if declared_size < index_end or declared_size > datasize:
        _fail("MALFORMED_CODE_SIGNATURE", "SuperBlob declared size is out of bounds")
    offsets: set[int] = set()
    member_ranges: list[tuple[int, int]] = []
    for index in range(count):
        _slot_type, blob_offset = struct.unpack_from(">II", signature, 12 + index * 8)
        if blob_offset in offsets:
            _fail("MALFORMED_CODE_SIGNATURE", "duplicate SuperBlob member offset")
        offsets.add(blob_offset)
        if blob_offset < index_end or blob_offset + 8 > declared_size:
            _fail("MALFORMED_CODE_SIGNATURE", "SuperBlob member header is out of bounds")
        _blob_magic, blob_size = struct.unpack_from(">II", signature, blob_offset)
        if blob_size < 8 or blob_offset + blob_size > declared_size:
            _fail("MALFORMED_CODE_SIGNATURE", "SuperBlob member is out of bounds")
        member_ranges.append((blob_offset, blob_offset + blob_size))
    member_ranges.sort()
    if any(
        current[0] < previous[1]
        for previous, current in zip(member_ranges, member_ranges[1:])
    ):
        _fail("MALFORMED_CODE_SIGNATURE", "SuperBlob members overlap")
    allocation_tail = signature[declared_size:]
    # LC_CODE_SIGNATURE owns the complete terminal allocation. Xcode's embedded
    # WatchKit SDK launcher contains a valid SuperBlob followed by a short opaque
    # nonzero tail, so the tail is evidence, not unsigned executable payload.
    return (
        declared_size,
        len(allocation_tail),
        sum(byte != 0 for byte in allocation_tail),
        _sha256(allocation_tail),
        _sha256(signature),
        _sha256(signature[:declared_size]),
    )


def _parse_thin(value: bytes, expected_cpu: tuple[int, int] | None = None) -> ThinMachO:
    if len(value) < 4:
        _fail("TRUNCATED_MACHO", "missing thin header")
    magic = struct.unpack_from("<I", value, 0)[0]
    if magic == MH_MAGIC:
        is_64 = False
        header_size = 28
    elif magic == MH_MAGIC_64:
        is_64 = True
        header_size = 32
    else:
        _fail("UNSUPPORTED_MACHO_MAGIC", f"thin magic {value[:4].hex()}")
    if len(value) < header_size:
        _fail("TRUNCATED_MACHO", "incomplete thin header")
    cpu_type = _read_u32(value, 4, "<", "cpu type")
    cpu_subtype = _read_u32(value, 8, "<", "cpu subtype")
    if expected_cpu is not None and (cpu_type, cpu_subtype) != expected_cpu:
        _fail("FAT_THIN_CPU_MISMATCH", f"descriptor={expected_cpu!r} thin={(cpu_type, cpu_subtype)!r}")
    if cpu_type not in SUPPORTED_PAGE_SIZES:
        _fail("UNSUPPORTED_ARCHITECTURE", _architecture_name(cpu_type, cpu_subtype))
    if _read_u32(value, 12, "<", "filetype") != 2:
        _fail("UNSUPPORTED_MACHO_FILETYPE", "release executable is not MH_EXECUTE")
    ncmds = _read_u32(value, 16, "<", "ncmds")
    sizeofcmds = _read_u32(value, 20, "<", "sizeofcmds")
    commands_end = header_size + sizeofcmds
    if commands_end > len(value):
        _fail("TRUNCATED_LOAD_COMMANDS", "load command region exceeds slice")

    cursor = header_size
    uuid: str | None = None
    signature: tuple[int, int, int] | None = None
    linkedit: tuple[int, int, int, int, int, int] | None = None
    for command_index in range(ncmds):
        if cursor + 8 > commands_end:
            _fail("TRUNCATED_LOAD_COMMANDS", f"command {command_index}")
        cmd, cmdsize = struct.unpack_from("<II", value, cursor)
        command_alignment = 8 if is_64 else 4
        if (
            cmdsize < 8
            or cmdsize % command_alignment != 0
            or cursor + cmdsize > commands_end
        ):
            _fail("MALFORMED_LOAD_COMMAND", f"command {command_index}")
        if cmd == LC_UUID:
            if uuid is not None or cmdsize != 24:
                _fail("INVALID_UUID_COMMAND", "expected exactly one 24-byte LC_UUID")
            raw_uuid = value[cursor + 8 : cursor + 24]
            hexadecimal = raw_uuid.hex()
            uuid = (
                f"{hexadecimal[0:8]}-{hexadecimal[8:12]}-{hexadecimal[12:16]}-"
                f"{hexadecimal[16:20]}-{hexadecimal[20:32]}"
            )
        elif cmd == LC_CODE_SIGNATURE:
            if signature is not None or cmdsize != 16:
                _fail("INVALID_CODE_SIGNATURE_COMMAND", "expected one 16-byte command")
            signature = (
                _read_u32(value, cursor + 8, "<", "signature dataoff"),
                _read_u32(value, cursor + 12, "<", "signature datasize"),
                cursor + 12,
            )
            if command_index != ncmds - 1:
                _fail(
                    "INVALID_CODE_SIGNATURE_COMMAND",
                    "LC_CODE_SIGNATURE is not the final load command",
                )
        elif (not is_64 and cmd == LC_SEGMENT) or (is_64 and cmd == LC_SEGMENT_64):
            minimum = 56 if not is_64 else 72
            if cmdsize < minimum:
                _fail("MALFORMED_SEGMENT_COMMAND", f"command {command_index}")
            segment_name = value[cursor + 8 : cursor + 24].split(b"\0", 1)[0]
            if segment_name == b"__LINKEDIT":
                if linkedit is not None:
                    _fail("AMBIGUOUS_LINKEDIT", "multiple __LINKEDIT segments")
                if is_64:
                    vmsize_offset, fileoff_offset, filesize_offset = 32, 40, 48
                    vmaddr = _read_u64(value, cursor + 24, "<", "__LINKEDIT vmaddr")
                    vmsize = _read_u64(value, cursor + vmsize_offset, "<", "__LINKEDIT vmsize")
                    fileoff = _read_u64(value, cursor + fileoff_offset, "<", "__LINKEDIT fileoff")
                    filesize = _read_u64(value, cursor + filesize_offset, "<", "__LINKEDIT filesize")
                    nsects = _read_u32(value, cursor + 64, "<", "__LINKEDIT nsects")
                else:
                    vmsize_offset, fileoff_offset, filesize_offset = 28, 32, 36
                    vmaddr = _read_u32(value, cursor + 24, "<", "__LINKEDIT vmaddr")
                    vmsize = _read_u32(value, cursor + vmsize_offset, "<", "__LINKEDIT vmsize")
                    fileoff = _read_u32(value, cursor + fileoff_offset, "<", "__LINKEDIT fileoff")
                    filesize = _read_u32(value, cursor + filesize_offset, "<", "__LINKEDIT filesize")
                    nsects = _read_u32(value, cursor + 48, "<", "__LINKEDIT nsects")
                if nsects != 0:
                    _fail("AMBIGUOUS_LINKEDIT", "__LINKEDIT unexpectedly contains sections")
                linkedit = (
                    vmaddr,
                    fileoff,
                    filesize,
                    vmsize,
                    cursor + filesize_offset,
                    cursor + vmsize_offset,
                )
        cursor += cmdsize
    if cursor != commands_end:
        _fail("LOAD_COMMAND_SIZE_MISMATCH", f"cursor={cursor} expected={commands_end}")
    if uuid is None:
        _fail("MISSING_UUID", "no LC_UUID")
    if signature is None:
        _fail("MISSING_CODE_SIGNATURE", "no LC_CODE_SIGNATURE")
    if linkedit is None:
        _fail("MISSING_LINKEDIT", "no __LINKEDIT segment")

    dataoff, datasize, datasize_offset = signature
    vmaddr, fileoff, filesize, vmsize, filesize_offset, vmsize_offset = linkedit
    page_size = SUPPORTED_PAGE_SIZES[cpu_type]
    if fileoff > dataoff or fileoff % page_size != 0 or vmaddr % page_size != 0:
        _fail("INVALID_LINKEDIT_RANGE", "fileoff is not a supported aligned prefix")
    if datasize % 16 != 0:
        _fail("INVALID_CODE_SIGNATURE_RANGE", "datasize is not 16-byte aligned")
    if fileoff + filesize != len(value):
        _fail("INVALID_LINKEDIT_RANGE", "__LINKEDIT does not terminate at slice end")
    if filesize != dataoff - fileoff + datasize:
        _fail("NONSIGNATURE_LINKEDIT_SIZE", "filesize is not payload plus signature")
    if vmsize != _align_up(filesize, page_size):
        _fail("NONSIGNATURE_LINKEDIT_VMSIZE", "vmsize is not page-rounded filesize")
    (
        declared_size,
        padding_size,
        padding_nonzero_count,
        padding_sha256,
        signature_allocation_sha256,
        signature_superblob_sha256,
    ) = _parse_code_signature(value, dataoff, datasize)

    canonical = bytearray(value[:dataoff])
    if is_64:
        struct.pack_into("<Q", canonical, filesize_offset, dataoff - fileoff)
        struct.pack_into("<Q", canonical, vmsize_offset, _align_up(dataoff - fileoff, page_size))
    else:
        struct.pack_into("<I", canonical, filesize_offset, dataoff - fileoff)
        struct.pack_into("<I", canonical, vmsize_offset, _align_up(dataoff - fileoff, page_size))
    struct.pack_into("<I", canonical, datasize_offset, 0)
    return ThinMachO(
        cpu_type=cpu_type,
        cpu_subtype=cpu_subtype,
        is_64=is_64,
        uuid=uuid,
        dataoff=dataoff,
        datasize=datasize,
        signature_declared_size=declared_size,
        signature_padding_size=padding_size,
        signature_padding_nonzero_count=padding_nonzero_count,
        signature_padding_sha256=padding_sha256,
        signature_allocation_sha256=signature_allocation_sha256,
        signature_superblob_sha256=signature_superblob_sha256,
        linkedit_fileoff=fileoff,
        linkedit_vmaddr=vmaddr,
        linkedit_filesize=filesize,
        linkedit_vmsize=vmsize,
        signature_datasize_offset=datasize_offset,
        linkedit_filesize_offset=filesize_offset,
        linkedit_vmsize_offset=vmsize_offset,
        canonical=bytes(canonical),
    )


def _parse_container(value: bytes) -> tuple[str, list[ContainerSlice]]:
    if len(value) < 4:
        _fail("TRUNCATED_MACHO", "missing container magic")
    big_magic = struct.unpack_from(">I", value, 0)[0]
    if big_magic != FAT_MAGIC:
        thin = _parse_thin(value)
        return (
            "thin",
            [ContainerSlice(0, thin.cpu_type, thin.cpu_subtype, 0, len(value), 0, value)],
        )
    if len(value) < 8:
        _fail("TRUNCATED_FAT_HEADER", "missing architecture count")
    count = struct.unpack_from(">I", value, 4)[0]
    if count == 0 or count > 16 or 8 + count * 20 > len(value):
        _fail("INVALID_FAT_ARCHITECTURES", f"count={count}")
    slices: list[ContainerSlice] = []
    previous_end = 8 + count * 20
    seen: set[tuple[int, int]] = set()
    for index in range(count):
        cpu_type, cpu_subtype, offset, size, align_exponent = struct.unpack_from(
            ">IIIII", value, 8 + index * 20
        )
        if align_exponent > 30:
            _fail("INVALID_FAT_ALIGNMENT", f"architecture {index}")
        key = (cpu_type, cpu_subtype)
        if key in seen:
            _fail("DUPLICATE_ARCHITECTURE", repr(key))
        seen.add(key)
        alignment = 1 << align_exponent
        expected_offset = _align_up(previous_end, alignment)
        if offset != expected_offset or offset % alignment != 0:
            _fail("NONCANONICAL_FAT_OFFSET", f"architecture {index}: {offset} != {expected_offset}")
        if size <= 0 or offset + size > len(value):
            _fail("INVALID_FAT_SLICE_RANGE", f"architecture {index}")
        if any(value[previous_end:offset]):
            _fail("NONZERO_FAT_PADDING", f"architecture {index}")
        slice_value = value[offset : offset + size]
        _parse_thin(slice_value, key)
        slices.append(
            ContainerSlice(index, cpu_type, cpu_subtype, offset, size, align_exponent, slice_value)
        )
        previous_end = offset + size
    if previous_end != len(value):
        _fail("TRAILING_FAT_BYTES", f"{len(value) - previous_end} bytes")
    return "fat32", slices


def _field_record(
    name: str,
    archive: int,
    ipa: int,
    canonical: int,
    archive_offset: int,
    ipa_offset: int,
    reason: str,
) -> dict[str, Any]:
    return {
        "field": name,
        "archive_value": archive,
        "ipa_value": ipa,
        "canonical_value": canonical,
        "archive_slice_offset": archive_offset,
        "ipa_slice_offset": ipa_offset,
        "reason": reason,
    }


def compare_macho_payloads(archive_path: pathlib.Path, ipa_path: pathlib.Path) -> dict[str, Any]:
    """Return a deterministic report or raise on any non-signature difference."""

    archive_value = archive_path.read_bytes()
    ipa_value = ipa_path.read_bytes()
    archive_format, archive_slices = _parse_container(archive_value)
    ipa_format, ipa_slices = _parse_container(ipa_value)
    if archive_format != ipa_format:
        _fail("CONTAINER_FORMAT_MISMATCH", f"{archive_format} != {ipa_format}")
    archive_keys = [(item.cpu_type, item.cpu_subtype) for item in archive_slices]
    ipa_keys = [(item.cpu_type, item.cpu_subtype) for item in ipa_slices]
    if archive_keys != ipa_keys:
        _fail("ARCHITECTURE_SET_MISMATCH", f"{archive_keys!r} != {ipa_keys!r}")
    if [item.align_exponent for item in archive_slices] != [
        item.align_exponent for item in ipa_slices
    ]:
        _fail("ARCHITECTURE_ALIGNMENT_MISMATCH", "fat alignment exponents differ")

    reports: list[dict[str, Any]] = []
    canonical_hasher = hashlib.sha256()
    canonical_hasher.update(b"aies-macho-canonical-v1\0")
    canonical_container_cursor = 8 + len(archive_slices) * 20
    for archive_slice, ipa_slice in zip(archive_slices, ipa_slices):
        key = (archive_slice.cpu_type, archive_slice.cpu_subtype)
        before = _parse_thin(archive_slice.value, key)
        after = _parse_thin(ipa_slice.value, key)
        if before.uuid != after.uuid:
            _fail("UUID_MISMATCH", f"{before.uuid} != {after.uuid}")
        if before.dataoff != after.dataoff:
            _fail("CODE_SIGNATURE_OFFSET_MISMATCH", f"{before.dataoff} != {after.dataoff}")
        if before.linkedit_fileoff != after.linkedit_fileoff:
            _fail("LINKEDIT_OFFSET_MISMATCH", "__LINKEDIT fileoff differs")
        if before.canonical != after.canonical:
            mismatch = next(
                (index for index, pair in enumerate(zip(before.canonical, after.canonical)) if pair[0] != pair[1]),
                min(len(before.canonical), len(after.canonical)),
            )
            _fail("UNRECOGNIZED_NON_SIGNATURE_DIFFERENCE", f"architecture={_architecture_name(*key)} offset={mismatch}")
        canonical_hasher.update(struct.pack(">IIQ", key[0], key[1], len(before.canonical)))
        canonical_hasher.update(before.canonical)
        canonical_container_offset = (
            0
            if archive_format == "thin"
            else _align_up(canonical_container_cursor, 1 << archive_slice.align_exponent)
        )
        if archive_format == "fat32":
            canonical_container_cursor = canonical_container_offset + len(before.canonical)
        unsigned_linkedit = before.dataoff - before.linkedit_fileoff
        canonical_vmsize = _align_up(unsigned_linkedit, SUPPORTED_PAGE_SIZES[before.cpu_type])
        normalized = [
            _field_record(
                "LC_CODE_SIGNATURE.datasize",
                before.datasize,
                after.datasize,
                0,
                before.signature_datasize_offset,
                after.signature_datasize_offset,
                "terminal code-signature allocation removed from semantic payload",
            ),
            _field_record(
                "__LINKEDIT.filesize",
                before.linkedit_filesize,
                after.linkedit_filesize,
                unsigned_linkedit,
                before.linkedit_filesize_offset,
                after.linkedit_filesize_offset,
                "filesize equals unsigned linkedit prefix plus signature allocation",
            ),
            _field_record(
                "__LINKEDIT.vmsize",
                before.linkedit_vmsize,
                after.linkedit_vmsize,
                canonical_vmsize,
                before.linkedit_vmsize_offset,
                after.linkedit_vmsize_offset,
                "vmsize is the supported 16-KiB page rounding of filesize",
            ),
        ]
        reports.append(
            {
                "architecture": _architecture_name(*key),
                "cpu_type": key[0],
                "cpu_subtype": key[1],
                "uuid": before.uuid,
                "archive": {
                    "fat_offset": archive_slice.offset,
                    "signed_slice_size": archive_slice.size,
                    "signature_offset": before.dataoff,
                    "signature_allocation_size": before.datasize,
                    "signature_declared_size": before.signature_declared_size,
                    "signature_padding_size": before.signature_padding_size,
                    "signature_padding_nonzero_count": before.signature_padding_nonzero_count,
                    "signature_padding_sha256": before.signature_padding_sha256,
                    "signature_allocation_sha256": before.signature_allocation_sha256,
                    "signature_superblob_sha256": before.signature_superblob_sha256,
                    "raw_sha256": _sha256(archive_slice.value),
                },
                "ipa": {
                    "fat_offset": ipa_slice.offset,
                    "signed_slice_size": ipa_slice.size,
                    "signature_offset": after.dataoff,
                    "signature_allocation_size": after.datasize,
                    "signature_declared_size": after.signature_declared_size,
                    "signature_padding_size": after.signature_padding_size,
                    "signature_padding_nonzero_count": after.signature_padding_nonzero_count,
                    "signature_padding_sha256": after.signature_padding_sha256,
                    "signature_allocation_sha256": after.signature_allocation_sha256,
                    "signature_superblob_sha256": after.signature_superblob_sha256,
                    "raw_sha256": _sha256(ipa_slice.value),
                },
                "canonical_payload_sha256": _sha256(before.canonical),
                "canonical_payload_size": len(before.canonical),
                "normalized_fields": normalized,
                "container_normalized_fields": (
                    []
                    if archive_format == "thin"
                    else [
                        _field_record(
                            "fat_arch.offset",
                            archive_slice.offset,
                            ipa_slice.offset,
                            canonical_container_offset,
                            8 + archive_slice.index * 20 + 8,
                            8 + ipa_slice.index * 20 + 8,
                            "minimal alignment recurrence over canonical per-slice payload sizes",
                        ),
                        _field_record(
                            "fat_arch.size",
                            archive_slice.size,
                            ipa_slice.size,
                            len(before.canonical),
                            8 + archive_slice.index * 20 + 12,
                            8 + ipa_slice.index * 20 + 12,
                            "signed slice size equals canonical payload plus terminal signature allocation",
                        ),
                    ]
                ),
                "all_other_bytes_equal": True,
            }
        )
    return {
        "schema": "aies.macho-signature-equivalence.v1",
        "status": "signature_aware_payload_equivalent",
        "container_format": archive_format,
        "archive_raw_sha256": _sha256(archive_value),
        "ipa_raw_sha256": _sha256(ipa_value),
        "architecture_count": len(reports),
        "architecture_set": [item["architecture"] for item in reports],
        "canonical_payload_sha256": canonical_hasher.hexdigest(),
        "normalized_field_allowlist": [
            "LC_CODE_SIGNATURE.datasize",
            "__LINKEDIT.filesize",
            "__LINKEDIT.vmsize",
            "fat_arch.offset (derived container layout; slices compared independently)",
            "terminal code-signature blob bytes",
        ],
        "architectures": reports,
    }
