#!/usr/bin/env python3
"""Static file server for the Flutter Web build with SPA fallback.

Serves mobile/build/web on :3001. Unknown extension-less paths (e.g.
/agent, /messages, /dm/x) fall back to index.html so path-based URLs
(usePathUrlStrategy) survive refresh and deep links.

Usage: python3 scripts/serve_web.py [port]
"""

import os
import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

BUILD_DIR = os.path.join(os.path.dirname(__file__), "..", "mobile", "build", "web")


class SpaRequestHandler(SimpleHTTPRequestHandler):
    def translate_path(self, path):
        translated = super().translate_path(path)
        if os.path.isdir(translated):
            index = os.path.join(translated, "index.html")
            if os.path.exists(index):
                return index
        if not os.path.exists(translated) and "." not in os.path.basename(path):
            return os.path.join(super().translate_path("/"), "index.html")
        return translated


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 3001
    root = os.path.abspath(BUILD_DIR)
    handler = partial(SpaRequestHandler, directory=root)
    server = ThreadingHTTPServer(("0.0.0.0", port), handler)
    print(f"Serving {root} on http://0.0.0.0:{port} (SPA fallback on)")
    server.serve_forever()


if __name__ == "__main__":
    main()
