# Source File Header Template

Every source file in this repository must carry a copyright and license
header. Use the appropriate template below for the file type.

The SPDX-License-Identifier line is mandatory; it is what license-scanning
tools (FOSSA, Black Duck, Snyk, ScanCode, REUSE) use to classify the
file. Do not omit it.

--------------------------------------------------------------------------------
For C, C++, Go, Rust, and other C-family source files:
--------------------------------------------------------------------------------

// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Amken LLC <https://www.amken.us>
//
// This file is part of the ticktrace Assembly SDK.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public
// License along with this program. If not, see
// <https://www.gnu.org/licenses/>.
//
// A commercial license is available from Amken LLC for use cases that
// cannot comply with the AGPL. See COMMERCIAL-LICENSE.md.

--------------------------------------------------------------------------------
For assembly source files (.S, .s):
--------------------------------------------------------------------------------

// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Amken LLC <https://www.amken.us>
//
// This file is part of the ticktrace Assembly SDK.
// Licensed under AGPL-3.0-or-later; commercial license available.
// See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

(Use `@` or `;` for the comment prefix instead of `//` if your assembler
requires it. GNU as on Arm accepts both `//` and `@` for line comments.)

--------------------------------------------------------------------------------
For Python, shell, YAML, CMake, Makefiles, and other #-comment files:
--------------------------------------------------------------------------------

# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copyright (C) 2026 Amken LLC <https://www.amken.us>
#
# This file is part of the ticktrace Assembly SDK.
# Licensed under AGPL-3.0-or-later; commercial license available.
# See LICENSE and COMMERCIAL-LICENSE.md in the root of this repository.

--------------------------------------------------------------------------------
Short-form header (acceptable for small files, examples, and tests):
--------------------------------------------------------------------------------

// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Amken LLC. See LICENSE and COMMERCIAL-LICENSE.md.

--------------------------------------------------------------------------------
Notes
--------------------------------------------------------------------------------

1. The copyright year should be the year of first publication of the
   file, NOT the year of the most recent edit. Do not "update" the year
   on every commit.

2. When merging substantive third-party contributions, add the
   contributor's copyright line BELOW Amken's, preserving Amken's as
   the primary copyright holder (required by the CLA).

3. Do not modify the SPDX identifier. "AGPL-3.0-or-later" is the
   correct identifier for the dual-licensed configuration. Do not
   write "AGPL-3.0", "AGPLv3", or any informal variant.

4. The REUSE specification (https://reuse.software/) is the
   authoritative reference for SPDX header usage in source files.
   This repository aims to be REUSE-compliant.
