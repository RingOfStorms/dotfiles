{
  constants,
  fleet,
  pkgs,
  ...
}:
let
  c = constants.services.mediaIntegrity;
  scanPaths = map (
    subdirectory: "${constants.services.nixarr.mediaDir}/${subdirectory}"
  ) c.scanSubdirectories;
  stateDirectory = builtins.baseNameOf c.dataDir;

  scanner = pkgs.writeScript "media-integrity-scan" ''
    #!${pkgs.python3}/bin/python3
    import datetime
    import html
    import json
    import math
    import os
    import pathlib
    import subprocess
    import sys
    import tempfile
    import time
    import traceback

    SCAN_ROOTS = ${builtins.toJSON scanPaths}
    EXTENSIONS = set(${builtins.toJSON c.extensions})
    REPORT_DIR = pathlib.Path(${builtins.toJSON c.dataDir})
    PER_FILE_TIMEOUT = ${toString c.perFileTimeoutSec}
    FFPROBE = ${builtins.toJSON "${pkgs.ffmpeg}/bin/ffprobe"}
    FFMPEG = ${builtins.toJSON "${pkgs.ffmpeg}/bin/ffmpeg"}
    AUXILIARY_VIDEO_DISPOSITIONS = ("attached_pic", "still_image", "timed_thumbnails")


    def utc_now():
        return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


    def atomic_write(path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8", errors="replace") as handle:
                handle.write(content)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary_name, 0o644)
            os.replace(temporary_name, path)
        except BaseException:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass
            raise


    def human_size(value):
        size = float(value)
        for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
            if size < 1024 or unit == "TiB":
                return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
            size /= 1024
        return f"{size:.1f} TiB"


    def human_duration(value):
        if value is None:
            return "—"
        seconds = int(round(value))
        hours, remainder = divmod(seconds, 3600)
        minutes, seconds = divmod(remainder, 60)
        if hours:
            return f"{hours:d}:{minutes:02d}:{seconds:02d}"
        return f"{minutes:d}:{seconds:02d}"


    def clipped_error(value, limit=12000):
        if value is None:
            return ""
        if isinstance(value, bytes):
            value = value.decode("utf-8", errors="replace")
        value = value.strip()
        if len(value) <= limit:
            return value
        return value[:limit] + "\n… output truncated …"


    def summarize_stream(stream):
        disposition = stream.get("disposition") or {}
        return {
            "index": stream["index"],
            "codec_type": stream.get("codec_type", "unknown"),
            "codec_name": stream.get("codec_name", "unknown"),
            "dispositions": sorted(name for name, enabled in disposition.items() if enabled),
        }


    def auxiliary_video_reasons(stream):
        if stream.get("codec_type") != "video":
            return []
        disposition = stream.get("disposition") or {}
        return [name for name in AUXILIARY_VIDEO_DISPOSITIONS if disposition.get(name)]


    def stream_description(stream):
        description = (
            f"stream #{stream.get('index', '?')}: "
            f"{stream.get('codec_type', 'unknown')}/{stream.get('codec_name', 'unknown')}"
        )
        dispositions = stream.get("dispositions", [])
        if dispositions:
            description += f" ({', '.join(dispositions)})"
        if stream.get("ignored_reason"):
            description += f" — ignored: {stream['ignored_reason']}"
        return description


    def render_html(state):
        results = state.get("results", [])
        passed = sum(result.get("status") == "passed" for result in results)
        failed = sum(result.get("status") in ("failed", "timeout") for result in results)
        completed = len(results)
        total = state.get("total_files", completed)
        pending = max(total - completed, 0)
        scan_errors = state.get("scan_errors", [])
        scan_status = state.get("status", "starting")

        if scan_status == "running":
            banner_class = "running"
            banner_text = f"Scan running — {completed} of {total} files checked"
        elif scan_status == "failed":
            banner_class = "failed"
            banner_text = "Scanner failed before all files could be checked"
        elif failed or scan_errors:
            banner_class = "failed"
            banner_text = f"Scan complete — {failed} file(s) need attention"
        else:
            banner_class = "passed"
            banner_text = "Scan complete — no integrity errors detected"

        document = ["""<!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="refresh" content="300">
      <title>Media Integrity Report</title>
      <style>
        :root { color-scheme: dark; font-family: system-ui, sans-serif; }
        body { margin: 0; background: #0b1017; color: #e5e7eb; }
        main { width: min(1500px, calc(100% - 2rem)); margin: 2rem auto; }
        h1 { margin-bottom: .25rem; }
        .muted { color: #9ca3af; }
        .banner { margin: 1.5rem 0; padding: 1rem 1.25rem; border-radius: .6rem; font-weight: 700; }
        .banner.passed { background: #064e3b; color: #a7f3d0; }
        .banner.failed { background: #7f1d1d; color: #fecaca; }
        .banner.running { background: #1e3a8a; color: #bfdbfe; }
        .summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: .75rem; margin: 1rem 0; }
        .card { background: #151d29; border: 1px solid #263244; border-radius: .6rem; padding: 1rem; }
        .card strong { display: block; margin-top: .25rem; font-size: 1.6rem; }
        .details { margin: 1rem 0; line-height: 1.6; }
        .errors { background: #3f1519; border: 1px solid #7f1d1d; border-radius: .6rem; padding: 1rem 1.25rem; }
        table { width: 100%; border-collapse: collapse; margin-top: 1.5rem; background: #111827; }
        th, td { padding: .7rem; border-bottom: 1px solid #263244; text-align: left; vertical-align: top; }
        th { position: sticky; top: 0; background: #1f2937; }
        tr.failed, tr.timeout { background: #2b1419; }
        .status { display: inline-block; border-radius: 999px; padding: .2rem .55rem; font-size: .8rem; font-weight: 700; text-transform: uppercase; }
        .status.passed { background: #064e3b; color: #a7f3d0; }
        .status.failed, .status.timeout { background: #7f1d1d; color: #fecaca; }
        code { overflow-wrap: anywhere; color: #dbeafe; }
        details { max-width: 35rem; }
        pre { white-space: pre-wrap; overflow-wrap: anywhere; color: #fecaca; }
        footer { margin: 2rem 0; color: #9ca3af; }
        @media (max-width: 900px) {
          table, thead, tbody, th, td, tr { display: block; }
          thead { display: none; }
          td { border-bottom: 0; padding: .35rem .7rem; }
          tr { padding: .5rem 0; border-bottom: 1px solid #374151; }
        }
      </style>
    </head>
    <body><main>
    """]
        document.append("<h1>Media Integrity Report</h1>")
        document.append(
            "<p class=\"muted\">Read-only ffprobe metadata validation and full FFmpeg audio/video decode. "
            "Attached pictures and thumbnail streams are inventoried but not decoded.</p>"
        )
        document.append(f"<div class=\"banner {banner_class}\">{html.escape(banner_text)}</div>")
        document.append("<section class=\"summary\">")
        for label, value in (("Discovered", total), ("Passed", passed), ("Failed", failed), ("Pending", pending)):
            document.append(f"<div class=\"card\"><span class=\"muted\">{label}</span><strong>{value}</strong></div>")
        document.append("</section>")

        details = [
            ("Started", state.get("started_at", "—")),
            ("Last update", state.get("updated_at", "—")),
            ("Finished", state.get("finished_at", "—")),
            ("Current file", state.get("current_file", "—") or "—"),
        ]
        document.append("<section class=\"card details\">")
        for label, value in details:
            document.append(f"<div><strong>{html.escape(label)}:</strong> <code>{html.escape(str(value))}</code></div>")
        roots = "<br>".join(f"<code>{html.escape(root)}</code>" for root in state.get("scan_roots", []))
        document.append(f"<div><strong>Scan roots:</strong><br>{roots}</div></section>")

        if scan_errors:
            document.append("<section class=\"errors\"><strong>Scanner errors</strong><ul>")
            for error in scan_errors:
                document.append(f"<li><code>{html.escape(error)}</code></li>")
            document.append("</ul></section>")

        document.append("""<table>
          <thead><tr><th>Status</th><th>File</th><th>Size</th><th>Duration</th><th>Streams</th><th>Decode time</th><th>Checked</th><th>Details</th></tr></thead>
          <tbody>""")
        ordered_results = sorted(
            results,
            key=lambda result: (result.get("status") == "passed", result.get("path", "").casefold()),
        )
        for result in ordered_results:
            status = result.get("status", "failed")
            path = html.escape(result.get("path", "unknown"))
            size = human_size(result.get("size_bytes", 0)) if result.get("size_bytes") is not None else "—"
            duration = human_duration(result.get("duration_seconds"))
            codecs = []
            if result.get("video_codecs"):
                codecs.append("video: " + ", ".join(result["video_codecs"]))
            if result.get("audio_codecs"):
                codecs.append("audio: " + ", ".join(result["audio_codecs"]))
            streams = html.escape("; ".join(codecs) or "—")
            elapsed = result.get("elapsed_seconds")
            elapsed_text = human_duration(elapsed) if elapsed is not None else "—"
            checked = html.escape(result.get("checked_at", "—"))
            error = result.get("error", "")
            details = []
            ignored_streams = result.get("ignored_streams", [])
            if ignored_streams:
                ignored_text = "\n".join(stream_description(stream) for stream in ignored_streams)
                details.append(
                    f"<details><summary>{len(ignored_streams)} auxiliary video stream(s) ignored</summary>"
                    f"<pre>{html.escape(ignored_text)}</pre></details>"
                )
            targeted_checks = result.get("targeted_checks", [])
            if targeted_checks:
                targeted_text = []
                for check in targeted_checks:
                    targeted_text.append(f"{stream_description(check)} — {check.get('status', 'failed')}")
                    if check.get("error"):
                        targeted_text.append(check["error"])
                details.append(
                    "<details><summary>Targeted stream verification</summary>"
                    f"<pre>{html.escape(chr(10).join(targeted_text))}</pre></details>"
                )
            if error:
                details.append(f"<details><summary>FFmpeg output</summary><pre>{html.escape(error)}</pre></details>")
            detail = "".join(details) or "—"
            document.append(
                f"<tr class=\"{status}\"><td><span class=\"status {status}\">{html.escape(status)}</span></td>"
                f"<td><code>{path}</code></td><td>{size}</td><td>{duration}</td><td>{streams}</td>"
                f"<td>{elapsed_text}</td><td>{checked}</td><td>{detail}</td></tr>"
            )
        document.append("""</tbody></table>
        <footer>
          FFmpeg reads each selected audio stream and non-auxiliary video stream from beginning to end and writes
          decoded output only to the null muxer. Attached pictures and thumbnails are reported but excluded.
          The scanner never writes to the media library. Raw results are available as <a href="results.json">results.json</a>.
        </footer>
        </main></body></html>
        """)
        return "".join(document)


    def write_state(state):
        state["updated_at"] = utc_now()
        atomic_write(REPORT_DIR / "results.json", json.dumps(state, indent=2, sort_keys=True) + "\n")
        atomic_write(REPORT_DIR / "index.html", render_html(state))


    def discover_files():
        files = {}
        errors = []

        def record_walk_error(error):
            errors.append(f"{error.filename}: {error.strerror}")

        for root_name in SCAN_ROOTS:
            root = pathlib.Path(root_name)
            if not root.is_dir():
                errors.append(f"scan root is unavailable or is not a directory: {root}")
                continue
            for directory, directory_names, file_names in os.walk(root, onerror=record_walk_error, followlinks=False):
                directory_names.sort()
                file_names.sort()
                for file_name in file_names:
                    if pathlib.Path(file_name).suffix.lower() not in EXTENSIONS:
                        continue
                    path = pathlib.Path(directory) / file_name
                    files[str(path)] = path
        return [files[name] for name in sorted(files, key=str.casefold)], errors


    def run_command(command):
        return subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=PER_FILE_TIMEOUT,
            check=False,
        )


    def decode_command(path, streams):
        command = [
            FFMPEG,
            "-nostdin",
            "-hide_banner",
            "-v", "error",
            "-xerror",
            "-i", str(path),
        ]
        for stream in streams:
            command.extend(["-map", f"0:{stream['index']}"])
        command.extend([
            "-sn",
            "-dn",
            "-f", "null",
            "-",
        ])
        return command


    def targeted_stream_check(path, stream):
        started = time.monotonic()
        result = dict(stream)
        result.update({"status": "failed", "error": ""})
        try:
            decode = run_command(decode_command(path, [stream]))
            if decode.returncode != 0:
                result["error"] = clipped_error(
                    decode.stderr or decode.stdout or "FFmpeg stream decode failed without output"
                )
                return result
            result["status"] = "passed"
            return result
        except subprocess.TimeoutExpired as error:
            result["status"] = "timeout"
            output = clipped_error(error.stderr or error.stdout)
            result["error"] = f"stream check exceeded {PER_FILE_TIMEOUT} seconds"
            if output:
                result["error"] += "\n" + output
            return result
        except (OSError, ValueError) as error:
            result["error"] = f"{type(error).__name__}: {error}"
            return result
        finally:
            result["elapsed_seconds"] = round(time.monotonic() - started, 3)


    def check_file(path):
        started = time.monotonic()
        result = {
            "path": str(path),
            "status": "failed",
            "checked_at": utc_now(),
            "size_bytes": None,
            "duration_seconds": None,
            "video_codecs": [],
            "audio_codecs": [],
            "decoded_streams": [],
            "ignored_streams": [],
            "targeted_checks": [],
            "error": "",
        }
        try:
            result["size_bytes"] = path.stat().st_size
            probe = run_command([
                FFPROBE,
                "-v", "error",
                "-show_error",
                "-show_format",
                "-show_streams",
                "-of", "json",
                str(path),
            ])
            if probe.returncode != 0:
                result["error"] = clipped_error(probe.stderr or probe.stdout or "ffprobe failed without output")
                return result
            try:
                metadata = json.loads(probe.stdout)
            except json.JSONDecodeError as error:
                result["error"] = f"ffprobe returned invalid JSON: {error}\n{clipped_error(probe.stdout)}"
                return result

            if metadata.get("error"):
                result["error"] = "ffprobe reported an error: " + json.dumps(metadata["error"], sort_keys=True)
                return result

            streams = metadata.get("streams", [])
            decoded_streams = []
            ignored_streams = []
            for stream in streams:
                if stream.get("codec_type") not in ("audio", "video"):
                    continue
                summary = summarize_stream(stream)
                ignored_reasons = auxiliary_video_reasons(stream)
                if ignored_reasons:
                    summary["ignored_reason"] = "auxiliary video disposition: " + ", ".join(ignored_reasons)
                    ignored_streams.append(summary)
                else:
                    decoded_streams.append(summary)

            result["decoded_streams"] = decoded_streams
            result["ignored_streams"] = ignored_streams
            result["video_codecs"] = sorted({
                stream["codec_name"] for stream in decoded_streams if stream["codec_type"] == "video"
            })
            result["audio_codecs"] = sorted({
                stream["codec_name"] for stream in decoded_streams if stream["codec_type"] == "audio"
            })
            duration_value = metadata.get("format", {}).get("duration")
            if duration_value is not None:
                try:
                    duration = float(duration_value)
                    if math.isfinite(duration) and duration >= 0:
                        result["duration_seconds"] = duration
                except (TypeError, ValueError):
                    pass

            if not decoded_streams:
                result["error"] = "ffprobe found no audio or non-auxiliary video streams"
                return result

            decode = run_command(decode_command(path, decoded_streams))
            if decode.returncode != 0:
                result["error"] = clipped_error(decode.stderr or decode.stdout or "FFmpeg decode failed without output")
                for stream in decoded_streams:
                    check = targeted_stream_check(path, stream)
                    result["targeted_checks"].append(check)
                    if check["status"] != "passed":
                        break
                return result

            result["status"] = "passed"
            return result
        except subprocess.TimeoutExpired as error:
            result["status"] = "timeout"
            output = clipped_error(error.stderr or error.stdout)
            result["error"] = f"integrity check exceeded {PER_FILE_TIMEOUT} seconds"
            if output:
                result["error"] += "\n" + output
            return result
        except (OSError, ValueError) as error:
            result["error"] = f"{type(error).__name__}: {error}"
            return result
        finally:
            result["elapsed_seconds"] = round(time.monotonic() - started, 3)


    def main():
        state = {
            "schema_version": 2,
            "status": "running",
            "started_at": utc_now(),
            "finished_at": None,
            "updated_at": None,
            "current_file": None,
            "scan_roots": SCAN_ROOTS,
            "scan_errors": [],
            "total_files": 0,
            "results": [],
        }
        write_state(state)

        try:
            files, discovery_errors = discover_files()
            state["scan_errors"] = discovery_errors
            state["total_files"] = len(files)
            write_state(state)
            print(f"media-integrity: discovered {len(files)} media file(s)", flush=True)

            if discovery_errors and not files:
                state["status"] = "failed"
                state["finished_at"] = utc_now()
                write_state(state)
                for error in discovery_errors:
                    print(f"media-integrity: {error}", file=sys.stderr, flush=True)
                return 1

            for position, path in enumerate(files, start=1):
                state["current_file"] = str(path)
                write_state(state)
                print(f"media-integrity: [{position}/{len(files)}] checking {path}", flush=True)
                result = check_file(path)
                state["results"].append(result)
                write_state(state)
                if result["status"] != "passed":
                    print(f"media-integrity: {result['status']}: {path}", file=sys.stderr, flush=True)

            state["status"] = "completed"
            state["current_file"] = None
            state["finished_at"] = utc_now()
            write_state(state)
            failed = sum(result["status"] != "passed" for result in state["results"])
            print(f"media-integrity: scan complete; {len(files) - failed} passed, {failed} failed", flush=True)
            return 1 if discovery_errors else 0
        except BaseException as error:
            state["status"] = "failed"
            state["current_file"] = None
            state["finished_at"] = utc_now()
            state["scan_errors"].append(f"{type(error).__name__}: {error}")
            state["scanner_traceback"] = traceback.format_exc()
            write_state(state)
            raise


    if __name__ == "__main__":
        sys.exit(main())
  '';
