#!/usr/bin/env python3
"""
Generate Apple .lproj/Upstream.strings files from upstream 7-Zip language files.

Usage:
    python3 project/scripts/generate_strings.py

Reads:  project/localization/Lang/*.txt, project/localization/Lang/en.ttt
Writes: ShichiZip/Resources/Localization/<locale>.lproj/Upstream.strings

App.strings is intentionally managed manually and is not generated here.
"""

import os
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Upstream lang file parser
# ---------------------------------------------------------------------------

def parse_lang_file(filepath: str) -> dict[int, str]:
    """Parse a 7-Zip .txt/.ttt language file into {string_id: text}."""
    strings: dict[int, str] = {}

    with open(filepath, 'r', encoding='utf-8-sig') as f:
        lines = f.readlines()

    current_section: int | None = None
    offset = 0

    for line in lines:
        line = line.rstrip('\n').rstrip('\r')

        if line.startswith(';'):
            continue

        stripped = line.strip()
        if stripped.isdigit() and len(stripped) <= 5:
            current_section = int(stripped)
            offset = 0
            continue

        if current_section is not None:
            string_id = current_section + offset
            strings[string_id] = line
            offset += 1

    return strings


def strip_accelerator(text: str) -> str:
    """Remove Windows-style accelerator key markers from text.

    Handles both:
    - English style: &Archive → Archive
    - CJK style: 压缩包(&A) → 压缩包
    """
    # First remove CJK-style parenthesized accelerators: (&X)
    text = re.sub(r'\(&[A-Za-z]\)', '', text)
    # Then remove remaining & markers
    text = text.replace('&', '')
    return text


# ---------------------------------------------------------------------------
# Upstream ID → app string key mapping
# ---------------------------------------------------------------------------

