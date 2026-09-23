#!/usr/bin/env python3
"""Run matched HTTP/1.1 smoke or longer repeated benchmarks.

Build both release binaries first; see bench/README.md. Results are written as
JSON including the complete oha output. Server processes are restarted per run.
"""
import argparse
import hashlib
import json
import os
import platform
import random
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def version(command):
    try:
        return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        return str(error)


def sha256(path):
    if not path.is_file():
        return "missing"
    return hashlib.sha256(path.read_bytes()).hexdigest()


def request(port, path):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=2) as response:
        return response.status, response.read().decode("utf-8"), dict(response.headers)


def run_oha(port, path, duration, connections):
    command = ["oha", "--no-tui", "--http-version", "1.1", "--output-format", "json",
               "-z", duration, "-c", str(connections),
               f"http://127.0.0.1:{port}{path}"]
    result = subprocess.run(command, text=True, capture_output=True, check=True)
    return {"command": command, "result": json.loads(result.stdout), "stderr": result.stderr}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration", default="10s", help="oha measured duration, e.g. 60s")
    parser.add_argument("--warmup", default="3s", help="oha warmup duration")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--connections", type=int, default=32)
    parser.add_argument("--port", type=int, default=38121)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--modes", nargs="+", choices=("action-controller", "baseline", "bare", "ohkami"),
                        default=["action-controller", "bare", "ohkami"])
    parser.add_argument("--paths", nargs="+", choices=("/plain", "/user/abc", "/json", "/json-buffered", "/json-large"),
                        default=["/plain", "/user/abc"], help="paths to benchmark")
    parser.add_argument("--crystal-binary", type=Path, default=ROOT / "bench" / "bin" / "http",
                        help="override the Action Controller/bare HTTP binary for before/after runs")
    parser.add_argument("--baseline-binary", type=Path,
                        help="previous Action Controller binary; select it with --modes baseline")
    parser.add_argument("--output", type=Path, default=ROOT / "bench" / "results.json")
    args = parser.parse_args()
    if args.repeats < 1 or args.connections < 1:
        parser.error("repeats and connections must be positive")
    if shutil.which("oha") is None:
        parser.error("oha is required; install it before running this suite")

    crystal_binary = args.crystal_binary.resolve()
    baseline_binary = args.baseline_binary.resolve() if args.baseline_binary else None
    ohkami_binary = ROOT / "bench" / "ohkami" / "target" / "release" / "action-controller-ohkami-bench"
    if "baseline" in args.modes and baseline_binary is None:
        parser.error("--baseline-binary is required when --modes includes baseline")
    for mode in args.modes:
        binary = ohkami_binary if mode == "ohkami" else baseline_binary if mode == "baseline" else crystal_binary
        if not binary.is_file():
            parser.error(f"missing {binary}; build release binaries first")

    results = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "host": platform.uname()._asdict(),
        "cpu_count": os.cpu_count(),
        "cpu_model": version(["sysctl", "-n", "machdep.cpu.brand_string"])
                     if sys.platform == "darwin" else "see /proc/cpuinfo",
        "crystal": version(["crystal", "--version"]),
        "rustc": version(["rustc", "--version"]),
        "oha": version(["oha", "--version"]),
        "git_head": version(["git", "-C", str(ROOT), "rev-parse", "HEAD"]),
        "ohkami_git_head": version(["git", "-C", str(ROOT.parent / "ohkami"), "rev-parse", "HEAD"]),
        "git_status": version(["git", "-C", str(ROOT), "status", "--short"]),
        "shard_lock_sha256": sha256(ROOT / "shard.lock"),
        "lucky_matcher_sha256": sha256(ROOT / "lib" / "lucky_router" / "src" / "lucky_router" / "matcher.cr"),
        "cargo_lock_sha256": sha256(ROOT / "bench" / "ohkami" / "Cargo.lock"),
        "settings": vars(args) | {"output": str(args.output),
                                    "crystal_binary": str(crystal_binary),
                                    "baseline_binary": str(baseline_binary) if baseline_binary else None},
        "runs": [],
    }
    order = [(mode, path) for mode in args.modes for path in args.paths]
    randomizer = random.Random(args.seed)
    try:
        for repeat in range(args.repeats):
            randomizer.shuffle(order)
            for mode, path in order:
                binary = ohkami_binary if mode == "ohkami" else baseline_binary if mode == "baseline" else crystal_binary
                server_mode = "action-controller" if mode == "baseline" else mode
                command = [str(binary), str(args.port)] if mode == "ohkami" else [str(binary), server_mode, str(args.port)]
                process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                try:
                    for _ in range(100):
                        if process.poll() is not None:
                            raise RuntimeError(f"server exited: {process.stderr.read().decode()}")
                        try:
                            status, body, headers = request(args.port, path)
                            break
                        except (OSError, urllib.error.URLError):
                            time.sleep(0.05)
                    else:
                        raise RuntimeError(f"server did not start: {command}")
                    expected = {"/plain": "OK", "/user/abc": "abc",
                                "/json": '{"message":"Hello, world!"}',
                                "/json-buffered": '{"message":"Hello, world!"}',
                                "/json-large": '{"data":"' + 'x' * 100_000 + '"}'}[path]
                    if (status, body) != (200, expected):
                        raise RuntimeError(f"unexpected response: status={status}, bytes={len(body)}, sha256={hashlib.sha256(body.encode()).hexdigest()}")
                    run_oha(args.port, path, args.warmup, args.connections)
                    measured = run_oha(args.port, path, args.duration, args.connections)
                    results["runs"].append({"repeat": repeat, "mode": mode, "path": path,
                                            "server_command": command, "validated_headers": headers,
                                            **measured})
                    print(f"{repeat + 1}/{args.repeats} {mode} {path}: complete", flush=True)
                finally:
                    process.terminate()
                    try:
                        process.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.communicate()
    finally:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(results, indent=2, default=str) + "\n")
        print(f"Wrote {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
