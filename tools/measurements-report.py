#!/usr/bin/env python3
"""Generate an HTML report with graphs from sbf70-cli JSON measurements."""

import argparse
import json
import sys
from datetime import datetime, timezone


FIELDS = [
    ("weight_kg", "Weight (kg)"),
    ("impedance", "Impedance"),
    ("fat_pct", "Fat (%)"),
    ("water_pct", "Water (%)"),
    ("muscle_pct", "Muscle (%)"),
    ("bone_kg", "Bone Mass (kg)"),
]


def parse_measurements(data: dict) -> list[dict]:
    measurements = data.get("measurements", data if isinstance(data, list) else [])
    return sorted(measurements, key=lambda m: m.get("timestamp", 0))


def build_chart_data(measurements: list[dict], field: str) -> tuple[list[str], list[float | None]]:
    labels = []
    values = []
    for m in measurements:
        ts = m.get("timestamp", 0)
        dt = datetime.fromtimestamp(ts, tz=timezone.utc) if ts else None
        labels.append(dt.strftime("%Y-%m-%d %H:%M") if dt else "N/A")
        values.append(m.get(field))
    return labels, values


def generate_html(data: dict) -> str:
    measurements = parse_measurements(data)
    uid = measurements[0].get("uid", "unknown") if measurements else "unknown"

    charts_js = ""
    for i, (field, title) in enumerate(FIELDS):
        labels, values = build_chart_data(measurements, field)
        charts_js += f"""
        new Chart(document.getElementById('chart{i}'), {{
            type: 'line',
            data: {{
                labels: {json.dumps(labels)},
                datasets: [{{
                    label: '{title}',
                    data: {json.dumps(values)},
                    borderColor: '#3b82f6',
                    backgroundColor: 'rgba(59,130,246,0.1)',
                    fill: true,
                    tension: 0.3,
                    pointRadius: 3
                }}]
            }},
            options: {{
                responsive: true,
                plugins: {{ title: {{ display: true, text: '{title}' }} }},
                scales: {{
                    x: {{ title: {{ display: true, text: 'Date' }} }},
                    y: {{ title: {{ display: true, text: '{title}' }} }}
                }}
            }}
        }});
"""

    charts_html = "\n".join(
        f'<div class="chart-container"><canvas id="chart{i}"></canvas></div>'
        for i in range(len(FIELDS))
    )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Scale Measurements Report - {uid}</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        body {{ font-family: system-ui, sans-serif; margin: 2rem; background: #f8fafc; color: #1e293b; }}
        h1 {{ margin-bottom: 0.25rem; }}
        .meta {{ color: #64748b; margin-bottom: 2rem; }}
        .chart-container {{ background: white; border-radius: 8px; padding: 1rem; margin-bottom: 1.5rem; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }}
        canvas {{ max-height: 300px; }}
    </style>
</head>
<body>
    <h1>Scale Measurements Report</h1>
    <div class="meta">User: {uid} | Measurements: {len(measurements)}</div>
    {charts_html}
    <script>
    {charts_js}
    </script>
</body>
</html>"""


def main():
    parser = argparse.ArgumentParser(description="Generate HTML report from sbf70-cli JSON")
    parser.add_argument("input", nargs="?", help="JSON file (default: stdin)")
    parser.add_argument("-o", "--output", help="Output HTML file (default: stdout)")
    args = parser.parse_args()

    if args.input:
        with open(args.input) as f:
            data = json.load(f)
    else:
        data = json.load(sys.stdin)

    html = generate_html(data)

    if args.output:
        with open(args.output, "w") as f:
            f.write(html)
    else:
        print(html)


if __name__ == "__main__":
    main()