# Each entry: upstream_id → "dotted.key"
# This defines which upstream strings we reuse and their stable app key names.
UPSTREAM_KEY_MAP: dict[int, str] = {
    # --- Common buttons (section 401) ---
    401: "common.ok",
    402: "common.cancel",
    406: "common.yes",
    407: "common.no",
    408: "common.close",
    409: "common.help",
    411: "common.continue",

    # --- Common confirmations (section 440) ---
    440: "common.yesToAll",
    441: "common.noToAll",
    442: "common.stop",
    443: "common.restart",
    444: "common.background",
    445: "common.foreground",
    446: "common.pause",
    447: "common.paused",
    448: "common.confirmCancel",

    # --- Menu bar (section 500) ---
    500: "menu.file",
    501: "menu.edit",
    502: "menu.view",
    503: "menu.favorites",
    504: "menu.tools",
    505: "menu.help",

    # --- File menu items (section 540) ---
    540: "menu.open",
    541: "menu.openInside",
    542: "menu.openOutside",
    543: "menu.itemView",
    544: "menu.itemEdit",
    545: "menu.rename",
    546: "menu.copyTo",
    547: "menu.moveTo",
    548: "menu.delete",
    549: "menu.splitFile",
    550: "menu.combineFiles",
    551: "menu.properties",
    552: "menu.comment",
    553: "menu.calculateChecksum",
    554: "menu.diff",
    555: "menu.createFolder",
    556: "menu.createFile",
    557: "menu.exit",
    558: "menu.link",
    559: "menu.alternateStreams",

    # --- Edit menu (section 600) ---
    600: "edit.selectAll",
    601: "edit.deselectAll",
    602: "edit.invertSelection",
    603: "edit.select",
    604: "edit.deselect",
    605: "edit.selectByType",
    606: "edit.deselectByType",

    # --- View modes (section 700) ---
    700: "view.largeIcons",
    701: "view.smallIcons",
    702: "view.list",
    703: "view.details",

    # --- View options (section 730) ---
    730: "view.unsorted",
    731: "view.flatView",
    732: "view.twoPanels",
    733: "view.toolbars",
    734: "view.openRootFolder",
    735: "view.upOneLevel",
    736: "view.foldersHistory",
    737: "view.refresh",
    738: "view.autoRefresh",

    # --- Toolbar labels (section 750) ---
    750: "view.archiveToolbar",
    751: "view.standardToolbar",
    752: "view.largeButtons",
    753: "view.showButtonsText",

    # --- Favorites (section 800) ---
    800: "favorites.addFolder",
    801: "favorites.bookmark",

    # --- Tools menu (section 900) ---
    900: "tools.options",
    901: "tools.benchmark",
    910: "tools.deleteTempFiles",

    # --- About (section 960) ---
    960: "about.contents",
    961: "about.about7Zip",

    # --- Column headers (section 1003) ---
    1003: "column.path",
    1004: "column.name",
    1005: "column.extension",
    1006: "column.folder",
    1007: "column.size",
    1008: "column.packedSize",
    1009: "column.attributes",
    1010: "column.created",
    1011: "column.accessed",
    1012: "column.modified",
    1013: "column.solid",
    1014: "column.commented",
    1015: "column.encrypted",
    1016: "column.splitBefore",
    1017: "column.splitAfter",
    1018: "column.dictionary",
    1020: "column.type",
    1021: "column.anti",
    1022: "column.method",
    1023: "column.hostOS",
    1024: "column.fileSystem",
    1025: "column.user",
    1026: "column.group",
    1027: "column.block",
    1028: "column.comment",
    1029: "column.position",
    1030: "column.pathPrefix",
    1031: "column.folders",
    1032: "column.files",
    1033: "column.version",
    1034: "column.volume",
    1035: "column.multivolume",
    1036: "column.offset",
    1037: "column.links",
    1038: "column.blocks",
    1039: "column.volumes",

    # --- Settings (section 2100) ---
    2100: "settings.options",
    2101: "settings.language",
    2102: "settings.languageLabel",

    # --- Folders settings (section 2400) ---
    2400: "settings.folders",
    2401: "settings.workingFolder",
    2402: "settings.systemTempFolder",
    2403: "settings.current",
    2404: "settings.specified",
    2405: "settings.removableDrivesOnly",
    2406: "settings.specifyTempLocation",

    # --- General settings (section 2500) ---
    2500: "settings.title",
    2501: "settings.showDotDot",
    2502: "settings.showRealIcons",
    2503: "settings.showSystemMenu",
    2504: "settings.fullRowSelect",
    2505: "settings.showGridLines",
    2506: "settings.singleClick",
    2507: "settings.altSelectionMode",
    2508: "settings.largeMemoryPages",

    # --- Progress operations (section 3300) ---
    3300: "progress.extracting",
    3301: "progress.compressing",
    3302: "progress.testing",
    3303: "progress.opening",
    3304: "progress.scanning",
    3305: "progress.removing",

    3320: "progress.adding",
    3321: "progress.updating",
    3322: "progress.analyzing",
    3323: "progress.replicating",
    3324: "progress.repacking",
    3325: "progress.skipping",
    3326: "progress.deleting",
    3327: "progress.headerCreating",

    # --- Extract dialog (section 3400) ---
    3400: "extract.title",
    3401: "extract.extractTo",
    3402: "extract.specifyLocation",

    3410: "extract.pathMode",
    3411: "extract.fullPathnames",
    3412: "extract.noPathnames",
    3413: "extract.absolutePathnames",
    3414: "extract.relativePathnames",

    3420: "extract.overwriteMode",
    3421: "extract.askBeforeOverwrite",
    3422: "extract.overwriteWithoutPrompt",
    3423: "extract.skipExisting",
    3424: "extract.autoRename",
    3425: "extract.autoRenameExisting",

    3430: "extract.eliminateDuplication",
    3431: "extract.restoreSecurity",

    # --- Quarantine propagation (section 3440) ---
    3440: "extract.propagateZoneId",
    3441: "extract.forOfficeFiles",

    # --- File replace confirmation (section 3500) ---
    3500: "replace.confirmTitle",
    3501: "replace.alreadyContains",
    3502: "replace.wouldYouLike",
    3503: "replace.withThisOne",
    3504: "replace.bytes",
    3505: "replace.autoRename",

    # --- Errors (section 3700) ---
    3700: "error.unsupportedMethod",
    3701: "error.dataError",
    3702: "error.crcFailed",
    3703: "error.dataErrorEncrypted",
    3704: "error.crcFailedEncrypted",
    3710: "error.wrongPassword",

    3721: "error.unsupportedMethodGeneric",
    3722: "error.dataErrorGeneric",
    3723: "error.crcFailedGeneric",
    3724: "error.unavailableData",
    3725: "error.unexpectedEnd",
    3726: "error.dataAfterPayload",
    3727: "error.isNotArchive",
    3728: "error.headersError",
    3729: "error.wrongPasswordGeneric",

    # --- Password dialog (section 3800) ---
    3800: "password.enterPassword",
    3801: "password.enterPasswordPrompt",
    3802: "password.reenterPassword",
    3803: "password.showPassword",
    3804: "password.passwordsMismatch",
    3806: "password.tooLong",
    3807: "password.password",

    # --- Progress info (section 3900) ---
    3900: "progress.elapsedTime",
    3901: "progress.remainingTime",
    3902: "progress.totalSize",
    3903: "progress.speed",
    3904: "progress.processed",
    3905: "progress.compressionRatio",
    3906: "progress.errors",
    3907: "progress.archives",

    # --- Add to archive / Compress dialog (section 4000) ---
    4000: "compress.title",
    4001: "compress.archive",
    4002: "compress.updateMode",
    4003: "compress.archiveFormat",
    4004: "compress.compressionLevel",
    4005: "compress.compressionMethod",
    4006: "compress.dictionarySize",
    4007: "compress.wordSize",
    4008: "compress.solidBlockSize",
    4009: "compress.cpuThreads",
    4010: "compress.parameters",
    4011: "compress.options",
    4012: "compress.createSFX",
    4013: "compress.compressShared",
    4014: "compress.encryption",
    4015: "compress.encryptionMethod",
    4016: "compress.encryptFileNames",
    4017: "compress.memoryCompressing",
    4018: "compress.memoryDecompressing",
    4019: "compress.deleteAfter",

    # --- Compress advanced options (section 4040) ---
    4040: "compress.storeSymbolicLinks",
    4041: "compress.storeHardLinks",
    4042: "compress.storeAlternateDataStreams",
    4043: "compress.storeFileSecurity",

    # --- Compression levels (section 4050) ---
    4050: "level.store",
    4051: "level.fastest",
    4052: "level.fast",
    4053: "level.normal",
    4054: "level.maximum",
    4055: "level.ultra",

    # --- Update modes (section 4060) ---
    4060: "update.addReplace",
    4061: "update.updateAdd",
    4062: "update.freshen",
    4063: "update.synchronize",

    # --- Browse / file filters (section 4070) ---
    4070: "compress.browse",
    4071: "compress.allFiles",
    4072: "compress.nonSolid",
    4073: "compress.solid",

    # --- Time options (section 4080) ---
    4080: "time.time",
    4081: "time.timestampPrecision",
    4082: "time.storeModificationTime",
    4083: "time.storeCreationTime",
    4084: "time.storeLastAccessTime",
    4085: "time.setArchiveTimeToLatest",
    4086: "time.doNotChangeAccessTime",

    # --- Copy/Move (section 6000) ---
    6000: "fileop.copy",
    6001: "fileop.move",
    6002: "fileop.copyTo",
    6003: "fileop.moveTo",
    6004: "fileop.copying",
    6005: "fileop.moving",
    6006: "fileop.renaming",
    6007: "fileop.selectDestination",
    6008: "fileop.notSupportedForFolder",
    6009: "fileop.errorRenaming",
    6010: "fileop.confirmCopy",
    6011: "fileop.confirmCopyToArchive",

    # --- Delete confirmations (section 6100) ---
    6100: "delete.confirmFile",
    6101: "delete.confirmFolder",
    6102: "delete.confirmMultiple",
    6103: "delete.askFile",
    6104: "delete.askFolder",
    6105: "delete.askMultiple",
    6106: "delete.deleting",
    6107: "delete.errorDeleting",

    # --- Create folder/file (section 6300) ---
    6300: "create.folder",
    6301: "create.file",
    6302: "create.folderName",
    6303: "create.fileName",
    6304: "create.newFolder",
    6305: "create.newFile",
    6306: "create.errorFolder",
    6307: "create.errorFile",

    # --- Properties / comments (section 6400) ---
    6400: "properties.comment",
    6401: "properties.commentLabel",
    6402: "properties.select",
    6403: "properties.deselect",
    6404: "properties.mask",

    # --- Properties / History (section 6600) ---
    6600: "properties.title",
    6601: "properties.foldersHistory",
    6602: "properties.diagnosticMessages",
    6603: "properties.message",

    # --- Toolbar buttons (section 7200) ---
    7200: "toolbar.add",
    7201: "toolbar.extract",
    7202: "toolbar.test",
    7203: "toolbar.copy",
    7204: "toolbar.move",
    7205: "toolbar.delete",
    7206: "toolbar.info",

    # --- Checksum (section 7500) ---
    7500: "checksum.calculating",
    7501: "checksum.information",
    7502: "checksum.crcData",
    7503: "checksum.crcDataNames",

    # --- Benchmark (section 7600) ---
    7600: "benchmark.title",
    7601: "benchmark.memoryUsage",
    7602: "benchmark.compressing",
    7603: "benchmark.decompressing",
    7604: "benchmark.rating",
    7605: "benchmark.totalRating",
    7606: "benchmark.current",
    7607: "benchmark.resulting",
    7608: "benchmark.cpuUsage",
    7609: "benchmark.ratingPerUsage",
    7610: "benchmark.passes",

    # --- Memory limit dialogs (section 7800) ---
    7800: "memory.usageRequest",
    7801: "memory.changeAllowedLimit",
    7802: "memory.repeatAction",
    7803: "memory.action",

    7810: "memory.blocked",
    7811: "memory.requiresBigRAM",
    7812: "memory.requiredSize",
    7813: "memory.allowedLimit",
    7814: "memory.limitSetBy7Zip",
    7815: "memory.ramSize",
    7816: "memory.maxAllowed",

    7820: "memory.allowUnpacking",
    7821: "memory.skipUnpacking",
    7822: "memory.skipped",
}


