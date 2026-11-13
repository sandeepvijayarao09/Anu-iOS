---
name: unit-table
description: Makes a conversion table between two units of length, weight or temperature, such as kilometres to miles from 1 to 10.
---

# Unit table

Use this skill when the user wants a table or chart of conversions, not a single conversion.

## Steps

1. Call `run_js` with `skill_name` "unit-table", `script_name` "index.js" and `data` set to a JSON string such as `{"from": "km", "to": "mi", "start": 1, "end": 10, "step": 1}`.
   Units: mm, cm, m, km, in, ft, yd, mi, g, kg, oz, lb, C, F, K. `start`, `end` and `step` are optional (1, 10 and 1). A table has at most 50 rows.
2. The script answers `{"result": "<markdown table>"}` or `{"error": "..."}`. Show the table as it is.

## Examples

- "Give me a kilometres to miles table from 5 to 50"
- "Chart of Celsius to Fahrenheit from -10 to 40 in steps of 5"
