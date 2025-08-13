#!/usr/bin/env python3
"""Generate an HTML report with graphs from sbf70-cli JSON measurements."""

import argparse
import json
import math
import sys
from datetime import datetime, timezone


RAW_FIELDS = [
    ("weight_kg", "Weight (kg)"),
    ("impedance", "Impedance"),
    ("fat_pct", "Fat (%)"),
    ("water_pct", "Water (%)"),
    ("muscle_pct", "Muscle (%)"),
    ("bone_kg", "Bone Mass (kg)"),
]

COMPUTED_FIELDS = [
    ("ffm_kg", "Fat-Free Mass (kg)"),
    ("fat_muscle_ratio", "Fat / Muscle Ratio"),
    ("hydration_balance", "Hydration Balance"),
    ("phase_angle", "Phase Angle (deg)"),
]


def parse_measurements(data: dict) -> list[dict]:
    measurements = data.get("measurements", data if isinstance(data, list) else [])
    return sorted(measurements, key=lambda m: m.get("timestamp", 0))


def compute_derived(measurements: list[dict], height_cm: float | None) -> list[dict]:
    for m in measurements:
        w = m.get("weight_kg")
        fat = m.get("fat_pct")
        water = m.get("water_pct")
        muscle = m.get("muscle_pct")
        z = m.get("impedance")

        if w is not None and fat is not None:
            m["ffm_kg"] = round(w * (1 - fat / 100), 2)
        if fat is not None and muscle is not None and muscle > 0:
            m["fat_muscle_ratio"] = round(fat / muscle, 4)
        if water is not None and fat is not None:
            denom = 100 - fat
            m["hydration_balance"] = round(water / denom, 4) if denom > 0 else None
        if w and z and z > 0 and height_cm:
            pa = math.degrees(math.atan(
                (height_cm / (0.1547 * math.sqrt(z)))
                / (0.2096 * w / (z * 0.5))
            ))
            m["phase_angle"] = round(pa, 2)
    return measurements


def build_chart_data(measurements: list[dict], field: str) -> list[dict]:
    points = []
    for m in measurements:
        ts = m.get("timestamp", 0)
        val = m.get(field)
        if ts and val is not None:
            points.append({"x": ts * 1000, "y": val})
    return points


def generate_html(data: dict, height_cm: float | None = None) -> str:
    measurements = parse_measurements(data)
    measurements = compute_derived(measurements, height_cm)
    uid = measurements[0].get("uid", "unknown") if measurements else "unknown"

    raw_defs = [(i, title, build_chart_data(measurements, field)) for i, (field, title) in enumerate(RAW_FIELDS)]
    offset = len(RAW_FIELDS)
    computed_defs = [(offset + i, title, build_chart_data(measurements, field)) for i, (field, title) in enumerate(COMPUTED_FIELDS)]

    all_defs = raw_defs + computed_defs

    charts_html = '<div class="section-title">Raw Measurements</div>\n'
    for i, title, _ in raw_defs:
        charts_html += f'<div class="chart-container"><canvas id="chart{i}"></canvas></div>\n'
    charts_html += '<div class="section-title">Computed Metrics</div>\n'
    for i, title, _ in computed_defs:
        charts_html += f'<div class="chart-container"><canvas id="chart{i}"></canvas></div>\n'

    chart_inits = ""
    for i, title, points in all_defs:
        chart_inits += f"""        charts[{i}] = new Chart(document.getElementById('chart{i}'), {{
            type: 'line',
            plugins: [crosshairPlugin],
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
        .section-title {{ font-size: 1.1rem; font-weight: 600; margin: 2rem 0 0.5rem; padding-bottom: 0.25rem; border-bottom: 2px solid #e2e8f0; color: #475569; }}
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
    let crosshairX = null;

    const crosshairPlugin = {{
        id: 'crosshair',
        afterDraw(chart) {{
            if (crosshairX === null) return;
            const xScale = chart.scales.x;
            const ctx = chart.ctx;
            const xPixel = xScale.getPixelForValue(crosshairX);
            const area = chart.chartArea;
            if (xPixel < area.left || xPixel > area.right) return;
            ctx.save();
            ctx.beginPath();
            ctx.moveTo(xPixel, area.top);
            ctx.lineTo(xPixel, area.bottom);
            ctx.lineWidth = 1;
            ctx.strokeStyle = 'rgba(239,68,68,0.7)';
            ctx.setLineDash([4, 4]);
            ctx.stroke();
            ctx.restore();
        }}
    }};

    function syncTooltips(event, elements, chart) {{
        if (syncing) return;
        if (!elements.length) {{
            crosshairX = null;
            charts.forEach(c => {{
                c.setActiveElements([]);
                c.update('none');
            }});
            return;
        }}
        syncing = true;
        const x = chart.data.datasets[0].data[elements[0].index].x;
        crosshairX = x;
        charts.forEach(c => {{
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
    parser.add_argument("--height", type=float, help="User height in cm (required for Phase Angle)")
    args = parser.parse_args()

    if args.input:
        with open(args.input) as f:
            data = json.load(f)
    else:
        data = json.load(sys.stdin)

    html = generate_html(data, args.height)

    if args.output:
        with open(args.output, "w") as f:
            f.write(html)
    else:
        print(html)


if __name__ == "__main__":
    main()
