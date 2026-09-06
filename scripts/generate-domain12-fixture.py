#!/usr/bin/env python3
"""Generate the Domain 12 concurrency reference from pinned Python code.

The supplied Python checkout identifies the source-of-truth repository. The
probe executes an isolated archive of the baseline recorded in the Services
fixture manifest, so local Python edits cannot alter the result.
"""

from __future__ import annotations

import argparse
import asyncio
import importlib
import io
import json
import logging
import sys
import tarfile
import tempfile
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import Protocol, TypedDict, Unpack, cast

import yaml


@dataclass(frozen=True)
class UnitInput:
    identifier: str
    artist: str
    album: str
    delay_milliseconds: int
    failure_kind: str | None = None


@dataclass(frozen=True)
class Limits:
    artist: int
    music_app: int
    album_workflows: int


@dataclass(frozen=True)
class ConcurrencyInput:
    identifier: str
    description: str
    limits: Limits
    units: tuple[UnitInput, ...]


CONCURRENCY_CASES = (
    ConcurrencyInput(
        identifier="reverse_completion",
        description=(
            "Five independent artist-album units complete out of order under "
            "a limit of two"
        ),
        limits=Limits(artist=2, music_app=3, album_workflows=4),
        units=(
            UnitInput("A", "Björk", "Debut", 80),
            UnitInput("B", "Massive Attack", "Mezzanine", 10),
            UnitInput("C", "Portishead", "Dummy", 60),
            UnitInput("D", "Tricky", "Maxinquaye", 5),
            UnitInput("E", "Goldfrapp", "Felt Mountain", 20),
        ),
    ),
    ConcurrencyInput(
        identifier="isolated_failure",
        description="One failed unit does not suppress unrelated metadata proposals",
        limits=Limits(artist=3, music_app=2, album_workflows=4),
        units=(
            UnitInput("F", "Fever Ray", "Fever Ray", 30),
            UnitInput("G", "Goldie", "Timeless", 5, failure_kind="writeEligibility"),
            UnitInput("H", "Hooverphonic", "A New Stereophonic Sound Spectacular", 15),
        ),
    ),
    ConcurrencyInput(
        identifier="unclassified_failure",
        description="An unclassified unit failure remains visible instead of saving a partial plan",
        limits=Limits(artist=3, music_app=2, album_workflows=4),
        units=(
            UnitInput("I", "Iamamiwhoami", "Kin", 30),
            UnitInput("J", "Jessie Ware", "Devotion", 5, failure_kind="unclassified"),
            UnitInput("K", "Kelly Lee Owens", "Inner Song", 15),
        ),
    ),
)


@dataclass(frozen=True)
class OrchestrationInput:
    identifier: str
    description: str
    trigger: str
    swift_mode: str
    automation: str
    python_dry_run: bool


ORCHESTRATION_CASES = (
    OrchestrationInput(
        "manual_preview",
        "A manual preview runs the full metadata pipeline without writing",
        "manualCheck",
        "preview",
        "manualOnly",
        True,
    ),
    OrchestrationInput(
        "manual_write",
        "A manual write request runs the full metadata pipeline",
        "manualCheck",
        "autoFix",
        "manualOnly",
        False,
    ),
    OrchestrationInput(
        "scheduled_preview",
        "A scheduled preview produces a full plan without writing",
        "backgroundSync",
        "preview",
        "scheduled",
        False,
    ),
    OrchestrationInput(
        "scheduled_write",
        "A scheduled Auto-fix run applies its full plan",
        "backgroundSync",
        "autoFix",
        "scheduled",
        False,
    ),
    OrchestrationInput(
        "watch_preview",
        "A library-change preview produces a full plan without writing",
        "fileSystemEvent",
        "preview",
        "libraryChange",
        False,
    ),
    OrchestrationInput(
        "watch_write",
        "A library-change Auto-fix run applies its full plan",
        "fileSystemEvent",
        "autoFix",
        "libraryChange",
        False,
    ),
)


class GenreConfiguration(Protocol):
    concurrent_limit: int


class RateLimits(Protocol):
    concurrent_api_calls: int


class YearRetrieval(Protocol):
    rate_limits: RateLimits


class DevelopmentConfiguration(Protocol):
    test_artists: list[str]


