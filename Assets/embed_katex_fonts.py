#!/usr/bin/env python3
"""Generate Sources/wtmd/Resources/katex-embedded.min.css.

Rewrites katex.min.css so every @font-face src uses only the woff2 file,
inlined as a base64 data URI. The result is fully self-contained: preview,
HTML export and PDF all embed the same stylesheet with zero network access.

Usage:
    python3 Assets/embed_katex_fonts.py <katex.min.css> <fonts-dir> <out.css>

Source: KaTeX 0.16.22 (MIT license, https://katex.org). The license header
of katex.min.css is preserved by this script.
"""
import base64
import re
import sys
from pathlib import Path


def main() -> None:
    css_path, fonts_dir, out_path = (Path(a) for a in sys.argv[1:4])
    css = css_path.read_text(encoding="utf-8")

    def inline(match: re.Match) -> str:
        name = match.group(1)
        font = (fonts_dir / name).read_bytes()
        data = base64.b64encode(font).decode("ascii")
        return f'url(data:font/woff2;base64,{data}) format("woff2")'

    # Each font face lists woff2, woff and ttf; keep only woff2, inlined.
    pattern = re.compile(r'url\(fonts/([A-Za-z0-9_-]+\.woff2)\) format\("woff2"\)')
    result, count = pattern.subn(inline, css)
    # Drop leftover woff/ttf fallbacks so no external reference remains.
    result = re.sub(r',url\(fonts/[A-Za-z0-9_-]+\.woff\) format\("woff"\)', "", result)
    result = re.sub(r',url\(fonts/[A-Za-z0-9_-]+\.ttf\) format\("truetype"\)', "", result)

    if "url(fonts/" in result:
        sys.exit("error: external font reference left behind")
    header = (
        f"/* KaTeX 0.16.22 fonts, inlined as base64 woff2 ({count} faces) "
        f"by Assets/embed_katex_fonts.py. KaTeX is MIT-licensed. */\n"
    )
    out_path.write_text(header + result, encoding="utf-8")
    print(f"ok: {count} fonts inlined -> {out_path} ({out_path.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
