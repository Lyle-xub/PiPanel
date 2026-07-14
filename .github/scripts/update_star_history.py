#!/usr/bin/env python3
"""Generate a self-hosted SVG chart from this repository's stargazers."""

from __future__ import annotations

import json
import math
import os
import sys
import urllib.error
import urllib.request
from collections import Counter
from datetime import date, datetime, timezone
from html import escape
from pathlib import Path


API_ROOT = "https://api.github.com"
OUTPUT = Path("docs/assets/star-history.svg")


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


def load_stars(repository: str, token: str) -> list[date]:
    dates: list[date] = []
    page = 1

    while True:
        result = github_get(
            f"/repos/{repository}/stargazers?per_page=100&page={page}",
            token,
            "application/vnd.github.star+json",
        )
        if not isinstance(result, list):
            raise RuntimeError("GitHub returned invalid stargazer data")

        for star in result:
            if not isinstance(star, dict) or not star.get("starred_at"):
                raise RuntimeError("Stargazer timestamps are unavailable")
            timestamp = str(star["starred_at"])
            dates.append(datetime.fromisoformat(timestamp.replace("Z", "+00:00")).date())

        if len(result) < 100:
            break
        page += 1

    return sorted(dates)


def nice_maximum(value: int) -> int:
    if value <= 5:
        return 5
    magnitude = 10 ** math.floor(math.log10(value))
    normalized = value / magnitude
    ceiling = 2 if normalized <= 2 else 5 if normalized <= 5 else 10
    return ceiling * magnitude


def build_svg(repository: str, created: date, stars: list[date]) -> str:
    width, height = 960, 480
    left, right, top, bottom = 76, 32, 88, 64
    plot_width = width - left - right
    plot_height = height - top - bottom
    today = datetime.now(timezone.utc).date()
    end = max(today, created)
    span = max((end - created).days, 1)

    daily = Counter(stars)
    points: list[tuple[date, int]] = [(created, 0)]
    cumulative = 0
    for day in sorted(daily):
        cumulative += daily[day]
        points.append((day, cumulative))
    if points[-1][0] != end:
        points.append((end, cumulative))

    y_max = nice_maximum(cumulative)

    def x(day: date) -> float:
        return left + ((day - created).days / span) * plot_width

    def y(value: int) -> float:
        return top + plot_height - (value / y_max) * plot_height

    line_points = " ".join(f"{x(day):.1f},{y(value):.1f}" for day, value in points)
    area_points = (
        f"{left},{top + plot_height} {line_points} "
        f"{x(points[-1][0]):.1f},{top + plot_height}"
    )

    y_grid: list[str] = []
    for index in range(6):
        value = round(y_max * index / 5)
        y_pos = y(value)
        y_grid.append(
            f'<line x1="{left}" y1="{y_pos:.1f}" x2="{width - right}" '
            f'y2="{y_pos:.1f}" class="grid" />'
            f'<text x="{left - 14}" y="{y_pos + 4:.1f}" text-anchor="end" '
            f'class="axis">{value}</text>'
        )

    x_grid: list[str] = []
    seen: set[date] = set()
    for index in range(5):
        day = created.fromordinal(created.toordinal() + round(span * index / 4))
        if day in seen:
            continue
        seen.add(day)
        x_pos = x(day)
        x_grid.append(
            f'<line x1="{x_pos:.1f}" y1="{top}" x2="{x_pos:.1f}" '
            f'y2="{top + plot_height}" class="grid" />'
            f'<text x="{x_pos:.1f}" y="{height - 30}" text-anchor="middle" '
            f'class="axis">{day:%Y-%m-%d}</text>'
        )

    label = escape(repository)
    updated = escape(today.isoformat())
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc">
  <title id="title">{label} Star growth</title>
  <desc id="desc">{cumulative} GitHub stars as of {updated}</desc>
  <defs>
    <linearGradient id="area" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#58a6ff" stop-opacity="0.38" />
      <stop offset="100%" stop-color="#58a6ff" stop-opacity="0.03" />
    </linearGradient>
  </defs>
  <style>
    text {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }}
    .grid {{ stroke: #30363d; stroke-width: 1; }}
    .axis {{ fill: #8b949e; font-size: 12px; }}
  </style>
  <rect width="{width}" height="{height}" rx="14" fill="#0d1117" />
  <text x="{left}" y="38" fill="#f0f6fc" font-size="20" font-weight="600">Star Growth</text>
  <text x="{left}" y="62" fill="#8b949e" font-size="13">{label}</text>
  <text x="{width - right}" y="44" fill="#f0f6fc" font-size="28" font-weight="700" text-anchor="end">★ {cumulative}</text>
  {''.join(y_grid)}
  {''.join(x_grid)}
  <polygon points="{area_points}" fill="url(#area)" />
  <polyline points="{line_points}" fill="none" stroke="#58a6ff" stroke-width="3" stroke-linejoin="round" stroke-linecap="round" />
  <circle cx="{x(points[-1][0]):.1f}" cy="{y(points[-1][1]):.1f}" r="5" fill="#58a6ff" stroke="#0d1117" stroke-width="2" />
  <text x="{width - right}" y="{height - 12}" fill="#6e7681" font-size="11" text-anchor="end">Updated {updated} UTC · GitHub Actions</text>
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
        stars = load_stars(repository, token)
        svg = build_svg(repository, created, stars)
    except (KeyError, RuntimeError, urllib.error.URLError, ValueError) as error:
        print(f"Unable to generate star history: {error}", file=sys.stderr)
        return 1

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(svg, encoding="utf-8")
    print(f"Wrote {OUTPUT} with {len(stars)} stars")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