class AppConfiguration(Protocol):
    apple_script_concurrency: int
    genre_update: GenreConfiguration
    year_retrieval: YearRetrieval
    development: DevelopmentConfiguration


class Track(Protocol):
    id: str


class ConfigurationType(Protocol):
    def model_validate(self, value: object) -> AppConfiguration: ...


class TrackFields(TypedDict):
    id: str
    name: str
    artist: str
    album: str
    genre: str
    year: str


class TrackFactory(Protocol):
    def __call__(self, **fields: Unpack[TrackFields]) -> Track: ...


class GenreManager(Protocol):
    async def update_genres_by_artist_async(
        self,
        tracks: list[Track],
        *,
        force: bool,
    ) -> tuple[list[Track], list[object]]: ...


class GenreManagerFactory(Protocol):
    def __call__(
        self,
        *,
        track_processor: object,
        console_logger: logging.Logger,
        error_logger: logging.Logger,
        analytics: object,
        config: AppConfiguration,
    ) -> GenreManager: ...


class OrchestratorCommand(Protocol):
    async def __call__(self, instance: object, arguments: object) -> None: ...


def completed_future() -> asyncio.Future[None]:
    future = asyncio.get_running_loop().create_future()
    future.set_result(None)
    return future


class PipelineProbe:
    def __init__(self) -> None:
        self.dry_run_mode: str | None = None
        self.pipeline_calls: list[dict[str, bool]] = []

    def set_dry_run_context(self, mode: str, _artists: set[str]) -> None:
        self.dry_run_mode = mode

    def run_main_pipeline(
        self,
        *,
        force: bool,
        fresh: bool,
    ) -> asyncio.Future[None]:
        self.pipeline_calls.append({"force": force, "fresh": fresh})
        return completed_future()


class ConcurrencyProbe:
    def __init__(self, replay_case: ConcurrencyInput) -> None:
        self.case = replay_case
        self.active = 0
        self.maximum_active = 0

    async def process(
        self,
        artist_name: str,
        all_artist_tracks: list[Track],
        _force_update: bool,
        _applescript_semaphore: asyncio.Semaphore,
        tracks_to_update: list[Track] | None = None,
    ) -> tuple[list[Track], list[object]]:
        track_ids = {track.id for track in all_artist_tracks}
        units = [unit for unit in self.case.units if unit.identifier in track_ids]
        if len(units) != 1:
            raise RuntimeError(
                f"expected one scripted unit for artist {artist_name!r}, "
                f"found track IDs {sorted(track_ids)}"
            )
        unit = units[0]
        self.active += 1
        self.maximum_active = max(self.maximum_active, self.active)
        try:
            await asyncio.sleep(unit.delay_milliseconds / 1000)
            if unit.failure_kind is not None:
                raise RuntimeError(f"scripted failure for {unit.identifier}")
            return tracks_to_update or [], []
        finally:
            self.active -= 1