in
{
  users.groups.media-integrity = { };
  users.users.media-integrity = {
    isSystemUser = true;
    group = "media-integrity";
    extraGroups = [ "media" ];
  };

  systemd.services.media-integrity-scan = {
    description = "Read-only FFmpeg media integrity scan";
    wants = [
      "autofs.service"
      "network-online.target"
    ];
    after = [
      "autofs.service"
      "network-online.target"
    ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = scanner;
      User = "media-integrity";
      Group = "media-integrity";
      SupplementaryGroups = [ "media" ];
      StateDirectory = stateDirectory;
      StateDirectoryMode = "0755";
      UMask = "0022";
      TimeoutStartSec = "infinity";

      Nice = 19;
      IOSchedulingClass = "idle";
      CPUWeight = 10;
      IOWeight = 10;

      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadOnlyPaths = map (path: "-${path}") scanPaths;
      NoNewPrivileges = true;
      LockPersonality = true;
      RestrictSUIDSGID = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
    };
  };

  systemd.timers.media-integrity-scan = {
    description = "Run the read-only media integrity scan weekly";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnActiveSec = "15m";
      OnCalendar = c.onCalendar;
      Persistent = true;
      RandomizedDelaySec = c.randomizedDelay;
      Unit = "media-integrity-scan.service";
    };
  };

  services.nginx.virtualHosts."h001.net.${fleet.global.domain}".locations."${c.webPath}" = {
    alias = "${c.dataDir}/";
    extraConfig = ''
      index index.html;
      autoindex off;
      add_header Cache-Control "no-store" always;
      add_header X-Content-Type-Options "nosniff" always;
    '';
  };
}
