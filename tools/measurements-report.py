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


def build_chart_data(measurements: list[dict], field: str) -> list[dict]:
    points = []
    for m in measurements:
        ts = m.get("timestamp", 0)
        val = m.get(field)
        if ts and val is not None:
            points.append({"x": ts * 1000, "y": val})
    return points


def generate_html(data: dict) -> str:
    measurements = parse_measurements(data)
    uid = measurements[0].get("uid", "unknown") if measurements else "unknown"

    chart_defs = []
    for i, (field, title) in enumerate(FIELDS):
        points = build_chart_data(measurements, field)
        chart_defs.append((i, title, points))

    charts_html = "\n".join(
        f'<div class="chart-container"><canvas id="chart{i}"></canvas></div>'
        for i, _, _ in chart_defs
    )

    chart_inits = ""
    for i, title, points in chart_defs:
        chart_inits += f"""        charts[{i}] = new Chart(document.getElementById('chart{i}'), {{
            type: 'line',
            data: {{
                datasets: [{{
                    label: '{title}',
                    data: {json.dumps(points)},
                    borderColor: '#3b82f6',
                    backgroundColor: 'rgba(59,130,246,0.1)',
                    fill: true,
                    tension: 0.3,
                    pointRadius: 3
                }}]
            }},
            options: {{
                responsive: true,
                plugins: {{
                    title: {{ display: true, text: '{title}' }},
                    tooltip: {{ mode: 'index', intersect: false }}
                }},
                scales: {{
                    x: {{
                        type: 'time',
                        time: {{ tooltipFormat: 'PPpp' }},
                        title: {{ display: true, text: 'Date' }}
                    }},
                    y: {{ title: {{ display: true, text: '{title}' }} }}
                }},
                onHover: syncTooltips
            }}
        }});
"""

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Scale Measurements Report - {uid}</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns"></script>
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
    const charts = [];
    let syncing = false;

    function syncTooltips(event, elements, chart) {{
        if (syncing) return;
        if (!elements.length) {{
            charts.forEach((c, i) => {{
                if (c !== chart) c.setActiveElements([]);
            }});
            return;
        }}
        syncing = true;
        const x = chart.data.datasets[0].data[elements[0].index].x;
        charts.forEach((c, i) => {{
            if (c === chart) return;
            const ds = c.data.datasets[0].data;
            let closest = 0;
            let minDist = Infinity;
            ds.forEach((pt, j) => {{
                const dist = Math.abs(pt.x - x);
                if (dist < minDist) {{ minDist = dist; closest = j; }}
            }});
            c.setActiveElements([{{ datasetIndex: 0, index: closest }}]);
            c.tooltip.setActiveElements([{{ datasetIndex: 0, index: closest }}], {{ x: 0, y: 0 }});
            c.update('none');
        }});
        syncing = false;
    }}

{chart_inits}
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