async def git_bytes(python_root: Path, *arguments: str) -> bytes:
    process = await asyncio.create_subprocess_exec(
        "git",
        "-C",
        str(python_root),
        *arguments,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await process.communicate()
    if process.returncode != 0:
        raise RuntimeError(
            f"git {' '.join(arguments)} failed: {stderr.decode().strip()}"
        )
    return stdout


async def git_output(python_root: Path, *arguments: str) -> str:
    return (await git_bytes(python_root, *arguments)).decode().strip()


async def verify_python_checkout(
    python_root: Path,
    expected_baseline: str,
) -> str:
    baseline = await git_output(python_root, "rev-parse", "HEAD")
    if baseline != expected_baseline:
        raise RuntimeError(
            f"Python baseline mismatch: expected {expected_baseline}, found {baseline}"
        )
    return baseline


def imported_attribute(module_name: str, attribute_name: str) -> object:
    return getattr(importlib.import_module(module_name), attribute_name)


def configuration(root: Path) -> AppConfiguration:
    configuration_type = cast(
        ConfigurationType,
        imported_attribute("core.models.track_models", "AppConfig"),
    )
    return configuration_type.model_validate(
        yaml.safe_load((root / "config.yaml").read_text(encoding="utf-8"))
    )


async def execute_case(
    replay_case: ConcurrencyInput,
    root: Path,
) -> dict[str, object]:
    current_configuration = configuration(root)
    current_configuration.genre_update.concurrent_limit = replay_case.limits.artist
    current_configuration.apple_script_concurrency = replay_case.limits.music_app
    current_configuration.year_retrieval.rate_limits.concurrent_api_calls = (
        replay_case.limits.album_workflows
    )
    track_factory = cast(
        TrackFactory,
        imported_attribute("core.models.track_models", "TrackDict"),
    )
    manager_factory = cast(
        GenreManagerFactory,
        imported_attribute("core.tracks.genre_manager", "GenreManager"),
    )
    logger = logging.getLogger(f"domain12.{replay_case.identifier}")
    logger.addHandler(logging.NullHandler())
    logger.propagate = False
    manager = manager_factory(
        track_processor=object(),
        console_logger=logger,
        error_logger=logger,
        analytics=object(),
        config=current_configuration,
    )
    probe = ConcurrencyProbe(replay_case)
    setattr(manager, "_process_artist_genres", probe.process)
    tracks = [
        track_factory(
            id=unit.identifier,
            name=f"Track {unit.identifier}",
            artist=unit.artist,
            album=unit.album,
            genre="Rock",
            year="",
        )
        for unit in replay_case.units
    ]

    updated_tracks, _ = await manager.update_genres_by_artist_async(
        tracks,
        force=True,
    )
    swift_maximum_active = min(
        replay_case.limits.artist,
        replay_case.limits.music_app,
        replay_case.limits.album_workflows,
    )
    divergences: list[dict[str, str]] = []
    if probe.maximum_active != swift_maximum_active:
        divergences.append(
            {
                "field": "maximumActive",
                "pythonValue": str(probe.maximum_active),
                "swiftValue": str(swift_maximum_active),
                "reason": (
                    "Swift plan units cover genre and year determination, so admission "
                    "uses the tightest configured artist, Music.app, and album-workflow limit."
                ),
            }
        )
    has_unclassified_failure = any(
        unit.failure_kind == "unclassified" for unit in replay_case.units
    )
    if has_unclassified_failure:
        divergences.append(
            {
                "field": "failureDisposition",
                "pythonValue": "continue",
                "swiftValue": "abort",
                "reason": (
                    "Python logs and drops arbitrary unit errors; Swift only isolates "
                    "classified write-eligibility failures and aborts unknown plan errors."
                ),
            }
        )
    return {
        "kind": "concurrency",
        "id": replay_case.identifier,
        "description": replay_case.description,
        "input": {
            "limits": {
                "artist": replay_case.limits.artist,
                "musicApp": replay_case.limits.music_app,
                "albumWorkflows": replay_case.limits.album_workflows,
            },
            "units": [
                {
                    "id": unit.identifier,
                    "artist": unit.artist,
                    "album": unit.album,
                    "delayMilliseconds": unit.delay_milliseconds,
                    "failureKind": unit.failure_kind,
                }
                for unit in replay_case.units
            ],
        },
        "expected": {
            "pythonMaximumActive": probe.maximum_active,
            "swiftMaximumActive": swift_maximum_active,
            "pythonProposalOrder": [track.id for track in updated_tracks],
            "swiftDisposition": "abort" if has_unclassified_failure else "continue",
        },
        "divergences": divergences,
    }


async def execute_orchestration_case(
    replay_case: OrchestrationInput,
    root: Path,
) -> dict[str, object]:
    secure_config = ModuleType("stubs.cryptography.secure_config")

    class SecurityConfigError(Exception):
        pass

    setattr(secure_config, "SecureConfig", object)
    setattr(secure_config, "SecurityConfigError", SecurityConfigError)
    sys.modules[secure_config.__name__] = secure_config
    orchestrator_module = importlib.import_module("app.orchestrator")
    orchestrator_type = cast(
        type[object],
        getattr(orchestrator_module, "Orchestrator"),
    )
    command = cast(
        OrchestratorCommand,
        getattr(orchestrator_type, "run_command"),
    )
    current_configuration = configuration(root)
    current_configuration.development.test_artists = []
    logger = logging.getLogger(f"domain12.{replay_case.identifier}")
    logger.addHandler(logging.NullHandler())
    logger.propagate = False
    pipeline = PipelineProbe()
    orchestrator = object.__new__(orchestrator_type)
    setattr(orchestrator, "config", current_configuration)
    setattr(orchestrator, "console_logger", logger)
    setattr(orchestrator, "error_logger", logger)
    setattr(orchestrator, "music_updater", pipeline)

    def skip_maintenance() -> asyncio.Future[None]:
        return completed_future()

    setattr(orchestrator, "_maybe_auto_verify", skip_maintenance)
    setattr(orchestrator, "_maybe_auto_verify_pending", skip_maintenance)
    original_music_check = getattr(orchestrator_module, "is_music_app_running")
    original_reset = getattr(orchestrator_module, "reset_cleaning_exceptions_log")
    setattr(orchestrator_module, "is_music_app_running", lambda _logger: True)
    setattr(orchestrator_module, "reset_cleaning_exceptions_log", lambda: None)
    try:
        await command(
            orchestrator,
            SimpleNamespace(
                command=None,
                dry_run=replay_case.python_dry_run,
                test_mode=False,
                force=False,
                fresh=False,
            ),
        )
    finally:
        setattr(orchestrator_module, "is_music_app_running", original_music_check)
        setattr(orchestrator_module, "reset_cleaning_exceptions_log", original_reset)

    swift_writes = 1 if replay_case.swift_mode == "autoFix" else 0
    swift_intents = ["previewFixes"]
    if swift_writes == 1:
        swift_intents.append("writeFixes")
    python_preview = pipeline.dry_run_mode == "dry_run"
    swift_preview = replay_case.swift_mode == "preview"
    divergences = []
    if python_preview != swift_preview:
        divergences.append(
            {
                "field": "mode",
                "reason": (
                    "Python launchd runs write by default; Swift preserves the user's "
                    "explicit automation preview mode."
                ),
            }
        )
    if len(pipeline.pipeline_calls) != 1:
        raise RuntimeError(
            f"expected one Python pipeline call, found {len(pipeline.pipeline_calls)}"
        )
    pipeline_call = pipeline.pipeline_calls[0]
    return {
        "kind": "orchestration",
        "id": replay_case.identifier,
        "description": replay_case.description,
        "input": {
            "trigger": replay_case.trigger,
            "swiftMode": replay_case.swift_mode,
            "automation": replay_case.automation,
            "pythonDryRun": replay_case.python_dry_run,
        },
        "pythonExpected": {
            "pipelineRuns": len(pipeline.pipeline_calls),
            "dryRunMode": pipeline.dry_run_mode,
            "force": pipeline_call.get("force"),
            "fresh": pipeline_call.get("fresh"),
        },
        "swiftExpected": {
            "persistedIntents": swift_intents,
            "terminalIntent": swift_intents[-1],
            "writeCount": swift_writes,
        },
        "divergences": divergences,
    }


async def build_fixture(root: Path, baseline: str) -> dict[str, object]:
    sys.path.insert(0, str(root))
    sys.path.insert(0, str(root / "src"))
    return {
        "schemaVersion": 1,
        "pythonBaseline": baseline,
        "cases": [
            *[
                await execute_case(replay_case, root)
                for replay_case in CONCURRENCY_CASES
            ],
            *[
                await execute_orchestration_case(replay_case, root)
                for replay_case in ORCHESTRATION_CASES
            ],
        ],
    }


async def generate(python_root: Path, expected_baseline: str) -> dict[str, object]:
    baseline = await verify_python_checkout(python_root, expected_baseline)
    archive = await git_bytes(
        python_root,
        "archive",
        "--format=tar",
        expected_baseline,
    )
    with tempfile.TemporaryDirectory(prefix="genre-updater-domain12-") as directory:
        source_root = Path(directory)
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as source_archive:
            source_archive.extractall(source_root, filter="data")
        fixture = await build_fixture(source_root, baseline)

    if await verify_python_checkout(python_root, expected_baseline) != baseline:
        raise RuntimeError("Python HEAD changed during fixture generation")
    return fixture


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python-root", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    python_root = arguments.python_root.resolve(strict=True)
    manifest = json.loads(
        arguments.manifest.resolve(strict=True).read_text(encoding="utf-8")
    )
    expected_baseline = str(manifest["pythonBaseline"])
    fixture = asyncio.run(generate(python_root, expected_baseline))
    output = arguments.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(fixture, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {output}")


if __name__ == "__main__":
    main()