# ---------------------------------------------------------------------------
# Apple locale code mapping
# ---------------------------------------------------------------------------

LANG_FILE_TO_APPLE_LOCALE: dict[str, str] = {
    'af': 'af', 'an': 'an', 'ar': 'ar', 'ast': 'ast', 'az': 'az',
    'ba': 'ba', 'be': 'be', 'bg': 'bg', 'bn': 'bn', 'br': 'br',
    'ca': 'ca', 'co': 'co', 'cs': 'cs', 'cy': 'cy',
    'da': 'da', 'de': 'de',
    'el': 'el', 'en': 'en', 'eo': 'eo', 'es': 'es', 'et': 'et', 'eu': 'eu',
    'fa': 'fa', 'fi': 'fi', 'fr': 'fr', 'fy': 'fy',
    'ga': 'ga', 'gl': 'gl', 'gu': 'gu',
    'he': 'he', 'hi': 'hi', 'hr': 'hr', 'hu': 'hu', 'hy': 'hy',
    'id': 'id', 'is': 'is', 'it': 'it',
    'ja': 'ja',
    'ka': 'ka', 'kk': 'kk', 'ko': 'ko',
    'ku': 'ku', 'ky': 'ky',
    'lt': 'lt', 'lv': 'lv',
    'mk': 'mk', 'mn': 'mn', 'mr': 'mr', 'ms': 'ms',
    'nb': 'nb', 'ne': 'ne', 'nl': 'nl', 'nn': 'nn',
    'pa-in': 'pa-IN', 'pl': 'pl', 'ps': 'ps', 'pt-br': 'pt-BR', 'pt': 'pt',
    'ro': 'ro', 'ru': 'ru',
    'sa': 'sa', 'si': 'si', 'sk': 'sk', 'sl': 'sl', 'sq': 'sq',
    'sr-spc': 'sr-Cyrl', 'sr-spl': 'sr-Latn', 'sv': 'sv', 'sw': 'sw',
    'ta': 'ta', 'tg': 'tg', 'th': 'th', 'tk': 'tk', 'tr': 'tr', 'tt': 'tt',
    'ug': 'ug', 'uk': 'uk', 'uz': 'uz',
    'vi': 'vi',
    'yo': 'yo',
    'zh-cn': 'zh-Hans', 'zh-tw': 'zh-Hant',
}


