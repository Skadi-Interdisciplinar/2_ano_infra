import importlib
import os

CANDIDATES = (
    "agente_ia.main",
    "agente_ia.app",
    "agente_ia.api",
    "agente_ia.server",
)


def resolve() -> str:
    for name in CANDIDATES:
        try:
            module = importlib.import_module(name)
        except ModuleNotFoundError:
            continue
        if getattr(module, "app", None) is not None:
            return f"{name}:app"
    raise SystemExit(
        "O pacote agente_ia foi instalado, mas nenhum modulo expoe a variavel app. "
        "Esperado um destes: agente_ia.main:app, agente_ia.app:app, agente_ia.api:app."
    )


if __name__ == "__main__":
    target = resolve()
    os.execvp(
        "uvicorn",
        ["uvicorn", target, "--host", "0.0.0.0", "--port", "8000"],
    )
