# Output Formats

All obs skills support three output formats. Default is **table** unless the user requests otherwise.

## Pretty Table (default)

Markdown table with aligned columns. Use `—` for missing values. Round numbers to 2 decimal places for costs, 0 for token/call counts.

```
| Column1 | Column2 | Column3 |
|---------|---------|---------|
| value   | value   | value   |
```

Rules:
- Header row is bold-style (markdown table header)
- Status columns: use UP/DOWN or OK/ERROR (no emojis unless user asks)
- Cost columns: prefix with `$`
- Large numbers: use `k` suffix for thousands (e.g., `124k`)
- Timestamps: relative ("3m ago", "2h ago") unless user asks for absolute

## CSV

Comma-separated values. First row is header. Quote fields that contain commas.

```
column1,column2,column3
value,"value, with comma",value
```

Rules:
- No markdown formatting
- Timestamps: ISO 8601 (`2026-03-11T21:00:00Z`)
- Numbers: raw (no `k` suffix, no `$` prefix)
- Missing values: empty field

## JSON

Array of objects. One object per row.

```json
[
  {"column1": "value", "column2": 123, "column3": null},
  {"column1": "value", "column2": 456, "column3": null}
]
```

Rules:
- Numbers are numbers (not strings)
- Missing values: `null`
- Timestamps: ISO 8601 strings
- Costs: raw float (no `$`)

## How to detect user's format preference

- Default: table
- User says "csv", "export", "spreadsheet" → CSV
- User says "json", "raw", "api" → JSON
- User says "table", "pretty", or nothing → table
