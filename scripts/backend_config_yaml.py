"""Bounded, duplicate-free YAML input; never expose declaration values in errors."""

from pathlib import Path
import stat

import yaml
from yaml.nodes import MappingNode, Node


class ConfigError(ValueError):
    """Invalid or unreadable backend configuration (safe for CLI diagnostics)."""


class DeclarationLoader(yaml.SafeLoader):
    """No aliases/merges or non-string/duplicate keys in this small contract."""

    def compose_node(self, parent: Node | None, index: object) -> Node:
        if self.check_event(yaml.AliasEvent):
            raise ConfigError("YAML aliases are unsupported")
        if getattr(self.peek_event(), "tag", None) is not None:
            raise ConfigError("explicit YAML tags are unsupported")
        if self.depth >= 20:
            raise ConfigError("YAML nesting exceeds 20 levels")
        self.depth += 1
        try:
            return super().compose_node(parent, index)
        finally:
            self.depth -= 1

    def __init__(self, stream: str) -> None:
        super().__init__(stream)
        self.depth = 0

    def construct_mapping(self, node: MappingNode, deep: bool = False) -> dict:
        keys: set[str] = set()
        for key, _ in node.value:
            if key.tag != "tag:yaml.org,2002:str":
                raise ConfigError(
                    "YAML mapping keys must be strings; merges unsupported"
                )
            if key.value in keys:
                raise ConfigError("duplicate YAML key")
            keys.add(key.value)
        return super().construct_mapping(node, deep=deep)


def read_yaml(path: Path) -> object:
    """Read one regular UTF-8 YAML document, at most 64 KiB."""
    try:
        mode = path.stat().st_mode
        if not stat.S_ISREG(mode) or not mode & 0o444:
            raise ConfigError("configuration must be a readable regular file")
        with path.open("rb") as stream:
            payload = stream.read(65537)
        if len(payload) > 65536:
            raise ConfigError("configuration exceeds 64 KiB")
        return yaml.load(payload.decode("utf-8"), Loader=DeclarationLoader)
    except ConfigError:
        raise
    except (OSError, ValueError, yaml.YAMLError, RecursionError) as error:
        raise ConfigError(
            "cannot read configuration: check permissions and YAML syntax"
        ) from error
