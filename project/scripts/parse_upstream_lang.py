#!/usr/bin/env python3
"""
Parse upstream 7-Zip language files (.txt/.ttt) into structured data.

The upstream format uses numbered sections where each string's ID = section_start + offset.
Empty lines within a section represent unused/empty string slots.
"""

import os
import sys
import json
import re
from pathlib import Path


def parse_lang_file(filepath: str) -> dict:
    """Parse a 7-Zip .txt/.ttt language file into {string_id: text}."""
    strings = {}
    metadata = {}

    with open(filepath, 'r', encoding='utf-8-sig') as f:
        lines = f.readlines()

    current_section = None
    offset = 0
    in_header = True

    for line in lines:
        line = line.rstrip('\n').rstrip('\r')

        # Skip header comment lines
        if line.startswith(';'):
            continue

        # Check if this is a section number (a line that is just digits)
        stripped = line.strip()
        if stripped.isdigit() and len(stripped) <= 5:
            section_num = int(stripped)
            # Section 0 is special (app info), other sections start at their number
            current_section = section_num
            offset = 0
            continue

        if current_section is not None:
            string_id = current_section + offset
            # Store the string (even if empty - empty strings are valid slots)
            text = line
            # Strip accelerator key markers (&) for display, but keep original
            strings[string_id] = text
            offset += 1

    return strings


def parse_english_template(filepath: str) -> dict:
    """Parse the English template and return {string_id: english_text}."""
    return parse_lang_file(filepath)


def get_lang_code_mapping() -> dict:
    """Map upstream filename stems to Apple locale codes."""
    return {
        'af': 'af', 'an': 'an', 'ar': 'ar', 'ast': 'ast', 'az': 'az',
        'ba': 'ba', 'be': 'be', 'bg': 'bg', 'bn': 'bn', 'br': 'br',
        'ca': 'ca', 'co': 'co', 'cs': 'cs', 'cy': 'cy',
        'da': 'da', 'de': 'de',
        'el': 'el', 'en': 'en', 'eo': 'eo', 'es': 'es', 'et': 'et', 'eu': 'eu', 'ext': 'ext',
        'fa': 'fa', 'fi': 'fi', 'fr': 'fr', 'fur': 'fur', 'fy': 'fy',
        'ga': 'ga', 'gl': 'gl', 'gu': 'gu',
        'he': 'he', 'hi': 'hi', 'hr': 'hr', 'hu': 'hu', 'hy': 'hy',
        'id': 'id', 'io': 'io', 'is': 'is', 'it': 'it',
        'ja': 'ja',
        'ka': 'ka', 'kaa': 'kaa', 'kab': 'kab', 'kk': 'kk', 'ko': 'ko',
        'ku-ckb': 'ku-CK', 'ku': 'ku', 'ky': 'ky',
        'lij': 'lij', 'lt': 'lt', 'lv': 'lv',
        'mk': 'mk', 'mn': 'mn', 'mng': 'mng', 'mng2': 'mng', 'mr': 'mr', 'ms': 'ms',
        'nb': 'nb', 'ne': 'ne', 'nl': 'nl', 'nn': 'nn',
        'pa-in': 'pa-IN', 'pl': 'pl', 'ps': 'ps', 'pt-br': 'pt-BR', 'pt': 'pt',
        'ro': 'ro', 'ru': 'ru',
        'sa': 'sa', 'si': 'si', 'sk': 'sk', 'sl': 'sl', 'sq': 'sq',
        'sr-spc': 'sr-Cyrl', 'sr-spl': 'sr-Latn', 'sv': 'sv', 'sw': 'sw',
        'ta': 'ta', 'tg': 'tg', 'th': 'th', 'tk': 'tk', 'tr': 'tr', 'tt': 'tt',
        'ug': 'ug', 'uk': 'uk', 'uz-cyrl': 'uz-Cyrl', 'uz': 'uz',
        'va': 'va', 'vi': 'vi',
        'yo': 'yo',
        'zh-cn': 'zh-Hans', 'zh-tw': 'zh-Hant',
    }


def strip_accelerator(text: str) -> str:
    """Remove Windows-style accelerator key markers (&) from text."""
    return text.replace('&', '')


