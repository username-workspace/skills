#!/usr/bin/env python3
"""Hook plumbing: hand the payload to conductor.py for the event named on the command line. All policy
lives in conductor.py."""
import os, subprocess, sys


def main():
    event = sys.argv[1] if len(sys.argv) > 1 else ""
    root = os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    script = os.path.join(root, "skills", "delivery-conductor", "scripts", "conductor.py")
    try:
        r = subprocess.run([sys.executable, script, "hook", "--event", event], input=sys.stdin.read(),
                           capture_output=True, text=True, timeout=290)
        if r.stdout.strip():
            sys.stdout.write(r.stdout)
    except Exception:
        pass


if __name__ == "__main__":
    main()