# ---------------------------------------------------------------------------
# .strings file generation
# ---------------------------------------------------------------------------

def escape_strings_value(text: str) -> str:
    """Escape text for use in a .strings file value."""
    return (text
            .replace('\\', '\\\\')
            .replace('"', '\\"')
            .replace('\n', '\\n')
            .replace('\t', '\\t'))


def generate_strings_content(key_translations: dict[str, str]) -> str:
    """Generate the content of a .strings file."""
    lines = []
    prev_section = None

    for key in sorted(key_translations.keys()):
        value = key_translations[key]
        # Group by first dotted component
        section = key.split('.')[0]
        if prev_section is not None and section != prev_section:
            lines.append('')
        prev_section = section

        escaped_value = escape_strings_value(value)
        lines.append(f'"{key}" = "{escaped_value}";')

    return '\n'.join(lines) + '\n'


def main():
    project_root = Path(__file__).resolve().parents[2]
    lang_dir = project_root / 'project' / 'localization' / 'Lang'
    output_dir = project_root / 'ShichiZip' / 'Resources' / 'Localization'
    en_file = lang_dir / 'en.ttt'

    if not en_file.exists():
        print(f"Error: English template not found: {en_file}", file=sys.stderr)
        sys.exit(1)

    # Parse English template
    en_strings = parse_lang_file(str(en_file))

    # Build English key→value from upstream
    en_upstream: dict[str, str] = {}
    for uid, key in UPSTREAM_KEY_MAP.items():
        text = en_strings.get(uid, '')
        # Strip accelerator markers for display
        text = strip_accelerator(text).strip()
        if text:
            en_upstream[key] = text

    print(f"Upstream English strings: {len(en_upstream)}")

    # Generate English .lproj
    en_lproj = output_dir / 'en.lproj'
    en_lproj.mkdir(parents=True, exist_ok=True)

    # Upstream.strings - from 7-Zip translations
    upstream_content = generate_strings_content(en_upstream)
    (en_lproj / 'Upstream.strings').write_text(upstream_content, encoding='utf-8')
    print(f"  Wrote {en_lproj / 'Upstream.strings'}")

    # Process each translation file
    generated_count = 0
    for lang_file in sorted(lang_dir.glob('*.txt')):
        stem = lang_file.stem
        if stem not in LANG_FILE_TO_APPLE_LOCALE:
            print(f"  Skipping {lang_file.name} (no Apple locale mapping)")
            continue

        apple_locale = LANG_FILE_TO_APPLE_LOCALE[stem]
        translated = parse_lang_file(str(lang_file))

        # Build translations for this locale
        locale_upstream: dict[str, str] = {}
        for uid, key in UPSTREAM_KEY_MAP.items():
            text = translated.get(uid, '')
            text = strip_accelerator(text).strip()
            if text:
                locale_upstream[key] = text

        if not locale_upstream:
            print(f"  Skipping {stem} ({apple_locale}): no translations found")
            continue

        # Write Upstream.strings
        locale_lproj = output_dir / f'{apple_locale}.lproj'
        locale_lproj.mkdir(parents=True, exist_ok=True)
        content = generate_strings_content(locale_upstream)
        (locale_lproj / 'Upstream.strings').write_text(content, encoding='utf-8')
        generated_count += 1

    print(f"\nGenerated Upstream.strings for {generated_count} locales (+1 English)")
    print(f"Output directory: {output_dir}")

    # Summary of coverage
    print("\n=== Coverage summary ===")
    # Check a few popular locales
    popular = ['ja', 'zh-cn', 'zh-tw', 'ko', 'fr', 'de', 'es', 'ru', 'pt-br', 'ar']
    for stem in popular:
        if stem not in LANG_FILE_TO_APPLE_LOCALE:
            continue
        apple_locale = LANG_FILE_TO_APPLE_LOCALE[stem]
        lproj = output_dir / f'{apple_locale}.lproj' / 'Upstream.strings'
        if lproj.exists():
            count = lproj.read_text().count('" = "')
            print(f"  {apple_locale:10s}: {count:3d}/{len(en_upstream)} upstream strings")


if __name__ == '__main__':
    main()