def main():
    project_root = Path(__file__).resolve().parents[2]
    lang_dir = project_root / 'project' / 'localization' / 'Lang'
    en_file = lang_dir / 'en.ttt'

    if not en_file.exists():
        print(f"English template not found: {en_file}", file=sys.stderr)
        sys.exit(1)

    # Parse English template
    en_strings = parse_english_template(str(en_file))

    print(f"Parsed {len(en_strings)} strings from English template\n")

    # Show sections with their strings
    print("=== UPSTREAM STRING IDS AND ENGLISH TEXT ===\n")
    for sid in sorted(en_strings.keys()):
        text = en_strings[sid]
        if text.strip():
            print(f"  {sid:>5}: {text}")

    # Parse a sample translation to verify
    print("\n=== SAMPLE: Japanese translation ===\n")
    ja_file = lang_dir / 'ja.txt'
    if ja_file.exists():
        ja_strings = parse_lang_file(str(ja_file))
        # Show side by side for key dialog strings
        key_sections = [
            ("Common", range(401, 420)),
            ("Extract Dialog", range(3400, 3450)),
            ("Password", range(3800, 3830)),
            ("Progress", range(3900, 3910)),
            ("Add to Archive", range(4000, 4100)),
        ]
        for section_name, id_range in key_sections:
            print(f"  --- {section_name} ---")
            for sid in id_range:
                en_text = en_strings.get(sid, '')
                ja_text = ja_strings.get(sid, '')
                if en_text.strip() or ja_text.strip():
                    print(f"  {sid:>5}: EN={en_text!r:40s} JA={ja_text!r}")
            print()

    # Count how many lang files we have
    lang_files = list(lang_dir.glob('*.txt')) + list(lang_dir.glob('*.ttt'))
    print(f"\nTotal language files: {len(lang_files)}")

    # Identify strings that match ShichiZip's needs
    print("\n=== STRINGS REUSABLE BY SHICHIZIP ===\n")

    # Define the mapping: upstream_id -> shichizip_key
    reusable = {
        # Common buttons
        401: ("common.ok", "OK"),
        402: ("common.cancel", "Cancel"),
        406: ("common.yes", "Yes"),
        407: ("common.no", "No"),
        408: ("common.close", "Close"),
        409: ("common.help", "Help"),
        411: ("common.continue", "Continue"),
        440: ("common.yesToAll", "Yes to All"),
        441: ("common.noToAll", "No to All"),
        442: ("common.stop", "Stop"),
        443: ("common.restart", "Restart"),
        444: ("common.background", "Background"),
        445: ("common.foreground", "Foreground"),
        446: ("common.pause", "Pause"),
        447: ("common.paused", "Paused"),
        448: ("common.confirmCancel", "Are you sure you want to cancel?"),

        # Menu bar
        500: ("menu.file", "File"),
        501: ("menu.edit", "Edit"),
        502: ("menu.view", "View"),
        503: ("menu.favorites", "Favorites"),
        504: ("menu.tools", "Tools"),
        505: ("menu.help", "Help"),

        # File menu items
        540: ("menu.open", "Open"),
        541: ("menu.openInside", "Open Inside"),
        542: ("menu.openOutside", "Open Outside"),
        543: ("menu.view", "View"),
        544: ("menu.edit", "Edit"),
        545: ("menu.rename", "Rename"),
        546: ("menu.copyTo", "Copy To..."),
        547: ("menu.moveTo", "Move To..."),
        548: ("menu.delete", "Delete"),
        549: ("menu.splitFile", "Split file..."),
        550: ("menu.combineFiles", "Combine files..."),
        551: ("menu.properties", "Properties"),
        552: ("menu.comment", "Comment..."),
        553: ("menu.calculateChecksum", "Calculate checksum"),
        554: ("menu.diff", "Diff"),
        555: ("menu.createFolder", "Create Folder"),
        556: ("menu.createFile", "Create File"),
        557: ("menu.exit", "Exit"),

        # Edit menu
        600: ("edit.selectAll", "Select All"),
        601: ("edit.deselectAll", "Deselect All"),
        602: ("edit.invertSelection", "Invert Selection"),

        # View menu
        700: ("view.largeIcons", "Large Icons"),
        701: ("view.smallIcons", "Small Icons"),
        702: ("view.list", "List"),
        703: ("view.details", "Details"),
        730: ("view.unsorted", "Unsorted"),
        731: ("view.flatView", "Flat View"),
        732: ("view.twoPanels", "2 Panels"),
        733: ("view.toolbars", "Toolbars"),
        734: ("view.openRootFolder", "Open Root Folder"),
        735: ("view.upOneLevel", "Up One Level"),
        736: ("view.foldersHistory", "Folders History..."),
        737: ("view.refresh", "Refresh"),
        738: ("view.autoRefresh", "Auto Refresh"),
        750: ("view.archiveToolbar", "Archive Toolbar"),
        751: ("view.standardToolbar", "Standard Toolbar"),
        752: ("view.largeButtons", "Large Buttons"),
        753: ("view.showButtonsText", "Show Buttons Text"),

        # Favorites
        800: ("favorites.addFolder", "Add folder to Favorites as"),
        801: ("favorites.bookmark", "Bookmark"),

        # Tools
        900: ("tools.options", "Options..."),
        901: ("tools.benchmark", "Benchmark"),
        910: ("tools.deleteTempFiles", "Delete Temporary Files..."),

        # Column headers
        1003: ("column.path", "Path"),
        1004: ("column.name", "Name"),
        1005: ("column.extension", "Extension"),
        1006: ("column.folder", "Folder"),
        1007: ("column.size", "Size"),
        1008: ("column.packedSize", "Packed Size"),
        1009: ("column.attributes", "Attributes"),
        1010: ("column.created", "Created"),
        1011: ("column.accessed", "Accessed"),
        1012: ("column.modified", "Modified"),

        # Progress
        3300: ("progress.extracting", "Extracting"),
        3301: ("progress.compressing", "Compressing"),
        3302: ("progress.testing", "Testing"),
        3303: ("progress.opening", "Opening..."),
        3304: ("progress.scanning", "Scanning..."),
        3305: ("progress.removing", "Removing"),

        3320: ("progress.adding", "Adding"),
        3321: ("progress.updating", "Updating"),
        3322: ("progress.analyzing", "Analyzing"),
        3323: ("progress.replicating", "Replicating"),
        3324: ("progress.repacking", "Repacking"),
        3325: ("progress.skipping", "Skipping"),
        3326: ("progress.deleting", "Deleting"),
        3327: ("progress.headerCreating", "Header creating"),

        # Extract dialog
        3400: ("extract.title", "Extract"),
        3401: ("extract.extractTo", "Extract to:"),
        3402: ("extract.specifyLocation", "Specify a location for extracted files."),
        3410: ("extract.pathMode", "Path mode:"),
        3411: ("extract.fullPathnames", "Full pathnames"),
        3412: ("extract.noPathnames", "No pathnames"),
        3413: ("extract.absolutePathnames", "Absolute pathnames"),
        3414: ("extract.relativePathnames", "Relative pathnames"),
        3420: ("extract.overwriteMode", "Overwrite mode:"),
        3421: ("extract.askBeforeOverwrite", "Ask before overwrite"),
        3422: ("extract.overwriteWithoutPrompt", "Overwrite without prompt"),
        3423: ("extract.skipExisting", "Skip existing files"),
        3424: ("extract.autoRename", "Auto rename"),
        3425: ("extract.autoRenameExisting", "Auto rename existing files"),
        3430: ("extract.eliminateDuplication", "Eliminate duplication of root folder"),
        3431: ("extract.restoreSecurity", "Restore file security"),

        # Errors
        3700: ("error.unsupportedMethod", "Unsupported compression method for '{0}'."),
        3701: ("error.dataError", "Data error in '{0}'. File is broken."),
        3702: ("error.crcFailed", "CRC failed in '{0}'. File is broken."),
        3703: ("error.dataErrorEncrypted", "Data error in encrypted file '{0}'. Wrong password?"),
        3704: ("error.crcFailedEncrypted", "CRC failed in encrypted file '{0}'. Wrong password?"),
        3710: ("error.wrongPassword", "Wrong password?"),

        # Password dialog
        3800: ("password.enterPassword", "Enter password"),
        3801: ("password.enterPasswordPrompt", "Enter password:"),
        3802: ("password.reenterPassword", "Reenter password:"),
        3803: ("password.showPassword", "Show password"),
        3804: ("password.passwordsMismatch", "Passwords do not match"),
        3806: ("password.tooLong", "Password is too long"),
        3807: ("password.password", "Password"),

        # Progress info
        3900: ("progress.elapsedTime", "Elapsed time:"),
        3901: ("progress.remainingTime", "Remaining time:"),
        3902: ("progress.totalSize", "Total size:"),
        3903: ("progress.speed", "Speed:"),
        3904: ("progress.processed", "Processed:"),
        3905: ("progress.compressionRatio", "Compression ratio:"),
        3906: ("progress.errors", "Errors:"),
        3907: ("progress.archives", "Archives:"),

        # Add to archive dialog
        4000: ("compress.title", "Add to archive"),
        4001: ("compress.archive", "Archive:"),
        4002: ("compress.updateMode", "Update mode:"),
        4003: ("compress.archiveFormat", "Archive format:"),
        4004: ("compress.compressionLevel", "Compression level:"),
        4005: ("compress.compressionMethod", "Compression method:"),
        4006: ("compress.dictionarySize", "Dictionary size:"),
        4007: ("compress.wordSize", "Word size:"),
        4008: ("compress.solidBlockSize", "Solid block size:"),
        4009: ("compress.cpuThreads", "Number of CPU threads:"),
        4010: ("compress.parameters", "Parameters:"),
        4011: ("compress.options", "Options"),
        4012: ("compress.createSFX", "Create SFX archive"),
        4013: ("compress.compressShared", "Compress shared files"),
        4014: ("compress.encryption", "Encryption"),
        4015: ("compress.encryptionMethod", "Encryption method:"),
        4016: ("compress.encryptFileNames", "Encrypt file names"),
        4017: ("compress.memoryCompressing", "Memory usage for Compressing:"),
        4018: ("compress.memoryDecompressing", "Memory usage for Decompressing:"),
        4019: ("compress.deleteAfter", "Delete files after compression"),

        # Compression levels
        4050: ("level.store", "Store"),
        4051: ("level.fastest", "Fastest"),
        4052: ("level.fast", "Fast"),
        4053: ("level.normal", "Normal"),
        4054: ("level.maximum", "Maximum"),
        4055: ("level.ultra", "Ultra"),

        # Update modes
        4060: ("update.addReplace", "Add and replace files"),
        4061: ("update.updateAdd", "Update and add files"),
        4062: ("update.freshen", "Freshen existing files"),
        4063: ("update.synchronize", "Synchronize files"),

        # Misc compress
        4070: ("compress.browse", "Browse"),
        4071: ("compress.allFiles", "All Files"),
        4072: ("compress.nonSolid", "Non-solid"),
        4073: ("compress.solid", "Solid"),

        # Copy/Move
        6000: ("fileop.copy", "Copy"),
        6001: ("fileop.move", "Move"),
        6002: ("fileop.copyTo", "Copy to:"),
        6003: ("fileop.moveTo", "Move to:"),
        6004: ("fileop.copying", "Copying..."),
        6005: ("fileop.moving", "Moving..."),
        6006: ("fileop.renaming", "Renaming..."),
        6007: ("fileop.selectDestination", "Select destination folder."),

        # Delete confirmation
        6100: ("delete.confirmFile", "Confirm File Delete"),
        6101: ("delete.confirmFolder", "Confirm Folder Delete"),
        6102: ("delete.confirmMultiple", "Confirm Multiple File Delete"),
        6103: ("delete.askFile", "Are you sure you want to delete '{0}'?"),
        6104: ("delete.askFolder", "Are you sure you want to delete the folder '{0}' and all its contents?"),
        6105: ("delete.askMultiple", "Are you sure you want to delete these {0} items?"),
        6106: ("delete.deleting", "Deleting..."),

        # Create folder/file
        6300: ("create.folder", "Create Folder"),
        6301: ("create.file", "Create File"),
        6302: ("create.folderName", "Folder name:"),
        6303: ("create.fileName", "File Name:"),
        6304: ("create.newFolder", "New Folder"),
        6305: ("create.newFile", "New File"),

        # Properties
        6400: ("properties.comment", "Comment"),
        6401: ("properties.commentLabel", "Comment:"),
        6402: ("properties.select", "Select"),
        6403: ("properties.deselect", "Deselect"),
        6404: ("properties.mask", "Mask:"),

        # Toolbar
        7200: ("toolbar.add", "Add"),
        7201: ("toolbar.extract", "Extract"),
        7202: ("toolbar.test", "Test"),
        7203: ("toolbar.copy", "Copy"),
        7204: ("toolbar.move", "Move"),
        7205: ("toolbar.delete", "Delete"),
        7206: ("toolbar.info", "Info"),

        # Checksum
        7500: ("checksum.calculating", "Checksum calculating..."),
        7501: ("checksum.information", "Checksum information"),

        # Benchmark
        7600: ("benchmark.title", "Benchmark"),
        7601: ("benchmark.memoryUsage", "Memory usage:"),
        7602: ("benchmark.compressing", "Compressing"),
        7603: ("benchmark.decompressing", "Decompressing"),
        7604: ("benchmark.rating", "Rating"),
        7605: ("benchmark.totalRating", "Total Rating"),
        7606: ("benchmark.current", "Current"),
        7607: ("benchmark.resulting", "Resulting"),
        7608: ("benchmark.cpuUsage", "CPU Usage"),
        7609: ("benchmark.ratingPerUsage", "Rating / Usage"),
        7610: ("benchmark.passes", "Passes:"),

        # Memory limit
        7800: ("memory.usageRequest", "Memory usage request"),
        7810: ("memory.blocked", "The operation was blocked by 7-Zip."),
        7811: ("memory.requiresBigRAM", "The operation requires big amount of memory (RAM)."),
        7812: ("memory.requiredSize", "required memory usage size"),
        7813: ("memory.allowedLimit", "allowed memory usage limit"),
        7815: ("memory.ramSize", "RAM size"),
        7820: ("memory.allowUnpacking", "Allow archive unpacking"),
        7821: ("memory.skipUnpacking", "Skip archive unpacking"),
        7822: ("memory.skipped", "Archive unpacking was skipped."),

        # Settings
        2100: ("settings.options", "Options"),
        2101: ("settings.language", "Language"),
        2102: ("settings.languageLabel", "Language:"),

        # Folders settings
        2400: ("settings.folders", "Folders"),
        2401: ("settings.workingFolder", "Working folder"),
        2402: ("settings.systemTempFolder", "System temp folder"),
        2403: ("settings.current", "Current"),
        2404: ("settings.specified", "Specified:"),
        2405: ("settings.removableDrivesOnly", "Use for removable drives only"),
        2406: ("settings.specifyTempLocation", "Specify a location for temporary archive files."),

        # General settings
        2500: ("settings.title", "Settings"),
        2501: ("settings.showDotDot", 'Show ".." item'),
        2502: ("settings.showRealIcons", "Show real file icons"),
        2503: ("settings.showSystemMenu", "Show system menu"),
        2504: ("settings.fullRowSelect", "Full row select"),
        2505: ("settings.showGridLines", "Show grid lines"),
        2506: ("settings.singleClick", "Single-click to open an item"),
        2507: ("settings.altSelectionMode", "Alternative selection mode"),
        2508: ("settings.largeMemoryPages", "Use large memory pages"),
    }

    found = 0
    missing = 0
    for uid, (key, expected_en) in sorted(reusable.items()):
        actual = strip_accelerator(en_strings.get(uid, '')).strip()
        # Normalize for comparison (strip trailing ...)
        match = actual.lower().rstrip('.') == expected_en.lower().rstrip('.')
        status = "✓" if match else f"✗ (got: {actual!r})"
        if match:
            found += 1
        else:
            missing += 1
        print(f"  {uid:>5} {key:40s} {status}")

    print(f"\n  Matched: {found}, Mismatched: {missing}")
    print(f"  Total reusable strings: {len(reusable)}")
    print(f"  Coverage: {found}/{len(reusable)} ({100*found/len(reusable):.0f}%)")


if __name__ == '__main__':
    main()
