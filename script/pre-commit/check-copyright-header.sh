#!/usr/bin/env bash
#
# Copyright header check for Solidity sources.
#
# addlicense does NOT support .sol files, so this script enforces the Circle
# Apache-2.0 header for Solidity directly. For each file passed (or each staged
# .sol file when run with no args) it checks for the header and, if missing,
# prepends the repo-standard /** ... */ block. Any file it fixes causes a
# non-zero exit so the commit stops and you can re-stage the change.

set -eu

YEAR=$(date +'%Y')

# The canonical header block (matches the format used across the repo).
header() {
    cat <<EOF
/**
 * Copyright ${YEAR} Circle Internet Group, Inc.  All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
EOF
}

# Number of lines in the canonical header block.
header_lines=$(header | wc -l | tr -d ' ')

# Normalize the copyright year to a placeholder so any valid 4-digit year is
# accepted, while every other line (Apache text, SPDX identifier, comment
# delimiters, spacing) must still match the canonical block byte-for-byte.
normalize_year() {
    sed -E 's/^( \* Copyright )[0-9]{4}( Circle Internet Group, Inc\.)/\1YYYY\2/'
}

expected_header=$(header | normalize_year)

# Collect target files: explicit args, else staged .sol files.
files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
    while IFS= read -r f; do files+=("$f"); done \
        < <(git diff --name-only --diff-filter=AMR --cached -- '*.sol')
fi

# Nothing to check (safe under `set -u` on bash 3.2).
if [ "${#files[@]}" -eq 0 ]; then
    exit 0
fi

fixed=0
for file in "${files[@]}"; do
    case "$file" in
        *.sol) ;;
        *) continue ;;
    esac
    [ -f "$file" ] || continue

    # Already has the exact canonical header (year ignored)? Nothing to do.
    # The whole block is compared — not just a substring — so a partial
    # header, wrong SPDX line, or missing Apache text is treated as missing.
    if [ "$(head -n "$header_lines" "$file" | normalize_year)" = "$expected_header" ]; then
        continue
    fi

    tmp=$(mktemp)
    header > "$tmp"
    # If the file leads with a bare SPDX comment, absorb it into the block;
    # otherwise keep all existing content below the new header.
    if [ "$(sed -n '1p' "$file")" = "// SPDX-License-Identifier: Apache-2.0" ]; then
        tail -n +2 "$file" >> "$tmp"
    else
        cat "$file" >> "$tmp"
    fi
    mv "$tmp" "$file"
    echo "added copyright header to $file"
    fixed=1
done

if [ "$fixed" -ne 0 ]; then
    echo "Copyright headers were added. Review and re-stage the changed files, then commit again."
    exit 1
fi
