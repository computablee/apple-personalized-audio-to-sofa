#!/bin/bash
# Checks every .sofa under the given dirs (default: sofa/) with
# libmysofa (mysofa2json) and netCDF (ncdump). Writes validate.log next to this script.
# Requires: brew install libmysofa netcdf
cd "$(dirname "$0")"
dirs=("$@"); [ ${#dirs[@]} -eq 0 ] && dirs=(sofa)
{
  for f in $(find "${dirs[@]}" -name '*.sofa' 2>/dev/null | sort); do
    echo "== $f"
    out=$(mysofa2json "$f" 2>&1); rc=$?
    if [ $rc -eq 0 ] && echo "$out" | grep -q '"Data.IR"'; then echo "libmysofa: OK ($(echo "$out" | wc -c | tr -d ' ') bytes json)"; else echo "libmysofa: FAIL rc=$rc"; echo "$out" | head -c 400; echo; fi
    if ncdump -h "$f" > /dev/null 2>&1; then echo "netCDF: OK"; else echo "netCDF: FAIL"; ncdump -h "$f" 2>&1 | head -5; fi
  done
  first=$(find "${dirs[@]}" -name '*.sofa' 2>/dev/null | sort | head -1)
  [ -n "$first" ] && { echo "== ncdump -h $first"; ncdump -h "$first"; echo "== mysofa2json excerpt"; mysofa2json "$first" 2>&1 | head -c 3000; }
} > validate.log 2>&1
grep -E "^(==|libmysofa|netCDF)" validate.log | grep -v "ncdump -h\|excerpt"
