#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Dmytro Udovychenko
# Removes only the two privileged files installed by Lidless.

set -euo pipefail

INSTALLED_HELPER="/Library/PrivilegedHelperTools/io.github.lidless.poweroff"
SUDOERS_FILE="/etc/sudoers.d/lidless"

echo "Lidless will remove:"
echo "  $INSTALLED_HELPER"
echo "  $SUDOERS_FILE"
echo

/usr/bin/sudo /bin/rm -f "$SUDOERS_FILE"
/usr/bin/sudo /bin/rm -f "$INSTALLED_HELPER"
/usr/bin/sudo /usr/sbin/visudo -c

echo "Lidless power permission removed."
