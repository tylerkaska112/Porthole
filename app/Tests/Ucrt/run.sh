#!/bin/bash
# RETIRED (2026-11-10): patch 0084's rule (ios_app_ucrt_alt_name, "an x64 program's own ucrtbase.dll no longer replaces the system one") is no longer in the engine. The engine merge took upstream's
# own version of the same fix instead (Madeira commit fcffc5b "ntdll iOS: skip an app-local x64 ucrtbase.dll", #286), so there is no function left to compile here. The Red Dead Redemption 2 /
# Rockstar launcher case it was written for is covered by a device run, not by this test.
echo "Ucrt: retired, the rule now comes from upstream's version of the fix (see this file)."
