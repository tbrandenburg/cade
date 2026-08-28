"""Minimal example service used to prove the M3 workspace contract.

The goal is not the application logic itself, only that `make build` and
`make test` succeed unmodified inside a freshly provisioned workspace.
"""


def greeting(name: str = "world") -> str:
    """Return a friendly greeting for `name`."""
    if not name:
        raise ValueError("name must not be empty")
    return f"Hi, {name}!"


def main() -> None:
    print(greeting())


if __name__ == "__main__":
    main()
