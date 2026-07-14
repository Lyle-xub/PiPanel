#!/usr/bin/env python3
"""Generate a self-hosted SVG chart from this repository's stargazers."""

from __future__ import annotations

import json
import math
import os
import sys
import urllib.error
import urllib.request
from datetime import date, datetime, timezone
from html import escape
from pathlib import Path


API_ROOT = "https://api.github.com"
OUTPUT = Path("docs/assets/star-history.svg")
HISTORY = Path("docs/assets/star-history.json")


def github_get(path: str, token: str, accept: str) -> object:
    request = urllib.request.Request(
        f"{API_ROOT}{path}",
        headers={
            "Accept": accept,
            "Authorization": f"Bearer {token}",
            "User-Agent": "PiPanel-star-history-action",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def load_repository(repository: str, token: str) -> dict[str, object]:
    result = github_get(
        f"/repos/{repository}", token, "application/vnd.github+json"
    )
    if not isinstance(result, dict):
        raise RuntimeError("GitHub returned invalid repository metadata")
    return result


def load_history() -> list[tuple[date, int]]:
    if not HISTORY.exists():
        return []

    raw = json.loads(HISTORY.read_text(encoding="utf-8"))
    if not isinstance(raw, list):
        raise RuntimeError("Star history file must contain a JSON array")

    history: list[tuple[date, int]] = []
    for entry in raw:
        if not isinstance(entry, dict):
            raise RuntimeError("Star history contains an invalid entry")
        day = date.fromisoformat(str(entry["date"]))
        stars = int(entry["stars"])
        if stars < 0:
            raise RuntimeError("Star count cannot be negative")
        history.append((day, stars))
    return sorted(history)


def save_history(history: list[tuple[date, int]]) -> None:
    data = [{"date": day.isoformat(), "stars": stars} for day, stars in history]
    HISTORY.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def nice_maximum(value: int) -> int:
    if value <= 5:
        return 5
    magnitude = 10 ** math.floor(math.log10(value))
    normalized = value / magnitude
    ceiling = 2 if normalized <= 2 else 5 if normalized <= 5 else 10
    return ceiling * magnitude


def build_svg(
    repository: str, created: date, history: list[tuple[date, int]]
) -> str:
    width, height = 800, 533
    left, right, top, bottom = 72, 28, 96, 96
    plot_width = width - left - right
    plot_height = height - top - bottom
    today = datetime.now(timezone.utc).date()
    values = {created: 0}
    values.update(history)
    points = sorted(values.items())
    start = points[0][0]
    end = max(today, points[-1][0])
    if points[-1][0] != end:
        points.append((end, points[-1][1]))
    span = max((end - start).days, 1)
    current_stars = points[-1][1]
    y_max = nice_maximum(max(value for _, value in points))

    def x(day: date) -> float:
        return left + ((day - start).days / span) * plot_width

    def y(value: int) -> float:
        return top + plot_height - (value / y_max) * plot_height

    line_path = " ".join(
        ("M" if index == 0 else "L") + f" {x(day):.1f} {y(value):.1f}"
        for index, (day, value) in enumerate(points)
    )

    def format_stars(value: int) -> str:
        if value >= 1_000_000:
            return f"{value / 1_000_000:.1f}".rstrip("0").rstrip(".") + "M"
        if value >= 1_000:
            return f"{value / 1_000:.1f}".rstrip("0").rstrip(".") + "K"
        return str(value)

    y_ticks: list[str] = []
    for index in range(6):
        value = round(y_max * index / 5)
        y_pos = y(value)
        label_text = "" if value == 0 else format_stars(value)
        y_ticks.append(
            f'<line x1="{left - 5}" y1="{y_pos:.1f}" x2="{left}" '
            f'y2="{y_pos:.1f}" class="tick-mark" />'
            f'<text x="{left - 12}" y="{y_pos + 5:.1f}" text-anchor="end" '
            f'class="tick-label">{label_text}</text>'
        )

    x_ticks: list[str] = []
    seen: set[date] = set()
    for index in range(6):
        day = date.fromordinal(start.toordinal() + round(span * index / 5))
        if day in seen:
            continue
        seen.add(day)
        x_pos = x(day)
        if span >= 730:
            tick_text = f"{day:%Y}"
        elif span >= 90:
            tick_text = f"{day:%b %Y}"
        else:
            tick_text = f"{day:%b %d}"
        x_ticks.append(
            f'<line x1="{x_pos:.1f}" y1="{top + plot_height}" '
            f'x2="{x_pos:.1f}" y2="{top + plot_height + 5}" class="tick-mark" />'
            f'<text x="{x_pos:.1f}" y="{top + plot_height + 27}" '
            f'text-anchor="middle" class="tick-label">{tick_text}</text>'
        )

    label = escape(repository)
    updated = escape(today.isoformat())
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc" style="background:#fff">
  <title id="title">{label} Star growth</title>
  <desc id="desc">{current_stars} GitHub stars as of {updated}</desc>
  <defs>
    <filter id="xkcdify" x="-4%" y="-4%" width="108%" height="108%">
      <feTurbulence type="fractalNoise" baseFrequency="0.025" numOctaves="2" seed="11" result="noise" />
      <feDisplacementMap in="SourceGraphic" in2="noise" scale="1.2" xChannelSelector="R" yChannelSelector="G" />
    </filter>
  </defs>
  <style>
    text {{ font-family: "Comic Sans MS", "Bradley Hand", "Segoe Print", cursive; fill: #000; }}
    .axis-line {{ fill: none; stroke: #000; stroke-width: 2; }}
    .tick-mark {{ stroke: #000; stroke-width: 1.5; }}
    .tick-label {{ font-size: 16px; }}
    .axis-title {{ font-size: 17px; }}
  </style>
  <rect width="{width}" height="{height}" fill="#fff" />
  <text x="50%" y="31" text-anchor="middle" font-size="20" font-weight="700">Star History</text>
  <rect x="{left + 8}" y="51" width="238" height="32" rx="5" fill="#fff" fill-opacity="0.9" stroke="#000" stroke-width="2" filter="url(#xkcdify)" />
  <rect x="{left + 15}" y="63" width="8" height="8" rx="2" fill="#dd4528" filter="url(#xkcdify)" />
  <text x="{left + 29}" y="72" font-size="15">{label}</text>
  <path d="M {left} {top} L {left} {top + plot_height} L {width - right} {top + plot_height}" class="axis-line" filter="url(#xkcdify)" />
  {''.join(y_ticks)}
  {''.join(x_ticks)}
  <path d="{line_path}" fill="none" stroke="#dd4528" stroke-width="3" stroke-linejoin="round" stroke-linecap="round" filter="url(#xkcdify)" />
  <text x="{left + plot_width / 2:.1f}" y="{height - 16}" text-anchor="middle" class="axis-title">Date</text>
  <text x="18" y="{top + plot_height / 2:.1f}" text-anchor="middle" class="axis-title" transform="rotate(-90 18 {top + plot_height / 2:.1f})">GitHub Stars</text>
  <text x="{width - right}" y="{height - 14}" text-anchor="end" font-size="11" fill="#999">Updated {updated}</text>
</svg>
'''


def main() -> int:
    token = os.environ.get("GITHUB_TOKEN")
    repository = os.environ.get("GITHUB_REPOSITORY")
    if not token or not repository:
        print("GITHUB_TOKEN and GITHUB_REPOSITORY are required", file=sys.stderr)
        return 2

    try:
        metadata = load_repository(repository, token)
        created = datetime.fromisoformat(
            str(metadata["created_at"]).replace("Z", "+00:00")
        ).date()
        current_stars = int(metadata["stargazers_count"])
        today = datetime.now(timezone.utc).date()
        values = dict(load_history())
        if not values and created < today:
            values[created] = 0
        values[today] = current_stars
        history = sorted(values.items())
        svg = build_svg(repository, created, history)
    except (KeyError, RuntimeError, urllib.error.URLError, ValueError) as error:
        print(f"Unable to generate star history: {error}", file=sys.stderr)
        return 1

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    save_history(history)
    OUTPUT.write_text(svg, encoding="utf-8")
    print(f"Wrote {OUTPUT} with {current_stars} stars")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
